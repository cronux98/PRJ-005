//---------------------------------------------------------------------
// Module      : weight_rom
// Project     : mnist_npu                Technology : FPGA-generic (Artix-7 100T / Nexys A7 target)
// Traces      : REQ-012, BLK-005
// Description : 25,450 x 16-bit signed ROM holding W1(784x32 row-major, addr
//               i*32+j) | b1(32, addr 25088+j) | W2(32x10 row-major, addr
//               25120+j*10+c) | b2(10, addr 25440+c). $readmemh-initialised
//               from the frozen golden weights.hex (arch.md §7 address map).
// Clock/Reset : clk (CD_CORE, 100 MHz nominal) / rst_n (SYNCHRONOUS active-low, no async)
// Assumptions : addr is always in [0,25449] by ctrl_fsm construction (arch.md §4 BLK-005).
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
`include "rtl/mnist_npu_defs.vh"

module weight_rom #(
    parameter WEIGHTS_HEX_FILE = `MNIST_NPU_WEIGHTS_HEX   // default: arch/golden_model/weights.hex
) (
    input  wire                clk,
    input  wire                rst_n,
    input  wire [14:0]         addr,      // 0..25449
    output reg  signed [15:0]  rdata      // registered, 1-cycle read latency
);
    reg signed [15:0] rom [0:25449];

    initial $readmemh(WEIGHTS_HEX_FILE, rom);

    // Synchronous reset per rtl_coding_guidelines.md §3 — SYNCHRONOUS ONLY, no negedge rst_n.
    always @(posedge clk) begin
        if (!rst_n) rdata <= 16'sd0;
        else        rdata <= rom[addr];
    end
endmodule

`default_nettype wire
