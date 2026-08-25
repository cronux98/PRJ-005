//---------------------------------------------------------------------
// tb_top_lrsweep.v — learning-rate sweep (VP-TOP-011, REQ-005)
// Project  : rinriAI (PRJ-005)
// Language : pure Verilog-2001, iverilog -g2001 -Wall
// DUT      : learn_accel (tiny 4x4x2)
// Checks   : for lr_shift in {0,1,2,4,8,15}, same shipped samples +
//            init weights: per-sample PRED/counters + final weight dump
//            must match the golden model for THAT lr_shift bit-exactly
//            (weight deltas scale exactly 2^-lr_shift). Vectors:
//            verify/golden/tiny_lr<ls>/{stimulus,expected}.hex
//            (stimulus identical across lr — the expected differs).
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_top_lrsweep;
    localparam FEATURES = 4, HIDDEN = 4, CLASSES = 2;
    localparam W_TOT = FEATURES*HIDDEN + HIDDEN + HIDDEN*CLASSES + CLASSES;
    localparam N_SAMPLES = 5;
    localparam STIM_WORDS = W_TOT + N_SAMPLES*(FEATURES+1);
    localparam EXP_WORDS  = N_SAMPLES*5 + W_TOT;

    reg clk_core = 1'b0;
    reg rst_n    = 1'b0;
    reg        apb_psel = 0, apb_penable = 0, apb_pwrite = 0;
    reg  [31:0] apb_paddr = 0, apb_pwdata = 0;
    wire [31:0] apb_prdata;
    wire        apb_pready, apb_pslverr;
    reg        s_valid = 0, s_last = 0;
    reg  [7:0] s_data = 0;
    wire       s_ready;

    integer errors = 0;
    reg [31:0] stim [0:STIM_WORDS-1];
    reg [31:0] exp  [0:EXP_WORDS-1];
    reg [31:0] rd;

    learn_accel #(.FEATURES(FEATURES), .HIDDEN(HIDDEN), .CLASSES(CLASSES)) dut (
        .clk_core (clk_core), .rst_n (rst_n),
        .psel (apb_psel), .penable (apb_penable), .pwrite (apb_pwrite),
        .paddr (apb_paddr), .pwdata (apb_pwdata), .prdata (apb_prdata),
        .pready (apb_pready), .pslverr (apb_pslverr),
        .s_valid (s_valid), .s_ready (s_ready), .s_data (s_data), .s_last (s_last)
    );

    `include "tb_common/clk_rst.vh"
    `include "tb_common/checker.vh"
    `include "tb_common/apb4_bfm.vh"
    `include "tb_common/stream_byte.vh"
    `include "tb_common/golden_replay.vh"

    integer ls;

    // ---------------------------------------------------------------
    initial begin
        $dumpfile("tb_top_lrsweep.vcd");
        $dumpvars(0, tb_top_lrsweep);

        $readmemh("arch/golden_model/stimulus.hex", stim);   // same inputs all lr

        tb_reset;

        for (ls = 0; ls <= 15; ls = ls + 1) begin
            if (ls == 3 || ls == 5 || ls == 6 || ls == 7 || (ls >= 9 && ls <= 14)) begin
                // skip: sweep set is {0,1,2,4,8,15} per VP-TOP-011
            end else begin
                case (ls)
                    0:  $readmemh("verify/golden/tiny_lr0/expected.hex", exp);
                    1:  $readmemh("verify/golden/tiny_lr1/expected.hex", exp);
                    2:  $readmemh("verify/golden/tiny_lr2/expected.hex", exp);
                    4:  $readmemh("verify/golden/tiny_lr4/expected.hex", exp);
                    8:  $readmemh("verify/golden/tiny_lr8/expected.hex", exp);
                    15: $readmemh("verify/golden/tiny_lr15/expected.hex", exp);
                endcase
                golden_replay(1'b0, 1'b0, ls[3:0]);
                $display("-- lr_shift=%0d replay done (errors=%0d) --", ls, errors);
            end
        end

        test_summary("tb_top_lrsweep");
        $finish;
    end

    initial begin #120_000_000; $display("TEST FAILED: timeout tb_top_lrsweep"); $finish; end
endmodule

`default_nettype wire
