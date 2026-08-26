//---------------------------------------------------------------------
// Module      : cnn_soc
// Project     : cnn_soc                Technology : FPGA-generic (NOT Sky130 — spec.md §2.1)
// Traces      : REQ-001, REQ-003, REQ-028, REQ-029, REQ-031, REQ-032
//               (+ SoC-level REQ-024/025/026/027 via the firmware contract)
// Description : Top-level integration — owns no state beyond wiring.
//               Instantiates BLK-002..BLK-012 per arch.md §4 BLK-001 /
//               block_diagram.mmd. picorv32_axi runs RV32I firmware from the
//               bootrom (executes in place, 0x0000_0000) over the
//               interconnect; SRAM (stack at 0x0003_0000), vec_rom (image/
//               label source), AXI2APB bridge to UART + GPIO, and the CNN
//               MMIO shell (cnn_axi_slave) around cnn_infer (single-shot by
//               reset-parking, REQ-023). Ties: pcpi_wr/rd/wait/ready = 0,
//               irq = 32'd0; eoi/trace_valid/trace_data/trap unconnected at
//               the top (the TB observes u_picorv32.trap hierarchically —
//               arch.md §12). Parameters re-exported so the TB can override
//               hex paths and UART_CLK_DIV (defaults are cnn_soc-root-
//               relative; PLAN.md R5 — the cnn `define defaults are correct
//               for the cnn root only, so every ROM path is overridden here).
//               NOTE: authored directly by the fe-rtl orchestrator (provider
//               session-limit fallback, AGENTS.md precedent 2026-08-20);
//               contract = arch.md §4 BLK-001 + §4 BLK-012 verbatim.
// Clock/Reset : clk (CD_CORE, 100 MHz) / rst_n (fully SYNCHRONOUS active-low —
//               passed through to picorv32.resetn and every slave; REQ-029)
// Assumptions : ASM-001 (min reset assert >= 2 cycles), ASM-002 (100.000 MHz);
//               single outstanding AXI transaction (CPU single-issue).
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module cnn_soc #(
    parameter UART_CLK_DIV     = 868,                                // REQ-021: round(100e6/115200); sim override e.g. 4
    parameter BOOT_HEX_FILE    = "sw/firmware.hex",                  // cnn_soc-root-relative (MEM-001)
    parameter IMAGES_HEX_FILE  = "../cnn/arch/golden_model/images.hex", // cnn_soc-root-relative (MEM-003)
    parameter LABELS_HEX_FILE  = "../cnn/arch/golden_model/labels.hex", // cnn_soc-root-relative (MEM-003)
    parameter WEIGHTS_HEX_FILE = "../cnn/arch/golden_model/weights.hex", // cnn_soc-root-relative (MEM-005)
    parameter LUT_HEX_FILE     = "../cnn/rtl/sigmoid_lut.hex"           // cnn_soc-root-relative (MEM-006)
) (
    input  wire        clk,        // core clock (CD_CORE, 100 MHz)
    input  wire        rst_n,      // fully synchronous active-low reset
    output wire        uart_tx,    // UART TX (BLK-013 via BLK-007)
    output wire [11:0] led         // LED output (BLK-008 GPIO_OUT)
);

    // ---- BLK-012 picorv32_axi <-> BLK-002 interconnect (IFI-004) ----
    wire        mem_axi_awvalid;
    wire        mem_axi_awready;
    wire [31:0] mem_axi_awaddr;
    wire [2:0]  mem_axi_awprot;
    wire        mem_axi_wvalid;
    wire        mem_axi_wready;
    wire [31:0] mem_axi_wdata;
    wire [3:0]  mem_axi_wstrb;
    wire        mem_axi_bvalid;
    wire        mem_axi_bready;
    wire        mem_axi_arvalid;
    wire        mem_axi_arready;
    wire [31:0] mem_axi_araddr;
    wire [2:0]  mem_axi_arprot;
    wire        mem_axi_rvalid;
    wire        mem_axi_rready;
    wire [31:0] mem_axi_rdata;

    // ---- BLK-002 -> slave ports (IFI-003, one set per slave) ----
    wire        boot_awvalid,  boot_awready;  wire [31:0] boot_awaddr; wire [2:0] boot_awprot;
    wire        boot_wvalid,   boot_wready;   wire [31:0] boot_wdata;  wire [3:0] boot_wstrb;
    wire        boot_bvalid,   boot_bready;
    wire        boot_arvalid,  boot_arready;  wire [31:0] boot_araddr; wire [2:0] boot_arprot;
    wire        boot_rvalid,   boot_rready;   wire [31:0] boot_rdata;

    wire        sram_awvalid,  sram_awready;  wire [31:0] sram_awaddr; wire [2:0] sram_awprot;
    wire        sram_wvalid,   sram_wready;   wire [31:0] sram_wdata;  wire [3:0] sram_wstrb;
    wire        sram_bvalid,   sram_bready;
    wire        sram_arvalid,  sram_arready;  wire [31:0] sram_araddr; wire [2:0] sram_arprot;
    wire        sram_rvalid,   sram_rready;   wire [31:0] sram_rdata;

    wire        vec_awvalid,   vec_awready;   wire [31:0] vec_awaddr;  wire [2:0] vec_awprot;
    wire        vec_wvalid,    vec_wready;    wire [31:0] vec_wdata;   wire [3:0] vec_wstrb;
    wire        vec_bvalid,    vec_bready;
    wire        vec_arvalid,   vec_arready;   wire [31:0] vec_araddr;  wire [2:0] vec_arprot;
    wire        vec_rvalid,    vec_rready;    wire [31:0] vec_rdata;

    wire        apb_awvalid,   apb_awready;   wire [31:0] apb_awaddr;  wire [2:0] apb_awprot;
    wire        apb_wvalid,    apb_wready;    wire [31:0] apb_wdata;   wire [3:0] apb_wstrb;
    wire        apb_bvalid,    apb_bready;
    wire        apb_arvalid,   apb_arready;   wire [31:0] apb_araddr;  wire [2:0] apb_arprot;
    wire        apb_rvalid,    apb_rready;    wire [31:0] apb_rdata;

    wire        cnn_awvalid,   cnn_awready;   wire [31:0] cnn_awaddr;  wire [2:0] cnn_awprot;
    wire        cnn_wvalid,    cnn_wready;    wire [31:0] cnn_wdata;   wire [3:0] cnn_wstrb;
    wire        cnn_bvalid,    cnn_bready;
    wire        cnn_arvalid,   cnn_arready;   wire [31:0] cnn_araddr;  wire [2:0] cnn_arprot;
    wire        cnn_rvalid,    cnn_rready;    wire [31:0] cnn_rdata;

    // ---- BLK-006 AXI2APB <-> BLK-007/008 APB bus (IFI-002) ----
    wire        psel_uart, psel_gpio, penable, pwrite;
    wire [11:0] paddr;
    wire [31:0] pwdata;
    wire [31:0] prdata_uart, prdata_gpio;
    wire        pready_uart, pready_gpio;

    // ---- BLK-009 <-> BLK-010 CNN core interface (IFI-001) ----
    wire        core_rst_n;
    wire [3:0]  exp_label;
    wire [9:0]  img_waddr;
    wire [7:0]  img_wdata;
    wire        img_we;
    wire [3:0]  pred;
    wire [6:0]  conf;
    wire [1:0]  verdict;
    wire        busy;
    wire        present;

    // ---- BLK-012 observation pins (unconnected at top; TB probes
    //      u_picorv32.trap hierarchically, arch.md §12) ----
    wire        trap, trace_valid;
    wire [31:0] eoi;            // picorv32_axi eoi is [31:0]
    wire [35:0] trace_data;
    wire        pcpi_valid;
    wire [31:0] pcpi_insn, pcpi_rs1, pcpi_rs2;

    // ==================================================================
    // BLK-012: RV32I CPU with built-in simplified AXI4-Lite master
    // (picorv32_axi, verbatim ip/picorv32.v). REQ-002 parameter set —
    // arch.md §4 BLK-012: all feature params 0, STACKADDR overridden.
    // ==================================================================
    picorv32_axi #(
        .PROGADDR_RESET  (32'h0000_0000),
        .STACKADDR       (32'h0003_0000),
        .ENABLE_MUL      (0),
        .ENABLE_DIV      (0),
        .ENABLE_FAST_MUL (0),
        .COMPRESSED_ISA  (0),
        .ENABLE_IRQ      (0),
        .ENABLE_COUNTERS (0),
        .ENABLE_COUNTERS64 (0),
        .CATCH_MISALIGN  (0),
        .CATCH_ILLINSN   (0),
        .ENABLE_PCPI     (0)
    ) u_picorv32 (
        .clk            (clk),
        .resetn         (rst_n),
        .trap           (trap),
        .mem_axi_awvalid(mem_axi_awvalid),
        .mem_axi_awready(mem_axi_awready),
        .mem_axi_awaddr (mem_axi_awaddr),
        .mem_axi_awprot (mem_axi_awprot),
        .mem_axi_wvalid (mem_axi_wvalid),
        .mem_axi_wready (mem_axi_wready),
        .mem_axi_wdata  (mem_axi_wdata),
        .mem_axi_wstrb  (mem_axi_wstrb),
        .mem_axi_bvalid (mem_axi_bvalid),
        .mem_axi_bready (mem_axi_bready),
        .mem_axi_arvalid(mem_axi_arvalid),
        .mem_axi_arready(mem_axi_arready),
        .mem_axi_araddr (mem_axi_araddr),
        .mem_axi_arprot (mem_axi_arprot),
        .mem_axi_rvalid (mem_axi_rvalid),
        .mem_axi_rready (mem_axi_rready),
        .mem_axi_rdata  (mem_axi_rdata),
        .pcpi_valid     (pcpi_valid),
        .pcpi_insn      (pcpi_insn),
        .pcpi_rs1       (pcpi_rs1),
        .pcpi_rs2       (pcpi_rs2),
        .pcpi_wr        (1'b0),
        .pcpi_rd        (32'd0),
        .pcpi_wait      (1'b0),
        .pcpi_ready     (1'b0),
        .irq            (32'd0),
        .eoi            (eoi),
        .trace_valid    (trace_valid),
        .trace_data     (trace_data)
    );

    // ==================================================================
    // BLK-002: combinational decode/forward + unmapped responder
    // ==================================================================
    axi_lite_interconnect u_axi_lite_interconnect (
        .clk            (clk),
        .rst_n          (rst_n),
        .mem_axi_awvalid(mem_axi_awvalid),
        .mem_axi_awready(mem_axi_awready),
        .mem_axi_awaddr (mem_axi_awaddr),
        .mem_axi_awprot (mem_axi_awprot),
        .mem_axi_wvalid (mem_axi_wvalid),
        .mem_axi_wready (mem_axi_wready),
        .mem_axi_wdata  (mem_axi_wdata),
        .mem_axi_wstrb  (mem_axi_wstrb),
        .mem_axi_bvalid (mem_axi_bvalid),
        .mem_axi_bready (mem_axi_bready),
        .mem_axi_arvalid(mem_axi_arvalid),
        .mem_axi_arready(mem_axi_arready),
        .mem_axi_araddr (mem_axi_araddr),
        .mem_axi_arprot (mem_axi_arprot),
        .mem_axi_rvalid (mem_axi_rvalid),
        .mem_axi_rready (mem_axi_rready),
        .mem_axi_rdata  (mem_axi_rdata),
        .boot_awvalid   (boot_awvalid),   .boot_awready   (boot_awready),
        .boot_awaddr    (boot_awaddr),    .boot_awprot    (boot_awprot),
        .boot_wvalid    (boot_wvalid),    .boot_wready    (boot_wready),
        .boot_wdata     (boot_wdata),     .boot_wstrb     (boot_wstrb),
        .boot_bvalid    (boot_bvalid),    .boot_bready    (boot_bready),
        .boot_arvalid   (boot_arvalid),   .boot_arready   (boot_arready),
        .boot_araddr    (boot_araddr),    .boot_arprot    (boot_arprot),
        .boot_rvalid    (boot_rvalid),    .boot_rready    (boot_rready),
        .boot_rdata     (boot_rdata),
        .sram_awvalid   (sram_awvalid),   .sram_awready   (sram_awready),
        .sram_awaddr    (sram_awaddr),    .sram_awprot    (sram_awprot),
        .sram_wvalid    (sram_wvalid),    .sram_wready    (sram_wready),
        .sram_wdata     (sram_wdata),     .sram_wstrb     (sram_wstrb),
        .sram_bvalid    (sram_bvalid),    .sram_bready    (sram_bready),
        .sram_arvalid   (sram_arvalid),   .sram_arready   (sram_arready),
        .sram_araddr    (sram_araddr),    .sram_arprot    (sram_arprot),
        .sram_rvalid    (sram_rvalid),    .sram_rready    (sram_rready),
        .sram_rdata     (sram_rdata),
        .vec_awvalid    (vec_awvalid),    .vec_awready    (vec_awready),
        .vec_awaddr     (vec_awaddr),     .vec_awprot     (vec_awprot),
        .vec_wvalid     (vec_wvalid),     .vec_wready     (vec_wready),
        .vec_wdata      (vec_wdata),      .vec_wstrb      (vec_wstrb),
        .vec_bvalid     (vec_bvalid),     .vec_bready     (vec_bready),
        .vec_arvalid    (vec_arvalid),    .vec_arready    (vec_arready),
        .vec_araddr     (vec_araddr),     .vec_arprot     (vec_arprot),
        .vec_rvalid     (vec_rvalid),     .vec_rready     (vec_rready),
        .vec_rdata      (vec_rdata),
        .apb_awvalid    (apb_awvalid),    .apb_awready    (apb_awready),
        .apb_awaddr     (apb_awaddr),     .apb_awprot     (apb_awprot),
        .apb_wvalid     (apb_wvalid),     .apb_wready     (apb_wready),
        .apb_wdata      (apb_wdata),      .apb_wstrb      (apb_wstrb),
        .apb_bvalid     (apb_bvalid),     .apb_bready     (apb_bready),
        .apb_arvalid    (apb_arvalid),    .apb_arready    (apb_arready),
        .apb_araddr     (apb_araddr),     .apb_arprot     (apb_arprot),
        .apb_rvalid     (apb_rvalid),     .apb_rready     (apb_rready),
        .apb_rdata      (apb_rdata),
        .cnn_awvalid    (cnn_awvalid),    .cnn_awready    (cnn_awready),
        .cnn_awaddr     (cnn_awaddr),     .cnn_awprot     (cnn_awprot),
        .cnn_wvalid     (cnn_wvalid),     .cnn_wready     (cnn_wready),
        .cnn_wdata      (cnn_wdata),      .cnn_wstrb      (cnn_wstrb),
        .cnn_bvalid     (cnn_bvalid),     .cnn_bready     (cnn_bready),
        .cnn_arvalid    (cnn_arvalid),    .cnn_arready    (cnn_arready),
        .cnn_araddr     (cnn_araddr),     .cnn_arprot     (cnn_arprot),
        .cnn_rvalid     (cnn_rvalid),     .cnn_rready     (cnn_rready),
        .cnn_rdata      (cnn_rdata)
    );

    // ==================================================================
    // BLK-003: bootrom (4 KB, firmware executes in place)
    // ==================================================================
    bootrom #(
        .BOOT_HEX_FILE (BOOT_HEX_FILE)
    ) u_bootrom (
        .clk        (clk),
        .rst_n      (rst_n),
        .boot_awvalid(boot_awvalid), .boot_awready(boot_awready),
        .boot_awaddr (boot_awaddr),  .boot_awprot (boot_awprot),
        .boot_wvalid (boot_wvalid),  .boot_wready (boot_wready),
        .boot_wdata  (boot_wdata),   .boot_wstrb  (boot_wstrb),
        .boot_bvalid (boot_bvalid),  .boot_bready (boot_bready),
        .boot_arvalid(boot_arvalid), .boot_arready(boot_arready),
        .boot_araddr (boot_araddr),  .boot_arprot (boot_arprot),
        .boot_rvalid (boot_rvalid),  .boot_rready (boot_rready),
        .boot_rdata  (boot_rdata)
    );

    // ==================================================================
    // BLK-004: SRAM (128 KB, stack at 0x0003_0000)
    // ==================================================================
    sram u_sram (
        .clk        (clk),
        .rst_n      (rst_n),
        .sram_awvalid(sram_awvalid), .sram_awready(sram_awready),
        .sram_awaddr (sram_awaddr),  .sram_awprot (sram_awprot),
        .sram_wvalid (sram_wvalid),  .sram_wready (sram_wready),
        .sram_wdata  (sram_wdata),   .sram_wstrb  (sram_wstrb),
        .sram_bvalid (sram_bvalid),  .sram_bready (sram_bready),
        .sram_arvalid(sram_arvalid), .sram_arready(sram_arready),
        .sram_araddr (sram_araddr),  .sram_arprot (sram_arprot),
        .sram_rvalid (sram_rvalid),  .sram_rready (sram_rready),
        .sram_rdata  (sram_rdata)
    );

    // ==================================================================
    // BLK-005: vec_rom (images + labels, frozen golden files)
    // ==================================================================
    vec_rom #(
        .IMAGES_HEX_FILE (IMAGES_HEX_FILE),
        .LABELS_HEX_FILE (LABELS_HEX_FILE)
    ) u_vec_rom (
        .clk        (clk),
        .rst_n      (rst_n),
        .vec_awvalid(vec_awvalid),  .vec_awready(vec_awready),
        .vec_awaddr (vec_awaddr),   .vec_awprot (vec_awprot),
        .vec_wvalid (vec_wvalid),   .vec_wready (vec_wready),
        .vec_wdata  (vec_wdata),    .vec_wstrb  (vec_wstrb),
        .vec_bvalid (vec_bvalid),   .vec_bready (vec_bready),
        .vec_arvalid(vec_arvalid),  .vec_arready(vec_arready),
        .vec_araddr (vec_araddr),   .vec_arprot (vec_arprot),
        .vec_rvalid (vec_rvalid),   .vec_rready (vec_rready),
        .vec_rdata  (vec_rdata)
    );

    // ==================================================================
    // BLK-006: AXI2APB bridge (UART + GPIO window)
    // ==================================================================
    axi2apb u_axi2apb (
        .clk        (clk),
        .rst_n      (rst_n),
        .apb_awvalid(apb_awvalid),  .apb_awready(apb_awready),
        .apb_awaddr (apb_awaddr),   .apb_awprot (apb_awprot),
        .apb_wvalid (apb_wvalid),   .apb_wready (apb_wready),
        .apb_wdata  (apb_wdata),    .apb_wstrb  (apb_wstrb),
        .apb_bvalid (apb_bvalid),   .apb_bready (apb_bready),
        .apb_arvalid(apb_arvalid),  .apb_arready(apb_arready),
        .apb_araddr (apb_araddr),   .apb_arprot (apb_arprot),
        .apb_rvalid (apb_rvalid),   .apb_rready (apb_rready),
        .apb_rdata  (apb_rdata),
        .psel_uart  (psel_uart),
        .psel_gpio  (psel_gpio),
        .penable    (penable),
        .pwrite     (pwrite),
        .paddr      (paddr),
        .pwdata     (pwdata),
        .prdata_uart(prdata_uart),
        .prdata_gpio(prdata_gpio),
        .pready_uart(pready_uart),
        .pready_gpio(pready_gpio)
    );

    // ==================================================================
    // BLK-007: APB UART shell over reused uart_tx (BLK-013)
    // ==================================================================
    apb_uart #(
        .UART_CLK_DIV (UART_CLK_DIV)
    ) u_apb_uart (
        .clk       (clk),
        .rst_n     (rst_n),
        .psel_uart (psel_uart),
        .penable   (penable),
        .pwrite    (pwrite),
        .paddr     (paddr),
        .pwdata    (pwdata),
        .prdata    (prdata_uart),
        .pready    (pready_uart),
        .uart_tx   (uart_tx)
    );

    // ==================================================================
    // BLK-008: APB GPIO (12-bit LED output)
    // ==================================================================
    apb_gpio u_apb_gpio (
        .clk     (clk),
        .rst_n   (rst_n),
        .psel    (psel_gpio),
        .penable (penable),
        .pwrite  (pwrite),
        .paddr   (paddr),
        .pwdata  (pwdata),
        .prdata  (prdata_gpio),
        .pready  (pready_gpio),
        .led     (led)
    );

    // ==================================================================
    // BLK-009: CNN MMIO shell + single-shot sequencer
    // ==================================================================
    cnn_axi_slave u_cnn_axi_slave (
        .clk         (clk),
        .rst_n       (rst_n),
        .cnn_awvalid (cnn_awvalid),  .cnn_awready (cnn_awready),
        .cnn_awaddr  (cnn_awaddr),   .cnn_awprot  (cnn_awprot),
        .cnn_wvalid  (cnn_wvalid),   .cnn_wready  (cnn_wready),
        .cnn_wdata   (cnn_wdata),    .cnn_wstrb   (cnn_wstrb),
        .cnn_bvalid  (cnn_bvalid),   .cnn_bready  (cnn_bready),
        .cnn_arvalid (cnn_arvalid),  .cnn_arready (cnn_arready),
        .cnn_araddr  (cnn_araddr),   .cnn_arprot  (cnn_arprot),
        .cnn_rvalid  (cnn_rvalid),   .cnn_rready  (cnn_rready),
        .cnn_rdata   (cnn_rdata),
        .core_rst_n  (core_rst_n),
        .exp_label   (exp_label),
        .img_waddr   (img_waddr),
        .img_wdata   (img_wdata),
        .img_we      (img_we),
        .pred        (pred),
        .conf        (conf),
        .verdict     (verdict),
        .busy        (busy),
        .present     (present)
    );

    // ==================================================================
    // BLK-010: rebuilt inference top (verified leaves + image_buffer).
    // Reset = core_rst_n from BLK-009 (park mechanism, REQ-023).
    // ==================================================================
    cnn_infer #(
        .WEIGHTS_HEX_FILE (WEIGHTS_HEX_FILE),
        .LUT_HEX_FILE     (LUT_HEX_FILE)
    ) u_cnn_infer (
        .clk        (clk),
        .rst_n      (core_rst_n),
        .exp_label  (exp_label),
        .img_waddr  (img_waddr),
        .img_wdata  (img_wdata),
        .img_we     (img_we),
        .pred       (pred),
        .conf       (conf),
        .verdict    (verdict),
        .busy       (busy),
        .present    (present)
    );

endmodule

`default_nettype wire
