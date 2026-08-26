//---------------------------------------------------------------------
// Module      : axi_lite_interconnect
// Project     : cnn_soc                Technology : FPGA-generic (NOT Sky130 — spec.md §2.1)
// Traces      : REQ-005, REQ-006, REQ-007, REQ-030, BLK-002
// Description : Combinational address decode (spec §3.1 / arch.md §7.1) +
//               request forwarding + per-channel response mux (5:1 +
//               unmapped responder). Single outstanding transaction (CPU is
//               single-issue) -> no arbitration, no ID tracking (PLAN.md §2).
//               The unmapped responder is the FSM-002 pattern with read data
//               constant 0: unmapped read response accept+2, write accept+1
//               (same as memory slaves); unmapped -> read 0 / write ignored /
//               complete (REQ-006). Latency 0 cycles (combinational forward).
//               NOTE: authored directly by the fe-rtl orchestrator (provider
//               session-limit fallback, AGENTS.md precedent 2026-08-20);
//               contract = arch.md §4 BLK-002 + §7.1 + §6.2 verbatim.
// Clock/Reset : clk (CD_CORE, 100 MHz) / rst_n (fully SYNCHRONOUS active-low — no async;
//               only the unmapped responder is stateful)
// Assumptions : Exactly one transaction at a time (adapter holds mem_valid
//               until bvalid/rvalid); address/data buses are passed to ALL
//               slaves unconditionally and only valid/ready are gated by the
//               decode, so unselected slaves never accept (their awready stays
//               low because they see no request).
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module axi_lite_interconnect (
    input  wire         clk,        // core clock (CD_CORE, 100 MHz)
    input  wire         rst_n,      // fully synchronous active-low reset
    // Master-side IFI-003 (from BLK-012 picorv32_axi)
    input  wire         mem_axi_awvalid,
    output wire         mem_axi_awready,
    input  wire [31:0]  mem_axi_awaddr,
    input  wire [2:0]   mem_axi_awprot,
    input  wire         mem_axi_wvalid,
    output wire         mem_axi_wready,
    input  wire [31:0]  mem_axi_wdata,
    input  wire [3:0]   mem_axi_wstrb,
    output wire         mem_axi_bvalid,
    input  wire         mem_axi_bready,
    input  wire         mem_axi_arvalid,
    output wire         mem_axi_arready,
    input  wire [31:0]  mem_axi_araddr,
    input  wire [2:0]   mem_axi_arprot,
    output wire         mem_axi_rvalid,
    input  wire         mem_axi_rready,
    output wire [31:0]  mem_axi_rdata,
    // Slave-side IFI-003 x5 — boot_ (BLK-003), sram_ (BLK-004),
    // vec_ (BLK-005), apb_ (BLK-006), cnn_ (BLK-009).
    // Directions are from THIS module's viewpoint: requests/addresses/data
    // are forwarded OUT to the slaves; ready/response signals come IN.
    output wire         boot_awvalid,  input  wire boot_awready,
    output wire [31:0]  boot_awaddr,   output wire [2:0] boot_awprot,
    output wire         boot_wvalid,   input  wire boot_wready,
    output wire [31:0]  boot_wdata,    output wire [3:0] boot_wstrb,
    input  wire         boot_bvalid,   output wire boot_bready,
    output wire         boot_arvalid,  input  wire boot_arready,
    output wire [31:0]  boot_araddr,   output wire [2:0] boot_arprot,
    input  wire         boot_rvalid,   output wire boot_rready,
    input  wire [31:0]  boot_rdata,
    output wire         sram_awvalid,  input  wire sram_awready,
    output wire [31:0]  sram_awaddr,   output wire [2:0] sram_awprot,
    output wire         sram_wvalid,   input  wire sram_wready,
    output wire [31:0]  sram_wdata,    output wire [3:0] sram_wstrb,
    input  wire         sram_bvalid,   output wire sram_bready,
    output wire         sram_arvalid,  input  wire sram_arready,
    output wire [31:0]  sram_araddr,   output wire [2:0] sram_arprot,
    input  wire         sram_rvalid,   output wire sram_rready,
    input  wire [31:0]  sram_rdata,
    output wire         vec_awvalid,   input  wire vec_awready,
    output wire [31:0]  vec_awaddr,    output wire [2:0] vec_awprot,
    output wire         vec_wvalid,    input  wire vec_wready,
    output wire [31:0]  vec_wdata,     output wire [3:0] vec_wstrb,
    input  wire         vec_bvalid,    output wire vec_bready,
    output wire         vec_arvalid,   input  wire vec_arready,
    output wire [31:0]  vec_araddr,    output wire [2:0] vec_arprot,
    input  wire         vec_rvalid,    output wire vec_rready,
    input  wire [31:0]  vec_rdata,
    output wire         apb_awvalid,   input  wire apb_awready,
    output wire [31:0]  apb_awaddr,    output wire [2:0] apb_awprot,
    output wire         apb_wvalid,    input  wire apb_wready,
    output wire [31:0]  apb_wdata,     output wire [3:0] apb_wstrb,
    input  wire         apb_bvalid,    output wire apb_bready,
    output wire         apb_arvalid,   input  wire apb_arready,
    output wire [31:0]  apb_araddr,    output wire [2:0] apb_arprot,
    input  wire         apb_rvalid,    output wire apb_rready,
    input  wire [31:0]  apb_rdata,
    output wire         cnn_awvalid,   input  wire cnn_awready,
    output wire [31:0]  cnn_awaddr,    output wire [2:0] cnn_awprot,
    output wire         cnn_wvalid,    input  wire cnn_wready,
    output wire [31:0]  cnn_wdata,     output wire [3:0] cnn_wstrb,
    input  wire         cnn_bvalid,    output wire cnn_bready,
    output wire         cnn_arvalid,   input  wire cnn_arready,
    output wire [31:0]  cnn_araddr,    output wire [2:0] cnn_arprot,
    input  wire         cnn_rvalid,    output wire cnn_rready,
    input  wire [31:0]  cnn_rdata
);

    // Address decode (arch.md §7.1, spec §3.1) — write side uses awaddr,
    // read side uses araddr. One-hot; no aliasing; unmapped includes
    // 0x0000_1000..0x0000_FFFF, 0x0003_0000..0x0FFF_FFFF, windows 0x2/0x3/0x6..0xF.
    wire sel_boot_w = (mem_axi_awaddr[31:28] == 4'h0) && (mem_axi_awaddr[31:16] == 16'h0000) && (mem_axi_awaddr[15:12] == 4'h0);
    wire sel_sram_w = (mem_axi_awaddr[31:28] == 4'h0) && ((mem_axi_awaddr[31:16] == 16'h0001) || (mem_axi_awaddr[31:16] == 16'h0002));
    wire sel_vec_w  = (mem_axi_awaddr[31:28] == 4'h1);
    wire sel_apb_w  = (mem_axi_awaddr[31:28] == 4'h4);
    wire sel_cnn_w  = (mem_axi_awaddr[31:28] == 4'h5);
    wire sel_um_w   = !(sel_boot_w || sel_sram_w || sel_vec_w || sel_apb_w || sel_cnn_w);

    wire sel_boot_r = (mem_axi_araddr[31:28] == 4'h0) && (mem_axi_araddr[31:16] == 16'h0000) && (mem_axi_araddr[15:12] == 4'h0);
    wire sel_sram_r = (mem_axi_araddr[31:28] == 4'h0) && ((mem_axi_araddr[31:16] == 16'h0001) || (mem_axi_araddr[31:16] == 16'h0002));
    wire sel_vec_r  = (mem_axi_araddr[31:28] == 4'h1);
    wire sel_apb_r  = (mem_axi_araddr[31:28] == 4'h4);
    wire sel_cnn_r  = (mem_axi_araddr[31:28] == 4'h5);
    wire sel_um_r   = !(sel_boot_r || sel_sram_r || sel_vec_r || sel_apb_r || sel_cnn_r);

    // ---- Request forwarding (valid gated by decode) ----
    assign boot_awvalid = mem_axi_awvalid && sel_boot_w;
    assign sram_awvalid = mem_axi_awvalid && sel_sram_w;
    assign vec_awvalid  = mem_axi_awvalid && sel_vec_w;
    assign apb_awvalid  = mem_axi_awvalid && sel_apb_w;
    assign cnn_awvalid  = mem_axi_awvalid && sel_cnn_w;
    wire   um_awvalid   = mem_axi_awvalid && sel_um_w;

    assign boot_wvalid  = mem_axi_wvalid && sel_boot_w;
    assign sram_wvalid  = mem_axi_wvalid && sel_sram_w;
    assign vec_wvalid   = mem_axi_wvalid && sel_vec_w;
    assign apb_wvalid   = mem_axi_wvalid && sel_apb_w;
    assign cnn_wvalid   = mem_axi_wvalid && sel_cnn_w;
    wire   um_wvalid    = mem_axi_wvalid && sel_um_w;

    assign boot_arvalid = mem_axi_arvalid && sel_boot_r;
    assign sram_arvalid = mem_axi_arvalid && sel_sram_r;
    assign vec_arvalid  = mem_axi_arvalid && sel_vec_r;
    assign apb_arvalid  = mem_axi_arvalid && sel_apb_r;
    assign cnn_arvalid  = mem_axi_arvalid && sel_cnn_r;
    wire   um_arvalid   = mem_axi_arvalid && sel_um_r;

    // ---- Ready muxes back to the master ----
    assign mem_axi_awready = sel_boot_w ? boot_awready : sel_sram_w ? sram_awready :
                             sel_vec_w  ? vec_awready  : sel_apb_w  ? apb_awready :
                             sel_cnn_w  ? cnn_awready  : um_awready;
    assign mem_axi_wready  = sel_boot_w ? boot_wready  : sel_sram_w ? sram_wready :
                             sel_vec_w  ? vec_wready   : sel_apb_w  ? apb_wready :
                             sel_cnn_w  ? cnn_wready   : um_wready;
    assign mem_axi_arready = sel_boot_r ? boot_arready : sel_sram_r ? sram_arready :
                             sel_vec_r  ? vec_arready  : sel_apb_r  ? apb_arready :
                             sel_cnn_r  ? cnn_arready  : um_arready;

    // ---- Response muxes (b channel keyed on write decode, r on read decode) ----
    assign mem_axi_bvalid = sel_boot_w ? boot_bvalid : sel_sram_w ? sram_bvalid :
                            sel_vec_w  ? vec_bvalid  : sel_apb_w  ? apb_bvalid :
                            sel_cnn_w  ? cnn_bvalid  : um_bvalid;
    assign mem_axi_rvalid = sel_boot_r ? boot_rvalid : sel_sram_r ? sram_rvalid :
                            sel_vec_r  ? vec_rvalid  : sel_apb_r  ? apb_rvalid :
                            sel_cnn_r  ? cnn_rvalid  : um_rvalid;
    assign mem_axi_rdata  = sel_boot_r ? boot_rdata  : sel_sram_r ? sram_rdata :
                            sel_vec_r  ? vec_rdata   : sel_apb_r  ? apb_rdata :
                            sel_cnn_r  ? cnn_rdata   : 32'd0;   // unmapped reads return 0

    // ---- Address/data/protocol pass-through to every slave (unselected
    //      slaves see no valid, hence never accept) ----
    assign boot_awaddr = mem_axi_awaddr;  assign sram_awaddr = mem_axi_awaddr;
    assign vec_awaddr  = mem_axi_awaddr;  assign apb_awaddr  = mem_axi_awaddr;
    assign cnn_awaddr  = mem_axi_awaddr;
    assign boot_awprot = mem_axi_awprot;  assign sram_awprot = mem_axi_awprot;
    assign vec_awprot  = mem_axi_awprot;  assign apb_awprot  = mem_axi_awprot;
    assign cnn_awprot  = mem_axi_awprot;
    assign boot_wdata  = mem_axi_wdata;   assign sram_wdata  = mem_axi_wdata;
    assign vec_wdata   = mem_axi_wdata;   assign apb_wdata   = mem_axi_wdata;
    assign cnn_wdata   = mem_axi_wdata;
    assign boot_wstrb  = mem_axi_wstrb;   assign sram_wstrb  = mem_axi_wstrb;
    assign vec_wstrb   = mem_axi_wstrb;   assign apb_wstrb   = mem_axi_wstrb;
    assign cnn_wstrb   = mem_axi_wstrb;
    assign boot_araddr = mem_axi_araddr;  assign sram_araddr = mem_axi_araddr;
    assign vec_araddr  = mem_axi_araddr;  assign apb_araddr  = mem_axi_araddr;
    assign cnn_araddr  = mem_axi_araddr;
    assign boot_arprot = mem_axi_arprot;  assign sram_arprot = mem_axi_arprot;
    assign vec_arprot  = mem_axi_arprot;  assign apb_arprot  = mem_axi_arprot;
    assign cnn_arprot  = mem_axi_arprot;
    assign boot_bready = mem_axi_bready;  assign sram_bready = mem_axi_bready;
    assign vec_bready  = mem_axi_bready;  assign apb_bready  = mem_axi_bready;
    assign cnn_bready  = mem_axi_bready;
    assign boot_rready = mem_axi_rready;  assign sram_rready = mem_axi_rready;
    assign vec_rready  = mem_axi_rready;  assign apb_rready  = mem_axi_rready;
    assign cnn_rready  = mem_axi_rready;

    // ---- Unmapped responder: FSM-002 pattern, read data constant 0 ----
    // | State       | Condition             | Next state  | Registered actions this cycle |
    // | ST_IDLE     | um_awvalid && um_wvalid| ST_WRESP   | awready<=1; wready<=1 (write ignored) |
    // | ST_IDLE     | um_arvalid            | ST_RRESP    | arready<=1                     |
    // | ST_IDLE     | else                  | ST_IDLE     | —                             |
    // | ST_WRESP    | always                | ST_IDLE     | bvalid<=1 (exactly 1 cycle)   |
    // | ST_RRESP    | always                | ST_RRESP_DLY| —                             |
    // | ST_RRESP_DLY| always                | ST_IDLE     | rvalid<=1 (exactly 1 cycle)   |
    // | (other)     | default:              | ST_IDLE     | illegal-state recovery        |
    localparam [1:0] ST_IDLE      = 2'd0;
    localparam [1:0] ST_WRESP     = 2'd1;
    localparam [1:0] ST_RRESP     = 2'd2;
    localparam [1:0] ST_RRESP_DLY = 2'd3;

    reg [1:0] um_state;
    reg um_awready, um_wready, um_arready, um_bvalid, um_rvalid;

    always @(posedge clk) begin
        if (!rst_n) begin
            um_state    <= ST_IDLE;
            um_awready  <= 1'b0;
            um_wready   <= 1'b0;
            um_arready  <= 1'b0;
            um_bvalid   <= 1'b0;
            um_rvalid   <= 1'b0;
        end else begin
            // Default deassertions (no latches).
            um_awready <= 1'b0;
            um_wready  <= 1'b0;
            um_arready <= 1'b0;
            um_bvalid  <= 1'b0;
            um_rvalid  <= 1'b0;

            case (um_state)
                ST_IDLE: begin
                    if (um_awvalid && um_wvalid) begin
                        um_awready <= 1'b1;
                        um_wready  <= 1'b1;
                        um_state   <= ST_WRESP;
                    end else if (um_arvalid) begin
                        um_arready <= 1'b1;
                        um_state   <= ST_RRESP;
                    end else begin
                        um_state <= ST_IDLE;
                    end
                end
                ST_WRESP: begin
                    um_bvalid <= 1'b1;
                    um_state  <= ST_IDLE;
                end
                ST_RRESP: begin
                    um_state <= ST_RRESP_DLY;
                end
                ST_RRESP_DLY: begin
                    um_rvalid <= 1'b1;
                    um_state  <= ST_IDLE;
                end
                default: begin
                    um_state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
