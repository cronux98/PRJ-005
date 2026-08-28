//---------------------------------------------------------------------
// Module      : fpu_sigmoid
// Project     : cnn_systolic        Technology : Sky130 130 nm
// Traces      : REQ-022, REQ-027, BLK-013; arch/piecewise_sigmoid.md
// Description : Piecewise sigmoid (COMBINATIONAL) — the pinned
//               activation σ(z): x=|z|; segment by FP32 compare against
//               the dyadic breakpoints {1/4..24} (unsigned bit compare,
//               both non-negative); σ = fp32_add(fp32_mul(m,x),c) with
//               the exact dyadic m/c bit patterns (piecewise_sigmoid.md
//               §2); z<0 → fp32_sub(1.0, σ).  Segment 13 (x ≥ 24,
//               saturation 251/256) flows through the same mul/add with
//               m=0, c=251/256 — bit-identical to the golden's direct
//               SIG_SAT (fmul(+0,x)=+0, fadd(+0,c)=c).  Mirrors
//               golden_ref_model.c sigmoid_piecewise() exactly.
// Clock/Reset : none (combinational)
// Assumptions : z finite normal FP32 or ±0 (range analysis).
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module fpu_sigmoid (
    input  wire [31:0] z,
    output wire [31:0] sigma
);

    wire [31:0] x = z & 32'h7FFFFFFF;      // |z| — exact (sign clear)

    // Breakpoints 1/4,1/2,3/4,1,3/2,2,3,4,6,8,12,16,24
    wire [31:0] BP [0:12];
    assign BP[0]  = 32'h3E800000;  assign BP[1]  = 32'h3F000000;
    assign BP[2]  = 32'h3F400000;  assign BP[3]  = 32'h3F800000;
    assign BP[4]  = 32'h3FC00000;  assign BP[5]  = 32'h40000000;
    assign BP[6]  = 32'h40400000;  assign BP[7]  = 32'h40800000;
    assign BP[8]  = 32'h40C00000;  assign BP[9]  = 32'h41000000;
    assign BP[10] = 32'h41400000;  assign BP[11] = 32'h41800000;
    assign BP[12] = 32'h41C00000;

    // Segment select: first BP[i] with x < BP[i] (i 0..11); 12 for
    // [16,24); 13 for x >= 24 (saturate).  All compares on the 31-bit
    // magnitude (BP < 2^31) — unsigned, golden-identical.
    wire [3:0] seg =
        (x[30:0] >= BP[12][30:0]) ? 4'd13
      : (x[30:0] <  BP[0][30:0])  ? 4'd0
      : (x[30:0] <  BP[1][30:0])  ? 4'd1
      : (x[30:0] <  BP[2][30:0])  ? 4'd2
      : (x[30:0] <  BP[3][30:0])  ? 4'd3
      : (x[30:0] <  BP[4][30:0])  ? 4'd4
      : (x[30:0] <  BP[5][30:0])  ? 4'd5
      : (x[30:0] <  BP[6][30:0])  ? 4'd6
      : (x[30:0] <  BP[7][30:0])  ? 4'd7
      : (x[30:0] <  BP[8][30:0])  ? 4'd8
      : (x[30:0] <  BP[9][30:0])  ? 4'd9
      : (x[30:0] <  BP[10][30:0]) ? 4'd10
      : (x[30:0] <  BP[11][30:0]) ? 4'd11
      : 4'd12;

    // Slopes SM (13/32,1/4,13/64,9/64,13/128,9/128,5/128,3/128,1/64,
    //            1/128,1/256,3/1024,1/1024, 0(sat)) — exact bit patterns.
    wire [31:0] SM [0:13];
    assign SM[0]  = 32'h3ED00000;  assign SM[1]  = 32'h3E800000;
    assign SM[2]  = 32'h3E500000;  assign SM[3]  = 32'h3E100000;
    assign SM[4]  = 32'h3DD00000;  assign SM[5]  = 32'h3D900000;
    assign SM[6]  = 32'h3D200000;  assign SM[7]  = 32'h3CC00000;
    assign SM[8]  = 32'h3C800000;  assign SM[9]  = 32'h3C000000;
    assign SM[10] = 32'h3B800000;  assign SM[11] = 32'h3B400000;
    assign SM[12] = 32'h3A800000;  assign SM[13] = 32'h00000000;

    // Intercepts SC (1/2,69/128,9/16,39/64,83/128,89/128,97/128,103/128,
    //               107/128,113/128,117/128,237/256,245/256,251/256).
    wire [31:0] SC [0:13];
    assign SC[0]  = 32'h3F000000;  assign SC[1]  = 32'h3F0A0000;
    assign SC[2]  = 32'h3F100000;  assign SC[3]  = 32'h3F1C0000;
    assign SC[4]  = 32'h3F260000;  assign SC[5]  = 32'h3F320000;
    assign SC[6]  = 32'h3F420000;  assign SC[7]  = 32'h3F4E0000;
    assign SC[8]  = 32'h3F560000;  assign SC[9]  = 32'h3F620000;
    assign SC[10] = 32'h3F6A0000;  assign SC[11] = 32'h3F6D0000;
    assign SC[12] = 32'h3F750000;  assign SC[13] = 32'h3F7B0000;

    wire [31:0] s_mul;
    wire [31:0] s_add;
    wire [31:0] s_fold;

    // sigma = fp32_add(fp32_mul(m, x), c) — MUL FIRST, then ADD (pinned).
    fpu_fp32_mul u_mul (
        .a (SM[seg]),
        .b (x),
        .y (s_mul)
    );
    fpu_fp32_add u_add (
        .a (s_mul),
        .b (SC[seg]),
        .y (s_add)
    );

    // Sign fold: z < 0 → fp32_sub(1.0, sigma) = fp32_add(1.0, sigma^sign).
    // (sign flip = XOR with 0x80000000 ONLY — {32{z[31]}} would invert all bits)
    fpu_fp32_add u_fold (
        .a (32'h3F800000),
        .b (s_add ^ {z[31], 31'd0}),
        .y (s_fold)
    );

    assign sigma = z[31] ? s_fold : s_add;

endmodule

`default_nettype wire
