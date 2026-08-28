//---------------------------------------------------------------------
// Module      : fpu_bf16_expand
// Project     : cnn_systolic        Technology : Sky130 130 nm
// Traces      : REQ-022; arch.md §5.1
// Description : BF16 → FP32 exact expansion: {s, e, keep, 16'b0}.
//               Combinational, wires only.
// Clock/Reset : none (combinational)
// Assumptions : —
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module fpu_bf16_expand (
    input  wire [15:0] a,
    output wire [31:0] y
);

    assign y = {a[15], a[14:7], a[6:0], 16'd0};

endmodule

`default_nettype wire
