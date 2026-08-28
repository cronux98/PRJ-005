//---------------------------------------------------------------------
// Module      : fc_datapath
// Project     : cnn_systolic        Technology : Sky130 130 nm
// Traces      : REQ-022, REQ-025, REQ-026, REQ-027, BLK-013
// Description : Serial floating-point FC datapath (BLK-013):
//               FC1 (784→32) and FC2 (32→10), 1 MAC/cycle steady state
//               (BF16 mult exact + FP32 RN-even/FTZ add — the golden's
//               accumulate order: bias first, inputs ascending,
//               systolic_dataflow.md §5).  Piecewise sigmoid (arch/
//               piecewise_sigmoid.md: dyadic m/c/breakpoints as exact
//               bit patterns; sigma = fadd(fmul(m,|z|),c); z<0 →
//               1−sigma), sigma256 = trunc(fadd(fmul(σ,256),0.5)),
//               argmax strict '>' lowest-index ties.  FSM-005/FSM-006.
//               Result path: best_val/best_idx registers (conv_ctrl
//               derives pred/conf/verdict at ST_PRESENT).
// Clock/Reset : clk (CD_CORE, 100 MHz) / rst_n (fully synchronous)
// Assumptions : launched by conv_ctrl (fc_go + fc_mode); owns the FM
//               read/write port and the weight serial port while active;
//               fc_bias is the muxed BF16 bias for the current j.
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module fc_datapath (
    input  wire         clk,          // CD_CORE clock, 100 MHz
    input  wire         rst_n,        // fully synchronous active-low reset
    // control
    input  wire         fc_go,        // 1-cycle launch
    input  wire         fc_mode,      // 0 = FC1, 1 = FC2
    output reg          fc_done,      // 1-cycle completion
    // IFI-011 FM port (owned while active)
    output reg  [12:0]  ff_addr,      // read address (FC1: 6272+i, FC2: i)
    input  wire [15:0]  ff_rdata,
    output reg  [12:0]  ff_waddr,     // h3 write (FC1: FM[j])
    output reg  [15:0]  ff_wdata,
    output reg          ff_we,
    // IFI-012 weight serial port
    output reg  [14:0]  ws_addr,
    input  wire [15:0]  ws_data,
    // MEM-005 bias read (muxed by the core for fc_mode/j)
    input  wire [15:0]  fc_bias,
    output wire [6:0]   fc_bias_idx,   // regfile index for the current j
    // result path (to conv_ctrl ST_PRESENT)
    output reg  [8:0]   best_val,     // sigma256 of the argmax winner
    output reg  [3:0]   best_idx      // argmax index (lowest-index ties)
);

    // FSM-005 : fc MAC sequencer (5 phases), reset = PH_IDLE
    localparam [2:0] PH_IDLE = 3'd0;
    localparam [2:0] PH_BIAS = 3'd1;  // acc <= bias; issue i=0 reads
    localparam [2:0] PH_MAC  = 3'd2;  // issue reads, pipelined MAC
    localparam [2:0] PH_DRAIN = 3'd3; // 2-cycle pipeline drain
    localparam [2:0] PH_ACT  = 3'd4;  // sigmoid pipeline (5 cycles)
    localparam [2:0] PH_WB   = 3'd5;  // h3 write / j++ / done

    reg [2:0]  ph;
    reg [4:0]  j;                     // output index 0..31 (FC1) / 0..9 (FC2)
    reg [9:0]  i;                     // input index 0..783 / 0..31
    reg [2:0]  act_t;                 // PH_ACT pipeline stage counter
    reg [31:0] acc;                   // FP32 accumulator
    reg [31:0] prod;                  // stage-1 product register
    reg [31:0] sig_z;                 // PH_ACT s1: pre-activation register
    reg [31:0] sigma;                 // PH_ACT s2: sigmoid output

    // ---- combinational FP units (bit-exact golden mirror) ----
    // Piecewise sigmoid (arch/piecewise_sigmoid.md) + sigma256 quantization.
    wire [31:0] sigma_nxt;
    wire [8:0]  sigma256;

    fpu_sigmoid u_sigmoid (
        .z     (sig_z),
        .sigma (sigma_nxt)
    );

    fpu_sigma256 u_sigma256 (
        .sigma (sigma_nxt),
        .y     (sigma256)
    );

    // bf16(σ) for h3 (FC1).
    fpu_bf16_round u_h3 (
        .a (sigma_nxt),
        .y (h3_nxt)
    );

    // ---- per-mode parameters ----
    wire [9:0]  n_in  = fc_mode ? 10'd32  : 10'd784;   // inputs per output
    wire [5:0]  n_out = fc_mode ? 6'd10   : 6'd32;     // outputs
    wire [12:0] fm_base = fc_mode ? 13'd0 : 13'd6272;  // p2 base / h3 base
    wire [14:0] w_base  = fc_mode ? 15'd26368 : 15'd1248;

    // ---- combinational helpers ----
    // FC bias regfile index (combinational so it is valid at PH_BIAS).
    assign fc_bias_idx = fc_mode ? (7'd56 + j) : (7'd24 + j);

    wire [31:0] acc_nxt;
    wire [31:0] prod_nxt;
    wire [15:0] h3_nxt;

    // MAC stage-1: exact BF16×BF16 product.
    fpu_bf16_mul u_mac_mul (
        .a (ws_data),
        .b (ff_rdata),
        .y (prod_nxt)
    );

    // MAC stage-2: FP32 accumulate (bias first, inputs ascending).
    fpu_fp32_add u_mac_add (
        .a (acc),
        .b (prod),
        .y (acc_nxt)
    );

    // ---- FSM ----
    always @(posedge clk) begin
        if (!rst_n) begin
            ph        <= PH_IDLE;
            j         <= 5'd0;
            i         <= 10'd0;
            act_t     <= 3'd0;
            acc       <= 32'd0;
            prod      <= 32'd0;
            sig_z     <= 32'd0;
            sigma     <= 32'd0;
            ff_addr   <= 13'd0;
            ff_waddr  <= 13'd0;
            ff_wdata  <= 16'd0;
            ff_we     <= 1'b0;
            ws_addr   <= 15'd0;
            best_val  <= 9'd0;
            best_idx  <= 4'd0;
            fc_done   <= 1'b0;
        end else begin
            // Defaults.
            ff_we   <= 1'b0;
            fc_done <= 1'b0;

            case (ph)
                PH_IDLE: begin
                    if (fc_go) begin
                        j   <= 5'd0;
                        ph  <= PH_BIAS;
                    end
                end

                PH_BIAS: begin
                    // acc = bias; issue the first MAC reads (i=0).
                    acc     <= {fc_bias[15], fc_bias[14:7], fc_bias[6:0], 16'd0};
                    i       <= 10'd1;
                    ff_addr <= fm_base;
                    ws_addr <= w_base;
                    ph      <= PH_MAC;
                end

                PH_MAC: begin
                    // Issue reads for input i; the pipeline lags 2 cycles
                    // (data at T+1, prod at T+1's edge, acc add at T+2's
                    // edge).  1 MAC/cycle steady state.
                    ff_addr <= fm_base + i;
                    ws_addr <= w_base + (i * (fc_mode ? 10'd10 : 10'd32)) + j;
                    if (i == n_in - 10'd1) ph <= PH_DRAIN;
                    else                   i <= i + 10'd1;
                end

                PH_DRAIN: begin
                    // 2-cycle pipeline drain (last add commits at the
                    // second PH_DRAIN cycle's edge).
                    if (act_t == 3'd1) begin
                        act_t <= 3'd0;
                        ph    <= PH_ACT;
                    end else begin
                        act_t <= act_t + 3'd1;
                    end
                end

                PH_ACT: begin
                    // Sigmoid pipeline: s1 latch |z| input, s2 combinational
                    // sigmoid, s3 sigma256/argmax (FC2) or h3 (FC1).
                    case (act_t)
                        3'd0: begin
                            sig_z <= acc;
                            act_t <= 3'd1;
                        end
                        3'd1: begin
                            sigma <= sigma_nxt;
                            act_t <= 3'd2;
                        end
                        3'd2: begin
                            // sigma valid: FC2 argmax (strict >, lowest-index
                            // ties); FC1 → h3 BF16.
                            if (fc_mode) begin
                                if (j == 5'd0 || sigma256 > best_val) begin
                                    best_val <= sigma256;
                                    best_idx <= j;
                                end
                            end
                            act_t <= 3'd0;
                            ph    <= PH_WB;
                        end
                        default: act_t <= 3'd0;
                    endcase
                end

                PH_WB: begin
                    // FC1: h3[j] → FM[j]; FC2: nothing to write.
                    if (!fc_mode) begin
                        ff_waddr <= {8'd0, j};
                        ff_wdata <= h3_nxt;
                        ff_we    <= 1'b1;
                    end
                    if (j == n_out - 5'd1) begin
                        fc_done <= 1'b1;
                        ph      <= PH_IDLE;
                    end else begin
                        j  <= j + 5'd1;
                        ph <= PH_BIAS;
                    end
                end

                default: ph <= PH_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
