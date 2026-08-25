//---------------------------------------------------------------------
// l7_shadow.vh — embedded golden shadow model for the L7 randomized soak
// Project  : rinriAI (PRJ-005) — L7 final gate
// Language : pure Verilog-2001 (include file, ifndef-guarded)
// Purpose  : transaction-level port of arch/golden_model/golden_ref_model.c
//            (+ sample_stream framing + learner control + APB CSR effects)
//            that replays the SAME seeded stimulus as the DUT and predicts
//            {pred, sample, correct, error, err-sticky} bit-exactly.
//            Validated against expected.hex (C model) by the l7_soak
//            self-test phase before the randomized phase.
// Contract : mirrors the RTL *as built* — including RTL-BUG-1 (label >=
//            CLASSES is processed, not rejected) and malformed-frame
//            err+RESYNC rules (REQ-018). Deviations show as per-sample
//            mismatches (the soak's PASS gate).
// Events   : the driver calls, in order, for every DUT-visible event:
//            sh_reset (on rst_n assert), sh_ctrl_write (per APB write,
//            mapped addrs only), sh_stream_byte (per accepted beat),
//            and sh_accept_check + sh_walk_cycle once per clock cycle
//            (mirrors the learner IDLE-accept and the init-walk FSM).
//---------------------------------------------------------------------
`ifndef TB_COMMON_L7_SHADOW_VH
`define TB_COMMON_L7_SHADOW_VH

// ---------------- shadow state (owned by the including TB) ----------------
reg signed [15:0] sh_w      [0:W_TOT-1];     // shadow weights (Q8.8)
reg        [7:0]  sh_pix    [0:FEATURES-1]; // captured frame pixels
reg signed [47:0] sh_acc48, sh_tmp48, sh_e16;
reg        [31:0] sh_sample, sh_correct, sh_error;
reg               sh_err;                   // sticky err (mirrors stats)
reg        [7:0]  sh_pred;                  // last predicted class
reg        [W_F-1:0] sh_px_cnt;
reg               sh_resync;                // 1 = RESYNC (drain to s_last)
reg               sh_sample_valid;          // level: full sample captured
reg        [7:0]  sh_pending_label;         // captured label byte
reg               sh_run_active, sh_step_mode, sh_halt_pending;
reg               sh_freeze, sh_done;
reg        [3:0]  sh_lr;
reg        [15:0] sh_waddr;                 // CSR WADDR pointer
reg        [15:0] sh_winit;                 // W_INIT_VAL
reg               sh_init_busy;             // bulk-init walk in progress
reg        [15:0] sh_init_addr;             // walk pointer
reg               sh_processing;            // shadow "busy" with a sample
reg        [7:0]  sh_last_label;            // label of the last processed sample
reg signed [15:0] sh_ah [0:255];          // last computed hidden activations
reg        [31:0] sh_beats;                 // accepted beats (byte count)
reg        [31:0] sh_frames_good, sh_frames_bad;

// ---------------- helpers (identical semantics to the C model) ------------
function signed [47:0] sh_sext16;
    input signed [15:0] x;
    begin sh_sext16 = {{32{x[15]}}, x}; end
endfunction

function signed [47:0] sh_sext32;
    input signed [31:0] x;
    begin sh_sext32 = {{16{x[31]}}, x}; end
endfunction

// trunc(x/2^n) toward zero — 48-bit
function signed [47:0] sh_trunc_pow2;
    input signed [47:0] x;
    input        [5:0]  n;
    reg          [47:0] m;
    begin
        m = x[47] ? (~x + 48'd1) : x;
        m = m >> n;
        sh_trunc_pow2 = x[47] ? (48'd0 - m) : m;
    end
endfunction

function [15:0] sh_sat16;
    input signed [47:0] x;
    begin
        if      (x >  48'sd32767) sh_sat16 = 16'h7FFF;
        else if (x < -48'sd32768) sh_sat16 = 16'h8000;
        else                      sh_sat16 = x[15:0];
    end
endfunction

// sigmoid: 128 + trunc(128*z / (256+|z|)) — C99 trunc toward zero.
// Division done in explicit sign-magnitude: a signed/unsigned operand mix
// would promote the division to unsigned (Verilog rule) and corrupt
// negative numerators.
function [15:0] sh_sigmoid;
    input signed [15:0] z;
    reg [31:0] num_mag;
    reg [17:0] den_mag;
    reg [31:0] q_mag;
    reg [15:0] az;
    reg signed [31:0] q;
    begin
        az      = z[15] ? (~z + 16'd1) : z;
        num_mag = {{9{z[15]}}, z, 7'b0};            // 128*z as bits; mag below
        if (z[15]) num_mag = (~num_mag + 32'd1);    // |128*z|
        den_mag = 18'd256 + {2'b00, az};            // 256+|z|
        q_mag   = num_mag / den_mag;                // unsigned, trunc toward 0
        q       = z[15] ? -q_mag : q_mag;
        sh_sigmoid = 16'sd128 + q[15:0];
    end
endfunction

// ---------------- shadow reset --------------------------------------------
task sh_reset;
    integer i;
    begin
        for (i = 0; i < W_TOT; i = i + 1) sh_w[i] = 16'sd0;
        for (i = 0; i < FEATURES; i = i + 1) sh_pix[i] = 8'h00;
        sh_acc48 = 48'sd0; sh_tmp48 = 48'sd0; sh_e16 = 48'sd0;
        sh_sample = 32'd0; sh_correct = 32'd0; sh_error = 32'd0;
        sh_err = 1'b0; sh_pred = 8'd0;
        sh_px_cnt = {W_F{1'b0}}; sh_resync = 1'b0;
        sh_sample_valid = 1'b0; sh_pending_label = 8'd0;
        sh_last_label = 8'd0;
        sh_run_active = 1'b0; sh_step_mode = 1'b0; sh_halt_pending = 1'b0;
        sh_freeze = 1'b0; sh_done = 1'b0;
        sh_lr = 4'd8; sh_waddr = 16'd0; sh_winit = 16'd0;
        sh_init_busy = 1'b0; sh_init_addr = 16'd0; sh_processing = 1'b0;
        sh_beats = 32'd0; sh_frames_good = 32'd0; sh_frames_bad = 32'd0;
    end
endtask

// ---------------- shadow CSR write (mirrors apb_regs + weight_ram) --------
// Called once per DUT APB write (mapped addresses only).
task sh_ctrl_write;
    input [31:0] addr;
    input [31:0] data;
    begin
        case (addr[5:2])
            4'd0: begin                          // CTRL 0x00
                sh_freeze = data[3];
                if (data[0] || data[1]) begin
                    // start/step take effect only when the learner is IDLE
                    if (!sh_processing) begin
                        sh_run_active = 1'b1;
                        sh_step_mode  = data[1];
                        sh_done       = 1'b0;
                    end
                end
                if (data[2] && !(data[0] || data[1])) begin
                    if (sh_processing) sh_halt_pending = 1'b1;
                    else sh_done = 1'b1;         // idle halt: done only
                end
                if (data[4]) begin
                    sh_sample = 32'd0; sh_correct = 32'd0; sh_error = 32'd0;
                    sh_err = 1'b0;
                end
                if (data[5] && !sh_run_active && !sh_processing && !sh_init_busy) begin
                    sh_init_busy = 1'b1;         // walk starts (1st write next cycle)
                    sh_init_addr = 16'd0;        // DUT resets walk_addr on init_go
                end
            end
            4'd1: sh_lr = data[3:0];             // LRN_RATE
            4'd7: sh_waddr = data[15:0];         // WADDR
            4'd8: begin                          // WDATA
                if (!sh_init_busy) begin
                    sh_w[sh_waddr] = data[15:0];
                    sh_waddr = sh_waddr + 16'd1;
                end
            end
            4'd9: sh_winit = data[15:0];         // W_INIT_VAL
            default: ;                           // unreachable (TB filters)
        endcase
    end
endtask

// ---------------- init-walk per-cycle step (mirrors weight_ram FSM-003) ---
// The DUT walks W_TOT words (1/cycle) while init_busy; WDATA CSR writes are
// dropped meanwhile (mirrored in sh_ctrl_write). Call once per clock cycle.
task sh_walk_cycle;
    begin
        if (sh_init_busy) begin
            sh_w[sh_init_addr] = sh_winit;
`ifdef L7_WDBG
            if (sh_init_addr == 16'd11)
                $display("WALK t=%0t addr=11 val=%04x winit=%04x busy=%b", $time, sh_winit,
                         sh_winit, sh_init_busy);
`endif
            if (sh_init_addr == W_TOT-1) sh_init_busy = 1'b0;
            else sh_init_addr = sh_init_addr + 16'd1;
        end
    end
endtask

// ---------------- shadow stream byte (mirrors sample_stream FSM-002) ------
// Called once per ACCEPTED beat (s_valid && s_ready) with the byte + last.
task sh_stream_byte;
    input [7:0] d;
    input       last;
    begin
        sh_beats = sh_beats + 32'd1;
        if (sh_resync) begin
            if (last) begin
                sh_resync = 1'b0;
                sh_px_cnt = {W_F{1'b0}};   // DUT resets px_cnt on RESYNC exit
            end
        end else if (sh_px_cnt < FEATURES) begin
            if (last) begin
                sh_err = 1'b1;                   // early last: malformed
                sh_sample_valid = 1'b0;          // DUT clears sample_valid
                sh_frames_bad = sh_frames_bad + 32'd1;
                sh_resync = 1'b1;
            end else begin
                sh_pix[sh_px_cnt] = d;
                sh_px_cnt = sh_px_cnt + 1'b1;
            end
        end else begin
            if (last) begin
                sh_px_cnt = {W_F{1'b0}};         // valid frame captured (level)
                sh_sample_valid = 1'b1;
                sh_pending_label = d;
            end else begin
                sh_err = 1'b1;                   // missing last: malformed
                sh_sample_valid = 1'b0;
                sh_frames_bad = sh_frames_bad + 32'd1;
                sh_resync = 1'b1;
            end
        end
    end
endtask

// ---------------- accept check (mirrors learner IDLE-accept) --------------
// Call once per clock cycle. When the learner is idle+running and a sample
// is pending, it accepts (processes) it — mirrors FSM-001 IDLE rule.
task sh_accept_check;
    begin
        if (sh_sample_valid && sh_run_active && !sh_processing) begin
            sh_sample_valid = 1'b0;
            sh_proc(sh_pending_label, sh_freeze, sh_lr);
        end
    end
endtask

// ---------------- shadow sample processing (C-model transaction) ---------
task sh_proc;
    input [7:0] label;
    input       freeze_i;
    input [3:0] lr_i;
    integer f, h, c;
    reg signed [15:0] a_h [0:255];
    reg signed [15:0] y   [0:255];
    reg signed [15:0] d_o [0:255];
    reg signed [15:0] d_h [0:255];
    reg signed [31:0] prod;
    reg signed [15:0] x16;              // pixel as SIGNED 16-bit (0..255)
    reg signed [47:0] acc, tmp, e16;
    reg [7:0] pred;
    begin
        sh_processing = 1'b1;
        sh_frames_good = sh_frames_good + 32'd1;

        // ---- forward hidden ----
        for (h = 0; h < HIDDEN; h = h + 1) begin
            acc = sh_sext16(sh_w[FEATURES*HIDDEN + h]) << 8;
            for (f = 0; f < FEATURES; f = f + 1) begin
                x16  = {8'b0, sh_pix[f]};
                prod = sh_w[h*FEATURES + f] * x16;   // signed x signed
                acc  = acc + sh_sext32(prod);
            end
            a_h[h] = sh_sigmoid(sh_sat16(sh_trunc_pow2(acc, 6'd8)));
            sh_ah[h] = a_h[h];
`ifdef L7_FWDBG
            if (h == 2) begin : h2dbg
                reg signed [47:0] a1, a2, a3, a4;
                a1 = sh_sext16(sh_w[8]) * {8'b0, sh_pix[0]};
                a2 = sh_sext16(sh_w[9]) * {8'b0, sh_pix[1]};
                a3 = sh_sext16(sh_w[10]) * {8'b0, sh_pix[2]};
                a4 = sh_sext16(sh_w[11]) * {8'b0, sh_pix[3]};
                $display("FWDH2 t=%0t b16=%04x bsext=%0d p=%0d %0d %0d %0d acc=%0d z=%0d ah=%0d",
                         $time, sh_w[16], sh_sext16(sh_w[16]), a1, a2, a3, a4, acc,
                         sh_sat16(sh_trunc_pow2(acc, 6'd8)), a_h[h]);
            end
`endif
        end
        // ---- forward output + argmax (lowest index on tie) ----
        pred = 8'd0;
        for (c = 0; c < CLASSES; c = c + 1) begin
            acc = sh_sext16(sh_w[FEATURES*HIDDEN + HIDDEN + HIDDEN*CLASSES + c]) << 8;
            for (h = 0; h < HIDDEN; h = h + 1) begin
                prod = sh_w[FEATURES*HIDDEN + HIDDEN + c*HIDDEN + h] * a_h[h];
                acc = acc + sh_sext32(prod);
            end
            y[c] = sh_sigmoid(sh_sat16(sh_trunc_pow2(acc, 6'd8)));
            if (y[c] > y[pred]) pred = c;
        end
        sh_pred = pred;
        sh_last_label = label;
`ifdef L7_DDBG
        begin : ddbg
            integer dc;
            for (dc = 0; dc < HIDDEN; dc = dc + 1)
                if (d_h[dc] !== dut.u_learner.delta_h_m[dc])
                    $display("DDIFF t=%0t h=%0d sh=%0d dut=%0d", $time, dc, d_h[dc],
                             dut.u_learner.delta_h_m[dc]);
        end
`endif
`ifdef L7_FWDBG
        $display("FWD t=%0t y=%0d %0d pred=%0d label=%0d freeze=%b lr=%0d w0=%04x w16=%04x",
                 $time, y[0], y[1], pred, label, freeze_i, lr_i, sh_w[0], sh_w[16]);
`endif

        // ---- counters (the RTL counts at DONE; this transaction runs at
        // the DUT's done edge, so clr_stats between accept and done hits
        // both sides symmetrically) ----
        if (sh_sample != 32'hFFFFFFFF) sh_sample = sh_sample + 32'd1;
        if (pred == label) begin
            if (sh_correct != 32'hFFFFFFFF) sh_correct = sh_correct + 32'd1;
        end else begin
            if (sh_error != 32'hFFFFFFFF) sh_error = sh_error + 32'd1;
        end

        if (!freeze_i) begin
            // ---- backprop ----
            for (c = 0; c < CLASSES; c = c + 1) begin
                tmp = (sh_sext16(y[c]) - (c == label ? 48'sd256 : 48'sd0))
                    * sh_sext16(y[c]) * (48'sd256 - sh_sext16(y[c]));
                d_o[c] = sh_sat16(sh_trunc_pow2(tmp, 6'd16));
            end
            for (h = 0; h < HIDDEN; h = h + 1) begin
                e16 = 48'sd0;
                for (c = 0; c < CLASSES; c = c + 1) begin
                    prod = sh_w[FEATURES*HIDDEN + HIDDEN + c*HIDDEN + h] * d_o[c];
                    e16 = e16 + sh_sext32(prod);
                end
                tmp = e16 * sh_sext16(a_h[h]) * (48'sd256 - sh_sext16(a_h[h]));
                d_h[h] = sh_sat16(sh_trunc_pow2(tmp, 6'd24));
            end
            // ---- update (eta = 2^-lr) ----
            for (c = 0; c < CLASSES; c = c + 1) begin
                for (h = 0; h < HIDDEN; h = h + 1) begin
                    prod = d_o[c] * a_h[h];
                    sh_w[FEATURES*HIDDEN + HIDDEN + c*HIDDEN + h] =
                        sh_sat16(sh_sext16(sh_w[FEATURES*HIDDEN + HIDDEN + c*HIDDEN + h])
                                 - sh_trunc_pow2(sh_sext32(prod), {2'b00, lr_i} + 6'd8));
                end
                sh_w[FEATURES*HIDDEN + HIDDEN + HIDDEN*CLASSES + c] =
                    sh_sat16(sh_sext16(sh_w[FEATURES*HIDDEN + HIDDEN + HIDDEN*CLASSES + c])
                             - sh_trunc_pow2(sh_sext16(d_o[c]), {2'b00, lr_i}));
            end
            for (h = 0; h < HIDDEN; h = h + 1) begin
                for (f = 0; f < FEATURES; f = f + 1) begin
                    x16  = {8'b0, sh_pix[f]};
                    prod = d_h[h] * x16;             // signed x signed
                    sh_w[h*FEATURES + f] =
                        sh_sat16(sh_sext16(sh_w[h*FEATURES + f])
                                 - sh_trunc_pow2(sh_sext32(prod), {2'b00, lr_i} + 6'd8));
                end
                sh_w[FEATURES*HIDDEN + h] =
                    sh_sat16(sh_sext16(sh_w[FEATURES*HIDDEN + h])
                             - sh_trunc_pow2(sh_sext16(d_h[h]), {2'b00, lr_i}));
            end
        end

        // ---- control: done semantics ----
        if (sh_step_mode || sh_halt_pending) begin
            sh_run_active = 1'b0;
            sh_done = 1'b1;
        end
        sh_step_mode = 1'b0;
        sh_halt_pending = 1'b0;
        // NOTE: sh_processing stays 1 until the DUT's sample_done (the
        // driver clears it) — mirrors the DUT's ~390-cycle busy window so
        // start/step/init_weights issued mid-processing are rejected here
        // exactly as the DUT rejects them.
    end
endtask

// ---------------- done processing (mirrors learner DONE state) ------------
// Called when the DUT's sample_done_p fires: counters increment (saturating),
// step/halt -> idle with done, busy window ends.
task sh_done_sample;
    begin
`ifdef L7_DONEDBG
        $display("DONE t=%0t pred=%0d lastlabel=%0d", $time, sh_pred, sh_last_label);
`endif
        if (sh_sample != 32'hFFFFFFFF) sh_sample = sh_sample + 32'd1;
        if (sh_pred == sh_last_label) begin
            if (sh_correct != 32'hFFFFFFFF) sh_correct = sh_correct + 32'd1;
        end else begin
            if (sh_error != 32'hFFFFFFFF) sh_error = sh_error + 32'd1;
        end
        if (sh_step_mode || sh_halt_pending) begin
            sh_run_active = 1'b0;
            sh_done = 1'b1;
        end
        sh_step_mode = 1'b0;
        sh_halt_pending = 1'b0;
        sh_processing = 1'b0;
    end
endtask

`endif // TB_COMMON_L7_SHADOW_VH
