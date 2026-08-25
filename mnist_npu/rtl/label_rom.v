//---------------------------------------------------------------------
// Module      : label_rom
// Project     : mnist_npu                Technology : FPGA-generic (Artix-7 100T / Nexys A7 target)
// Traces      : REQ-014, BLK-007
// Description : 100 x 8-bit unsigned ROM, addr = img_idx. $readmemh-
//               initialised from the frozen golden labels.hex.
// Clock/Reset : clk (CD_CORE, 100 MHz nominal) / rst_n (SYNCHRONOUS active-low, no async)
// Assumptions : addr is always in [0,99] by ctrl_fsm construction (arch.md §4 BLK-007).
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
`include "rtl/mnist_npu_defs.vh"

module label_rom #(
    parameter LABELS_HEX_FILE = `MNIST_NPU_LABELS_HEX   // default: arch/golden_model/labels.hex
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [6:0]  addr,      // 0..99
    output reg  [7:0]  rdata      // registered, 1-cycle read latency
);
    reg [7:0] rom [0:99];

    initial $readmemh(LABELS_HEX_FILE, rom);

    always @(posedge clk) begin
        if (!rst_n) rdata <= 8'd0;
        else        rdata <= rom[addr];
    end
endmodule

`default_nettype wire
