//---------------------------------------------------------------------
// Module      : fpu_sigma256
// Project     : cnn_systolic        Technology : Sky130 130 nm
// Traces      : REQ-027, BLK-013; arch/piecewise_sigmoid.md §5
// Description : sigma256 = trunc(fp32_add(fp32_mul(σ,256.0),0.5)) —
//               COMBINATIONAL, mirrors golden_ref_model.c sigma256_of().
//               fp32_mul(σ,256.0) is EXACTLY {exp+8} (power of two; σ=±0
//               → ±0); the +0.5 and the truncate are exact FP32 steps
//               (σ ∈ [0,1] → σ·256+0.5 ∈ [0.5,256.5] exactly
//               representable).  Result 0..256 (9 bits).
// Clock/Reset : none (combinational)
// Assumptions : sigma ∈ [0,1] normal FP32 or ±0.
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module fpu_sigma256 (
    input  wire [31:0] sigma,
    output wire [8:0]  y
);

    wire [31:0] scaled = (sigma == 32'h00000000 || sigma == 32'h80000000)
                       ? sigma : {sigma[31], sigma[30:23] + 8'd8, sigma[22:0]};

    wire [31:0] t;
    fpu_fp32_add u_add (
        .a (scaled),
        .b (32'h3F000000),           // 0.5
        .y (t)
    );

    // trunc: e==0 → 0; m24 >> (150 - e) with bounds (golden).
    wire [7:0]  t_e   = t[30:23];
    wire [23:0] t_m24 = {1'b1, t[22:0]};
    wire signed [8:0] t_shift = 9'sd150 - $signed({1'b0, t_e});

    assign y = (t_e == 8'd0)   ? 9'd0
             : (t_shift <= 9'sd0)  ? 9'd0
             : (t_shift >= 9'sd24) ? 9'd0
             : t_m24 >> t_shift;

endmodule

`default_nettype wire
