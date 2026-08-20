//---------------------------------------------------------------------
// tb_stats.v — module gate for BLK-006 stats
// Project  : rinriAI (PRJ-005) — VP-STAT-001 (REQ-007, REQ-013, REQ-018,
//           REQ-019)
// Language : pure Verilog-2001, iverilog -g2001 -Wall
// DUT      : rtl/stats.v
// Coverage : reset values, one-per-sample increment, correct/error
//            mutual exclusion, N-sample run, saturation at 0xFFFFFFFF
//            (hierarchical preload), clr_stats clears counters + err but
//            not PRED, err sticky until clr_stats, PRED capture at
//            sample_done_p, clear-wins priority (documented).
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_stats;
    reg clk_core = 1'b0;
    reg rst_n    = 1'b0;

    reg        sample_done_p = 0, correct_p = 0, error_p = 0;
    reg        err_p = 0, clr_stats_p = 0;
    reg  [7:0] pred_i = 0;
    wire [31:0] sample_count, correct_count, error_count;
    wire        err;
    wire [7:0]  pred;

    integer errors = 0;

    stats dut (
        .clk_core (clk_core), .rst_n (rst_n),
        .sample_done_p (sample_done_p), .correct_p (correct_p),
        .error_p (error_p), .err_p (err_p), .clr_stats_p (clr_stats_p),
        .pred_i (pred_i), .sample_count (sample_count),
        .correct_count (correct_count), .error_count (error_count),
        .err (err), .pred (pred)
    );

    `include "tb_common/clk_rst.vh"
    `include "tb_common/checker.vh"

    // Pulse helpers (NBA-deasserted so the DUT samples them)
    task pulse;
        input [31:0] which;              // bit0=done, bit1=correct, bit2=error, bit3=err, bit4=clr
        begin
            sample_done_p <= which[0];
            correct_p     <= which[1];
            error_p       <= which[2];
            err_p         <= which[3];
            clr_stats_p   <= which[4];
            @(posedge clk_core);
            sample_done_p <= 1'b0;
            correct_p     <= 1'b0;
            error_p       <= 1'b0;
            err_p         <= 1'b0;
            clr_stats_p   <= 1'b0;
            @(posedge clk_core);         // settle
        end
    endtask

    // ---------------------------------------------------------------
    initial begin
        $dumpfile("tb_stats.vcd");
        $dumpvars(0, tb_stats);

        tb_reset;
        check_eq(sample_count,  32'h00000000, "sample_count reset");
        check_eq(correct_count, 32'h00000000, "correct_count reset");
        check_eq(error_count,   32'h00000000, "error_count reset");
        check_eq1(err, 1'b0, "err reset");
        check_eq(pred, 8'h00, "pred reset");

        // ---- 1. One sample, correct -----------------------------------
        pred_i = 8'h03;
        pulse(5'b00011);                 // done + correct
        check_eq(sample_count,  32'h00000001, "sample=1 after one correct");
        check_eq(correct_count, 32'h00000001, "correct=1");
        check_eq(error_count,   32'h00000000, "error=0");
        check_eq(pred, 8'h03, "pred captured");

        // ---- 2. One sample, error -------------------------------------
        pred_i = 8'h02;
        pulse(5'b00101);                 // done + error
        check_eq(sample_count, 32'h00000002, "sample=2");
        check_eq(correct_count, 32'h00000001, "correct stays 1");
        check_eq(error_count,  32'h00000001, "error=1");
        check_eq(pred, 8'h02, "pred updated");

        // ---- 3. done without correct/error: counters unchanged --------
        pulse(5'b00001);
        check_eq(sample_count,  32'h00000003, "sample=3");
        check_eq(correct_count, 32'h00000001, "correct unchanged");
        check_eq(error_count,   32'h00000001, "error unchanged");

        // ---- 4. correct AND error same cycle: independent ifs ---------
        pulse(5'b00111);                 // done + correct + error (illegal but defined)
        check_eq(sample_count,  32'h00000004, "sample=4");
        check_eq(correct_count, 32'h00000002, "correct incremented (independent if)");
        check_eq(error_count,   32'h00000002, "error incremented (independent if)");

        // ---- 5. err sticky ---------------------------------------------
        pulse(5'b01000);                 // err_p only
        check_eq1(err, 1'b1, "err sticky set");
        pulse(5'b00001);                 // sample while err set
        check_eq1(err, 1'b1, "err stays set across samples");
        check_eq(sample_count, 32'h00000005, "sample=5");

        // ---- 6. Saturation (hierarchical deposit near max) -------------
        dut.sample_count  = 32'hFFFFFFFE;   // deposit (not force: NBAs still work)
        dut.correct_count = 32'hFFFFFFFF;
        dut.error_count   = 32'hFFFFFFFE;
        pulse(5'b00011);                 // done + correct
        check_eq(sample_count,  32'hFFFFFFFF, "sample saturates at max");
        check_eq(correct_count, 32'hFFFFFFFF, "correct already max, no wrap");
        check_eq(error_count,   32'hFFFFFFFE, "error untouched (no error_p)");
        pulse(5'b00101);                 // done + error: error clamps at max
        check_eq(sample_count,  32'hFFFFFFFF, "sample still max (no wrap)");
        check_eq(error_count,   32'hFFFFFFFF, "error saturates at max");
        pulse(5'b10000);                 // clr_stats: back to zero
        check_eq(sample_count,  32'h00000000, "clr after saturation clears");
        check_eq(error_count,   32'h00000000, "clr after saturation clears error");
        pulse(5'b00001);                 // one sample after clear
        check_eq(sample_count,  32'h00000001, "sample=1 after saturation+clr");
        check_eq(error_count,   32'h00000000, "error=0 after saturation+clr");

        // ---- 7. clr_stats clears counters + err, not PRED ---------------
        pred_i = 8'h07;
        pulse(5'b10001);                 // clr + done same cycle: clear wins
        check_eq(sample_count,  32'h00000000, "clr clears sample (wins over done)");
        check_eq(correct_count, 32'h00000000, "clr clears correct");
        check_eq(error_count,   32'h00000000, "clr clears error");
        check_eq1(err, 1'b0, "clr clears err");
        check_eq(pred, 8'h07, "clr does NOT clear pred");
        // err re-set, then clr alone
        pulse(5'b01000);
        check_eq1(err, 1'b1, "err set again");
        pulse(5'b10000);
        check_eq1(err, 1'b0, "clr alone clears err");
        check_eq(pred, 8'h07, "pred survives clr alone");

        test_summary("tb_stats");
        $finish;
    end

    // Watchdog
    initial begin
        #1_000_000;
        $display("TEST FAILED: timeout tb_stats");
        $finish;
    end
endmodule

`default_nettype wire
