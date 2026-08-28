//---------------------------------------------------------------------
// Module      : fpu_bf16_round
// Project     : cnn_systolic        Technology : Sky130 130 nm
// Traces      : REQ-022, BLK-011, BLK-013; arch.md §5.1
// Description : FP32 → BF16 conversion, RN-even, FTZ — BIT-EXACT mirror
//               of golden_ref_model.c bf16_round(): keep top 7 mantissa
//               bits, round bit = mant[15], sticky = |mant[14:0]|,
//               round iff r && (S || keep[0]); mantissa overflow →
//               exp+1; subnormal/zero input → ±0 (sign kept).
//               Combinational.
// Clock/Reset : none (combinational)
// Assumptions : finite normal FP32 or ±0; NaN/±Inf unreachable.
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module fpu_bf16_round (
    input  wire [31:0] a,
    output wire [15:0] y
);

    wire        sa  = a[31];
    wire [7:0]  ea  = a[30:23];
    wire [22:0] ma  = a[22:0];

    wire [6:0]  keep0 = ma[22:16];
    wire        r     = ma[15];
    wire        S     = |ma[14:0];

    wire [7:0]  keep1 = {1'b0, keep0} + {7'd0, (r && (S || keep0[0]))};
    wire        ovf   = (keep1 == 8'h80);
    wire [6:0]  keep  = ovf ? 7'd0 : keep1[6:0];
    wire [7:0]  ea1   = ovf ? (ea + 8'd1) : ea;
    wire        ovinf = (ea1 >= 8'hFF);

    assign y = (ea == 8'h00) ? {sa, 15'd0}
             : ovinf         ? {sa, 8'hFF, 7'd0}
             : {sa, ea1, keep};

endmodule

`default_nettype wire
