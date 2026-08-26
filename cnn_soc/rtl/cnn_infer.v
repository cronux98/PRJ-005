//---------------------------------------------------------------------
// Module      : cnn_infer
// Project     : cnn_soc                Technology : FPGA-generic (NOT Sky130 — spec.md §2.1)
// Traces      : REQ-018, REQ-019, REQ-020, REQ-021, REQ-022, REQ-023, REQ-031, BLK-010
// Description : The rebuilt inference top — the verified CNN leaves with the
//               exact wiring of cnn_npu.v:99-233, minus the I/O skin
//               (image_rom, label_rom, uart_line_fmt, uart_tx, led_ctrl).
//               ZERO edits to the reused leaves (BLK-014..BLK-019, in ip/).
//               Deltas (arch.md §4 BLK-010):
//                 - image_buffer (BLK-011) replaces image_rom: core read
//                   .raddr(irom_addr[9:0]) — with img_idx parked at 0 the
//                   image address is the in-image offset 0..783
//                   (cnn/arch/arch.md:506); CPU write port from BLK-009.
//                 - label_rom replaced by .lrom_data({4'd0, exp_label})
//                   (REQ-019); .lrom_addr output left open.
//                 - .lf_done(1'b1) tied: PH_WAIT_UART exits in 1 cycle
//                   (ctrl_fsm.v:449-455); the single-shot sequencer parks
//                   the core before ST_HOLD can matter (REQ-023).
//                 - .lf_start/.lf_exp/.lf_idx outputs left open (no
//                   uart_line_fmt).
//                 - sigmoid_lut is structural: .addr(mac_z[15:0]) bypasses
//                   ctrl_fsm (cnn_npu.v:140, REQ-022).
//               Result exposure (ctrl_fsm.v:186-198): pred=lf_pred,
//               conf=lf_conf, verdict=lf_verdict, busy=lc_busy,
//               present=lc_present. HOLD_CYCLES/BLINK_CYCLES/CLK_DIV/
//               MAX_LINE_LEN not re-exported — core defaults stand (park
//               precedes HOLD; the free-runner never reaches its hold path).
//               NOTE: authored directly by the fe-rtl orchestrator (provider
//               session-limit fallback, AGENTS.md precedent 2026-08-20);
//               contract = arch.md §4 BLK-010 + cnn_npu.v:99-233 verbatim.
// Clock/Reset : clk (CD_CORE, 100 MHz) / rst_n = core_rst_n from BLK-009
//               (fully SYNCHRONOUS active-low; the park mechanism resets the
//               core between single shots)
// Assumptions : img_idx=0 always (single-shot by reset-parking, REQ-023);
//               CPU writes the image buffer only while the core is parked.
// Source      : custom (wraps reused ip/ctrl_fsm.v, ip/mac_datapath.v,
//               ip/win_addr_gen.v, ip/fm_ram.v, ip/weight_rom.v,
//               ip/sigmoid_lut.v + rtl/image_buffer.v)
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module cnn_infer #(
    parameter WEIGHTS_HEX_FILE = "../cnn/arch/golden_model/weights.hex", // cnn_soc-root-relative (MEM-005)
    parameter LUT_HEX_FILE     = "../cnn/rtl/sigmoid_lut.hex"            // cnn_soc-root-relative (MEM-005)
) (
    input  wire         clk,        // core clock (CD_CORE, 100 MHz)
    input  wire         rst_n,      // core reset = cnn_axi_slave.core_rst_n (park)
    input  wire [3:0]   exp_label,  // expected label from CNN_EXP register (replaces label_rom)
    input  wire [9:0]   img_waddr,  // CPU image-buffer write address 0..783 (BLK-009)
    input  wire [7:0]   img_wdata,  // CPU image-buffer write data (pixel byte)
    input  wire         img_we,     // CPU image-buffer write enable
    output wire [3:0]   pred,       // predicted digit (lf_pred, ctrl_fsm.v:189)
    output wire [6:0]   conf,       // confidence 0..100 (lf_conf, ctrl_fsm.v:191)
    output wire [1:0]   verdict,    // 0=PASS 1=FAIL 2=UART_ERR (lf_verdict, ctrl_fsm.v:193)
    output wire         busy,       // inference busy (lc_busy, ctrl_fsm.v:187)
    output wire         present     // result-present strobe, 1 cycle (lc_present, ctrl_fsm.v:198)
);

    // ---- Internal net bundle, mirroring cnn_npu.v:95-233 exactly ----
    wire [14:0]        wrom_addr;
    wire signed [15:0] wrom_data;
    wire [16:0]        irom_addr;
    wire [7:0]         irom_data;
    wire [6:0]         lrom_addr;   // open: no label_rom consumer
    wire [12:0]        fmram_addr;
    wire signed [15:0] fmram_wdata;
    wire               fmram_we;
    wire signed [15:0] fmram_rdata;
    wire signed [15:0] mac_a;
    wire signed [15:0] mac_b;
    wire               mac_bias_ld;
    wire signed [15:0] mac_bias;
    wire               mac_acc_en;
    wire signed [15:0] mac_z;
    wire signed [15:0] mac_h;
    wire [7:0]         lut_data;
    wire [2:0]         layer_sel;
    wire [4:0]         wag_u_cnt;
    wire [4:0]         wag_y_cnt;
    wire [4:0]         wag_x_cnt;
    wire [3:0]         wag_ic_cnt;
    wire [1:0]         wag_iy_cnt;
    wire [1:0]         wag_ix_cnt;
    wire [9:0]         wag_i_cnt;
    wire [6:0]         wag_img_idx;
    wire [1:0]         wag_pool_tap;
    wire [14:0]        wag_wrom_bias_addr;
    wire [14:0]        wag_wrom_tap_addr;
    wire [16:0]        wag_irom_addr;
    wire [12:0]        wag_fmram_rd_addr;
    wire [12:0]        wag_fmram_wr_addr;
    wire               wag_tap_valid;
    wire               lf_start;    // open: no uart_line_fmt
    wire [3:0]         lf_pred;
    wire [6:0]         lf_conf;
    wire [3:0]         lf_exp;      // open
    wire [6:0]         lf_idx;      // open
    wire [1:0]         lf_verdict;
    wire [3:0]         lc_pred;     // open (pred exposure uses lf_pred, arch.md §4 BLK-010)
    wire [1:0]         lc_verdict;
    wire               lc_present;  // result-present strobe (ctrl_fsm.v:198)
    wire               lc_busy;     // inference busy (ctrl_fsm.v:187)

    // Reused leaves (byte-for-byte files in ip/), wiring verbatim from
    // cnn_npu.v:99-227. weight_rom and sigmoid_lut hex paths are parameterised
    // (arch.md §7.2 MEM-005).
    weight_rom #(
        .WEIGHTS_HEX_FILE (WEIGHTS_HEX_FILE)
    ) u_weight_rom (
        .clk   (clk),
        .rst_n (rst_n),
        .addr  (wrom_addr),
        .rdata (wrom_data)
    );

    sigmoid_lut #(
        .LUT_HEX_FILE (LUT_HEX_FILE)
    ) u_sigmoid_lut (
        .clk   (clk),
        .rst_n (rst_n),
        .addr  (mac_z[15:0]),   // structural (cnn_npu.v:140, REQ-022)
        .rdata (lut_data)
    );

    fm_ram u_fm_ram (
        .clk   (clk),
        .rst_n (rst_n),
        .addr  (fmram_addr),
        .wdata (fmram_wdata),
        .we    (fmram_we),
        .rdata (fmram_rdata)
    );

    mac_datapath u_mac_datapath (
        .clk         (clk),
        .rst_n       (rst_n),
        .mac_a       (mac_a),
        .mac_b       (mac_b),
        .mac_bias_ld (mac_bias_ld),
        .mac_bias    (mac_bias),
        .mac_acc_en  (mac_acc_en),
        .mac_z       (mac_z),
        .mac_h       (mac_h)
    );

    win_addr_gen u_win_addr_gen (
        .layer_sel      (layer_sel),
        .u_cnt          (wag_u_cnt),
        .y_cnt          (wag_y_cnt),
        .x_cnt          (wag_x_cnt),
        .ic_cnt         (wag_ic_cnt),
        .iy_cnt         (wag_iy_cnt),
        .ix_cnt         (wag_ix_cnt),
        .i_cnt          (wag_i_cnt),
        .img_idx        (wag_img_idx),
        .pool_tap       (wag_pool_tap),
        .wrom_bias_addr (wag_wrom_bias_addr),
        .wrom_tap_addr  (wag_wrom_tap_addr),
        .irom_addr      (wag_irom_addr),
        .fmram_rd_addr  (wag_fmram_rd_addr),
        .fmram_wr_addr  (wag_fmram_wr_addr),
        .tap_valid      (wag_tap_valid)
    );

    ctrl_fsm u_ctrl_fsm (
        .clk         (clk),
        .rst_n       (rst_n),

        .wrom_addr   (wrom_addr),
        .wrom_data   (wrom_data),

        .irom_addr   (irom_addr),
        .irom_data   (irom_data),

        .lrom_addr   (lrom_addr),
        .lrom_data   ({4'd0, exp_label}),   // label_rom replaced (REQ-019)

        .fmram_addr  (fmram_addr),
        .fmram_wdata (fmram_wdata),
        .fmram_we    (fmram_we),
        .fmram_rdata (fmram_rdata),

        .mac_a       (mac_a),
        .mac_b       (mac_b),
        .mac_bias_ld (mac_bias_ld),
        .mac_bias    (mac_bias),
        .mac_acc_en  (mac_acc_en),
        .mac_h       (mac_h),

        .lut_data    (lut_data),

        .layer_sel          (layer_sel),
        .wag_u_cnt          (wag_u_cnt),
        .wag_y_cnt          (wag_y_cnt),
        .wag_x_cnt          (wag_x_cnt),
        .wag_ic_cnt         (wag_ic_cnt),
        .wag_iy_cnt         (wag_iy_cnt),
        .wag_ix_cnt         (wag_ix_cnt),
        .wag_i_cnt          (wag_i_cnt),
        .wag_img_idx        (wag_img_idx),
        .wag_pool_tap       (wag_pool_tap),
        .wag_wrom_bias_addr (wag_wrom_bias_addr),
        .wag_wrom_tap_addr  (wag_wrom_tap_addr),
        .wag_irom_addr      (wag_irom_addr),
        .wag_fmram_rd_addr  (wag_fmram_rd_addr),
        .wag_fmram_wr_addr  (wag_fmram_wr_addr),
        .wag_tap_valid      (wag_tap_valid),

        .lf_start    (lf_start),
        .lf_pred     (lf_pred),
        .lf_conf     (lf_conf),
        .lf_exp      (lf_exp),
        .lf_idx      (lf_idx),
        .lf_verdict  (lf_verdict),
        .lf_done     (1'b1),               // PH_WAIT_UART exits in 1 cycle (ctrl_fsm.v:449-455)

        .lc_pred     (lc_pred),
        .lc_verdict  (lc_verdict),
        .lc_present  (lc_present),
        .lc_busy     (lc_busy)
    );

    // CPU-writable image source (BLK-011); read port preserves the 1-cycle
    // registered timing of image_rom (ctrl_fsm ADDR->ACC unchanged).
    image_buffer u_image_buffer (
        .clk   (clk),
        .rst_n (rst_n),
        .raddr (irom_addr[9:0]),
        .rdata (irom_data),
        .waddr (img_waddr),
        .wdata (img_wdata),
        .we    (img_we)
    );

    // Result exposure (arch.md §4 BLK-010; ctrl_fsm.v:186-198).
    assign pred    = lf_pred;
    assign conf    = lf_conf;
    assign verdict = lf_verdict;
    assign busy    = lc_busy;
    assign present = lc_present;

endmodule

`default_nettype wire
