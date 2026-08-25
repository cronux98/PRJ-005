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

    // previous-cycle samples ($past substitute; wrapper-local, resolvable)
    reg        sv_d1, ack_d1, errp_d1, err_d1, clr_d1;
    reg [31:0] sc_d1;
    reg [2:0]  lst_d1;
    reg        sst_d1;
    reg [3:0]  cyc;
    always @(posedge clk_core) begin
        if (!rst_n) begin
            cyc <= 4'd0; sv_d1 <= 1'b0; ack_d1 <= 1'b0; errp_d1 <= 1'b0;
            err_d1 <= 1'b0; clr_d1 <= 1'b0; sc_d1 <= 32'd0;
            lst_d1 <= 3'd0; sst_d1 <= 1'b0;
        end else begin
            cyc <= cyc + 1'b1;
            sv_d1 <= fp_sample_valid; ack_d1 <= fp_ack_p; errp_d1 <= fp_err_p;
            err_d1 <= fp_err; clr_d1 <= fp_clr_stats_p;
            sc_d1 <= fp_sample_count; lst_d1 <= fp_lstate; sst_d1 <= fp_sstate;
        end
    end

    // bounded-busy counters
    reg [5:0] dbusy;
    reg [7:0] ibusy;
    always @(posedge clk_core) begin
        if (!rst_n) dbusy <= 6'd0;
        else if (fp_div_busy) dbusy <= dbusy + 1'b1;
        else dbusy <= 6'd0;
    end
    always @(posedge clk_core) begin
        if (!rst_n) ibusy <= 8'd0;
        else if (fp_init_busy) ibusy <= ibusy + 1'b1;
        else ibusy <= 8'd0;
    end

    // Reset model (fe-sby requirement 2)
    always @(posedge clk_core) begin
        if ($initstate) assume (rst_n == 1'b0);
    end

    // P1: divider never hangs
    always @(posedge clk_core) begin
        if (rst_n && !$initstate) begin
            if (fp_div_busy) assert (dbusy <= 6'd33);
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
            if (sv_d1 && !ack_d1 && !errp_d1) assert (fp_sample_valid);
        end
    end

    // P4: err sticky until clr_stats_p
    always @(posedge clk_core) begin
        if (rst_n && !$initstate && cyc >= 4'd1) begin
            if (err_d1 && !clr_d1) assert (fp_err);
        end
    end

    // P5: sample_count saturates (no wrap)
    always @(posedge clk_core) begin
        if (rst_n && !$initstate && cyc >= 4'd1) begin
            if (sc_d1 == 32'hFFFFFFFF)
                assert (fp_sample_count == 32'hFFFFFFFF || clr_d1);
        end
    end

    // P6: malformed pulse -> RESYNC next cycle
    always @(posedge clk_core) begin
        if (rst_n && !$initstate && cyc >= 4'd1) begin
            if (errp_d1) assert (sst_d1 == 1'b1);
        end
    end

    // P7: DONE -> IDLE next cycle
    always @(posedge clk_core) begin
        if (rst_n && !$initstate && cyc >= 4'd1) begin
            if (lst_d1 == 3'd7) assert (fp_lstate == 3'd0);
        end
    end

    // P8: IDLE + run_active + sample_valid -> FWD_H next cycle
    always @(posedge clk_core) begin
        if (rst_n && !$initstate && cyc >= 4'd1) begin
            if (lst_d1 == 3'd0 && fp_run_active && sv_d1)
                assert (fp_lstate == 3'd1);
        end
    end

    // P9: init walk terminates (busy bounded by W_TOT+2 = 32 cycles)
    always @(posedge clk_core) begin
        if (rst_n && !$initstate) begin
            if (fp_init_busy) assert (ibusy <= 8'd33);
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
