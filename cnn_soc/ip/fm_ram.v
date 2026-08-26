//---------------------------------------------------------------------
// Module      : fm_ram
// Project     : cnn (mnist_npu v2)      Technology : FPGA-generic (Artix-7 100T / Nexys A7 target)
// Traces      : REQ-006, REQ-007, REQ-009, REQ-012, REQ-023, BLK-008
// Description : Single 7,840 x 16-bit signed feature-map RAM, reused across
//               every inter-layer activation (conv1/pool1/conv2/pool2/FC1
//               outputs) via two fixed address regions — Region A
//               [0:6271], Region B [6272:7839] — per the hazard-free
//               ping-pong reuse proof in arch.md §7.1. Single R/W port;
//               ctrl_fsm's phase sequencing guarantees exactly one
//               operation (read OR write) per cycle, and never overwrites
//               data before its last consumer has read it (arch.md §7.1),
//               so no reset of RAM contents is needed.
// Clock/Reset : clk (CD_CORE, 100 MHz nominal) / rst_n (SYNCHRONOUS active-low, no async)
// Assumptions : addr always in [0,7839] by win_addr_gen construction.
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module fm_ram (
    input  wire                clk,
    input  wire                rst_n,
    input  wire [12:0]         addr,     // 0..7839 (Region A 0..6271, Region B 6272..7839)
    input  wire signed [15:0]  wdata,
    input  wire                we,
    output reg  signed [15:0]  rdata     // registered, 1-cycle read latency
);
    reg signed [15:0] ram [0:7839];

    always @(posedge clk) begin
        if (!rst_n) begin
            rdata <= 16'sd0;
        end else begin
            if (we) ram[addr] <= wdata;
            rdata <= ram[addr];
        end
    end
endmodule

`default_nettype wire
