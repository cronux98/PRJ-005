//---------------------------------------------------------------------
// Module      : fpu_fp32_add
// Project     : cnn_systolic        Technology : Sky130 130 nm
// Traces      : REQ-022, BLK-010, BLK-013; arch.md §5.1
// Description : IEEE-754 FP32 add on bit patterns — RN-even, FTZ.
//               BIT-EXACT mirror of golden_ref_model.c f32_add()
//               (the FP32 accumulate contract): zero shortcuts
//               (x + ±0 = x; +0 + -0 = +0; exact zero → +0),
//               FTZ subnormal inputs, 27-bit GRS alignment, direction-
//               correct RN-even rounding (sticky breaks the midpoint
//               tie differently for add vs sub), FTZ subnormal results,
//               ±Inf on overflow (unreachable by range analysis).
//               Combinational. The accumulate ORDER is pinned by the
//               callers (systolic_dataflow.md §3-5) — never fuse/reorder.
// Clock/Reset : none (combinational)
// Assumptions : operands are finite normal FP32 (or ±0); NaN/±Inf
//               unreachable (range analysis, arch.md §5.1) — mirrored
//               defensively as ±Inf like the golden.
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module fpu_fp32_add (
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

    // FTZ inputs: subnormal mantissas (exp==0) are treated as 0.
    wire [22:0] ma_eff = (ea == 8'h00) ? 23'd0 : ma;
    wire [22:0] mb_eff = (eb == 8'h00) ? 23'd0 : mb;

    // NaN/Inf: unreachable; mirror the golden (±Inf).
    wire        naninf   = (ea == 8'hFF) || (eb == 8'hFF);
    wire        inf_sign = (ea == 8'hFF) ? sa : sb;

    // Zero shortcuts (golden order: both-zero → +0, then a==0 → b, b==0 → a).
    wire        both_zero = (ea == 8'h00) && (eb == 8'h00);
    wire        a_zero    = (ea == 8'h00);
    wire        b_zero    = (eb == 8'h00);

    wire        is_sub = (sa != sb);

    // 27-bit aligned significands (24-bit + 3 GRS), sticky S.
    wire [26:0] aq0 = {1'b1, ma_eff, 3'b000};
    wire [26:0] bq0 = {1'b1, mb_eff, 3'b000};

    // Ensure the a-operand (aq) has the larger exponent.
    wire        swap = (ea < eb);
    wire [26:0] aq   = swap ? bq0 : aq0;
    wire [26:0] bq   = swap ? aq0 : bq0;
    wire [7:0]  e    = swap ? eb   : ea;
    wire        saq  = swap ? sb   : sa;
    wire [7:0]  emin = swap ? ea   : eb;
    wire [7:0]  diff = e - emin;

    // Align bq right by diff, collecting a sticky bit.
    wire        big_diff = (diff >= 8'd27);
    wire [26:0] bq_sh    = big_diff ? 27'd0 : (bq >> diff);
    wire        S0       = big_diff ? 1'b1
                         : (diff == 8'd0) ? 1'b0
                         : (|(bq & ((27'd1 << diff) - 27'd1)));

    // Sum / difference (magnitude path) on the ALIGNED operands.
    wire [27:0] s_sum     = {1'b0, aq} + {1'b0, bq_sh};   // ≤ 2^28-2
    wire        s_sub_neg = (aq < bq_sh);
    wire [26:0] s_sub_abs = s_sub_neg ? (~aq + bq_sh + 27'd1) : (aq - bq_sh);
    wire        s_pos     = (aq > bq_sh);                // for diff==0 sub case
    wire        s_zero    = is_sub ? (aq == bq_sh) : 1'b0;

    // Result sign: same-sign add → common sign; opposite-sign add → sign of the
    // larger-magnitude operand (diff>0 → the aq operand; diff==0 → mantissa
    // comparison). NEVER the sign of the raw difference (golden sign-bug fix).
    wire        neg = is_sub ? ((diff != 8'd0) ? saq : (s_pos ? saq : sb)) : sa;

    wire [27:0] s_abs = is_sub ? {1'b0, s_sub_abs} : s_sum;

    // Normalize so the MSB sits at bit 26.
    wire [7:0]  msb;                                     // 0..27 (s_abs != 0)
    assign msb = (s_abs[27]) ? 8'd27 :
                 (s_abs[26]) ? 8'd26 :
                 (s_abs[25]) ? 8'd25 :
                 (s_abs[24]) ? 8'd24 :
                 (s_abs[23]) ? 8'd23 :
                 (s_abs[22]) ? 8'd22 :
                 (s_abs[21]) ? 8'd21 :
                 (s_abs[20]) ? 8'd20 :
                 (s_abs[19]) ? 8'd19 :
                 (s_abs[18]) ? 8'd18 :
                 (s_abs[17]) ? 8'd17 :
                 (s_abs[16]) ? 8'd16 :
                 (s_abs[15]) ? 8'd15 :
                 (s_abs[14]) ? 8'd14 :
                 (s_abs[13]) ? 8'd13 :
                 (s_abs[12]) ? 8'd12 :
                 (s_abs[11]) ? 8'd11 :
                 (s_abs[10]) ? 8'd10 :
                 (s_abs[9])  ? 8'd9  :
                 (s_abs[8])  ? 8'd8  :
                 (s_abs[7])  ? 8'd7  :
                 (s_abs[6])  ? 8'd6  :
                 (s_abs[5])  ? 8'd5  :
                 (s_abs[4])  ? 8'd4  :
                 (s_abs[3])  ? 8'd3  :
                 (s_abs[2])  ? 8'd2  :
                 (s_abs[1])  ? 8'd1  : 8'd0;

    // Right-shift case (msb > 26 → shift ≤ 1 for the add) / left-shift case.
    wire        shr       = (msb > 8'd26);
    wire [7:0]  shift_amt = shr ? (msb - 8'd26) : (8'd26 - msb);
    wire [27:0] s_norm    = shr ? (s_abs >> shift_amt) : (s_abs << shift_amt);
    wire signed [8:0] e_norm = shr
        ? ($signed({1'b0, e}) + $signed({1'b0, shift_amt}))
        : ($signed({1'b0, e}) - $signed({1'b0, shift_amt}));
    wire        S1        = S0 | (shr & s_abs[0]);

    // 24-bit mantissa candidate + GRS.
    wire [23:0] keep0 = s_norm[26:3];
    wire [2:0]  r     = s_norm[2:0];

    // RN-even with direction-correct sticky (r==4 midpoint: add rounds up when
    // sticky, sub rounds down when sticky; exact tie → round-half-even).
    wire        up    = (r >= 3'd5) ? 1'b1
                      : (r == 3'd4) ? (S1 ? (is_sub ? 1'b0 : 1'b1) : keep0[0])
                      : 1'b0;
    wire [24:0] keep1 = keep0 + up;
    wire [23:0] keep  = (keep1 == 25'h1000000) ? keep1[24:1] : keep1[23:0];
    wire signed [8:0] e_f = (keep1 == 25'h1000000) ? (e_norm + 9'sd1) : e_norm;

    // FTZ subnormal result (e <= 0) → ±0; overflow (unreachable) → ±Inf.
    wire        ftz   = (e_f <= 9'sd0);
    wire        ovinf = (e_f >= 9'sd255);

    assign y = naninf    ? (inf_sign ? 32'hFF800000 : 32'h7F800000)
             : both_zero ? 32'h00000000
             : a_zero    ? b
             : b_zero    ? a
             : s_zero    ? 32'h00000000
             : ftz       ? (neg ? 32'h80000000 : 32'h00000000)
             : ovinf     ? (neg ? 32'hFF800000 : 32'h7F800000)
             : {neg, e_f[7:0], keep[22:0]};

endmodule

`default_nettype wire
