//---------------------------------------------------------------------
// Module      : sigmoid_lut
// Project     : mnist_npu                Technology : FPGA-generic (Artix-7 100T / Nexys A7 target)
// Traces      : REQ-006, BLK-004
// Description : 65536 x 8-bit ROM implementing sigma(z) = 128 +
//               trunc(128*z/(256+|z|)) bit-exactly for every possible 16-bit
//               signed z (address = z's raw two's-complement bit pattern).
//               $readmemh-initialised from rtl/sigmoid_lut.hex, generated
//               deterministically by tools/gen_sigmoid_lut.py and verified
//               bit-exact against the golden formula by tools/check_lut.py
//               (must PASS 65536/65536 — project brief §5, non-negotiable).
//               NOT sourced from arch/golden_model/ — that directory holds
//               the network's golden vectors, not this LUT table (arch.md §4 BLK-004).
// Clock/Reset : clk (CD_CORE, 100 MHz nominal) / rst_n (SYNCHRONOUS active-low, no async)
// Assumptions : addr is the full 16-bit z bit pattern; always valid (ROM defined for all addresses).
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
`include "rtl/mnist_npu_defs.vh"

module sigmoid_lut #(
    parameter LUT_HEX_FILE = `MNIST_NPU_SIGMOID_LUT_HEX   // default: rtl/sigmoid_lut.hex
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [15:0]  addr,      // z, raw two's-complement bit pattern
    output reg  [7:0]   rdata      // registered, 1-cycle read latency
);
    reg [7:0] rom [0:65535];

    initial $readmemh(LUT_HEX_FILE, rom);

    always @(posedge clk) begin
        if (!rst_n) rdata <= 8'd0;
        else        rdata <= rom[addr];
    end
endmodule

`default_nettype wire
