//---------------------------------------------------------------------
// Module      : label_rom
// Project     : cnn (mnist_npu v2)      Technology : FPGA-generic (Artix-7 100T / Nexys A7 target)
// Traces      : REQ-021, BLK-007
// Description : 100 x 8-bit unsigned ROM, $readmemh-initialised from
//               arch/golden_model/labels.hex, providing the expected label
//               for each image index (REQ-016).
// Clock/Reset : clk (CD_CORE, 100 MHz nominal) / rst_n (SYNCHRONOUS active-low, no async)
// Assumptions : addr (img_idx) always in [0,99].
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
`include "rtl/cnn_defs.vh"

module label_rom #(
    parameter LABELS_HEX_FILE = `CNN_LABELS_HEX   // default: arch/golden_model/labels.hex
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [6:0]   addr,      // 0..99
    output reg  [7:0]   rdata      // registered, 1-cycle read latency
);
    reg [7:0] rom [0:99];

    initial $readmemh(LABELS_HEX_FILE, rom);

    always @(posedge clk) begin
        if (!rst_n) rdata <= 8'd0;
        else        rdata <= rom[addr];
    end
endmodule

`default_nettype wire
