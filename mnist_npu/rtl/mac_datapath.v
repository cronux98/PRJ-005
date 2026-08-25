//---------------------------------------------------------------------
// Module      : mac_datapath
// Project     : mnist_npu                Technology : FPGA-generic (Artix-7 100T / Nexys A7 target)
// Traces      : REQ-002, REQ-003, REQ-004, REQ-005, REQ-008, REQ-028, REQ-029, BLK-003
// Description : Single shared 16x16->32-bit signed multiplier feeding one
//               shared 40-bit signed accumulator (REQ-028/029). Bit-exact to
//               golden_ref_model.c forward(): acc = (bias<<8) + sum(a*b),
//               z = saturate(acc>>>8, -32768, 32767). mac_a is always a
//               zero-extended unsigned byte/activation (pixel 0..255 or
//               hidden activation 1..255, REQ-003/007) treated as the
//               non-negative half of a signed 16-bit range — safe because
//               the true sign bit (bit 15) is always 0 for these operands.
//               mac_b is always a genuine signed Q8.8 weight/bias word.
//               Bias load: ctrl_fsm drives mac_a=0 on the bias-load cycle
//               (bias fetched as its own ROM read, distinct from the first
//               weight term — a single-port ROM cannot return two words in
//               one cycle) so `product`=0 and acc<=bias_q16_16 exactly.
// Clock/Reset : clk (CD_CORE, 100 MHz nominal) / rst_n (SYNCHRONOUS active-low, no async)
// Assumptions : ctrl_fsm never asserts mac_bias_ld and mac_acc_en in the same cycle.
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module mac_datapath (
    input  wire                clk,
    input  wire                rst_n,
    input  wire signed [15:0]  mac_a,        // pixel/hidden-activation operand, zero-extended (0 on bias-load cycle)
    input  wire signed [15:0]  mac_b,        // weight operand, Q8.8 signed
    input  wire                mac_bias_ld,  // 1 = acc <= (bias<<8, Q16.16) this cycle (mac_a forced 0 by ctrl_fsm)
    input  wire signed [15:0]  mac_bias,     // bias word, Q8.8 signed, valid when mac_bias_ld
    input  wire                mac_acc_en,   // 1 = acc <= acc + mac_a*mac_b this cycle
    output wire signed [15:0]  mac_z         // saturated z = acc>>>8, COMBINATIONAL from the
                                              // current acc (no extra pipeline stage — valid
                                              // immediately once acc holds its final value,
                                              // i.e. the cycle after the last accumulate step)
);
    reg  signed [39:0] acc;                  // REQ-028: >=40-bit signed accumulator
    wire signed [31:0] product;              // REQ-029: 16x16 -> 32-bit signed product
    wire signed [39:0] product_ext;          // sign-extended to 40 bits for the adder
    wire signed [39:0] bias_q16_16;          // bias, Q16.16-aligned, sign-extended to 40 bits
    wire signed [39:0] acc_shifted;          // acc >>> 8, arithmetic (pre-saturate)

    assign product     = mac_a * mac_b;
    assign product_ext = {{8{product[31]}}, product};
    assign bias_q16_16 = {{16{mac_bias[15]}}, mac_bias, 8'b0};
    assign acc_shifted = acc >>> 8;

    // z is purely combinational from acc — always the saturate of "acc as it
    // stands right now"; the caller (ctrl_fsm) only samples it once acc has
    // settled to a meaningful final value (ST_L1_ACT/ST_L2_ACT).
    assign mac_z = (acc_shifted >  40'sd32767) ?  16'sd32767 :
                   (acc_shifted < -40'sd32768) ? -16'sd32768 :
                                                  acc_shifted[15:0];

    // Sequential: SYNCHRONOUS reset only (rtl_coding_guidelines.md §3), non-blocking.
    always @(posedge clk) begin
        if (!rst_n) begin
            acc <= 40'sd0;
        end else begin
            if (mac_bias_ld)
                acc <= bias_q16_16 + product_ext;   // product_ext == 0 when mac_a==0
            else if (mac_acc_en)
                acc <= acc + product_ext;
        end
    end
endmodule

`default_nettype wire
