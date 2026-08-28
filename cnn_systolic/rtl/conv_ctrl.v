//---------------------------------------------------------------------
// Module      : conv_ctrl
// Project     : cnn_systolic        Technology : Sky130 130 nm
// Traces      : REQ-023, REQ-024, REQ-025, REQ-039, BLK-011
// Description : Conv/pool/FC layer controller + array feed + drain
//               pipeline.  Owns FSM-002 (layer), FSM-003 (sub-pass),
//               the bias staging (MEM-005 via bias_regfile), the
//               layer-start weight loads, the drain → ReLU → BF16 →
//               FM write pipeline (8 writes/cycle overlapped with the
//               next phase), and the result path (ST_PRESENT: conf =
//               (best*100)>>8, verdict = conf<50 ? 2 : (best==exp ?
//               0 : 1)).  The array accumulate ORDER (bias first, then
//               pinned sub-pass order) is realised by the sub-pass
//               schedule: sub_t 0..9 per sub-pass — act_ld at 0, add
//               commits at 2..9 (add_en[c] at sub_t == c+2), swap at 9;
//               weight shadow loads overlap the wavefront (issue at
//               sub_t 0..7, enable at 1..8).  conv1: 2 sub-passes/
//               pixel (A: taps 0..7, B: tap 8 + zero cols); conv2:
//               18 sub-passes/pixel (g = p/9, k = p%9) with a group
//               drain + bias re-init between groups (systolic_dataflow
//               .md §3-4, tiling_plan.md).  Cycle budget per arch
//               §6.5: conv1 22/px, conv2 184/px, pool 6/unit.
// Clock/Reset : clk (CD_CORE, 100 MHz) / rst_n (fully synchronous;
//               rst_n = the shell's core_rst_n park signal)
// Assumptions : reset state ST_IDLE (busy=0, clock gating PWR-001
//               point); the core launches on reset release (image
//               pre-loaded by firmware before START); FM write port is
//               free during conv compute (drain overlaps next phase).
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module conv_ctrl (
    input  wire         clk,          // CD_CORE clock, 100 MHz
    input  wire         rst_n,        // core park reset (fully synchronous)
    input  wire [3:0]   exp_label,    // expected label (CNN_EXP)
    // ---- memories ----
    output wire [9:0]   img_raddr,    // IFI-005 shared img-bank read address
    input  wire [71:0]  img_rdata,    // 9 banks x 8b (tap t = [8t +: 8])
    output wire [7:0]   p1_raddr,     // IFI-005 p1 shared read address
    output wire         p1_zero,      // OOB tap zero mux
    input  wire [127:0] p1_rdata,     // 8 x 16b
    output wire [119:0] wp_addr,      // IFI-008 weight parallel addrs (port c = [15c +: 15])
    input  wire [127:0] wp_data,      // port c = [16c +: 16]
    output reg  [14:0]  ws_addr,      // IFI-012/014 serial addr (bias staging)
    input  wire [15:0]  ws_data,
    // ---- FM port (IFI-009; drain writes / pool2 reads handled here) ----
    output reg  [12:0]  fm_raddr,
    input  wire [15:0]  fm_rdata,
    output reg  [12:0]  fm_waddr,
    output reg  [15:0]  fm_wdata,
    output reg          fm_we,
    // ---- array (IFI-006/007) ----
    output wire [127:0] act_in,       // 8 lanes x 16b BF16
    output reg          act_ld,
    output wire [127:0] w_load_data,  // per-column shadow data
    output wire [63:0]  w_load_en,    // per-PE enable (bit r*8+c)
    output reg          w_swap,
    output wire [255:0] bias_in,      // 8 rows x 32b FP32
    output reg          bias_en,
    output wire [7:0]   add_en,       // per-column add commit
    output wire         drain_en,     // array drain capture
    input  wire [255:0] dout,         // 8 x 32b FP32 sums
    // ---- bias regfile (MEM-005) ----
    output reg  [6:0]   br_widx,
    output reg  [15:0]  br_wdata,
    output reg          br_wen,
    output wire [55:0]  br_a_idx,     // port r = [7r +: 7]
    input  wire [127:0] br_a_data,    // port r = [16r +: 16]
    // ---- pool / fc ----
    output reg          pool_go,
    output reg          pool_mode,    // 0 = pool1, 1 = pool2
    input  wire         pool_done,
    output reg          fc_go,
    output reg          fc_mode,      // 0 = FC1, 1 = FC2
    input  wire         fc_done,
    input  wire [8:0]   fc_best_val,
    input  wire [3:0]   fc_best_idx,
    // ---- result path ----
    output reg  [3:0]   pred,
    output reg  [6:0]   conf,
    output reg  [1:0]   verdict,
    output reg          present,
    output reg          busy,
    // ---- memory ownership (mux selectors for cnn_core) ----
    output wire         pool_active,  // pool owns the FM read/write ports
    output wire         fc_active     // fc owns FM + weight serial ports
);

    // FSM-002 : layer FSM (binary), reset = ST_IDLE
    localparam [3:0] S_IDLE    = 4'd0;
    localparam [3:0] S_CONV1   = 4'd1;
    localparam [3:0] S_POOL1   = 4'd2;
    localparam [3:0] S_CONV2   = 4'd3;
    localparam [3:0] S_POOL2   = 4'd4;
    localparam [3:0] S_FC1     = 4'd5;
    localparam [3:0] S_FC2     = 4'd6;
    localparam [3:0] S_PRESENT = 4'd7;

    // Conv sub-phases (FSM-003 + bias staging + layer-start loads)
    localparam [2:0] P_BSTAGE = 3'd0;  // bias staging (serial ROM reads)
    localparam [2:0] P_WLOAD  = 3'd1;  // layer-start weight shadow load
    localparam [2:0] P_WSWAP  = 3'd2;  // layer-start swap
    localparam [2:0] P_BIAS   = 3'd3;  // pixel/group bias init + first read addrs
    localparam [2:0] P_SUB    = 3'd4;  // sub-pass (sub_t 0..9)
    localparam [2:0] P_DRAIN  = 3'd5;  // pixel/group drain (acc capture)

    reg [3:0] state;
    reg [2:0] phase;
    reg [3:0] sub_t;          // 0..9 within P_SUB
    reg [4:0] pass;           // conv1 0..1 (A/B), conv2 0..17
    reg [4:0] oy, ox;         // pixel coords
    reg [6:0] bcnt;           // bias-staging counter
    reg [3:0] wq;             // layer-start load counter
    reg       wrun;           // FM drain write chain active
    reg [2:0] wcnt;           // drain write index 0..7
    reg [1:0] drain_grp;      // conv2 drained oc-group (0/1)

    wire is_conv1 = (state == S_CONV1);
    wire is_conv2 = (state == S_CONV2);
    wire is_conv  = is_conv1 || is_conv2;
    wire conv_pass_b = is_conv1 && (pass == 5'd1);
    wire conv2_g     = (pass >= 5'd9);              // conv2 oc-group
    wire [4:0] ox_max = is_conv2 ? 5'd13 : 5'd27;
    wire [4:0] oy_max = is_conv2 ? 5'd13 : 5'd27;

    // ---- load mode for the pass being shadow-loaded (the NEXT pass) ----
    // 0 = conv1 pass A (next pixel), 1 = conv1 pass B, 2 = conv2 pass p+1
    wire [1:0] ld_mode = is_conv2 ? 2'd2
                       : (pass == 5'd0) ? 2'd1
                       : 2'd0;
    wire [4:0] pass_nxt = pass + 5'd1;
    wire [1:0] c2_g_nxt = (pass_nxt >= 5'd18) ? 2'd2
                        : (pass_nxt >= 5'd9)  ? 2'd1 : 2'd0;
    wire [3:0] c2_k_nxt = pass_nxt - (c2_g_nxt * 5'd9);

    // ---- load issue/enable windows ----
    wire ld_issue  = (phase == P_SUB)   ? (sub_t <= 4'd7)
                   : (phase == P_WLOAD) ? 1'b1 : 1'b0;
    wire ld_enable = (phase == P_SUB)   ? ((sub_t >= 4'd1) && (sub_t <= 4'd8))
                   : (phase == P_WLOAD) ? (wq >= 4'd1) : 1'b0;
    wire [3:0] ld_q = (phase == P_WLOAD) ? wq : sub_t;
    wire [3:0] en_q = ld_q - 4'd1;

    // ---- per-port load addresses (generate) ----
    genvar pc;
    generate
        for (pc = 0; pc < 8; pc = pc + 1) begin : g_wp
            wire [14:0] a_a  = (9 * ld_q) + pc;                          // conv1 pass A
            wire [14:0] a_b  = (pc == ld_q) ? ((9 * ld_q) + 8) : 15'd0;  // conv1 pass B
            wire [14:0] a_c2 = 15'd80 + ((c2_g_nxt * 8 + ld_q) * 72)     // conv2
                             + (pc * 9) + c2_k_nxt;
            assign wp_addr[15*pc +: 15] = ld_issue
                ? ((ld_mode == 2'd0) ? a_a : (ld_mode == 2'd1) ? a_b : a_c2)
                : 15'd0;
        end
    endgenerate

    // ---- per-PE load enables + per-column load data (generate) ----
    genvar lr, lc;
    generate
        for (lr = 0; lr < 8; lr = lr + 1) begin : g_wle_row
            for (lc = 0; lc < 8; lc = lc + 1) begin : g_wle_col
                wire en_a = (lr == en_q);
                wire en_b = ((lr == en_q) && (lc == 0)) || ((en_q == 0) && (lc != 0));
                assign w_load_en[lr*8 + lc] = ld_enable
                    ? ((ld_mode == 2'd1) ? en_b : en_a) : 1'b0;
            end
        end
        for (lc = 0; lc < 8; lc = lc + 1) begin : g_wld
            assign w_load_data[16*lc +: 16] =
                (ld_mode == 2'd1) ? ((lc == 0) ? wp_data[16*en_q +: 16] : 16'd0)
                                  : wp_data[16*lc +: 16];
        end
    endgenerate

    // ---- per-column add commit strobes (sub_t == c+2 → commits 2..9) ----
    genvar ac;
    generate
        for (ac = 0; ac < 8; ac = ac + 1) begin : g_add
            assign add_en[ac] = (phase == P_SUB) && (sub_t == ac + 4'd2);
        end
    endgenerate

    // ---- array bias rows (expanded BF16 from the regfile) ----
    wire [6:0] bias_base = is_conv1 ? 7'd0
                         : is_conv2 ? (7'd8 + (conv2_g ? 7'd8 : 7'd0))
                         : 7'd0;
    genvar br;
    generate
        for (br = 0; br < 8; br = br + 1) begin : g_bias
            wire [15:0] bv = br_a_data[16*br +: 16];   // this row's BF16 bias
            assign br_a_idx[7*br +: 7] = bias_base + br;
            assign bias_in[32*br +: 32] =
                {bv[15], bv[14:7], bv[6:0], 16'd0};
        end
    endgenerate

    // ---- pixel → BF16 (exact; golden bf16_of_pixel) ----
    function [15:0] bf16_of_pixel;
        input [7:0] p;
        reg [2:0] e7;
        begin
            if (p == 8'd0) begin
                bf16_of_pixel = 16'd0;
            end else begin
                e7 = p[7] ? 3'd7 : p[6] ? 3'd6 : p[5] ? 3'd5 : p[4] ? 3'd4
                   : p[3] ? 3'd3 : p[2] ? 3'd2 : p[1] ? 3'd1 : 3'd0;
                bf16_of_pixel = ((8'd119 + e7) << 7) | ((p << (7 - e7)) & 8'h7F);
            end
        end
    endfunction

    // ---- activation lanes ----
    // conv1: pass A lane c = bank c; pass B lane 0 = bank 8, lanes 1..7 = banks 1..7
    // conv2: lane c = p1 bank c (already BF16)
    wire [15:0] px_bf [0:8];
    genvar pt;
    generate
        for (pt = 0; pt < 9; pt = pt + 1) begin : g_px
            assign px_bf[pt] = bf16_of_pixel(img_rdata[8*pt +: 8]);
        end
    endgenerate

    assign act_in = is_conv2 ? p1_rdata
                  : conv_pass_b
                    ? {px_bf[7], px_bf[6], px_bf[5], px_bf[4],
                       px_bf[3], px_bf[2], px_bf[1], px_bf[8]}
                    : {px_bf[7], px_bf[6], px_bf[5], px_bf[4],
                       px_bf[3], px_bf[2], px_bf[1], px_bf[0]};

    // ---- conv2 p1 tap address (current pass and next pass) ----
    wire [3:0] pk    = (pass    >= 5'd9) ? (pass    - 5'd9) : pass;
    wire [1:0] p_iy  = (pk >= 4'd6) ? 2'd2 : (pk >= 4'd3) ? 2'd1 : 2'd0;
    wire [1:0] p_ix  = pk - (p_iy * 3);
    wire [3:0] pk_n  = (pass_nxt >= 5'd18) ? (pass_nxt - 5'd18)
                     : (pass_nxt >= 5'd9)  ? (pass_nxt - 5'd9) : pass_nxt;
    wire [1:0] p_iy_n = (pk_n >= 4'd6) ? 2'd2 : (pk_n >= 4'd3) ? 2'd1 : 2'd0;
    wire [1:0] p_ix_n = pk_n - (p_iy_n * 3);

    wire signed [8:0] t_oy  = $signed({4'd0, oy}) + $signed(p_iy)  - 9'sd1;
    wire signed [8:0] t_ox  = $signed({4'd0, ox}) + $signed(p_ix)  - 9'sd1;
    wire signed [8:0] t_oyn = $signed({4'd0, oy}) + $signed(p_iy_n) - 9'sd1;
    wire signed [8:0] t_oxn = $signed({4'd0, ox}) + $signed(p_ix_n) - 9'sd1;

    wire p_oob  = (t_oy  < 9'sd0) || (t_oy  >= 9'sd14) ||
                  (t_ox  < 9'sd0) || (t_ox  >= 9'sd14);
    wire p_oobn = (t_oyn < 9'sd0) || (t_oyn >= 9'sd14) ||
                  (t_oxn < 9'sd0) || (t_oxn >= 9'sd14);
    wire [7:0] p_addr  = (t_oy  * 9'sd14) + t_ox;    // low 8 bits; OOB gated
    wire [7:0] p_addrn = (t_oyn * 9'sd14) + t_oxn;

    // The p1 read data corresponds to the address presented ONE cycle
    // earlier: present pass p+1's addr at sub_t 8 (data valid from sub_t
    // 9 on); the zero flag follows the data (sub_t 9 → next pass's flag).
    wire p1_nxt_phase = (phase == P_SUB) && (sub_t >= 4'd8);
    assign p1_raddr = p1_nxt_phase ? p_addrn : p_addr;
    assign p1_zero  = ((phase == P_SUB) && (sub_t == 4'd9)) ? p_oobn : p_oob;

    // ---- image bank read address (conv1; constant per pixel) ----
    assign img_raddr = (oy * 5'd28) + ox;

    // ---- drain capture strobe ----
    assign drain_en = (phase == P_DRAIN);

    // ---- memory-ownership selectors (cnn_core muxes) ----
    assign pool_active = (state == S_POOL1) || (state == S_POOL2);
    assign fc_active   = ((state == S_FC1) || (state == S_FC2)) &&
                         (phase != P_BSTAGE);

    // ---- drain → BF16 (ReLU + round) ----
    wire [31:0] dout_sel  = dout[32*wcnt +: 32];
    wire [31:0] dout_relu = dout_sel[31] ? 32'd0 : dout_sel;
    wire [15:0] dout_bf16;
    fpu_bf16_round u_drain_bf16 (
        .a (dout_relu),
        .y (dout_bf16)
    );

    // ==================================================================
    // Sequential control
    // ==================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            phase      <= P_BSTAGE;
            sub_t      <= 4'd0;
            pass       <= 4'd0;
            oy         <= 5'd0;
            ox         <= 5'd0;
            bcnt       <= 7'd0;
            wq         <= 4'd0;
            wrun       <= 1'b0;
            wcnt       <= 3'd0;
            drain_grp  <= 2'd0;
            act_ld     <= 1'b0;
            w_swap     <= 1'b0;
            bias_en    <= 1'b0;
            ws_addr    <= 15'd0;
            br_widx    <= 7'd0;
            br_wdata   <= 16'd0;
            br_wen     <= 1'b0;
            fm_waddr   <= 13'd0;
            fm_wdata   <= 16'd0;
            fm_we      <= 1'b0;
            fm_raddr   <= 13'd0;
            pool_go    <= 1'b0;
            pool_mode  <= 1'b0;
            fc_go      <= 1'b0;
            fc_mode    <= 1'b0;
            pred       <= 4'd0;
            conf       <= 7'd0;
            verdict    <= 2'd0;
            present    <= 1'b0;
            busy       <= 1'b0;
        end else begin
            // ---- defaults (1-cycle pulses / per-cycle signals) ----
            act_ld   <= 1'b0;
            w_swap   <= 1'b0;
            bias_en  <= 1'b0;
            present  <= 1'b0;
            pool_go  <= 1'b0;
            fc_go    <= 1'b0;
            br_wen   <= 1'b0;
            fm_we    <= 1'b0;

            // ---- FM drain write chain (8 writes, overlapped) ----
            // oc = wcnt (conv1) or drain_grp*8+wcnt (conv2); {grp,cnt} = 5-bit oc.
            if (wrun) begin
                fm_we    <= 1'b1;
                if (is_conv1)
                    fm_waddr <= ({6'd0, wcnt} * 13'd784) + (oy * 5'd28) + ox;
                else
                    fm_waddr <= ({7'd0, drain_grp, wcnt} * 13'd196)
                              + (oy * 5'd14) + ox;
                fm_wdata <= dout_bf16;
                if (wcnt == 3'd7) wrun <= 1'b0;
                else              wcnt <= wcnt + 3'd1;
            end

            // ---- layer FSM ----
            case (state)
                S_IDLE: begin
                    // Parked (busy=0).  On reset release the core launches.
                    busy  <= 1'b1;
                    state <= S_CONV1;
                    phase <= P_BSTAGE;
                end

                // ============ CONV1 ============
                S_CONV1: begin
                    case (phase)
                        P_BSTAGE: begin
                            // Stage conv1 biases (flat 72..79 → idx 0..7).
                            ws_addr <= 15'd72 + bcnt;
                            if (bcnt >= 7'd1) begin
                                br_wen   <= 1'b1;
                                br_widx  <= bcnt - 7'd1;
                                br_wdata <= ws_data;
                            end
                            if (bcnt == 7'd8) begin
                                bcnt  <= 7'd0;
                                phase <= P_WLOAD;
                            end else begin
                                bcnt <= bcnt + 7'd1;
                            end
                        end

                        P_WLOAD: begin
                            // Layer-start load of pixel-0 pass-A weights.
                            if (wq == 4'd7) begin
                                wq    <= 4'd0;
                                phase <= P_WSWAP;
                            end else begin
                                wq <= wq + 4'd1;
                            end
                        end

                        P_WSWAP: begin
                            w_swap <= 1'b1;
                            phase  <= P_BIAS;
                        end

                        P_BIAS: begin
                            bias_en <= 1'b1;
                            pass    <= 4'd0;
                            sub_t   <= 4'd0;
                            phase   <= P_SUB;
                        end

                        P_SUB: begin
                            if (sub_t == 4'd0) act_ld <= 1'b1;
                            if (sub_t == 4'd9) w_swap <= 1'b1;
                            if (sub_t == 4'd9) begin
                                sub_t <= 4'd0;
                                if (pass == 4'd0) begin
                                    pass <= 4'd1;          // pass B
                                end else begin
                                    phase <= P_DRAIN;      // pixel done
                                end
                            end else begin
                                sub_t <= sub_t + 4'd1;
                            end
                        end

                        P_DRAIN: begin
                            wrun      <= 1'b1;
                            wcnt      <= 3'd0;
                            drain_grp <= 2'd0;
                            // advance pixel / layer
                            if (ox == ox_max && oy == oy_max) begin
                                state <= S_POOL1;
                                phase <= P_BSTAGE;
                                ox    <= 5'd0;
                                oy    <= 5'd0;
                            end else begin
                                if (ox == ox_max) begin
                                    ox <= 5'd0;
                                    oy <= oy + 5'd1;
                                end else begin
                                    ox <= ox + 5'd1;
                                end
                                pass  <= 4'd0;
                                phase <= P_BIAS;
                            end
                        end

                        default: phase <= P_BIAS;
                    endcase
                end

                // ============ POOL1 ============
                S_POOL1: begin
                    pool_go   <= 1'b1;
                    pool_mode <= 1'b0;
                    if (pool_done) begin
                        state <= S_CONV2;
                        phase <= P_BSTAGE;
                    end
                end

                // ============ CONV2 ============
                S_CONV2: begin
                    case (phase)
                        P_BSTAGE: begin
                            // Stage conv2 biases (flat 1232..1247 → idx 8..23).
                            ws_addr <= 15'd1232 + bcnt;
                            if (bcnt >= 7'd1) begin
                                br_wen   <= 1'b1;
                                br_widx  <= 7'd8 + (bcnt - 7'd1);
                                br_wdata <= ws_data;
                            end
                            if (bcnt == 7'd16) begin
                                bcnt  <= 7'd0;
                                phase <= P_WLOAD;
                            end else begin
                                bcnt <= bcnt + 7'd1;
                            end
                        end

                        P_WLOAD: begin
                            // Layer-start load of pixel-0 pass-0 weights.
                            if (wq == 4'd7) begin
                                wq    <= 4'd0;
                                phase <= P_WSWAP;
                            end else begin
                                wq <= wq + 4'd1;
                            end
                        end

                        P_WSWAP: begin
                            w_swap <= 1'b1;
                            phase  <= P_BIAS;
                        end

                        P_BIAS: begin
                            bias_en <= 1'b1;
                            if (!(pass == 5'd9)) pass <= 5'd0;  // keep 9 at g1
                            sub_t   <= 4'd0;
                            phase   <= P_SUB;
                        end

                        P_SUB: begin
                            if (sub_t == 4'd0) act_ld <= 1'b1;
                            if (sub_t == 4'd9) w_swap <= 1'b1;
                            if (sub_t == 4'd9) begin
                                sub_t <= 4'd0;
                                if (pass == 5'd8) begin
                                    phase <= P_DRAIN;      // g0 drain
                                end else if (pass == 5'd17) begin
                                    phase <= P_DRAIN;      // g1 drain
                                end else begin
                                    pass <= pass + 5'd1;
                                end
                            end else begin
                                sub_t <= sub_t + 4'd1;
                            end
                        end

                        P_DRAIN: begin
                            wrun      <= 1'b1;
                            wcnt      <= 3'd0;
                            drain_grp <= (pass >= 5'd9) ? 2'd1 : 2'd0;
                            if (pass == 5'd8) begin
                                // g0 drain → g1 bias
                                pass  <= 5'd9;
                                phase <= P_BIAS;
                            end else begin
                                // g1 drain → next pixel / layer done
                                if (ox == ox_max && oy == oy_max) begin
                                    state <= S_POOL2;
                                    phase <= P_BSTAGE;
                                    ox    <= 5'd0;
                                    oy    <= 5'd0;
                                end else begin
                                    if (ox == ox_max) begin
                                        ox <= 5'd0;
                                        oy <= oy + 5'd1;
                                    end else begin
                                        ox <= ox + 5'd1;
                                    end
                                    pass  <= 4'd0;
                                    phase <= P_BIAS;
                                end
                            end
                        end

                        default: phase <= P_BIAS;
                    endcase
                end

                // ============ POOL2 ============
                S_POOL2: begin
                    pool_go   <= 1'b1;
                    pool_mode <= 1'b1;
                    if (pool_done) begin
                        state <= S_FC1;
                        phase <= P_BSTAGE;
                    end
                end

                // ============ FC1 ============
                S_FC1: begin
                    if (phase == P_BSTAGE) begin
                        // Stage fc1 biases (flat 26336..26367 → idx 24..55).
                        ws_addr <= 15'd26336 + bcnt;
                        if (bcnt >= 7'd1) begin
                            br_wen   <= 1'b1;
                            br_widx  <= 7'd24 + (bcnt - 7'd1);
                            br_wdata <= ws_data;
                        end
                        if (bcnt == 7'd32) begin
                            bcnt  <= 7'd0;
                            phase <= P_BIAS;   // run phase
                        end else begin
                            bcnt <= bcnt + 7'd1;
                        end
                    end else begin
                        fc_go   <= 1'b1;
                        fc_mode <= 1'b0;
                        if (fc_done) begin
                            state <= S_FC2;
                            phase <= P_BSTAGE;
                        end
                    end
                end

                // ============ FC2 ============
                S_FC2: begin
                    if (phase == P_BSTAGE) begin
                        // Stage fc2 biases (flat 26688..26697 → idx 56..65).
                        ws_addr <= 15'd26688 + bcnt;
                        if (bcnt >= 7'd1) begin
                            br_wen   <= 1'b1;
                            br_widx  <= 7'd56 + (bcnt - 7'd1);
                            br_wdata <= ws_data;
                        end
                        if (bcnt == 7'd10) begin
                            bcnt  <= 7'd0;
                            phase <= P_BIAS;   // run phase
                        end else begin
                            bcnt <= bcnt + 7'd1;
                        end
                    end else begin
                        fc_go   <= 1'b1;
                        fc_mode <= 1'b1;
                        if (fc_done) begin
                            state <= S_PRESENT;
                        end
                    end
                end

                // ============ PRESENT ============
                S_PRESENT: begin
                    present <= 1'b1;
                    pred    <= fc_best_idx;
                    conf    <= (fc_best_val * 9'd100) >> 8;
                    verdict <= ((fc_best_val * 9'd100) >> 8) < 7'd50
                             ? 2'd2
                             : (fc_best_idx == exp_label) ? 2'd0 : 2'd1;
                    state   <= S_IDLE;
                    busy    <= 1'b0;
                end

                default: begin
                    state <= S_IDLE;
                    phase <= P_BSTAGE;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
