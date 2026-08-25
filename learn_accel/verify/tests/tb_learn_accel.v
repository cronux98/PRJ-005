//---------------------------------------------------------------------
// tb_learn_accel.v — top-level acceptance test (VP-TOP-004, REQ-011)
// Project  : rinriAI (PRJ-005) — golden-model replay on the full DUT
// Language : pure Verilog-2001, iverilog -g2001 -Wall
// DUT      : learn_accel (tiny config 4x4x2), all 7 RTL blocks
// Golden   : inputs = arch/golden_model/stimulus.hex (shipped, correct);
//            expected = verify/golden/tiny_shipped_corrected/expected.hex
//            (C-model-regenerated — the shipped expected.hex has hand-
//            derivation errors, see verify/run-000/FINDINGS.md G-1).
// Checks   : per-sample PRED + counters vs golden, final weight dump vs
//            golden, in STEP mode and CONTINUOUS mode. This is the
//            bit-exactness gate (REQ-011): mismatch count must be 0.
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_learn_accel;
    localparam FEATURES = 4;
    localparam HIDDEN   = 4;
    localparam CLASSES  = 2;
    localparam W_TOT    = FEATURES*HIDDEN + HIDDEN + HIDDEN*CLASSES + CLASSES; // 30
    localparam N_SAMPLES = 5;
    localparam STIM_WORDS = W_TOT + N_SAMPLES*(FEATURES+1);   // 55
    localparam EXP_WORDS  = N_SAMPLES*5 + W_TOT;              // 55

    reg clk_core = 1'b0;
    reg rst_n    = 1'b0;

    // APB4
    reg        apb_psel = 0, apb_penable = 0, apb_pwrite = 0;
    reg  [31:0] apb_paddr = 0, apb_pwdata = 0;
    wire [31:0] apb_prdata;
    wire        apb_pready, apb_pslverr;

    // stream
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

    // ---------------------------------------------------------------
    initial begin
        $dumpfile("tb_learn_accel.vcd");
        $dumpvars(0, tb_learn_accel);

        $readmemh("arch/golden_model/stimulus.hex", stim);
        $readmemh("verify/golden/tiny_shipped_corrected/expected.hex", exp);

        tb_reset;

        // ---- VP-TOP-004: full learning flow, STEP mode ----------------
        $display("-- step mode --");
        golden_replay(1'b0, 1'b0, 4'd0);     // step, train, lr_shift=0

        // ---- VP-TOP-004 variant: CONTINUOUS mode -----------------------
        $display("-- continuous mode --");
        // reload weights (training mutated them), rerun continuously
        golden_replay(1'b1, 1'b0, 4'd0);     // continuous, train, lr_shift=0

        // ---- VP-TOP-005: inference-only (freeze=1) ---------------------
        $display("-- freeze mode --");
        // freeze expected: preds/counters/weights for an update-free run
        $readmemh("verify/golden/tiny_freeze/expected.hex", exp);
        golden_replay(1'b0, 1'b1, 4'd0);     // step, freeze=1

        test_summary("tb_learn_accel");
        $finish;
    end

    // Watchdog: tiny config ~3.5k cycles/sample; 100ms is huge headroom
    initial begin
        #100_000_000;
        $display("TEST FAILED: timeout tb_learn_accel");
        $finish;
    end
endmodule

`default_nettype wire
