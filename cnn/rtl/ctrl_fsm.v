//---------------------------------------------------------------------
// Module      : ctrl_fsm
// Project     : cnn (mnist_npu v2)      Technology : FPGA-generic (Artix-7 100T / Nexys A7 target)
// Traces      : REQ-001, REQ-004..REQ-018, REQ-024, REQ-025, REQ-027, BLK-002,
//               FSM-001, FSM-002, FSM-003, FSM-004
// Description : Sequences one image's full CNN inference: CONV1, POOL1,
//               CONV2, POOL2, FC1, FC2, PRESENT, HOLD (arch.md §6.1), then
//               advances to the next image, forever (REQ-024). Within
//               CONV1/CONV2/FC1/FC2 a shared 6-phase "mac_phase" sequences
//               each output unit's bias fetch + tap loop + activation +
//               writeback (arch.md §6.2); within POOL1/POOL2 a shared
//               6-phase "pool_phase" sequences each output unit's 4-way
//               read + compare + writeback (arch.md §6.3); within PRESENT a
//               2-phase "present_phase" computes confidence/verdict and
//               waits for the UART line to finish (arch.md §6.5). All three
//               reuse one physical `phase` register (never active
//               simultaneously, since only one outer state is active at a
//               time). The loop counters (wag_*) double as the direct
//               inputs to win_addr_gen (IFI-010) — there is no separate
//               internal copy, so the two can never drift apart.
// Clock/Reset : clk (CD_CORE, 100 MHz nominal) / rst_n (SYNCHRONOUS active-low, no async)
// Assumptions : mac_datapath.mac_z is wired directly to sigmoid_lut's
//               address at the top level (structural, cnn_npu.v) — ctrl_fsm
//               never drives lut_addr itself, only consumes mac_h (conv
//               path) and lut_data (FC path), identical convention to v1.
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module ctrl_fsm #(
    parameter HOLD_CYCLES = 50000000   // REQ-025: default ~0.5s @100MHz; sim override 4-16
) (
    input  wire         clk,
    input  wire         rst_n,

    // weight_rom port (IFI-003)
    output reg  [14:0]         wrom_addr,
    input  wire signed [15:0]  wrom_data,

    // image_rom port (IFI-004)
    output reg  [16:0]  irom_addr,
    input  wire [7:0]   irom_data,

    // label_rom port (IFI-005) — continuously addressed by img_idx
    output wire [6:0]   lrom_addr,
    input  wire [7:0]   lrom_data,

    // fm_ram port (IFI-006)
    output reg  [12:0]         fmram_addr,
    output reg  signed [15:0]  fmram_wdata,
    output reg                  fmram_we,
    input  wire signed [15:0]  fmram_rdata,

    // mac_datapath port (IFI-001) — mac_z is NOT read here; it is wired
    // directly from mac_datapath to sigmoid_lut at the top level.
    output reg  signed [15:0]  mac_a,
    output wire signed [15:0]  mac_b,
    output reg                 mac_bias_ld,
    output wire signed [15:0]  mac_bias,
    output reg                 mac_acc_en,
    input  wire signed [15:0]  mac_h,       // conv-path ReLU'd activation

    // sigmoid_lut data-out consumption (address side wired at top level to mac_z)
    input  wire [7:0]   lut_data,

    // win_addr_gen port (IFI-010)
    output wire [2:0]   layer_sel,
    output reg  [4:0]   wag_u_cnt,
    output reg  [4:0]   wag_y_cnt,
    output reg  [4:0]   wag_x_cnt,
    output reg  [3:0]   wag_ic_cnt,
    output reg  [1:0]   wag_iy_cnt,
    output reg  [1:0]   wag_ix_cnt,
    output reg  [9:0]   wag_i_cnt,
    output wire [6:0]   wag_img_idx,
    output wire [1:0]   wag_pool_tap,
    input  wire [14:0]  wag_wrom_bias_addr,
    input  wire [14:0]  wag_wrom_tap_addr,
    input  wire [16:0]  wag_irom_addr,
    input  wire [12:0]  wag_fmram_rd_addr,
    input  wire [12:0]  wag_fmram_wr_addr,
    input  wire         wag_tap_valid,

    // uart_line_fmt port (IFI-009)
    output wire          lf_start,
    output wire [3:0]   lf_pred,
    output wire [6:0]   lf_conf,
    output wire [3:0]   lf_exp,
    output wire [6:0]   lf_idx,
    output wire [1:0]   lf_verdict,
    input  wire          lf_done,

    // led_ctrl port (IFI-008)
    output wire [3:0]   lc_pred,
    output wire [1:0]   lc_verdict,
    output wire          lc_present,
    output wire          lc_busy
);
    // ---- FSM-001 outer state encoding (binary, 3-bit). Values 0..5 double
    // as layer_sel for win_addr_gen (LSEL_CONV1..LSEL_FC2 use the identical
    // encoding, win_addr_gen.v) ----
    localparam [2:0] ST_CONV1   = 3'd0,
                     ST_POOL1   = 3'd1,
                     ST_CONV2   = 3'd2,
                     ST_POOL2   = 3'd3,
                     ST_FC1     = 3'd4,
                     ST_FC2     = 3'd5,
                     ST_PRESENT = 3'd6,
                     ST_HOLD    = 3'd7;

    // ---- FSM-002 mac_phase (CONV1/CONV2/FC1/FC2) and FSM-003 pool_phase
    // (POOL1/POOL2) share one physical register (never simultaneously
    // active, since only one outer state is active at a time) ----
    localparam [2:0] PH_BIAS_ADDR = 3'd0,   // mac_phase           | pool_phase
                     PH_BIAS_ACC  = 3'd1,   // mac_phase           | (PH_READ1 alias)
                     PH_TAP_ADDR  = 3'd2,   // mac_phase           | (PH_READ2 alias)
                     PH_TAP_ACC   = 3'd3,   // mac_phase           | (PH_READ3 alias)
                     PH_ACT       = 3'd4,   // mac_phase           | (PH_CMP alias)
                     PH_WB        = 3'd5;   // mac_phase/pool_phase (shared name and value)
    localparam [2:0] PH_READ0 = 3'd0, PH_READ1 = 3'd1, PH_READ2 = 3'd2,
                     PH_READ3 = 3'd3, PH_CMP   = 3'd4;
    localparam [2:0] PH_RESULT    = 3'd0,   // present_phase
                     PH_WAIT_UART = 3'd1;

    reg [2:0]  state;
    reg [2:0]  phase;
    reg [6:0]  img_idx;      // 0..99
    reg        tap_valid_r;  // registered zero-pad flag (valid during PH_TAP_ACC)
    reg [7:0]  best_val;     // FC2 argmax running max
    reg [3:0]  best_idx;     // FC2 argmax running index
    reg [31:0] hold_cnt;
    reg signed [15:0] pool_max;   // running max across a pool unit's 4 taps

    // wag_u_cnt/wag_y_cnt/wag_x_cnt/wag_ic_cnt/wag_iy_cnt/wag_ix_cnt/wag_i_cnt
    // ARE the loop counters themselves (declared as output reg ports above) —
    // there is no separate internal copy, so win_addr_gen always sees exactly
    // what ctrl_fsm's own state machine holds.

    assign lrom_addr    = img_idx;
    assign layer_sel    = state;                // 0..5 match win_addr_gen's LSEL_*; 6/7 (PRESENT/HOLD) ignored there
    assign wag_img_idx  = img_idx;
    assign wag_pool_tap = phase[1:0];            // meaningful only during POOL1/POOL2 PH_READ0..PH_READ3

    assign mac_b    = wrom_data;                 // weight word, valid whenever consumed (PH_TAP_ACC)
    assign mac_bias = wrom_data;                 // bias word, valid whenever consumed (PH_BIAS_ACC)

    // ---- per-layer loop bounds (combinational) ----
    reg [4:0] u_max, yx_max;
    always @* begin
        case (state)
            ST_CONV1: begin u_max = 5'd7;  yx_max = 5'd27; end
            ST_POOL1: begin u_max = 5'd7;  yx_max = 5'd13; end
            ST_CONV2: begin u_max = 5'd15; yx_max = 5'd13; end
            ST_POOL2: begin u_max = 5'd15; yx_max = 5'd6;  end
            ST_FC1:   begin u_max = 5'd31; yx_max = 5'd0;  end
            ST_FC2:   begin u_max = 5'd9;  yx_max = 5'd0;  end
            default:  begin u_max = 5'd0;  yx_max = 5'd0;  end
        endcase
    end

    wire is_fc   = (state == ST_FC1) || (state == ST_FC2);
    wire is_pool = (state == ST_POOL1) || (state == ST_POOL2);
    wire is_conv = (state == ST_CONV1) || (state == ST_CONV2);

    wire conv_last_tap = (state == ST_CONV2)
                       ? (wag_ic_cnt == 4'd7 && wag_iy_cnt == 2'd2 && wag_ix_cnt == 2'd2)
                       : (wag_iy_cnt == 2'd2 && wag_ix_cnt == 2'd2);   // CONV1 (IC=1)
    wire fc_last_tap  = (state == ST_FC1) ? (wag_i_cnt == 10'd783) : (wag_i_cnt == 10'd31);
    wire mac_last_tap = is_fc ? fc_last_tap : conv_last_tap;

    wire loop_exhausted = is_fc ? (wag_u_cnt == u_max)
                                 : (wag_u_cnt == u_max && wag_y_cnt == yx_max && wag_x_cnt == yx_max);

    // ---- confidence / verdict: pure combinational functions of best_val/
    // best_idx/lrom_data (REQ-015/016), stable from FC2's last WB cycle
    // through PRESENT and HOLD (best_val/best_idx are not touched again
    // until the NEXT image's FC2 pass reaches wag_u_cnt==0) ----
    wire [15:0] conf_scaled = best_val * 16'd100;
    wire [6:0]  confidence  = conf_scaled[14:8];                // (best_val*100)>>8, REQ-015
    wire        is_trash    = (confidence < 7'd50);              // REQ-016
    wire        is_correct  = (!is_trash) && (best_idx == lrom_data[3:0]);
    wire [1:0]  verdict     = is_trash ? 2'd2 : (is_correct ? 2'd0 : 2'd1);

    assign lc_pred    = best_idx;
    assign lc_verdict = verdict;
    assign lc_busy    = (state != ST_HOLD);                      // REQ-027 busy window

    assign lf_pred    = best_idx;
    assign lf_conf    = confidence;
    assign lf_exp     = lrom_data[3:0];
    assign lf_idx     = img_idx;
    assign lf_verdict = verdict;

    // lc_present/lf_start: PH_RESULT is architecturally exactly 1 cycle long
    // (unconditional transition to PH_WAIT_UART), so the level itself is a
    // valid 1-cycle strobe.
    assign lc_present = (state == ST_PRESENT) && (phase == PH_RESULT);
    assign lf_start   = (state == ST_PRESENT) && (phase == PH_RESULT);

    // ---- combinational address / datapath-enable generation ----
    always @* begin
        wrom_addr   = 15'd0;
        irom_addr   = 17'd0;
        fmram_addr  = 13'd0;
        fmram_wdata = 16'sd0;
        fmram_we    = 1'b0;
        mac_a       = 16'sd0;
        mac_bias_ld = 1'b0;
        mac_acc_en  = 1'b0;

        case (state)
            ST_CONV1, ST_CONV2: begin
                case (phase)
                    PH_BIAS_ADDR: wrom_addr = wag_wrom_bias_addr;
                    PH_BIAS_ACC:  begin mac_bias_ld = 1'b1; mac_a = 16'sd0; end
                    PH_TAP_ADDR: begin
                        wrom_addr  = wag_wrom_tap_addr;
                        irom_addr  = wag_irom_addr;             // only meaningful for CONV1
                        fmram_addr = wag_fmram_rd_addr;         // only meaningful for CONV2
                    end
                    PH_TAP_ACC: begin
                        mac_acc_en = 1'b1;
                        mac_a = tap_valid_r
                              ? ((state == ST_CONV1) ? {8'd0, irom_data} : fmram_rdata)
                              : 16'sd0;
                    end
                    PH_WB: begin
                        fmram_addr  = wag_fmram_wr_addr;
                        fmram_wdata = mac_h;                    // combinational, stable since last PH_TAP_ACC
                        fmram_we    = 1'b1;
                    end
                    default: ;
                endcase
            end

            ST_POOL1, ST_POOL2: begin
                case (phase)
                    PH_READ0, PH_READ1, PH_READ2, PH_READ3: fmram_addr = wag_fmram_rd_addr;
                    PH_WB: begin
                        fmram_addr  = wag_fmram_wr_addr;
                        fmram_wdata = pool_max;
                        fmram_we    = 1'b1;
                    end
                    default: ;   // PH_CMP: no new address needed (last read already issued at PH_READ3)
                endcase
            end

            ST_FC1, ST_FC2: begin
                case (phase)
                    PH_BIAS_ADDR: wrom_addr = wag_wrom_bias_addr;
                    PH_BIAS_ACC:  begin mac_bias_ld = 1'b1; mac_a = 16'sd0; end
                    PH_TAP_ADDR: begin
                        wrom_addr  = wag_wrom_tap_addr;
                        fmram_addr = wag_fmram_rd_addr;
                    end
                    PH_TAP_ACC: begin
                        mac_acc_en = 1'b1;
                        mac_a = fmram_rdata;                    // FC has no zero-padding, always valid
                    end
                    PH_WB: begin
                        if (state == ST_FC1) begin
                            fmram_addr  = wag_fmram_wr_addr;
                            fmram_wdata = {8'd0, lut_data};
                            fmram_we    = 1'b1;
                        end
                        // ST_FC2: no fm_ram write — argmax update happens in the
                        // sequential block below, from lut_data directly.
                    end
                    default: ;
                endcase
            end

            default: ;   // ST_PRESENT, ST_HOLD: no ROM/RAM/MAC activity
        endcase
    end

    // ---- sequential: state/phase/counter update, SYNCHRONOUS reset only ----
    always @(posedge clk) begin
        if (!rst_n) begin
            state       <= ST_CONV1;
            phase       <= PH_BIAS_ADDR;
            img_idx     <= 7'd0;
            wag_u_cnt   <= 5'd0;
            wag_y_cnt   <= 5'd0;
            wag_x_cnt   <= 5'd0;
            wag_ic_cnt  <= 4'd0;
            wag_iy_cnt  <= 2'd0;
            wag_ix_cnt  <= 2'd0;
            wag_i_cnt   <= 10'd0;
            tap_valid_r <= 1'b0;
            best_val    <= 8'd0;
            best_idx    <= 4'd0;
            hold_cnt    <= 32'd0;
            pool_max    <= 16'sd0;
        end else begin
            case (state)
                // ================= CONV1 / CONV2 =================
                ST_CONV1, ST_CONV2: begin
                    case (phase)
                        PH_BIAS_ADDR: phase <= PH_BIAS_ACC;
                        PH_BIAS_ACC:  phase <= PH_TAP_ADDR;
                        PH_TAP_ADDR: begin
                            tap_valid_r <= wag_tap_valid;
                            phase       <= PH_TAP_ACC;
                        end
                        PH_TAP_ACC: begin
                            if (mac_last_tap) begin
                                phase <= PH_ACT;
                            end else begin
                                // advance tap index: ix -> iy -> ic (ic only reached/used for CONV2)
                                if (wag_ix_cnt == 2'd2) begin
                                    wag_ix_cnt <= 2'd0;
                                    if (wag_iy_cnt == 2'd2) begin
                                        wag_iy_cnt <= 2'd0;
                                        wag_ic_cnt <= wag_ic_cnt + 4'd1;
                                    end else begin
                                        wag_iy_cnt <= wag_iy_cnt + 2'd1;
                                    end
                                end else begin
                                    wag_ix_cnt <= wag_ix_cnt + 2'd1;
                                end
                                phase <= PH_TAP_ADDR;
                            end
                        end
                        PH_ACT: phase <= PH_WB;
                        PH_WB: begin
                            wag_iy_cnt <= 2'd0;
                            wag_ix_cnt <= 2'd0;
                            wag_ic_cnt <= 4'd0;
                            if (loop_exhausted) begin
                                wag_u_cnt <= 5'd0;
                                wag_y_cnt <= 5'd0;
                                wag_x_cnt <= 5'd0;
                                phase     <= PH_READ0;
                                state     <= (state == ST_CONV1) ? ST_POOL1 : ST_POOL2;
                            end else begin
                                if (wag_x_cnt == yx_max) begin
                                    wag_x_cnt <= 5'd0;
                                    if (wag_y_cnt == yx_max) begin
                                        wag_y_cnt <= 5'd0;
                                        wag_u_cnt <= wag_u_cnt + 5'd1;
                                    end else begin
                                        wag_y_cnt <= wag_y_cnt + 5'd1;
                                    end
                                end else begin
                                    wag_x_cnt <= wag_x_cnt + 5'd1;
                                end
                                phase <= PH_BIAS_ADDR;
                            end
                        end
                        default: phase <= PH_BIAS_ADDR;
                    endcase
                end

                // ================= POOL1 / POOL2 =================
                // Read pipeline (fm_ram has 1-cycle registered read latency):
                // PH_READ0 presents tap0's address; PH_READ1 presents tap1's
                // address AND captures tap0's data (unconditional first
                // sample); PH_READ2 presents tap2's address AND compares in
                // tap1's data; PH_READ3 presents tap3's address AND compares
                // in tap2's data; PH_CMP presents no new address and compares
                // in tap3's (the last) data.
                ST_POOL1, ST_POOL2: begin
                    case (phase)
                        PH_READ0: phase <= PH_READ1;
                        PH_READ1: begin pool_max <= fmram_rdata; phase <= PH_READ2; end
                        PH_READ2: begin
                            pool_max <= (fmram_rdata > pool_max) ? fmram_rdata : pool_max;
                            phase    <= PH_READ3;
                        end
                        PH_READ3: begin
                            pool_max <= (fmram_rdata > pool_max) ? fmram_rdata : pool_max;
                            phase    <= PH_CMP;
                        end
                        PH_CMP: begin
                            pool_max <= (fmram_rdata > pool_max) ? fmram_rdata : pool_max;
                            phase    <= PH_WB;
                        end
                        PH_WB: begin
                            if (loop_exhausted) begin
                                wag_u_cnt <= 5'd0;
                                wag_y_cnt <= 5'd0;
                                wag_x_cnt <= 5'd0;
                                phase     <= PH_BIAS_ADDR;
                                state     <= (state == ST_POOL1) ? ST_CONV2 : ST_FC1;
                            end else begin
                                if (wag_x_cnt == yx_max) begin
                                    wag_x_cnt <= 5'd0;
                                    if (wag_y_cnt == yx_max) begin
                                        wag_y_cnt <= 5'd0;
                                        wag_u_cnt <= wag_u_cnt + 5'd1;
                                    end else begin
                                        wag_y_cnt <= wag_y_cnt + 5'd1;
                                    end
                                end else begin
                                    wag_x_cnt <= wag_x_cnt + 5'd1;
                                end
                                phase <= PH_READ0;
                            end
                        end
                        default: phase <= PH_READ0;
                    endcase
                end

                // ================= FC1 / FC2 =================
                ST_FC1, ST_FC2: begin
                    case (phase)
                        PH_BIAS_ADDR: phase <= PH_BIAS_ACC;
                        PH_BIAS_ACC:  phase <= PH_TAP_ADDR;
                        PH_TAP_ADDR:  phase <= PH_TAP_ACC;
                        PH_TAP_ACC: begin
                            if (mac_last_tap) begin
                                phase <= PH_ACT;
                            end else begin
                                wag_i_cnt <= wag_i_cnt + 10'd1;
                                phase     <= PH_TAP_ADDR;
                            end
                        end
                        PH_ACT: phase <= PH_WB;
                        PH_WB: begin
                            wag_i_cnt <= 10'd0;
                            if (state == ST_FC2) begin
                                // Argmax, lowest-index tie-break (REQ-014): wag_u_cnt==0
                                // unconditionally wins, so no explicit inter-image reset
                                // of best_val is needed (matches golden_ref_model.c
                                // `if (out[i] > out[best]) best = i;`).
                                if (wag_u_cnt == 5'd0 || lut_data > best_val) begin
                                    best_val <= lut_data;
                                    best_idx <= wag_u_cnt[3:0];
                                end
                            end
                            if (loop_exhausted) begin
                                wag_u_cnt <= 5'd0;
                                phase     <= (state == ST_FC1) ? PH_BIAS_ADDR : PH_RESULT;
                                state     <= (state == ST_FC1) ? ST_FC2 : ST_PRESENT;
                            end else begin
                                wag_u_cnt <= wag_u_cnt + 5'd1;
                                phase     <= PH_BIAS_ADDR;
                            end
                        end
                        default: phase <= PH_BIAS_ADDR;
                    endcase
                end

                // ================= PRESENT =================
                ST_PRESENT: begin
                    case (phase)
                        PH_RESULT: phase <= PH_WAIT_UART;
                        PH_WAIT_UART: begin
                            if (lf_done) begin
                                hold_cnt <= 32'd0;
                                state    <= ST_HOLD;
                            end
                        end
                        default: phase <= PH_RESULT;
                    endcase
                end

                // ================= HOLD =================
                ST_HOLD: begin
                    if (hold_cnt == HOLD_CYCLES - 1) begin
                        img_idx <= (img_idx == 7'd99) ? 7'd0 : img_idx + 7'd1;
                        state   <= ST_CONV1;
                        phase   <= PH_BIAS_ADDR;
                    end else begin
                        hold_cnt <= hold_cnt + 32'd1;
                    end
                end

                default: begin
                    state <= ST_CONV1;   // REQ-035 illegal-state recovery
                    phase <= PH_BIAS_ADDR;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
