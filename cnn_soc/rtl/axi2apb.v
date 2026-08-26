//---------------------------------------------------------------------
// Module      : axi2apb
// Project     : cnn_soc                Technology : FPGA-generic (NOT Sky130 — spec.md §2.1)
// Traces      : REQ-005, REQ-011, BLK-006
// Description : Converts one simplified-AXI transaction in window
//               0x4000_0000 into an APB access. Target decode is computed
//               from the FULL captured address: UART = 0x4000_0000..+0x0007
//               (awaddr[15:12]==0 && awaddr[11:0]<=7), GPIO =
//               0x4000_1000..+0x1003 (awaddr[15:12]==1 && awaddr[11:0]<=3);
//               any other offset is completed internally with PRDATA=0 and
//               PREADY (no PSLVERR — not in the APB subset, spec IF-004).
//               NOTE: the GPIO +0x1000 offset cannot be represented in
//               PADDR[11:0] (0x1000 needs bit 12), so the target is decoded
//               from awaddr[15:12]/[11:0] at the request-capture edge and
//               registered; PADDR[11:0] is the low 12 bits for the APB
//               targets (apb_uart decodes [3:0], apb_gpio ignores it).
//               Pinned accept policy: awready/wready/arready are asserted
//               only during the APB ACCESS phase, so the response is always
//               exactly 1 cycle after the bridge's accept cycle; write data
//               and address are stable from the picorv32_axi adapter while
//               mem_valid holds (single outstanding), so no buffering
//               (PLAN.md §7). Total request->response = 3 cycles.
//               Authored by the fe-rtl orchestrator (provider session-limit
//               fallback, AGENTS.md precedent 2026-08-20); contract =
//               arch.md §6.1 FSM-001 verbatim + the §4 BLK-006 decode
//               semantics implemented on the full address (see NOTE above —
//               gate-review fix, 2026-08-26).
// Clock/Reset : clk (CD_CORE, 100 MHz) / rst_n (fully SYNCHRONOUS active-low — no async)
// Assumptions : APB targets are zero-wait (pready always 1); the interconnect
//               only routes window 0x4000_0000..0x4FFF_FFFF here
//               (sel_apb = A[31:28]==4'h4), so [31:28] is not re-checked;
//               adapter keeps bready/rready high while a request is
//               outstanding (picorv32.v:2786-2787), so 1-cycle response
//               pulses are safe.
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module axi2apb (
    input  wire         clk,        // core clock (CD_CORE, 100 MHz)
    input  wire         rst_n,      // fully synchronous active-low reset
    // IFI-003 slave (apb_ prefix)
    input  wire         apb_awvalid,
    output reg          apb_awready,
    input  wire [31:0]  apb_awaddr,
    input  wire [2:0]   apb_awprot,
    input  wire         apb_wvalid,
    output reg          apb_wready,
    input  wire [31:0]  apb_wdata,
    input  wire [3:0]   apb_wstrb,
    output reg          apb_bvalid,
    input  wire         apb_bready,
    input  wire         apb_arvalid,
    output reg          apb_arready,
    input  wire [31:0]  apb_araddr,
    input  wire [2:0]   apb_arprot,
    output reg          apb_rvalid,
    input  wire         apb_rready,
    output reg  [31:0]  apb_rdata,
    // IFI-002 APB master (per-target selects; shared penable/pwrite/paddr/pwdata)
    output reg          psel_uart,
    output reg          psel_gpio,
    output reg          penable,
    output reg          pwrite,
    output reg  [11:0]  paddr,
    output wire [31:0]  pwdata,
    input  wire [31:0]  prdata_uart,
    input  wire [31:0]  prdata_gpio,
    input  wire         pready_uart,
    input  wire         pready_gpio
);

    // FSM-001 : axi2apb bridge (arch.md §6.1) — 4 states, reset = ST_IDLE
    // | State    | Condition                     | Next state | Registered actions this cycle                 |
    // | ST_IDLE  | awvalid && wvalid (write)     | ST_SETUP   | capture paddr<=awaddr[11:0], pwrite<=1,      |
    // |          |                               |            |   tgt_uart/tgt_gpio <= decode(awaddr)        |
    // | ST_IDLE  | arvalid (read)                | ST_SETUP   | capture paddr<=araddr[11:0], pwrite<=0,      |
    // |          |                               |            |   tgt_uart/tgt_gpio <= decode(araddr)        |
    // | ST_IDLE  | else                          | ST_IDLE    | —                                            |
    // | ST_SETUP | always                        | ST_ACCESS  | psel<=1 (registered target); penable<=0      |
    // | ST_ACCESS| pready (targets 0-wait)       | ST_RESP    | penable<=1; accept; prdata_r<=prdata         |
    // | ST_ACCESS| !pready                       | ST_ACCESS  | stay (never occurs; kept for completeness)   |
    // | ST_RESP  | always                        | ST_IDLE    | bvalid<=1 (wr) / rvalid<=1; rdata<=prdata_r  |
    // | (other)  | default:                      | ST_IDLE    | illegal-state recovery                       |
    localparam [1:0] ST_IDLE   = 2'd0;
    localparam [1:0] ST_SETUP  = 2'd1;
    localparam [1:0] ST_ACCESS = 2'd2;
    localparam [1:0] ST_RESP   = 2'd3;

    reg [1:0]  state;
    reg        tgt_uart;    // registered target select (from full address decode)
    reg        tgt_gpio;
    reg [31:0] prdata_r;    // read-data capture at the ACCESS edge

    // Combinational response muxes on the REGISTERED target; unmapped APB
    // offset -> PREADY with PRDATA=0 (bridge-side completion, no PSLVERR).
    wire        pready_eff = tgt_uart ? pready_uart : tgt_gpio ? pready_gpio : 1'b1;
    wire [31:0] prdata_eff = tgt_uart ? prdata_uart : tgt_gpio ? prdata_gpio : 32'd0;

    // No write-data buffering (PLAN.md §7): the adapter holds wdata stable
    // until wready (single outstanding), so PWData is a direct wire.
    assign pwdata = apb_wdata;

    always @(posedge clk) begin
        if (!rst_n) begin
            state       <= ST_IDLE;
            paddr       <= 12'd0;
            pwrite      <= 1'b0;
            tgt_uart    <= 1'b0;
            tgt_gpio    <= 1'b0;
            psel_uart   <= 1'b0;
            psel_gpio   <= 1'b0;
            penable     <= 1'b0;
            prdata_r    <= 32'd0;
            apb_awready <= 1'b0;
            apb_wready  <= 1'b0;
            apb_arready <= 1'b0;
            apb_bvalid  <= 1'b0;
            apb_rvalid  <= 1'b0;
            apb_rdata   <= 32'd0;
        end else begin
            // Default deassertions: one-cycle handshake pulses fall unless a
            // state below re-asserts them this edge (no latches).
            apb_awready <= 1'b0;
            apb_wready  <= 1'b0;
            apb_arready <= 1'b0;
            apb_bvalid  <= 1'b0;
            apb_rvalid  <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (apb_awvalid && apb_wvalid) begin
                        // Write request: capture address + direction + target,
                        // NO accept yet. GPIO's +0x1000 lives in [15:12], so
                        // the target decode uses the full address.
                        paddr    <= apb_awaddr[11:0];
                        pwrite   <= 1'b1;
                        tgt_uart <= (apb_awaddr[15:12] == 4'h0) && (apb_awaddr[11:0] <= 12'h7);
                        tgt_gpio <= (apb_awaddr[15:12] == 4'h1) && (apb_awaddr[11:0] <= 12'h3);
                        state    <= ST_SETUP;
                    end else if (apb_arvalid) begin
                        // Read request: capture address + direction + target.
                        paddr    <= apb_araddr[11:0];
                        pwrite   <= 1'b0;
                        tgt_uart <= (apb_araddr[15:12] == 4'h0) && (apb_araddr[11:0] <= 12'h7);
                        tgt_gpio <= (apb_araddr[15:12] == 4'h1) && (apb_araddr[11:0] <= 12'h3);
                        state    <= ST_SETUP;
                    end else begin
                        state <= ST_IDLE;
                    end
                end

                ST_SETUP: begin
                    // APB SETUP phase: select the captured target.
                    psel_uart <= tgt_uart;
                    psel_gpio <= tgt_gpio;
                    penable   <= 1'b0;
                    state     <= ST_ACCESS;
                end

                ST_ACCESS: begin
                    // APB ACCESS phase: accept and capture read data.
                    penable <= 1'b1;
                    if (pready_eff) begin
                        if (pwrite) begin
                            apb_awready <= 1'b1;
                            apb_wready  <= 1'b1;
                        end else begin
                            apb_arready <= 1'b1;
                            prdata_r    <= prdata_eff;
                        end
                        state <= ST_RESP;
                    end else begin
                        state <= ST_ACCESS;
                    end
                end

                ST_RESP: begin
                    // Exactly 1-cycle response (no BRESP/RRESP beyond the pulse;
                    // adapter keeps its ready high — picorv32.v:2786-2787).
                    if (pwrite) begin
                        apb_bvalid <= 1'b1;
                    end else begin
                        apb_rvalid <= 1'b1;
                        apb_rdata  <= prdata_r;
                    end
                    psel_uart <= 1'b0;
                    psel_gpio <= 1'b0;
                    penable   <= 1'b0;
                    state     <= ST_IDLE;
                end

                default: begin
                    // Illegal-state recovery.
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
