//---------------------------------------------------------------------
// Module      : ctrl_fsm
// Project     : mnist_npu                Technology : FPGA-generic (Artix-7 100T / Nexys A7 target)
// Traces      : REQ-001, REQ-004..REQ-011, REQ-015, REQ-016, REQ-019, REQ-028, REQ-029, BLK-002, FSM-001
// Description : Sequences one image's full inference (layer-1 MAC loop,
//               layer-1 activation/writeback, layer-2 MAC loop, layer-2
//               activation/writeback, argmax/confidence/verdict, UART line
//               dispatch, LED presentation, hold), then advances to the next
//               image, forever (REQ-015). Each MAC-loop step is an ADDR/ACC
//               pair (`mstep`) to respect the 1-cycle read latency of
//               weight_rom/image_rom/hidden_ram; each hidden/output unit's
//               bias is fetched as its own ADDR/ACC pair before its 784/32
//               weight terms (arch.md §6.1 MAC-loop ROM-latency clarification).
// Clock/Reset : clk (CD_CORE, 100 MHz nominal) / rst_n (SYNCHRONOUS active-low, no async)
// Assumptions : mac_datapath.mac_z is combinational and wired directly to
//               sigmoid_lut's address at the top level (arch.md §4 BLK-004) —
//               ctrl_fsm does not carry lut_addr itself, only consumes lut_data.
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module ctrl_fsm #(
    parameter HOLD_CYCLES = 50000000   // REQ-016: default ~0.5s @100MHz; sim override 4-16
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

    // hidden_ram port (IFI-006)
    output reg  [4:0]   hram_addr,
    output reg  [15:0]  hram_wdata,
    output reg          hram_we,
    input  wire [15:0]  hram_rdata,

    // mac_datapath port (IFI-001) — mac_z is NOT read here; it is wired
    // directly from mac_datapath to sigmoid_lut at the top level.
    output reg  signed [15:0]  mac_a,
    output wire signed [15:0]  mac_b,
    output reg                 mac_bias_ld,
    output wire signed [15:0]  mac_bias,
    output reg                 mac_acc_en,

    // sigmoid_lut data-out consumption (address side is wired at top level)
    input  wire [7:0]   lut_data,

    // uart_line_fmt port (IFI-009)
    output reg          lf_start,
    output wire [3:0]   lf_pred,
    output wire [6:0]   lf_conf,
    output wire [3:0]   lf_exp,
    output wire [6:0]   lf_idx,
    output wire [1:0]   lf_verdict,
    input  wire          lf_done,

    // led_ctrl port (IFI-008)
    output wire [3:0]   lc_pred,
    output wire [1:0]   lc_verdict,
    output reg          lc_present,
    output wire         lc_busy
);
    // ---- FSM-001 state encoding (binary, 4-bit) ----
    localparam [3:0] ST_IMG_START = 4'd0,
                     ST_L1_MAC    = 4'd1,
                     ST_L1_ACT    = 4'd2,
                     ST_L1_WB     = 4'd3,
                     ST_L2_MAC    = 4'd4,
                     ST_L2_ACT    = 4'd5,
                     ST_L2_WB     = 4'd6,
                     ST_RESULT    = 4'd7,
                     ST_PRESENT   = 4'd8,
                     ST_HOLD      = 4'd9;

    // ---- MAC-loop micro-step encoding (binary, 2-bit) — see file header ----
    localparam [1:0] MSTEP_BIAS_ADDR = 2'd0,
                     MSTEP_BIAS_ACC  = 2'd1,
                     MSTEP_ADDR      = 2'd2,
                     MSTEP_ACC       = 2'd3;

    reg [3:0]  state;
    reg [1:0]  mstep;
    reg [6:0]  img_idx;    // 0..99
    reg [9:0]  i_cnt;      // 0..783
    reg [5:0]  j_cnt;      // 0..31 (reused as layer-2 inner loop counter)
    reg [3:0]  c_cnt;      // 0..9
    reg [7:0]  best_val;
    reg [3:0]  best_idx;
    reg [31:0] hold_cnt;

    assign lrom_addr = img_idx;
    assign mac_b     = wrom_data;   // weight word, valid whenever consumed (MSTEP_ACC)
    assign mac_bias   = wrom_data;   // bias word, valid whenever consumed (MSTEP_BIAS_ACC)

    // img_base = img_idx*784, recomputed continuously; img_idx only changes
    // once per image and stays stable for tens of thousands of cycles, so
    // img_base is always settled well before it is used (arch.md §4 BLK-002).
    wire [31:0] img_base_full = img_idx * 32'd784;
    wire [16:0] img_base      = img_base_full[16:0];

    wire [31:0] l2_waddr_full = 32'd25120 + (j_cnt * 32'd10) + c_cnt;
    wire [14:0] l2_waddr      = l2_waddr_full[14:0];

    // ---- confidence / verdict: pure combinational functions of best_val/
    // best_idx/lrom_data, all stable and finalised by the time ST_RESULT is
    // entered (REQ-009/010/011) ----
    wire [15:0] conf_scaled = best_val * 16'd100;
    wire [6:0]  confidence  = conf_scaled[14:8];               // (best_val*100)>>8, REQ-010
    wire        is_trash    = (confidence < 7'd50);            // REQ-011
    wire        is_correct  = (!is_trash) && (best_idx == lrom_data[3:0]);
    wire [1:0]  verdict     = is_trash ? 2'd2 : (is_correct ? 2'd0 : 2'd1);

    assign lc_pred    = best_idx;
    assign lc_verdict = verdict;
    assign lc_busy    = (state != ST_HOLD);                    // REQ-019 busy window

    assign lf_pred    = best_idx;
    assign lf_conf    = confidence;
    assign lf_exp     = lrom_data[3:0];
    assign lf_idx     = img_idx;
    assign lf_verdict = verdict;

    // lc_present / lf_start: ST_RESULT is architecturally exactly 1 cycle
    // long (unconditional transition to ST_PRESENT), so the state level
    // itself is a valid 1-cycle strobe.
    always @* begin
        lc_present = (state == ST_RESULT);
        lf_start   = (state == ST_RESULT);
    end

    // ---- combinational address / datapath-enable generation ----
    always @* begin
        wrom_addr   = 15'd0;
        irom_addr   = 17'd0;
        hram_addr   = 5'd0;
        hram_wdata  = 16'd0;
        hram_we     = 1'b0;
        mac_a       = 16'sd0;
        mac_bias_ld = 1'b0;
        mac_acc_en  = 1'b0;

        case (state)
            ST_L1_MAC: begin
                case (mstep)
                    MSTEP_BIAS_ADDR: begin
                        wrom_addr = 15'd25088 + {9'd0, j_cnt};
                    end
                    MSTEP_BIAS_ACC: begin
                        mac_bias_ld = 1'b1;
                        mac_a       = 16'sd0;
                    end
                    MSTEP_ADDR: begin
                        wrom_addr = {i_cnt, 5'd0} + {9'd0, j_cnt};   // i_cnt*32 + j_cnt
                        irom_addr = img_base + {7'd0, i_cnt};
                    end
                    MSTEP_ACC: begin
                        mac_acc_en = 1'b1;
                        mac_a      = {8'd0, irom_data};
                    end
                    default: ;
                endcase
            end

            ST_L2_MAC: begin
                case (mstep)
                    MSTEP_BIAS_ADDR: begin
                        wrom_addr = 15'd25440 + {11'd0, c_cnt};
                    end
                    MSTEP_BIAS_ACC: begin
                        mac_bias_ld = 1'b1;
                        mac_a       = 16'sd0;
                    end
                    MSTEP_ADDR: begin
                        wrom_addr = l2_waddr;
                        hram_addr = j_cnt;
                    end
                    MSTEP_ACC: begin
                        mac_acc_en = 1'b1;
                        mac_a      = $signed(hram_rdata);
                    end
                    default: ;
                endcase
            end

            ST_L1_WB: begin
                hram_addr  = j_cnt;
                hram_wdata = {8'd0, lut_data};
                hram_we    = 1'b1;
            end

            default: ;   // ST_IMG_START, ST_L1_ACT, ST_L2_ACT, ST_L2_WB, ST_RESULT, ST_PRESENT, ST_HOLD
        endcase
    end

    // ---- sequential: state/mstep/counter update, SYNCHRONOUS reset only ----
    always @(posedge clk) begin
        if (!rst_n) begin
            state    <= ST_IMG_START;
            mstep    <= MSTEP_BIAS_ADDR;
            img_idx  <= 7'd0;
            i_cnt    <= 10'd0;
            j_cnt    <= 6'd0;
            c_cnt    <= 4'd0;
            best_val <= 8'd0;
            best_idx <= 4'd0;
            hold_cnt <= 32'd0;
        end else begin
            case (state)
                ST_IMG_START: begin
                    i_cnt <= 10'd0;
                    j_cnt <= 6'd0;
                    mstep <= MSTEP_BIAS_ADDR;
                    state <= ST_L1_MAC;
                end

                ST_L1_MAC: begin
                    case (mstep)
                        MSTEP_BIAS_ADDR: mstep <= MSTEP_BIAS_ACC;
                        MSTEP_BIAS_ACC:  mstep <= MSTEP_ADDR;
                        MSTEP_ADDR:      mstep <= MSTEP_ACC;
                        MSTEP_ACC: begin
                            if (i_cnt == 10'd783) begin
                                state <= ST_L1_ACT;
                            end else begin
                                i_cnt <= i_cnt + 10'd1;
                                mstep <= MSTEP_ADDR;
                            end
                        end
                        default: mstep <= MSTEP_BIAS_ADDR;
                    endcase
                end

                ST_L1_ACT: begin
                    state <= ST_L1_WB;
                end

                ST_L1_WB: begin
                    if (j_cnt == 6'd31) begin
                        j_cnt <= 6'd0;
                        c_cnt <= 4'd0;
                        mstep <= MSTEP_BIAS_ADDR;
                        state <= ST_L2_MAC;
                    end else begin
                        j_cnt <= j_cnt + 6'd1;
                        i_cnt <= 10'd0;
                        mstep <= MSTEP_BIAS_ADDR;
                        state <= ST_L1_MAC;
                    end
                end

                ST_L2_MAC: begin
                    case (mstep)
                        MSTEP_BIAS_ADDR: mstep <= MSTEP_BIAS_ACC;
                        MSTEP_BIAS_ACC:  mstep <= MSTEP_ADDR;
                        MSTEP_ADDR:      mstep <= MSTEP_ACC;
                        MSTEP_ACC: begin
                            if (j_cnt == 6'd31) begin
                                state <= ST_L2_ACT;
                            end else begin
                                j_cnt <= j_cnt + 6'd1;
                                mstep <= MSTEP_ADDR;
                            end
                        end
                        default: mstep <= MSTEP_BIAS_ADDR;
                    endcase
                end

                ST_L2_ACT: begin
                    state <= ST_L2_WB;
                end

                ST_L2_WB: begin
                    if (c_cnt == 4'd0 || lut_data > best_val) begin
                        best_val <= lut_data;
                        best_idx <= c_cnt;
                    end
                    if (c_cnt == 4'd9) begin
                        state <= ST_RESULT;
                    end else begin
                        c_cnt <= c_cnt + 4'd1;
                        j_cnt <= 6'd0;
                        mstep <= MSTEP_BIAS_ADDR;
                        state <= ST_L2_MAC;
                    end
                end

                ST_RESULT: begin
                    state <= ST_PRESENT;
                end

                ST_PRESENT: begin
                    if (lf_done) begin
                        hold_cnt <= 32'd0;
                        state    <= ST_HOLD;
                    end
                end

                ST_HOLD: begin
                    if (hold_cnt == HOLD_CYCLES - 1) begin
                        img_idx <= (img_idx == 7'd99) ? 7'd0 : img_idx + 7'd1;
                        state   <= ST_IMG_START;
                    end else begin
                        hold_cnt <= hold_cnt + 32'd1;
                    end
                end

                default: state <= ST_IMG_START;   // REQ-024 illegal-state recovery
            endcase
        end
    end
endmodule

`default_nettype wire
