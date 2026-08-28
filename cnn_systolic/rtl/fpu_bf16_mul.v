//---------------------------------------------------------------------
// Module      : fpu_bf16_mul
// Project     : cnn_systolic        Technology : Sky130 130 nm
// Traces      : REQ-022, BLK-010, BLK-013; arch.md §5.1
// Description : BF16 × BF16 → FP32 multiply.  EXACT (no rounding): the
//               product of two 8-bit significands fits in 16 bits ≤ 24,
//               so the result is exactly representable in FP32 — the
//               golden's f32_mul rounds, but the rounding is a no-op
//               for MAC operands (systolic_dataflow.md §7). Bit-identical
//               to golden_ref_model.c f32_mul(bf16_to_f32(a),
//               bf16_to_f32(b)) — the exponent/keep derivation mirrors
//               the golden (e = ea+eb-126, keep = P<<8/9, msb 46/47).
//               Combinational, small (8×8 multiplier).
// Clock/Reset : none (combinational)
// Assumptions : operands are BF16 (16-bit sign/8-exp/7-mant patterns);
//               zero → ±0 (FTZ input, golden); NaN/Inf unreachable.
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module fpu_bf16_mul (
    input  wire [15:0] a,
    input  wire [15:0] b,
    output wire [31:0] y
);

    wire        sa = a[15];
    wire        sb = b[15];
    wire [7:0]  ea = a[14:7];
    wire [7:0]  eb = b[14:7];
    wire [6:0]  ka = a[6:0];
    wire [6:0]  kb = b[6:0];

    wire        sign    = sa ^ sb;
    wire        zero_in = (ea == 8'h00) || (eb == 8'h00);

    // P = (0x80|ka)(0x80|kb) ∈ [0x4000, 0xFE01] — 16-bit product.
    wire [15:0] P    = {1'b1, ka} * {1'b1, kb};
    wire        p_hi = P[15];                       // P >= 0x8000 → msb(m)=47

    // Golden: e = ea+eb-126; msb 46 (P<0x8000) → e -= 1, keep = P<<9;
    //         msb 47 → keep = P<<8.  (No rounding: exact product.)
    wire signed [9:0] e0 = $signed({2'b00, ea}) + $signed({2'b00, eb}) - 10'sd126;
    wire signed [9:0] e  = p_hi ? e0 : (e0 - 10'sd1);

    wire [23:0] keep = p_hi ? {P, 8'd0} : {1'b0, P[14:0], 9'd0};

    wire        ftz   = (e <= 10'sd0);
    wire        ovinf = (e >= 10'sd255);

    assign y = zero_in ? (sign ? 32'h80000000 : 32'h00000000)
             : ftz     ? (sign ? 32'h80000000 : 32'h00000000)
             : ovinf   ? (sign ? 32'hFF800000 : 32'h7F800000)
             : {sign, e[7:0], keep[22:0]};

endmodule

`default_nettype wire
