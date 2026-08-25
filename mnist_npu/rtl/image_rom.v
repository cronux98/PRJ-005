//---------------------------------------------------------------------
// Module      : image_rom
// Project     : mnist_npu                Technology : FPGA-generic (Artix-7 100T / Nexys A7 target)
// Traces      : REQ-013, BLK-006
// Description : 78,400 x 8-bit unsigned ROM (100 images x 784 pixels),
//               addr = img_idx*784+i. $readmemh-initialised from the frozen
//               golden images.hex.
// Clock/Reset : clk (CD_CORE, 100 MHz nominal) / rst_n (SYNCHRONOUS active-low, no async)
// Assumptions : addr is always in [0,78399] by ctrl_fsm construction (arch.md §4 BLK-006).
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
`include "rtl/mnist_npu_defs.vh"

module image_rom #(
    parameter IMAGES_HEX_FILE = `MNIST_NPU_IMAGES_HEX   // default: arch/golden_model/images.hex
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [16:0]  addr,      // 0..78399
    output reg  [7:0]   rdata      // registered, 1-cycle read latency
);
    reg [7:0] rom [0:78399];

    initial $readmemh(IMAGES_HEX_FILE, rom);

    always @(posedge clk) begin
        if (!rst_n) rdata <= 8'd0;
        else        rdata <= rom[addr];
    end
endmodule

`default_nettype wire
