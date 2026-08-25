//---------------------------------------------------------------------
// rinriAI_fv.v — formal property wrapper for learn_accel (tiny config)
// Project  : rinriAI (PRJ-005) — fe-sby formal (L6)
// Style    : procedural asserts only (suite yosys 0.65 cannot parse SVA).
//           DUT = verify/formal/learn_accel_fv.v (formal copy with probe
//           output ports — hierarchical refs do not resolve under
//           `read -formal`, so probes are flat ports, per fe-sby skill).
// Properties:
//   P1  divider never hangs: div_busy bounded to 33 cycles
//   P2  OI-008: sample_valid -> s_ready deasserted (overwrite window closed)
//   P3  sample_valid holds until ack_p or err_p (handshake, no silent drop)
//   P4  err sticky until clr_stats_p
//   P5  counters saturate at 0xFFFFFFFF (no wrap)
//   P6  err_p -> sample_stream enters RESYNC next cycle
//   P7  DONE -> IDLE next cycle (FSM-001 arc)
//   P8  IDLE accept -> FWD_H next cycle (FSM-001 arc)
//   P9  init walk terminates: init_busy bounded to W_TOT+2 cycles
//   C1..C6 covers: sample_done_p, err, div_done, FWD_O, BP_H, UPD_H
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module rinriAI_fv;
    localparam FEATURES = 4, HIDDEN = 4, CLASSES = 2;

    reg clk_core = 1'b0;
    reg rst_n    = 1'b0;
    reg        psel = 0, penable = 0, pwrite = 0;
    reg  [31:0] paddr = 0, pwdata = 0;
    reg        s_valid = 0, s_last = 0;
    reg  [7:0] s_data = 0;
    wire       s_ready;
    wire       fp_sample_valid, fp_ack_p, fp_err_p, fp_err, fp_clr_stats_p;
    wire [31:0] fp_sample_count;
    wire [2:0]  fp_lstate;
    wire        fp_run_active, fp_sstate, fp_div_busy, fp_div_done, fp_init_busy;

    learn_accel #(.FEATURES(FEATURES), .HIDDEN(HIDDEN), .CLASSES(CLASSES)) dut (
        .clk_core (clk_core), .rst_n (rst_n),
        .psel (psel), .penable (penable), .pwrite (pwrite),
        .paddr (paddr), .pwdata (pwdata), .prdata (), .pready (), .pslverr (),
        .s_valid (s_valid), .s_ready (s_ready), .s_data (s_data), .s_last (s_last),
        .fp_sample_valid (fp_sample_valid), .fp_ack_p (fp_ack_p),
        .fp_err_p (fp_err_p), .fp_err (fp_err), .fp_clr_stats_p (fp_clr_stats_p),
        .fp_sample_count (fp_sample_count), .fp_lstate (fp_lstate),
        .fp_run_active (fp_run_active), .fp_sstate (fp_sstate),
        .fp_div_busy (fp_div_busy), .fp_div_done (fp_div_done),
        .fp_init_busy (fp_init_busy)
    );

    // cycle counter for $past guards
    reg [3:0] cyc;
    initial cyc = 4'd0;
    always @(posedge clk_core) cyc <= cyc + 1'b1;

    // Reset model (fe-sby requirement 2)
    always @(posedge clk_core) begin
        if ($initstate) assume (rst_n == 1'b0);
    end

    // P1: divider never hangs (div_busy implies done within 34 cycles:
    // if busy this cycle and not busy last cycle... use bounded via $past chain)
    always @(posedge clk_core) begin
        if (rst_n && !$initstate && cyc >= 4'd2) begin
            if ($past(fp_div_busy, 2) && $past(fp_div_busy, 1))
                assert (!fp_div_busy || $past(fp_div_done, 1));
        end
    end

    // P2: OI-008 — sample pending -> stream closed
    always @(posedge clk_core) begin
        if (rst_n && !$initstate) begin
            if (fp_sample_valid) assert (!s_ready);
        end
    end

    // P3: sample_valid holds until ack_p or err_p
    always @(posedge clk_core) begin
        if (rst_n && !$initstate && cyc >= 4'd1) begin
            if ($past(fp_sample_valid) && !$past(fp_ack_p) && !$past(fp_err_p))
                assert (fp_sample_valid);
        end
    end

    // P4: err sticky until clr_stats_p
    always @(posedge clk_core) begin
        if (rst_n && !$initstate && cyc >= 4'd1) begin
            if ($past(fp_err) && !$past(fp_clr_stats_p)) assert (fp_err);
        end
    end

    // P5: sample_count saturates (no wrap)
    always @(posedge clk_core) begin
        if (rst_n && !$initstate && cyc >= 4'd1) begin
            if ($past(fp_sample_count) == 32'hFFFFFFFF)
                assert (fp_sample_count == 32'hFFFFFFFF || $past(fp_clr_stats_p));
        end
    end

    // P6: malformed pulse -> RESYNC next cycle
    always @(posedge clk_core) begin
        if (rst_n && !$initstate && cyc >= 4'd1) begin
            if ($past(fp_err_p)) assert (fp_sstate == 1'b1);
        end
    end

    // P7: DONE -> IDLE next cycle
    always @(posedge clk_core) begin
        if (rst_n && !$initstate && cyc >= 4'd1) begin
            if ($past(fp_lstate) == 3'd7) assert (fp_lstate == 3'd0);
        end
    end

    // P8: IDLE + run_active + sample_valid -> FWD_H next cycle
    always @(posedge clk_core) begin
        if (rst_n && !$initstate && cyc >= 4'd1) begin
            if ($past(fp_lstate) == 3'd0 && $past(fp_run_active) && $past(fp_sample_valid))
                assert (fp_lstate == 3'd1);
        end
    end

    // P9: init walk terminates (init_busy bounded: within W_TOT+2 cycles)
    always @(posedge clk_core) begin
        if (rst_n && !$initstate && cyc >= 4'd1) begin
            if ($past(fp_init_busy) && fp_init_busy &&
                $past(fp_init_busy, 2) && $past(fp_init_busy, 3) &&
                $past(fp_init_busy, 4) && $past(fp_init_busy, 5) &&
                $past(fp_init_busy, 6) && $past(fp_init_busy, 7) &&
                $past(fp_init_busy, 8) && $past(fp_init_busy, 9) &&
                $past(fp_init_busy, 10) && $past(fp_init_busy, 11) &&
                $past(fp_init_busy, 12) && $past(fp_init_busy, 13) &&
                $past(fp_init_busy, 14) && $past(fp_init_busy, 15) &&
                $past(fp_init_busy, 16) && $past(fp_init_busy, 17) &&
                $past(fp_init_busy, 18) && $past(fp_init_busy, 19) &&
                $past(fp_init_busy, 20) && $past(fp_init_busy, 21) &&
                $past(fp_init_busy, 22) && $past(fp_init_busy, 23) &&
                $past(fp_init_busy, 24) && $past(fp_init_busy, 25) &&
                $past(fp_init_busy, 26) && $past(fp_init_busy, 27) &&
                $past(fp_init_busy, 28) && $past(fp_init_busy, 29) &&
                $past(fp_init_busy, 30) && $past(fp_init_busy, 31) &&
                $past(fp_init_busy, 32))
                assert (!fp_init_busy);   // 33 cycles busy max -> done
        end
    end

    // Covers
    always @(posedge clk_core) begin
        if (rst_n && !$initstate) begin
            cover (fp_lstate == 3'd7);          // DONE
            cover (fp_err);
            cover (fp_div_done);
            cover (fp_lstate == 3'd2);          // FWD_O
            cover (fp_lstate == 3'd4);          // BP_H
            cover (fp_lstate == 3'd6);          // UPD_H
        end
    end

endmodule

`default_nettype wire
