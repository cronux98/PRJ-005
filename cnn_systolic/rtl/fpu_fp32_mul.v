//---------------------------------------------------------------------
// Module      : fpu_fp32_mul
// Project     : cnn_systolic        Technology : Sky130 130 nm
// Traces      : REQ-022, BLK-013; arch.md §5.1
// Description : IEEE-754 FP32 multiply on bit patterns — RN-even, FTZ.
//               BIT-EXACT mirror of golden_ref_model.c f32_mul()
//               (used by the piecewise sigmoid scale step
//               sigma = fadd(fmul(m,x),c) — m/x are general FP32, so
//               the full 24×24 path is required here).
//               Combinational.  BF16×BF16 MAC operands never use this
//               unit (they are exact in fpu_bf16_mul).
// Clock/Reset : none (combinational)
// Assumptions : finite normal FP32 or ±0; NaN/±Inf unreachable (range
//               analysis) — mirrored as ±Inf like the golden.
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module fpu_fp32_mul (
    input  wire [31:0] a,
    input  wire [31:0] b,
    output wire [31:0] y
);

    wire        sa = a[31];
    wire        sb = b[31];
    wire [7:0]  ea = a[30:23];
    wire [7:0]  eb = b[30:23];
    wire [22:0] ma = a[22:0];
    wire [22:0] mb = b[22:0];

    // FTZ inputs: subnormal mantissas treated as 0.
    wire [22:0] ma_eff = (ea == 8'h00) ? 23'd0 : ma;
    wire [22:0] mb_eff = (eb == 8'h00) ? 23'd0 : mb;

    wire        naninf   = (ea == 8'hFF) || (eb == 8'hFF);
    wire        zero_in  = (ea == 8'h00) || (eb == 8'h00);
    wire        sign     = sa ^ sb;

    // e = ea + eb - 126 (golden); signed 10-bit for the FTZ/overflow checks.
    wire signed [9:0] e0 = $signed({2'b00, ea}) + $signed({2'b00, eb}) - 10'sd126;

    // 24×24 significand product (48 bits); MSB is 46 or 47.
    wire [47:0] m  = {1'b1, ma_eff} * {1'b1, mb_eff};
    wire        hi = m[47];

    wire [47:0] m_n = hi ? m : (m << 1);
    wire signed [9:0] e_n = hi ? e0 : (e0 - 10'sd1);

    wire [23:0] keep0 = m_n[47:24];
    wire [23:0] r     = m_n[23:0];

    // RN-even at the 24-bit boundary.
    wire        up    = (r > 24'h800000) || ((r == 24'h800000) && keep0[0]);
    wire [24:0] keep1 = keep0 + up;
    wire [23:0] keep  = (keep1 == 25'h1000000) ? keep1[24:1] : keep1[23:0];
    wire signed [9:0] e = (keep1 == 25'h1000000) ? (e_n + 10'sd1) : e_n;

    wire        ftz   = (e <= 10'sd0);
    wire        ovinf = (e >= 10'sd255);

    assign y = naninf  ? (sign ? 32'hFF800000 : 32'h7F800000)
             : zero_in ? (sign ? 32'h80000000 : 32'h00000000)
             : ftz     ? (sign ? 32'h80000000 : 32'h00000000)
             : ovinf   ? (sign ? 32'hFF800000 : 32'h7F800000)
             : {sign, e[7:0], keep[22:0]};

endmodule

`default_nettype wire
