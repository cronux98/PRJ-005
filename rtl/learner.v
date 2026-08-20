//---------------------------------------------------------------------
// Module      : learner
// Project     : rinriAI   Technology : Sky130 130 nm
// Traces      : REQ-002, REQ-003, REQ-004, REQ-005, REQ-011, REQ-016,
//               REQ-017, REQ-021  (arch.md 4.4, BLK-004)
// Description : Training/inference datapath + control core (FSM-001).
//               Forward pass, backprop, online SGD per sample; run/step/
//               halt semantics; instantiates BLK-007 div_seq for the
//               sigmoid rational approximation. Bit-exact with
//               arch/golden_model/golden_ref_model.c (arch.md 5 contract).
// Clock/Reset : clk_core (CD_CORE) / rst_n (synchronous, active low, ASM-002)
// Assumptions : Pixel reads (x_rdata) and weight-RAM port-A reads (a_rdata)
//               are COMBINATIONAL. div_num/div_den are combinational from
//               z_reg and are stable for the whole division because z_reg is
//               only written at a FWD finalize step, never while div runs.
//               W_F/W_H/W_C must satisfy 2^W_F>FEATURES, 2^W_H>HIDDEN,
//               2^W_C>CLASSES (counters reach the terminal count). Defaults
//               (784/32/10 -> 12/6/4) satisfy this; the TB checks overrides.
// Deviations  :
//   - OI-008 fix: accept_en = run_active && IDLE && !sample_valid (adds the
//     !sample_valid term vs arch.md 6.2 text) to close the 1-cycle window
//     where a back-to-back feeder could overwrite the pending sample.
//   - BP_O/UPD_O read the PER-CLASS y from MEM-004 (out_delta[c]), NOT the
//     scalar y_reg (which only holds the last class's y): arch.md 5.3 uses
//     y[c] per class and the golden model is authoritative.
//   - div_den = 256 + |z|: |z| is the true 16-bit magnitude
//     (z[15] ? -z[15:0] : z[15:0]) zero-extended to 17 bits; a literal
//     17-bit two's-complement negate would leave bit16 set and corrupt the
//     divisor, so the magnitude is taken in 16 bits (matches golden az).
//   - micro-state ms is 3 bits: FSM-001 BP_H has five micro-steps (0..4),
//     which do not fit 2 bits; all other states use 0..3.
//   - Phase-counter resets added where FSM-001 omits them but the schedule
//     requires them (UPD_O->next class resets h_cnt; UPD_O->UPD_H resets
//     h_cnt and f_cnt). Transaction-level golden model is unaffected.
// Source      : custom (no external IP)
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module learner #(
    parameter integer FEATURES = 784,   // input pixels, legal 1..4096
    parameter integer HIDDEN   = 32,    // hidden units, legal 1..512
    parameter integer CLASSES  = 10,    // output classes, legal 1..256
    parameter integer W_F      = 12,    // pixel counter / x_addr width
    parameter integer W_H      = 6,     // hidden counter width
    parameter integer W_C      = 4      // class counter width
) (
    input  wire                 clk_core,     // core clock (CD_CORE)
    input  wire                 rst_n,        // synchronous active-low reset

    // IFI-001 : control in (from BLK-002)
    input  wire                 start_p,      // 1-cycle: begin continuous run
    input  wire                 step_p,       // 1-cycle: process one sample
    input  wire                 halt_p,       // 1-cycle: graceful stop
    input  wire                 freeze,       // level: inference only (no BP/WU)
    input  wire [3:0]           lr_shift,     // level: eta = 2^-lr_shift

    // IFI-002 : stats out (to BLK-006)
    output reg                  sample_done_p,// 1-cycle: sample processed
    output reg                  correct_p,    // 1-cycle: pred == label
    output reg                  error_p,      // 1-cycle: pred != label
    output wire [7:0]           pred,         // level: last predicted class

    // IFI-003 : sample port (with BLK-003)
    input  wire                 sample_valid, // level: sample ready
    input  wire [7:0]           label,        // level: captured label
    output reg                  ack_p,        // 1-cycle: sample accepted
    output reg  [W_F-1:0]       x_addr,       // pixel read address
    input  wire [7:0]           x_rdata,      // combinational pixel read

    // IFI-004 : weight RAM port A (to BLK-005)
    output reg  [15:0]          a_addr,       // port A address
    output wire [15:0]          a_wdata,      // port A write data
    output reg                  a_we,         // port A write enable
    input  wire [15:0]          a_rdata,      // port A combinational read

    // IFI-008 : stream backpressure (to BLK-003)
    output wire                 accept_en,    // s_ready = accept_en (OI-008)

    // IFI-009 : status (to BLK-002)
    output wire                 busy,         // run_active
    output wire                 done          // step/halt completed
);

    //-----------------------------------------------------------------
    // FSM-001 state encoding (arch.md 6.1)
    //-----------------------------------------------------------------
    localparam [2:0] ST_IDLE  = 3'd0,
                     ST_FWD_H = 3'd1,
                     ST_FWD_O = 3'd2,
                     ST_BP_O  = 3'd3,
                     ST_BP_H  = 3'd4,
                     ST_UPD_O = 3'd5,
                     ST_UPD_H = 3'd6,
                     ST_DONE  = 3'd7;

    // Weight address-map bases (arch.md 7)
    localparam [31:0] OFF_BH_C = FEATURES*HIDDEN;                       // b_h base
    localparam [31:0] OFF_WO_C = FEATURES*HIDDEN + HIDDEN;              // w_o base
    localparam [31:0] OFF_BO_C = FEATURES*HIDDEN + HIDDEN + HIDDEN*CLASSES; // b_o base

    //-----------------------------------------------------------------
    // Fixed-point helpers (bit-exact with golden_ref_model.c, arch.md 5.2)
    //-----------------------------------------------------------------
    // trunc(x / 2^n) toward zero: magnitude-shift-negate (never a bare >>>)
    function signed [47:0] trunc_pow2;
        input signed [47:0] x;
        input        [5:0]  n;
        reg          [47:0] mag;                 // unsigned magnitude
        begin
            mag       = x[47] ? (~x + 48'd1) : x;   // |x|
            mag       = mag >> n;                   // logical shift (unsigned)
            trunc_pow2 = x[47] ? (48'd0 - mag) : mag;
        end
    endfunction

    // saturate to signed 16-bit
    function [15:0] sat16;
        input signed [47:0] x;
        begin
            if      (x >  48'sd32767) sat16 = 16'h7FFF;
            else if (x < -48'sd32768) sat16 = 16'h8000;
            else                      sat16 = x[15:0];
        end
    endfunction

    //-----------------------------------------------------------------
    // Control / datapath registers
    //-----------------------------------------------------------------
    reg [2:0]        state_r;
    reg [2:0]        ms;               // micro-state (0..4; 3 bits, see header)

    reg [W_F-1:0]    f_cnt;            // pixel index
    reg [W_H-1:0]    h_cnt;            // hidden index
    reg [W_C-1:0]    c_cnt;            // class index

    reg              run_active;       // busy
    reg              step_mode;        // single-sample mode
    reg              halt_pending;     // halt requested, applied at DONE
    reg              freeze_ff;        // inference-only for this sample
    reg              done_ff;          // step/halt completed
    reg [3:0]        lr_shift_ff;      // captured lr_shift
    reg [7:0]        label_ff;         // captured label
    reg [15:0]       best_val;         // argmax running max (sigma, positive)
    reg [W_C-1:0]    best_idx;         // argmax index

    reg signed [47:0] acc;             // MAC accumulator (Q16.16)
    reg signed [15:0] z_reg;           // pre-activation (Q8.8)
    reg signed [15:0] y_reg;           // last output sigma (observability only)
    reg signed [47:0] tmp;             // BP scratch product
    reg signed [47:0] e16;             // hidden error sum
    reg signed [15:0] w_r;             // registered port-A read (for RMW)
    reg signed [47:0] upd;             // computed weight decrement
    reg               div_start;       // 1-cycle start pulse to div_seq

    // Local memories (single-owner writes: this module's clocked block)
    reg [15:0] act_h     [0:HIDDEN-1];  // MEM-003 : hidden activations a_h
    reg [15:0] out_delta [0:CLASSES-1]; // MEM-004 : y[c] then delta_o[c]
    reg [15:0] delta_h_m [0:HIDDEN-1];  // MEM-005 : delta_h[h]

    integer ri;                         // reset-loop var (used in ONE block only)

    //-----------------------------------------------------------------
    // Combinational reads and typed operands
    //-----------------------------------------------------------------
    wire signed [15:0] a_rd_s   = a_rdata;               // weight, signed Q8.8
    wire signed [15:0] x_rd_s   = {8'b0, x_rdata};       // pixel, 0..255 (positive)
    wire        [15:0] act_h_rd = act_h[h_cnt];
    wire        [15:0] out_rd   = out_delta[c_cnt];
    wire        [15:0] dh_rd    = delta_h_m[h_cnt];
    wire signed [15:0] act_h_s  = act_h_rd;              // a_h in [1,255] (positive)
    wire signed [15:0] out_rd_s = out_rd;                // y[c] or delta_o[c]
    wire signed [15:0] dh_rd_s  = dh_rd;                 // delta_h[h]

    // Forward MAC: weight * (x in FWD_H, a_h in FWD_O)
    wire               fwd_hidden = (state_r == ST_FWD_H);
    wire signed [15:0] mac_b      = fwd_hidden ? x_rd_s : act_h_s;
    wire signed [31:0] mac_prod   = a_rd_s * mac_b;

    // BP_H hidden-error term: w_o[c][h] * delta_o[c]
    wire signed [31:0] wo_do_prod = a_rd_s * out_rd_s;

    // BP_O per-class terms (y_c held in MEM-004 until BP_O ms=2 overwrite)
    wire [7:0]         cc_ext   = {{(8-W_C){1'b0}}, c_cnt};
    wire               is_label = (cc_ext == label_ff);
    wire signed [15:0] t_val    = is_label ? 16'sd256 : 16'sd0;
    wire signed [15:0] bp_ymt   = out_rd_s - t_val;      // (y - t)
    wire signed [15:0] bp_256my = 16'sd256 - out_rd_s;   // (256 - y)
    wire signed [31:0] bp_p0    = bp_ymt * out_rd_s;     // (y-t)*y
    // BP_H derivative surrogate a*(256-a)
    wire signed [15:0] bp_256ma = 16'sd256 - act_h_s;
    wire signed [31:0] bp_aprod = act_h_s * bp_256ma;    // a*(256-a) (positive)

    // Update operands (sign-extended to 48 for trunc_pow2)
    wire signed [31:0] do_ah_p  = out_rd_s * act_h_s;    // delta_o * a_h
    wire signed [31:0] dh_x_p   = dh_rd_s * x_rd_s;      // delta_h * x
    wire signed [47:0] do_ah_48 = {{16{do_ah_p[31]}}, do_ah_p};
    wire signed [47:0] dh_x_48  = {{16{dh_x_p[31]}},  dh_x_p};
    wire signed [47:0] do_48    = {{32{out_rd_s[15]}}, out_rd_s}; // delta_o (bias)
    wire signed [47:0] dh_48    = {{32{dh_rd_s[15]}},  dh_rd_s};  // delta_h (bias)
    wire        [5:0]  n_wgt    = {2'b00, lr_shift_ff} + 6'd8;    // lr_shift+8
    wire        [5:0]  n_bias   = {2'b00, lr_shift_ff};           // lr_shift

    // Sigmoid I/O to div_seq: num = 128*z, den = 256+|z|, sigma = 128 + q
    wire signed [31:0] div_num_w = {{9{z_reg[15]}}, z_reg[15:0], 7'b0};
    wire        [15:0] absz16    = z_reg[15] ? (~z_reg[15:0] + 16'd1) : z_reg[15:0];
    wire        [16:0] div_den_w = 17'd256 + {1'b0, absz16};
    wire               div_busy_w;                       // unused (guard n/a)
    wire               div_done_w;
    wire signed [16:0] div_q;
    wire signed [17:0] sigma_s   = 18'sd128 + {div_q[16], div_q}; // 128 + q, [1,255]
    wire        [15:0] sigma16   = sigma_s[15:0];

    // Weight-map address components (16-bit-truncatable; W_TOT <= 65535)
    wire [31:0] addr_wh = (h_cnt * FEATURES) + f_cnt;    // w_h[h][f]
    wire [31:0] addr_bh = OFF_BH_C + h_cnt;              // b_h[h]
    wire [31:0] addr_wo = OFF_WO_C + (c_cnt * HIDDEN) + h_cnt; // w_o[c][h]
    wire [31:0] addr_bo = OFF_BO_C + c_cnt;              // b_o[c]

    // Write-back datum: sat16(w_r - upd)
    wire signed [47:0] w_r_48   = {{32{w_r[15]}}, w_r};
    wire signed [47:0] w_sub    = w_r_48 - upd;
    assign a_wdata = sat16(w_sub);

    // Status / observability
    wire [7:0] bidx_ext = {{(8-W_C){1'b0}}, best_idx};
    wire       best_eq  = (bidx_ext == label_ff);
    assign accept_en = run_active && (state_r == ST_IDLE) && !sample_valid;
    assign busy      = run_active;
    assign done      = done_ff;
    assign pred      = {{(8-W_C){1'b0}}, best_idx};   // OI-005: last argmax index

    //-----------------------------------------------------------------
    // BLK-007 divider instance (named ports only)
    //-----------------------------------------------------------------
    div_seq u_div (
        .clk_core (clk_core),
        .rst_n    (rst_n),
        .div_start(div_start),
        .div_num  (div_num_w),
        .div_den  (div_den_w),
        .div_busy (div_busy_w),
        .div_done (div_done_w),
        .div_q    (div_q)
    );

    //-----------------------------------------------------------------
    // Port-A / pixel address + write-enable decode (combinational).
    // Defaults on entry -> no latch; every case has a default.
    //-----------------------------------------------------------------
    always @* begin
        a_addr = 16'd0;
        x_addr = {W_F{1'b0}};
        a_we   = 1'b0;
        case (state_r)
            ST_FWD_H: begin
                if (ms == 3'd0)      a_addr = addr_bh[15:0];          // read b_h[h]
                else if (ms == 3'd1) begin
                    a_addr = addr_wh[15:0];                           // read w_h[h][f]
                    x_addr = f_cnt;                                   // read x[f]
                end
            end
            ST_FWD_O: begin
                if (ms == 3'd0)      a_addr = addr_bo[15:0];          // read b_o[c]
                else if (ms == 3'd1) a_addr = addr_wo[15:0];          // read w_o[c][h]
            end
            ST_BP_H: begin
                if (ms == 3'd1)      a_addr = addr_wo[15:0];          // read w_o[c][h]
            end
            ST_UPD_O: begin
                if (ms == 3'd0)
                    a_addr = (h_cnt < HIDDEN) ? addr_wo[15:0] : addr_bo[15:0]; // read
                else if (ms == 3'd2) begin
                    a_addr = addr_wo[15:0];                           // write w_o[c][h]
                    a_we   = 1'b1;
                end
                else if (ms == 3'd3) begin
                    a_addr = addr_bo[15:0];                           // write b_o[c]
                    a_we   = 1'b1;
                end
            end
            ST_UPD_H: begin
                if (ms == 3'd0)
                    a_addr = (f_cnt < FEATURES) ? addr_wh[15:0] : addr_bh[15:0]; // read
                else if (ms == 3'd1) x_addr = f_cnt;                  // read x[f]
                else if (ms == 3'd2) begin
                    a_addr = addr_wh[15:0];                           // write w_h[h][f]
                    a_we   = 1'b1;
                end
                else if (ms == 3'd3) begin
                    a_addr = addr_bh[15:0];                           // write b_h[h]
                    a_we   = 1'b1;
                end
            end
            default: begin
                a_addr = 16'd0;
                x_addr = {W_F{1'b0}};
                a_we   = 1'b0;
            end
        endcase
    end

    //-----------------------------------------------------------------
    // FSM-001 + datapath (single clocked owner, synchronous reset ASM-002).
    // Non-blocking only. Output pulses default low each cycle.
    //-----------------------------------------------------------------
    always @(posedge clk_core) begin
        if (!rst_n) begin : reset_blk
            state_r      <= ST_IDLE;
            ms           <= 3'd0;
            f_cnt        <= {W_F{1'b0}};
            h_cnt        <= {W_H{1'b0}};
            c_cnt        <= {W_C{1'b0}};
            run_active   <= 1'b0;
            step_mode    <= 1'b0;
            halt_pending <= 1'b0;
            freeze_ff    <= 1'b0;
            done_ff      <= 1'b0;
            lr_shift_ff  <= 4'd8;                 // REQ-005 reset value
            label_ff     <= 8'd0;
            best_val     <= 16'd0;
            best_idx     <= {W_C{1'b0}};
            acc          <= 48'sd0;
            z_reg        <= 16'sd0;
            y_reg        <= 16'sd0;
            tmp          <= 48'sd0;
            e16          <= 48'sd0;
            w_r          <= 16'sd0;
            upd          <= 48'sd0;
            div_start    <= 1'b0;
            ack_p        <= 1'b0;
            sample_done_p<= 1'b0;
            correct_p    <= 1'b0;
            error_p      <= 1'b0;
            for (ri = 0; ri < HIDDEN;  ri = ri + 1) act_h[ri]     <= 16'd0;
            for (ri = 0; ri < HIDDEN;  ri = ri + 1) delta_h_m[ri] <= 16'd0;
            for (ri = 0; ri < CLASSES; ri = ri + 1) out_delta[ri] <= 16'd0;
        end else begin
            // single-cycle pulses default low; states override
            ack_p         <= 1'b0;
            sample_done_p <= 1'b0;
            correct_p     <= 1'b0;
            error_p       <= 1'b0;
            div_start     <= 1'b0;

            // halt requested outside IDLE -> apply at DONE
            if (halt_p && (state_r != ST_IDLE)) halt_pending <= 1'b1;

            case (state_r)
            //---------------------------------------------------------
            ST_IDLE: begin
                if (start_p || step_p) begin      // start/step only in IDLE
                    run_active <= 1'b1;
                    step_mode  <= step_p;
                    done_ff    <= 1'b0;
                end
                if (halt_p) done_ff <= 1'b1;
                if (run_active && sample_valid) begin
                    ack_p       <= 1'b1;          // accept the pending sample
                    label_ff    <= label;
                    best_val    <= 16'd0;
                    best_idx    <= {W_C{1'b0}};
                    h_cnt       <= {W_H{1'b0}};
                    c_cnt       <= {W_C{1'b0}};
                    f_cnt       <= {W_F{1'b0}};
                    freeze_ff   <= freeze;
                    lr_shift_ff <= lr_shift;
                    ms          <= 3'd0;
                    state_r     <= ST_FWD_H;
                end
            end
            //---------------------------------------------------------
            ST_FWD_H: begin
                case (ms)
                    3'd0: begin                   // preload bias_h << 8
                        acc   <= {{24{a_rdata[15]}}, a_rdata, 8'b0};
                        f_cnt <= {W_F{1'b0}};
                        ms    <= 3'd1;
                    end
                    3'd1: begin
                        if (f_cnt < FEATURES) begin
                            acc   <= acc + {{16{mac_prod[31]}}, mac_prod};
                            f_cnt <= f_cnt + 1'b1;
                        end else begin
                            z_reg     <= sat16(trunc_pow2(acc, 6'd8));
                            div_start <= 1'b1;
                            ms        <= 3'd2;
                        end
                    end
                    3'd2: begin                   // wait divider, store sigma
                        if (div_done_w) begin
                            act_h[h_cnt] <= sigma16;
                            ms           <= 3'd3;
                        end
                    end
                    3'd3: begin
                        if (h_cnt == HIDDEN-1) begin
                            c_cnt   <= {W_C{1'b0}};
                            ms      <= 3'd0;
                            state_r <= ST_FWD_O;
                        end else begin
                            h_cnt <= h_cnt + 1'b1;
                            ms    <= 3'd0;
                        end
                    end
                    default: ms <= 3'd0;
                endcase
            end
            //---------------------------------------------------------
            ST_FWD_O: begin
                case (ms)
                    3'd0: begin                   // preload bias_o << 8
                        acc   <= {{24{a_rdata[15]}}, a_rdata, 8'b0};
                        h_cnt <= {W_H{1'b0}};
                        ms    <= 3'd1;
                    end
                    3'd1: begin
                        if (h_cnt < HIDDEN) begin
                            acc   <= acc + {{16{mac_prod[31]}}, mac_prod};
                            h_cnt <= h_cnt + 1'b1;
                        end else begin
                            z_reg     <= sat16(trunc_pow2(acc, 6'd8));
                            div_start <= 1'b1;
                            ms        <= 3'd2;
                        end
                    end
                    3'd2: begin                   // sigma -> y[c], argmax on new value
                        if (div_done_w) begin
                            y_reg            <= sigma16;
                            out_delta[c_cnt] <= sigma16;
                            if (sigma16 > best_val) begin
                                best_val <= sigma16;
                                best_idx <= c_cnt;
                            end
                            ms <= 3'd3;
                        end
                    end
                    3'd3: begin
                        if (c_cnt == CLASSES-1) begin
                            if (freeze_ff) begin
                                ms      <= 3'd0;
                                state_r <= ST_DONE;
                            end else begin
                                h_cnt   <= {W_H{1'b0}};
                                c_cnt   <= {W_C{1'b0}};
                                ms      <= 3'd0;
                                state_r <= ST_BP_O;
                            end
                        end else begin
                            c_cnt <= c_cnt + 1'b1;
                            ms    <= 3'd0;
                        end
                    end
                    default: ms <= 3'd0;
                endcase
            end
            //---------------------------------------------------------
            ST_BP_O: begin
                case (ms)
                    3'd0: begin                   // (y-t)*y ; y from MEM-004[c]
                        tmp <= {{16{bp_p0[31]}}, bp_p0};
                        ms  <= 3'd1;
                    end
                    3'd1: begin                   // *(256-y)
                        tmp <= tmp * bp_256my;
                        ms  <= 3'd2;
                    end
                    3'd2: begin                   // delta_o = sat16(trunc(tmp,16))
                        out_delta[c_cnt] <= sat16(trunc_pow2(tmp, 6'd16));
                        ms               <= 3'd3;
                    end
                    3'd3: begin
                        if (c_cnt == CLASSES-1) begin
                            h_cnt   <= {W_H{1'b0}};
                            c_cnt   <= {W_C{1'b0}};
                            ms      <= 3'd0;
                            state_r <= ST_BP_H;
                        end else begin
                            c_cnt <= c_cnt + 1'b1;
                            ms    <= 3'd0;
                        end
                    end
                    default: ms <= 3'd0;
                endcase
            end
            //---------------------------------------------------------
            ST_BP_H: begin
                case (ms)
                    3'd0: begin                   // e16 = 0
                        e16   <= 48'sd0;
                        c_cnt <= {W_C{1'b0}};
                        ms    <= 3'd1;
                    end
                    3'd1: begin
                        if (c_cnt < CLASSES) begin // e16 += w_o[c][h]*delta_o[c]
                            e16   <= e16 + {{16{wo_do_prod[31]}}, wo_do_prod};
                            c_cnt <= c_cnt + 1'b1;
                        end else begin             // a*(256-a)
                            tmp <= {{16{bp_aprod[31]}}, bp_aprod};
                            ms  <= 3'd2;
                        end
                    end
                    3'd2: begin                   // e16 * (a*(256-a))
                        tmp <= e16 * tmp;
                        ms  <= 3'd3;
                    end
                    3'd3: begin                   // delta_h = sat16(trunc(tmp,24))
                        delta_h_m[h_cnt] <= sat16(trunc_pow2(tmp, 6'd24));
                        ms               <= 3'd4;
                    end
                    3'd4: begin
                        if (h_cnt == HIDDEN-1) begin
                            c_cnt   <= {W_C{1'b0}};
                            h_cnt   <= {W_H{1'b0}};
                            ms      <= 3'd0;
                            state_r <= ST_UPD_O;
                        end else begin
                            h_cnt <= h_cnt + 1'b1;
                            ms    <= 3'd0;
                        end
                    end
                    default: ms <= 3'd0;
                endcase
            end
            //---------------------------------------------------------
            ST_UPD_O: begin
                case (ms)
                    3'd0: begin                   // register weight read for RMW
                        w_r <= a_rdata;
                        if (h_cnt < HIDDEN) begin
                            ms <= 3'd1;
                        end else begin            // bias path
                            upd <= trunc_pow2(do_48, n_bias);
                            ms  <= 3'd3;
                        end
                    end
                    3'd1: begin                   // upd = trunc(delta_o*a_h, lr+8)
                        upd <= trunc_pow2(do_ah_48, n_wgt);
                        ms  <= 3'd2;
                    end
                    3'd2: begin                   // write w_o (a_we in decode); advance h
                        h_cnt <= h_cnt + 1'b1;
                        ms    <= 3'd0;
                    end
                    3'd3: begin                   // write b_o (a_we in decode); advance c
                        if (c_cnt == CLASSES-1) begin
                            h_cnt   <= {W_H{1'b0}};
                            f_cnt   <= {W_F{1'b0}}; // for UPD_H's first hidden
                            ms      <= 3'd0;
                            state_r <= ST_UPD_H;
                        end else begin
                            c_cnt <= c_cnt + 1'b1;
                            h_cnt <= {W_H{1'b0}};   // reset h for next class
                            ms    <= 3'd0;
                        end
                    end
                    default: ms <= 3'd0;
                endcase
            end
            //---------------------------------------------------------
            ST_UPD_H: begin
                case (ms)
                    3'd0: begin                   // register weight read for RMW
                        w_r <= a_rdata;
                        if (f_cnt < FEATURES) begin
                            ms <= 3'd1;
                        end else begin            // bias path
                            upd <= trunc_pow2(dh_48, n_bias);
                            ms  <= 3'd3;
                        end
                    end
                    3'd1: begin                   // upd = trunc(delta_h*x, lr+8)
                        upd <= trunc_pow2(dh_x_48, n_wgt);
                        ms  <= 3'd2;
                    end
                    3'd2: begin                   // write w_h (a_we in decode); advance f
                        f_cnt <= f_cnt + 1'b1;
                        ms    <= 3'd0;
                    end
                    3'd3: begin                   // write b_h (a_we in decode); advance h
                        if (h_cnt == HIDDEN-1) begin
                            ms      <= 3'd0;
                            state_r <= ST_DONE;
                        end else begin
                            h_cnt <= h_cnt + 1'b1;
                            f_cnt <= {W_F{1'b0}};
                            ms    <= 3'd0;
                        end
                    end
                    default: ms <= 3'd0;
                endcase
            end
            //---------------------------------------------------------
            ST_DONE: begin
                sample_done_p <= 1'b1;
                correct_p     <=  best_eq;
                error_p       <= !best_eq;
                if (step_mode || halt_pending) begin
                    run_active <= 1'b0;
                    done_ff    <= 1'b1;
                end
                step_mode    <= 1'b0;
                halt_pending <= 1'b0;
                ms           <= 3'd0;
                state_r      <= ST_IDLE;
            end
            //---------------------------------------------------------
            default: begin                        // illegal-state recovery
                state_r <= ST_IDLE;
                ms      <= 3'd0;
                f_cnt   <= {W_F{1'b0}};
                h_cnt   <= {W_H{1'b0}};
                c_cnt   <= {W_C{1'b0}};
            end
            endcase
        end
    end

endmodule

`default_nettype wire
