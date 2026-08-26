//---------------------------------------------------------------------
// Module      : weight_rom
// Project     : cnn (mnist_npu v2)      Technology : FPGA-generic (Artix-7 100T / Nexys A7 target)
// Traces      : REQ-013, REQ-019, BLK-005
// Description : 26,698 x 16-bit signed ROM holding conv1_w(72,addr 0)|
//               conv1_b(8,addr 72)|conv2_w(1152,addr 80)|conv2_b(16,addr
//               1232)|fc1_w(25088,addr 1248)|fc1_b(32,addr 26336)|
//               fc2_w(320,addr 26368)|fc2_b(10,addr 26688). $readmemh
//               -initialised from the frozen golden weights.hex (arch.md
//               §7 address map / spec.md §3 region table).
// Clock/Reset : clk (CD_CORE, 100 MHz nominal) / rst_n (SYNCHRONOUS active-low, no async)
// Assumptions : addr always in [0,26697] by win_addr_gen construction (arch.md §4 BLK-005).
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
`include "rtl/cnn_defs.vh"

module weight_rom #(
    parameter WEIGHTS_HEX_FILE = `CNN_WEIGHTS_HEX   // default: arch/golden_model/weights.hex
) (
    input  wire                clk,
    input  wire                rst_n,
    input  wire [14:0]         addr,      // 0..26697
    output reg  signed [15:0]  rdata      // registered, 1-cycle read latency
);
    reg signed [15:0] rom [0:26697];

    initial $readmemh(WEIGHTS_HEX_FILE, rom);

    // Synchronous reset per rtl_coding_guidelines.md §3 — SYNCHRONOUS ONLY, no negedge rst_n.
    always @(posedge clk) begin
        if (!rst_n) rdata <= 16'sd0;
        else        rdata <= rom[addr];
    end
endmodule

`default_nettype wire
