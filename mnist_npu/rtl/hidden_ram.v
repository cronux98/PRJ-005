//---------------------------------------------------------------------
// Module      : hidden_ram
// Project     : mnist_npu                Technology : FPGA-generic (Artix-7 100T / Nexys A7 target)
// Traces      : REQ-007, BLK-008
// Description : 32 x 16-bit RAM holding hidden-layer activations h[0..31]
//               (LUT sigma output, range 1..255, zero-extended) between
//               layer-1 write and layer-2 read. Single R/W port; ctrl_fsm
//               always writes every entry (layer 1) before reading any of
//               them (layer 2) in the same image pass — no reset needed for
//               contents (arch.md §4 BLK-008).
// Clock/Reset : clk (CD_CORE, 100 MHz nominal) / rst_n (SYNCHRONOUS active-low, no async)
// Assumptions : addr always in [0,31] by ctrl_fsm construction.
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module hidden_ram (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [4:0]   addr,     // 0..31
    input  wire [15:0]  wdata,
    input  wire         we,
    output reg  [15:0]  rdata     // registered, 1-cycle read latency
);
    reg [15:0] ram [0:31];

    always @(posedge clk) begin
        if (!rst_n) begin
            rdata <= 16'd0;
        end else begin
            if (we) ram[addr] <= wdata;
            rdata <= ram[addr];
        end
    end
endmodule

`default_nettype wire
