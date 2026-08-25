//---------------------------------------------------------------------
// Module      : stats
// Project     : rinriAI   Technology : Sky130 130 nm
// Traces      : REQ-007, REQ-013, REQ-018, REQ-019
// Description : SAMPLE/CORRECT/ERROR saturating counters, sticky err flag,
//               and PRED (last predicted class) register. BLK-006.
// Clock/Reset : clk_core (CD_CORE) / rst_n (synchronous, active low)
// Assumptions : sample_done_p/correct_p/error_p are 1-cycle pulses from the
//               learner DONE state (FSM-001); correct_p and error_p are
//               mutually exclusive by construction. err_p is a 1-cycle pulse
//               from BLK-003 (malformed sample). clr_stats_p is a 1-cycle
//               pulse from BLK-002 CSR. pred_i is stable at the sample_done_p
//               edge (learner DONE emission). clr_stats_p and sample_done_p
//               cannot fire together by construction; if they ever do, clear
//               wins (arch.md 4.6).
// Source      : custom (no external IP)
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none                     // catch typo'd implicit wires

module stats (
    input  wire        clk_core,          // core clock
    input  wire        rst_n,             // synchronous active-low reset (ASM-002)
    input  wire        sample_done_p,     // 1-cycle pulse: one per processed sample
    input  wire        correct_p,         // 1-cycle pulse: pred == label
    input  wire        error_p,           // 1-cycle pulse: pred != label
    input  wire        err_p,             // 1-cycle pulse: malformed sample (sticky)
    input  wire        clr_stats_p,       // 1-cycle pulse: clear counters + err (not pred)
    input  wire [7:0]  pred_i,            // level: last predicted class from BLK-004
    output reg  [31:0] sample_count,      // saturating sample counter
    output reg  [31:0] correct_count,     // saturating correct-prediction counter
    output reg  [31:0] error_count,       // saturating wrong-prediction counter
    output reg         err,               // sticky malformed-sample flag (STATUS[2])
    output reg  [7:0]  pred               // last predicted class register (PRED)
);

    // Single sequential block; synchronous active-low reset per rtl_coding_guidelines
    // section 3 (ASM-002). Non-blocking assignments only. Every reg driven from here
    // and nowhere else (single-driver discipline).
    always @(posedge clk_core) begin
        if (!rst_n) begin
            // Reset behaviour: all outputs 0 (arch.md 4.6)
            sample_count  <= 32'd0;
            correct_count <= 32'd0;
            error_count   <= 32'd0;
            err           <= 1'b0;
            pred          <= 8'd0;
        end else begin
            // clr_stats_p has priority over the sample path. Simultaneous
            // clr_stats_p and sample_done_p is impossible by construction; if it
            // ever occurs, clear wins (arch.md 4.6). pred is NOT cleared here.
            if (clr_stats_p) begin
                sample_count  <= 32'd0;
                correct_count <= 32'd0;
                error_count   <= 32'd0;
                err           <= 1'b0;
            end else begin
                if (sample_done_p) begin
                    // Saturate at 0xFFFFFFFF: compare-before-increment, no wrap
                    if (sample_count != 32'hFFFFFFFF)
                        sample_count <= sample_count + 32'd1;
                    // Independent ifs so each counter only counts its own pulse
                    // (correct_p / error_p mutually exclusive by construction)
                    if (correct_p && (correct_count != 32'hFFFFFFFF))
                        correct_count <= correct_count + 32'd1;
                    if (error_p && (error_count != 32'hFFFFFFFF))
                        error_count <= error_count + 32'd1;
                end
                // Sticky err: set on malformed-sample pulse; only clr_stats_p
                // (handled in the branch above, which takes priority) clears it
                if (err_p)
                    err <= 1'b1;
            end
            // pred samples the level at the sample_done_p edge; never cleared by
            // clr_stats_p (arch.md 4.6). Independent of the clr/sample priority
            // branch because clr does not touch pred and the two cannot coincide.
            if (sample_done_p)
                pred <= pred_i;
        end
    end

endmodule

`default_nettype wire                     // restore default for downstream tools
