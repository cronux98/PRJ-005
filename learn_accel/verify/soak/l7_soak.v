//---------------------------------------------------------------------
// l7_soak.v — L7 multi-hour randomized soak (final gate, user-requested)
// Project  : rinriAI (PRJ-005)
// Language : pure Verilog-2001, iverilog -g2001 -Wall
// DUT      : learn_accel, config via defines (default tiny 4x4x2)
// Shadow   : verify/soak/l7_shadow.vh — transaction port of the C golden
//            model; validated bit-exact by the SELF-TEST phase first.
// Stimulus : seeded LFSR-32 scenario generator:
//            - pixel modes: uniform / zeros / extremes(0,255) / gradient
//            - labels: valid 0..C-1 + invalid >=C injection (RTL-BUG-1
//              mirror: processed, not rejected)
//            - frame corruption: s_last early / missing last / dropped
//              beats / random backpressure (natural via s_ready waits)
//            - APB chaos: start/step/halt/freeze toggle, LRN_RATE,
//              W_INIT_VAL, init_weights, WADDR/WDATA round-trips (read-back
//              vs shadow), reserved-addr PSLVERR
//            - mode mixing: train/step/freeze/halt; random resets
// Checks   : after EVERY DUT sample_done — PRED + SAMPLE/CORRECT/ERROR +
//            err-sticky vs shadow bit-exactly; invariant
//            CORRECT+ERROR==SAMPLE; WDATA read-backs vs shadow; periodic
//            weight spot-checks; X/Z watchdog; per-phase timeout; heartbeat.
// Run      : iverilog -g2001 -Iverify -o l7.vvp l7_soak.v <filelist>
//            ./l7.vvp +seed=N +target=M   (setsid-backgrounded, per-seed)
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

`ifndef CFG_F
`define CFG_F 4
`endif
`ifndef CFG_H
`define CFG_H 4
`endif
`ifndef CFG_C
`define CFG_C 2
`endif

module l7_soak;
    localparam FEATURES = `CFG_F;
    localparam HIDDEN   = `CFG_H;
    localparam CLASSES  = `CFG_C;
    localparam W_TOT = FEATURES*HIDDEN + HIDDEN + HIDDEN*CLASSES + CLASSES;
    localparam W_F = (FEATURES <= 2) ? 2 : (FEATURES <= 4) ? 3 : (FEATURES <= 8) ? 4 :
                     (FEATURES <= 16) ? 5 : (FEATURES <= 32) ? 6 : (FEATURES <= 64) ? 7 :
                     (FEATURES <= 128) ? 8 : (FEATURES <= 256) ? 9 : (FEATURES <= 512) ? 10 : 12;

    // config from plusargs
    integer seed;
    integer target_samples;
    integer max_cycles;

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
    reg [31:0] rd;
    reg [7:0] sh_label_hint;    // 0xFF = invalid-label marker for next frame

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
    `include "soak/l7_shadow.vh"

    // ---------------- soak bookkeeping -----------------------------------
    integer samples_done = 0;
    integer cycles = 0;
    integer mismatches = 0;
    integer checks = 0;
    integer apb_ops = 0, resets = 0, corrupt_frames = 0;
    integer heart = 0;
    integer event_counter = 0;
    reg  done_pending = 0;
    reg  wait_walk = 0;      // serialise frames/APB while the init walk runs
    // event history ring (diagnostics on mismatch)
    reg [7:0] ev_hist [0:15];
    reg [7:0] ev_aux [0:15];
    integer ev_idx = 0;
    task ev_log;
        input [7:0] t;
        input [7:0] a;
        begin
            ev_hist[ev_idx] = t; ev_aux[ev_idx] = a;
            ev_idx = (ev_idx + 1) % 16;
        end
    endtask
    task ev_dump;
        integer k;
        begin
            $display("  control: run=%b step=%b freeze=%b lr=%0d waddr=%0d initbusy=%b err=%b sv=%b proc=%b pendlabel=%0d",
                     sh_run_active, sh_step_mode, sh_freeze, sh_lr, sh_waddr, sh_init_busy,
                     sh_err, sh_sample_valid, sh_processing, sh_pending_label);
            $display("  dut: pred=%0d label@ack=%0d state=%0d | sh: pred=%0d pendlabel=%0d",
                     dut.u_stats.pred, dut_label_at_ack, dut.u_learner.state_r, sh_pred,
                     sh_pending_label);
            $display("  dut w[0..7]=%04x %04x %04x %04x %04x %04x %04x %04x", dut.u_weight_ram.mem[0],
                     dut.u_weight_ram.mem[1], dut.u_weight_ram.mem[2], dut.u_weight_ram.mem[3],
                     dut.u_weight_ram.mem[4], dut.u_weight_ram.mem[5], dut.u_weight_ram.mem[6],
                     dut.u_weight_ram.mem[7]);
            $display("  sh  w[0..7]=%04x %04x %04x %04x %04x %04x %04x %04x", sh_w[0], sh_w[1],
                     sh_w[2], sh_w[3], sh_w[4], sh_w[5], sh_w[6], sh_w[7]);
            $display("  shpx=%0d %0d %0d %0d | dutpx=%0d %0d %0d %0d", sh_pix[0], sh_pix[1],
                     sh_pix[2], sh_pix[3], dut.u_sample_stream.mem[0], dut.u_sample_stream.mem[1],
                     dut.u_sample_stream.mem[2], dut.u_sample_stream.mem[3]);
            $display("  sh pred=%0d acklabel=%0d | dut pred=%0d", sh_pred, sh_ack_label,
                     dut.u_stats.pred);
            $display("  sh ah=%0d %0d %0d %0d | dut ah=%0d %0d %0d %0d", sh_ah[0], sh_ah[1],
                     sh_ah[2], sh_ah[3], dut.u_learner.act_h[0], dut.u_learner.act_h[1],
                     dut.u_learner.act_h[2], dut.u_learner.act_h[3]);
            $display("  dut w[8..15]=%04x %04x %04x %04x %04x %04x %04x %04x", dut.u_weight_ram.mem[8],
                     dut.u_weight_ram.mem[9], dut.u_weight_ram.mem[10], dut.u_weight_ram.mem[11],
                     dut.u_weight_ram.mem[12], dut.u_weight_ram.mem[13], dut.u_weight_ram.mem[14],
                     dut.u_weight_ram.mem[15]);
            $display("  sh  w[8..15]=%04x %04x %04x %04x %04x %04x %04x %04x", sh_w[8], sh_w[9],
                     sh_w[10], sh_w[11], sh_w[12], sh_w[13], sh_w[14], sh_w[15]);
            $display("  dut w[16..23]=%04x %04x %04x %04x %04x %04x %04x %04x", dut.u_weight_ram.mem[16],
                     dut.u_weight_ram.mem[17], dut.u_weight_ram.mem[18], dut.u_weight_ram.mem[19],
                     dut.u_weight_ram.mem[20], dut.u_weight_ram.mem[21], dut.u_weight_ram.mem[22],
                     dut.u_weight_ram.mem[23]);
            $display("  sh  w[16..23]=%04x %04x %04x %04x %04x %04x %04x %04x", sh_w[16], sh_w[17],
                     sh_w[18], sh_w[19], sh_w[20], sh_w[21], sh_w[22], sh_w[23]);
            $display("  dut busy=%b run=%b | sh w[0..5]=%04x %04x %04x %04x %04x %04x", dut.busy,
                     dut.u_learner.run_active, sh_w[0], sh_w[1], sh_w[2], sh_w[3], sh_w[4], sh_w[5]);
            $display("  event history (last 16):");
            for (k = 0; k < 16; k = k + 1) begin
                if (ev_hist[(ev_idx + k) % 16] !== 8'hFF)
                    $display("    [%0d] type=%0d aux=%0d", k, ev_hist[(ev_idx+k)%16], ev_aux[(ev_idx+k)%16]);
            end
        end
    endtask
    reg  x_flag = 0;
    reg [31:0] lfsr;
    reg [31:0] since_done;
    reg mode_done_flag;

    // X/Z watchdog on DUT outputs + key state
    always @(posedge clk_core) begin
        if (rst_n) begin
            if (apb_prdata === 32'bx || apb_prdata === 32'bz ||
                s_ready === 1'bx ||
                dut.u_stats.sample_count === 32'bx ||
                dut.u_stats.pred === 8'bx ||
                dut.u_learner.state_r === 3'bx)
                x_flag <= 1'b1;
        end
    end

    // sample_done handling: at the DUT's done edge, apply the shadow's
    // counter/done semantics and SNAPSHOT the shadow state (pred, counters,
    // err) — the compare runs later against the snapshot, so a same/next-
    // cycle accept (ack_seen PROC) cannot corrupt the comparison.
    reg [7:0]  snap_pred;
    reg [31:0] snap_S, snap_C, snap_E;
    reg        snap_err;
    reg [7:0]  dsnap_pred;
    reg [31:0] dsnap_S, dsnap_C, dsnap_E;
    reg        dsnap_err;
    reg [1:0]  done_d;               // done-pulse delay: counters settle at +2
    reg        err_d1;
    always @(posedge clk_core) begin
        err_d1 <= dut.u_stats.err;
`ifdef L7_ERRDBG
        if (rst_n && !err_d1 && dut.u_stats.err)
            $display("ERRSET t=%0t sh_err=%b shresync=%b shpx=%0d dutstate=%b dutpx=%0d",
                     $time, sh_err, sh_resync, sh_px_cnt, dut.u_sample_stream.state_r,
                     dut.u_sample_stream.px_cnt);
`endif
    end
    always @(posedge clk_core) begin
        if (!rst_n) begin
            done_pending <= 1'b0;
            done_d <= 2'b00;
            snap_pred <= 8'd0; snap_S <= 32'd0; snap_C <= 32'd0; snap_E <= 32'd0;
            snap_err <= 1'b0;
            dsnap_pred <= 8'd0; dsnap_S <= 32'd0; dsnap_C <= 32'd0; dsnap_E <= 32'd0;
            dsnap_err <= 1'b0;
        end else begin
            done_d <= {done_d[0], dut.u_learner.sample_done_p};
            if (done_d[1]) begin
`ifdef L7_DONEDBG
            $display("DONEEDGE t=%0t acklabel=%0d ackfrz=%b acklr=%0d pred=%0d err=%b dute=%b",
                     $time, sh_ack_label, sh_ack_freeze, sh_ack_lr, sh_pred, sh_err,
                     dut.u_stats.err);
`endif
            sh_proc(sh_ack_label, sh_ack_freeze, sh_ack_lr);
            sh_processing = 1'b0;
`ifdef L7_WCMP
            begin : wcmp
                integer wc;
                for (wc = 0; wc < W_TOT; wc = wc + 1) begin
                    if (dut.u_weight_ram.mem[wc] !== sh_w[wc])
                        $display("WCMP-DIFF t=%0t w=%0d dut=%04x sh=%04x", $time, wc,
                                 dut.u_weight_ram.mem[wc], sh_w[wc]);
                end
            end
`endif
`ifdef L7_XCHK
            begin : xchk
                integer xh, xf, xc;
                reg signed [15:0] xa [0:255];
                reg signed [15:0] xy [0:255];
                reg signed [31:0] xp;
                reg signed [47:0] xacc;
                reg [7:0] xpred;
                for (xh = 0; xh < HIDDEN; xh = xh + 1) begin
                    xacc = {{24{dut.u_weight_ram.mem[FEATURES*HIDDEN + xh][15]}},
                            dut.u_weight_ram.mem[FEATURES*HIDDEN + xh], 8'b0};
                    for (xf = 0; xf < FEATURES; xf = xf + 1) begin
                        xp = {{8{dut.u_weight_ram.mem[xh*FEATURES + xf][15]}},
                              dut.u_weight_ram.mem[xh*FEATURES + xf]} * {8'b0, sh_pix[xf]};
                        xacc = xacc + {{16{xp[31]}}, xp};
                    end
                    xa[xh] = sh_sigmoid(sh_sat16(sh_trunc_pow2(xacc, 6'd8)));
                end
                xpred = 8'd0;
                for (xc = 0; xc < CLASSES; xc = xc + 1) begin
                    xacc = {{24{dut.u_weight_ram.mem[FEATURES*HIDDEN + HIDDEN + HIDDEN*CLASSES + xc][15]}},
                            dut.u_weight_ram.mem[FEATURES*HIDDEN + HIDDEN + HIDDEN*CLASSES + xc], 8'b0};
                    for (xh = 0; xh < HIDDEN; xh = xh + 1) begin
                        xp = {{8{dut.u_weight_ram.mem[FEATURES*HIDDEN + HIDDEN + xc*HIDDEN + xh][15]}},
                              dut.u_weight_ram.mem[FEATURES*HIDDEN + HIDDEN + xc*HIDDEN + xh]} * xa[xh];
                        xacc = xacc + {{16{xp[31]}}, xp};
                    end
                    xy[xc] = sh_sigmoid(sh_sat16(sh_trunc_pow2(xacc, 6'd8)));
                    if (xy[xc] > xy[xpred]) xpred = xc;
                end
                $display("XCHK t=%0t dutmem-pred=%0d shpred=%0d dutpred=%0d y=%0d %0d", $time,
                         xpred, sh_pred, dut.u_stats.pred, xy[0], xy[1]);
            end
`endif
            snap_pred <= sh_pred;
            snap_S <= sh_sample;
            snap_C <= sh_correct;
            snap_E <= sh_error;
            snap_err <= sh_err;
            dsnap_pred <= dut.u_stats.pred;
            dsnap_S <= dut.u_stats.sample_count;
            dsnap_C <= dut.u_stats.correct_count;
            dsnap_E <= dut.u_stats.error_count;
            dsnap_err <= dut.u_stats.err;
            done_pending <= 1'b1;
            end
        end
    end

    // accept latch: the DUT's ack_p is the authoritative accept event — the
    // shadow processes the pending sample exactly then (lockstep counters).
    reg ack_seen;
    reg [7:0] dut_label_at_ack;      // DUT label at the accept (diagnostics)
    reg [7:0] sh_ack_label;          // shadow label at the accept (deferral-proof)
    reg       sh_ack_freeze;
    reg [3:0] sh_ack_lr;
    always @(posedge clk_core) begin
        if (!rst_n) begin
            ack_seen <= 1'b0;
            sh_ack_label <= 8'd0;
        end else if (dut.u_learner.ack_p) begin
            ack_seen <= 1'b1;
            sh_processing = 1'b1;           // busy window [accept, done)
            sh_sample_valid = 1'b0;         // DUT clears sample_valid on accept
            dut_label_at_ack <= dut.u_sample_stream.label;
            sh_ack_label <= sh_pending_label;
            sh_ack_freeze <= sh_freeze;
            sh_ack_lr <= sh_lr;
            begin : pxchk
                integer pf;
                reg [7:0] pxd;
                pxd = 8'd0;
                for (pf = 0; pf < FEATURES; pf = pf + 1)
                    if (sh_pix[pf] !== dut.u_sample_stream.mem[pf]) pxd = pxd + 1;
                if (pxd !== 8'd0) begin
                    $display("SOAK-FAIL seed=%0d t=%0t PXDIFF=%0d sh0=%0d dut0=%0d (frame capture diverged)",
                             seed, $time, pxd, sh_pix[0], dut.u_sample_stream.mem[0]);
                    mismatches = mismatches + 1;
                end
            end
        end
    end

    // per-phase hang watchdog
    always @(posedge clk_core) begin
        if (!rst_n) since_done <= 32'd0;
        else if (dut.u_learner.sample_done_p) since_done <= 32'd0;
        else if (since_done != 32'hFFFFFFFF) since_done <= since_done + 1'b1;
    end

    // ---------------- LFSR -------------------------------------------------
    function [31:0] lfsr_next;
        input [31:0] st;
        begin
            lfsr_next = (st >> 1) ^ (st[0] ? 32'h0020_0003 : 32'h0000_0000);
        end
    endfunction

    // ---------------- compare task (DUT stats vs shadow) ------------------
    task cmp_sample;
        begin
            checks = checks + 1;
`ifdef L7_CMPDBG
            $display("CMP t=%0t chk=%0d dutpred=%0d snappred=%0d dutS=%0d snapS=%0d dutC=%0d snapC=%0d dutE=%0d snapE=%0d",
                     $time, checks, dut.u_stats.pred, snap_pred,
                     dut.u_stats.sample_count, snap_S, dut.u_stats.correct_count, snap_C,
                     dut.u_stats.error_count, snap_E);
`endif
            if (dsnap_pred !== snap_pred) begin
                $display("SOAK-FAIL seed=%0d chk=%0d pred: dsnap=%0d snap=%0d live_dut=%0d",
                         seed, checks, dsnap_pred, snap_pred, dut.u_stats.pred);
                ev_dump;
                mismatches = mismatches + 1;
            end
            if (dsnap_S !== snap_S) begin
                $display("SOAK-FAIL seed=%0d chk=%0d sample: dut=%0d sh=%0d", seed, checks,
                         dut.u_stats.sample_count, snap_S);
                mismatches = mismatches + 1;
            end
            if (dsnap_C !== snap_C) begin
                $display("SOAK-FAIL seed=%0d chk=%0d correct: dut=%0d sh=%0d", seed, checks,
                         dut.u_stats.correct_count, snap_C);
                ev_dump;
                mismatches = mismatches + 1;
            end
            if (dsnap_E !== snap_E) begin
                $display("SOAK-FAIL seed=%0d chk=%0d error: dut=%0d sh=%0d", seed, checks,
                         dut.u_stats.error_count, snap_E);
                mismatches = mismatches + 1;
            end
            if (dsnap_err !== snap_err) begin
                $display("SOAK-FAIL seed=%0d chk=%0d err: dut=%b sh=%b", seed, checks,
                         dut.u_stats.err, snap_err);
                ev_dump;
                mismatches = mismatches + 1;
            end
            if (dsnap_C + dsnap_E !== dsnap_S) begin
                $display("SOAK-FAIL seed=%0d chk=%0d invariant C+E!=S", seed, checks);
                mismatches = mismatches + 1;
            end
            samples_done = samples_done + 1;
            done_pending = 0;
        end
    endtask

    // ---------------- one streamed byte with optional corruption ----------
    // mode: 0 normal, 1 early-last, 2 dropped-beat, 3 extra s_last
    task stream_byte_soak;
        input [7:0] d;
        input       last;
        input [2:0] mode;
        begin
            if (mode == 3'd2) begin
                // dropped beat: present one cycle; if accepted at that edge
                // the beat already happened (consume, done), else withdraw
                // and re-present normally below.
                s_valid <= 1'b1; s_data <= d; s_last <= last;
                @(posedge clk_core);
                if (s_ready) begin
                    sh_stream_byte(d, last);        // beat happened at this edge
                    s_valid <= 1'b0; s_last <= 1'b0;
                    @(posedge clk_core);            // settle
                    mode_done_flag = 1'b1;
                end else begin
                    s_valid <= 1'b0;                // withdrew without a beat
                    @(posedge clk_core);
                end
            end
            if (!mode_done_flag) begin
            // normal stream (beat = first posedge with s_ready after assert)
            s_valid <= 1'b1; s_data <= d; s_last <= (mode == 3'd1) ? 1'b1 : last;
            if (!s_ready) begin
                begin : wait_ready
                    integer wc;
                    wc = 0;
                    while (!s_ready) begin
                        @(posedge clk_core);
                        wc = wc + 1;
                        // auto-restart: learner idle-not-running (halted or
                        // never started) -> kick it with a step
                        if (wc > 200 && !dut.u_learner.run_active &&
                            !dut.u_learner.sample_done_p) begin
                            apb_write(32'h00, 32'h00000002);
                            sh_ctrl_write(32'h00, 32'h00000002);
                            wc = 0;
                        end
                    end
                end
            end else begin
                @(posedge clk_core);
            end
`ifdef L7_BYTEDBG
            if ($time > 72530000 && $time < 72575000)
                $display("BEAT t=%0t d=%0d last=%b mode=%0d shresync=%b shpx=%0d dutpx=%0d dutstate=%b",
                         $time, d, last, mode, sh_resync, sh_px_cnt,
                         dut.u_sample_stream.px_cnt, dut.u_sample_stream.state_r);
`endif
            sh_stream_byte(d, (mode == 3'd1) ? 1'b1 : last);
            s_valid <= 1'b0; s_last <= 1'b0;
            @(posedge clk_core);                    // settle
            end
            mode_done_flag = 1'b0;
            if (mode == 3'd3) begin
                // stray extra s_last beat
                s_valid <= 1'b1; s_data <= 8'h00; s_last <= 1'b1;
                if (!s_ready) begin
                    while (!s_ready) @(posedge clk_core);
                end else begin
                    @(posedge clk_core);
                end
                sh_stream_byte(8'h00, 1'b1);
                s_valid <= 1'b0; s_last <= 1'b0;
                @(posedge clk_core);
            end
        end
    endtask

    // ---------------- APB chaos ops (DUT + shadow mirror) ------------------
    task apb_chaos;
        input [3:0] op;
        begin
            case (op)
                4'd0: begin apb_write(32'h00, 32'h00000001); sh_ctrl_write(32'h00, 32'h00000001); end
                4'd1: begin apb_write(32'h00, 32'h00000002); sh_ctrl_write(32'h00, 32'h00000002); end
                4'd2: begin apb_write(32'h00, 32'h00000004); sh_ctrl_write(32'h00, 32'h00000004); end
                4'd3: begin
                    rd = sh_freeze ? 32'h00000000 : 32'h00000008;
                    apb_write(32'h00, rd); sh_ctrl_write(32'h00, rd);
                end
                4'd4: begin
                    rd = {28'h0, lfsr[3:0]};
                    apb_write(32'h04, rd); sh_ctrl_write(32'h04, rd);
                end
                4'd5: begin
                    if (!sh_init_busy && !sh_processing) begin
                        rd = {16'h0, lfsr[15:0]};
`ifdef L7_WDBG
                        $display("INIT t=%0t winit=%04x run=%b proc=%b", $time, rd[15:0],
                                 sh_run_active, sh_processing);
`endif
                        apb_write(32'h24, rd); sh_ctrl_write(32'h24, rd);
                        apb_write(32'h00, 32'h00000020); sh_ctrl_write(32'h00, 32'h00000020);
                        wait_walk = 1'b1;   // let the 30-cycle walk finish
                    end
                end
                4'd6: begin
                    if (!sh_init_busy && !sh_processing && !sh_sample_valid) begin
                        rd = {16'h0, lfsr[15:0] % W_TOT};
                        apb_write(32'h1C, rd); sh_ctrl_write(32'h1C, rd);
                        rd = {16'h0, lfsr[15:0]};
                        apb_write(32'h20, rd); sh_ctrl_write(32'h20, rd);
                        // self-verify: read back the SAME address (re-set it;
                        // the WDATA access auto-incremented both pointers)
                        apb_write(32'h1C, rd); sh_ctrl_write(32'h1C, rd);
                        apb_read(32'h20, rd);
                        if (rd[15:0] !== sh_w[sh_waddr]) begin
                            $display("SOAK-FAIL seed=%0d WRV t=%0t waddr=%0d dut=%04x sh=%04x",
                                     seed, $time, sh_waddr, rd[15:0], sh_w[sh_waddr]);
                            mismatches = mismatches + 1;
                        end
                    end
                end
                4'd7: begin
                    if (!sh_init_busy && !sh_processing && !sh_sample_valid) begin
                        rd = {16'h0, lfsr[15:0] % W_TOT};
                        apb_write(32'h1C, rd); sh_ctrl_write(32'h1C, rd);
`ifdef L7_WDBG
                        if (dut.u_apb_regs.waddr_ff !== sh_waddr)
                            $display("WADDR-DIFF t=%0t dut=%0d sh=%0d", $time,
                                     dut.u_apb_regs.waddr_ff, sh_waddr);
`endif
                        apb_read(32'h20, rd);
                        if (rd[15:0] !== sh_w[sh_waddr]) begin
                            $display("SOAK-FAIL seed=%0d CSR readback t=%0t waddr=%0d dut=%04x sh=%04x initbusy=%b",
                                     seed, $time, sh_waddr, rd[15:0], sh_w[sh_waddr], sh_init_busy);
                            mismatches = mismatches + 1;
                        end
                        sh_waddr = sh_waddr + 16'd1;   // WDATA read auto-increments
                    end
                end
                4'd8: begin
                    apb_access_expect_err(1'b1, 32'h00000028, 32'hDEADBEEF, rd);
                    apb_access_expect_err(1'b0, 32'h00000100, 32'h0, rd);
                end
                4'd9: begin
                    apb_write(32'h00, 32'h00000010); sh_ctrl_write(32'h00, 32'h00000010);
                end
                default: begin end
            endcase
            apb_ops = apb_ops + 1;
        end
    endtask

    // ---------------- weight spot check (DUT vs shadow) --------------------
    task weight_spot_check;
        integer k;
        reg [15:0] a;
        begin
            for (k = 0; k < 5; k = k + 1) begin
                a = lfsr[15:0] % W_TOT;
                apb_write(32'h1C, {16'h0, a});
                apb_read(32'h20, rd);
                if (rd[15:0] !== sh_w[a]) begin
                    $display("SOAK-FAIL seed=%0d weight[%0d]: dut=%04x sh=%04x", seed, a,
                             rd[15:0], sh_w[a]);
                    mismatches = mismatches + 1;
                end
            end
        end
    endtask

    // ---------------- shadow self-test (C-model vectors) -------------------
    task shadow_selftest;
        reg [31:0] stim [0:54];
        reg [31:0] exp  [0:54];
        integer i, p;
        integer selftest_err;
        begin
            selftest_err = 0;
            $readmemh("verify/golden/tiny_shipped_corrected/stimulus.hex", stim);
            $readmemh("verify/golden/tiny_shipped_corrected/expected.hex", exp);
            sh_reset;
            sh_ctrl_write(32'h04, 32'h00000000);
            sh_ctrl_write(32'h1C, 32'h00000000);
            for (i = 0; i < W_TOT; i = i + 1)
                sh_ctrl_write(32'h20, {16'h0, stim[i][15:0]});
            for (i = 0; i < 5; i = i + 1) begin
                sh_ctrl_write(32'h00, 32'h00000002);   // step
                for (p = 0; p < FEATURES; p = p + 1)
                    sh_stream_byte(stim[W_TOT + i*(FEATURES+1) + p][7:0], 1'b0);
                sh_stream_byte(stim[W_TOT + i*(FEATURES+1) + FEATURES][7:0], 1'b1);
                sh_accept_check;
                sh_processing = 1'b0;       // done edge would clear it
                if (sh_pred !== exp[i*5 + 0][7:0]) begin
                    $display("SELFTEST-FAIL sample %0d pred: sh=%0d want=%0d", i, sh_pred, exp[i*5+0][7:0]);
                    selftest_err = selftest_err + 1;
                end
                if (sh_sample !== exp[i*5 + 2] || sh_correct !== exp[i*5 + 3] ||
                    sh_error !== exp[i*5 + 4]) begin
                    $display("SELFTEST-FAIL sample %0d counters: sh=%0d/%0d/%0d want=%0d/%0d/%0d", i,
                             sh_sample, sh_correct, sh_error, exp[i*5+2], exp[i*5+3], exp[i*5+4]);
                    selftest_err = selftest_err + 1;
                end
                if (!sh_run_active) begin
                    // step completed -> idle; next step allowed (no-op check)
                end
            end
            for (i = 0; i < W_TOT; i = i + 1) begin
                if (sh_w[i] !== exp[25 + i][15:0]) begin
                    $display("SELFTEST-FAIL weight %0d: sh=%04x want=%04x", i, sh_w[i], exp[25+i][15:0]);
                    selftest_err = selftest_err + 1;
                end
            end
            if (selftest_err == 0) $display("SELFTEST PASS (shadow bit-exact vs C model)");
            else begin
                $display("SELFTEST FAIL: %0d errors — shadow broken, aborting", selftest_err);
                $finish;
            end
        end
    endtask

    // ---------------- main soak driver -------------------------------------
    integer i, p;
    reg [31:0] rnd;
    reg [7:0] px;

    initial begin
        seed = 1;
        target_samples = 2000000;
        max_cycles = 400000000;
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        if (!$value$plusargs("target=%d", target_samples)) target_samples = 2000000;
        if (!$value$plusargs("maxcyc=%d", max_cycles)) max_cycles = 400000000;
        lfsr = 32'h9E3779B9 ^ seed[31:0];
        sh_label_hint = 8'h00;
        for (i = 0; i < 16; i = i + 1) ev_hist[i] = 8'hFF;
        $display("L7-SOAK seed=%0d target=%0d cfg=%0dx%0dx%0d start", seed, target_samples,
                 FEATURES, HIDDEN, CLASSES);
`ifdef L7_DUMP
        $dumpfile("l7_soak.vcd");
        $dumpvars(0, l7_soak);
`endif

        tb_reset;
        sh_reset;
        if (FEATURES == 4 && HIDDEN == 4 && CLASSES == 2) begin
            shadow_selftest;            // tiny-config vectors only
            sh_reset;                   // selftest mutated the shadow; restart clean
        end

        while (samples_done < target_samples && cycles < max_cycles) begin
            @(posedge clk_core);
            cycles = cycles + 1;

            // per-cycle shadow mirror: init walk only (the sample
            // transaction runs at the DUT's done edge in the always block)
            sh_walk_cycle;
            if (wait_walk && !dut.u_weight_ram.init_busy && !sh_init_busy) wait_walk = 1'b0;

            // heartbeat
            if (samples_done >= heart + 5000) begin
                heart = samples_done;
                $display("L7-SOAK seed=%0d done=%0d cyc=%0d mism=%0d beats=%0d apb=%0d rst=%0d corr=%0d",
                         seed, samples_done, cycles, mismatches, sh_beats, apb_ops, resets,
                         corrupt_frames);
            end

            // compare a completed sample against the done-edge snapshot
            if (done_pending && !dut.u_learner.sample_done_p) begin
                cmp_sample;
                if (mismatches > 1000) begin
                    $display("L7-SOAK seed=%0d ABORT: >1000 mismatches", seed);
                    $finish;
                end
            end

            // X watchdog
            if (x_flag) begin
                $display("SOAK-FAIL seed=%0d X/Z detected on DUT outputs", seed);
                mismatches = mismatches + 1;
                x_flag = 0;
            end

            // hang watchdog (tight for debug)
            if (since_done > 32'd2000000) begin
                $display("SOAK-DBG seed=%0d HANG? t=%0t dutstate=%0d srdy=%b run=%b sv=%b initbusy=%b waitwalk=%b",
                         seed, $time, dut.u_learner.state_r, s_ready, dut.u_learner.run_active,
                         dut.u_sample_stream.sample_valid, dut.u_weight_ram.init_busy, wait_walk);
            end
            if (since_done > 32'd50000000) begin
                $display("SOAK-FAIL seed=%0d HANG: no sample_done for %0d cycles", seed, since_done);
                $finish;
            end

            // self-heal: if the learner has been idle-not-running, kick it
            if (!dut.u_learner.run_active && !dut.u_learner.sample_done_p &&
                since_done > 32'd2000) begin
                apb_write(32'h00, 32'h00000002);   // step
                sh_ctrl_write(32'h00, 32'h00000002);
            end

            // event scheduler (paused while the init walk runs)
            rnd = lfsr_next(lfsr); lfsr = rnd;
            if (wait_walk) begin
                // walk in progress: no new events; drain the walk
            end else if (rnd[31:26] == 6'd0 && apb_ops < 200000) begin
                // APB chaos ~1/64 of events; real ops only (0..9)
                ev_log(8'd20 + rnd[5:4], 8'd0);
                apb_chaos(rnd[3:0] % 4'd10);
            end else if (rnd[31:26] == 6'd1 && resets < 50) begin
                resets = resets + 1;
                ev_log(8'd30, 8'd0);
                rst_n <= 1'b0;
                repeat (5) @(posedge clk_core);
                rst_n <= 1'b1;
                @(posedge clk_core);
                sh_reset;
                done_pending = 0;
                ack_seen = 0;
                wait_walk = 0;
                x_flag = 0;
            end else if (rnd[31:30] != 2'b11) begin
                // stream a frame (~3/4 of events)
                px = 8'h00;
                case (rnd[21:20])
                    2'd0: px = rnd[7:0];
                    2'd1: px = 8'h00;
                    2'd2: px = rnd[0] ? 8'hFF : 8'h00;
                    2'd3: px = (event_counter * 7) & 8'hFF;
                endcase
                if (rnd[9:5] == 5'd0) sh_label_hint = 8'hFF;   // invalid-label inject
                case (rnd[19:17])
                    3'd0: begin
                        // early s_last at a random pixel index
                        corrupt_frames = corrupt_frames + 1;
                        ev_log(8'd10, 8'd0);
                        for (p = 0; p < FEATURES; p = p + 1) begin
                            if (p == (rnd[16:8] % FEATURES)) begin
                                stream_byte_soak(px, 1'b1, 3'd1);
                                p = FEATURES;
                            end else begin
                                stream_byte_soak(px, 1'b0, 3'd0);
                            end
                        end
                        stream_byte_soak(8'h00, 1'b1, 3'd0);   // resync byte
                    end
                    3'd1: begin
                        // missing last at label position
                        corrupt_frames = corrupt_frames + 1;
                        ev_log(8'd11, 8'd0);
                        for (p = 0; p < FEATURES; p = p + 1)
                            stream_byte_soak(px, 1'b0, 3'd0);
                        stream_byte_soak(px, 1'b0, 3'd0);      // label w/o last
                        stream_byte_soak(8'h00, 1'b1, 3'd0);   // resync
                    end
                    3'd2: begin
                        // dropped-beat corruption on the first pixel
                        corrupt_frames = corrupt_frames + 1;
                        ev_log(8'd12, 8'd0);
                        stream_byte_soak(px, 1'b0, 3'd2);
                        for (p = 1; p < FEATURES; p = p + 1)
                            stream_byte_soak(px, 1'b0, 3'd0);
                        if (sh_label_hint == 8'hFF)
                            stream_byte_soak(CLASSES + (rnd[7:0] % 8'd16), 1'b1, 3'd0);
                        else
                            stream_byte_soak(sh_label_hint, 1'b1, 3'd0);
                    end
                    default: begin
                        // normal valid frame (valid or >=C injected label)
                        ev_log(8'd13, sh_label_hint == 8'hFF ? 8'd1 : 8'd0);
                        for (p = 0; p < FEATURES; p = p + 1)
                            stream_byte_soak(px, 1'b0, 3'd0);
                        if (sh_label_hint == 8'hFF)
                            stream_byte_soak(CLASSES + (rnd[7:0] % 8'd16), 1'b1, 3'd0);
                        else
                            stream_byte_soak(sh_label_hint, 1'b1, 3'd0);
                    end
                endcase
                sh_label_hint = 8'h00;
                event_counter = event_counter + 1;
            end
            // else: idle cycles (~1/4)
        end

        $display("L7-SOAK seed=%0d END: done=%0d cyc=%0d mism=%0d beats=%0d apb=%0d rst=%0d corr=%0d",
                 seed, samples_done, cycles, mismatches, sh_beats, apb_ops, resets, corrupt_frames);
        weight_spot_check;
        if (samples_done < target_samples)
            $display("L7-SOAK seed=%0d INCOMPLETE: %0d/%0d samples (cycle budget)", seed,
                     samples_done, target_samples);
        if (mismatches == 0 && samples_done >= target_samples)
            $display("SOAK_PASS seed=%0d samples=%0d", seed, samples_done);
        else
            $display("SOAK_FAIL seed=%0d samples=%0d mism=%0d", seed, samples_done, mismatches);
        $finish;
    end

    initial begin
        #400_000_000_000;
        $display("SOAK-FAIL seed=%0d GLOBAL TIMEOUT", seed);
        $finish;
    end
endmodule

`default_nettype wire
