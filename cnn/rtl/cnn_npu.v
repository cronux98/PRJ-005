//---------------------------------------------------------------------
// Module      : cnn_npu
// Project     : cnn (mnist_npu v2)      Technology : FPGA-generic (Artix-7 100T / Nexys A7 target)
// Traces      : all REQs (top-level integration), BLK-001
// Description : Top-level integration of the free-running CNN inference
//               NPU. Single clock domain, fully synchronous reset. No host
//               interface: after reset, infers image indices 0..99 forever
//               (Conv1-ReLU->Pool1->Conv2-ReLU->Pool2->FC1-sigmoid->
//               FC2-sigmoid), presenting each result on led[11:0] and one
//               exact UART line (spec/spec.md, arch/arch.md). Externally
//               identical product to v1 mnist_npu (same ports, UART format,
//               LED scheme); only the internal datapath differs.
// Clock/Reset : clk (CD_CORE, 100 MHz nominal) / rst_n (SYNCHRONOUS active-low, no async)
// Assumptions : none beyond those documented in each leaf module.
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
`include "rtl/cnn_defs.vh"
`include "rtl/mnist_npu_defs.vh"

module cnn_npu #(
    parameter HOLD_CYCLES      = 50000000,                 // REQ-025
    parameter BLINK_CYCLES     = 100000,                   // REQ-026 (v2 default; fixes v1's invisible-blink bug)
    parameter CLK_DIV          = 868,                      // REQ-031
    parameter MAX_LINE_LEN     = 80,                       // BLK-011
    parameter WEIGHTS_HEX_FILE = `CNN_WEIGHTS_HEX,         // REQ-019
    parameter IMAGES_HEX_FILE  = `CNN_IMAGES_HEX,          // REQ-020
    parameter LABELS_HEX_FILE  = `CNN_LABELS_HEX,          // REQ-021
    parameter LUT_HEX_FILE     = `MNIST_NPU_SIGMOID_LUT_HEX // REQ-022 (v1 LUT reused unchanged)
) (
    input  wire         clk,
    input  wire         rst_n,
    output wire [11:0]  led,
    output wire          uart_tx
);
    // ---- ctrl_fsm <-> ROM/RAM ports ----
    wire [14:0]        wrom_addr;
    wire signed [15:0] wrom_data;
    wire [16:0]        irom_addr;
    wire [7:0]         irom_data;
    wire [6:0]         lrom_addr;
    wire [7:0]         lrom_data;
    wire [12:0]        fmram_addr;
    wire signed [15:0] fmram_wdata;
    wire               fmram_we;
    wire signed [15:0] fmram_rdata;

    // ---- ctrl_fsm <-> mac_datapath (IFI-001) ----
    wire signed [15:0] mac_a;
    wire signed [15:0] mac_b;
    wire                mac_bias_ld;
    wire signed [15:0] mac_bias;
    wire                mac_acc_en;
    wire signed [15:0] mac_z;
    wire signed [15:0] mac_h;

    // ---- mac_datapath -> sigmoid_lut (structural, bypasses ctrl_fsm — arch.md §4 BLK-004) ----
    wire [7:0] lut_data;

    // ---- ctrl_fsm <-> win_addr_gen (IFI-010) ----
    wire [2:0]  layer_sel;
    wire [4:0]  wag_u_cnt;
    wire [4:0]  wag_y_cnt;
    wire [4:0]  wag_x_cnt;
    wire [3:0]  wag_ic_cnt;
    wire [1:0]  wag_iy_cnt;
    wire [1:0]  wag_ix_cnt;
    wire [9:0]  wag_i_cnt;
    wire [6:0]  wag_img_idx;
    wire [1:0]  wag_pool_tap;
    wire [14:0] wag_wrom_bias_addr;
    wire [14:0] wag_wrom_tap_addr;
    wire [16:0] wag_irom_addr;
    wire [12:0] wag_fmram_rd_addr;
    wire [12:0] wag_fmram_wr_addr;
    wire        wag_tap_valid;

    // ---- ctrl_fsm <-> uart_line_fmt (IFI-009) ----
    wire        lf_start;
    wire [3:0]  lf_pred;
    wire [6:0]  lf_conf;
    wire [3:0]  lf_exp;
    wire [6:0]  lf_idx;
    wire [1:0]  lf_verdict;
    wire         lf_done;

    // ---- uart_line_fmt <-> uart_tx (IFI-007) ----
    wire [7:0] utx_data;
    wire        utx_valid;
    wire        utx_ready;

    // ---- ctrl_fsm <-> led_ctrl (IFI-008) ----
    wire [3:0] lc_pred;
    wire [1:0] lc_verdict;
    wire        lc_present;
    wire        lc_busy;

    weight_rom #(
        .WEIGHTS_HEX_FILE (WEIGHTS_HEX_FILE)
    ) u_weight_rom (
        .clk   (clk),
        .rst_n (rst_n),
        .addr  (wrom_addr),
        .rdata (wrom_data)
    );

    image_rom #(
        .IMAGES_HEX_FILE (IMAGES_HEX_FILE)
    ) u_image_rom (
        .clk   (clk),
        .rst_n (rst_n),
        .addr  (irom_addr),
        .rdata (irom_data)
    );

    label_rom #(
        .LABELS_HEX_FILE (LABELS_HEX_FILE)
    ) u_label_rom (
        .clk   (clk),
        .rst_n (rst_n),
        .addr  (lrom_addr),
        .rdata (lrom_data)
    );

    fm_ram u_fm_ram (
        .clk   (clk),
        .rst_n (rst_n),
        .addr  (fmram_addr),
        .wdata (fmram_wdata),
        .we    (fmram_we),
        .rdata (fmram_rdata)
    );

    sigmoid_lut #(
        .LUT_HEX_FILE (LUT_HEX_FILE)
    ) u_sigmoid_lut (
        .clk   (clk),
        .rst_n (rst_n),
        .addr  (mac_z[15:0]),   // structural: address = z's raw two's-complement bit pattern (REQ-022)
        .rdata (lut_data)
    );

    mac_datapath u_mac_datapath (
        .clk          (clk),
        .rst_n        (rst_n),
        .mac_a        (mac_a),
        .mac_b        (mac_b),
        .mac_bias_ld  (mac_bias_ld),
        .mac_bias     (mac_bias),
        .mac_acc_en   (mac_acc_en),
        .mac_z        (mac_z),
        .mac_h        (mac_h)
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

    ctrl_fsm #(
        .HOLD_CYCLES (HOLD_CYCLES)
    ) u_ctrl_fsm (
        .clk         (clk),
        .rst_n       (rst_n),

        .wrom_addr   (wrom_addr),
        .wrom_data   (wrom_data),

        .irom_addr   (irom_addr),
        .irom_data   (irom_data),

        .lrom_addr   (lrom_addr),
        .lrom_data   (lrom_data),

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
        .lf_done     (lf_done),

        .lc_pred     (lc_pred),
        .lc_verdict  (lc_verdict),
        .lc_present  (lc_present),
        .lc_busy     (lc_busy)
    );

    uart_line_fmt #(
        .MAX_LINE_LEN (MAX_LINE_LEN)
    ) u_uart_line_fmt (
        .clk        (clk),
        .rst_n      (rst_n),

        .lf_start   (lf_start),
        .lf_pred    (lf_pred),
        .lf_conf    (lf_conf),
        .lf_exp     (lf_exp),
        .lf_idx     (lf_idx),
        .lf_verdict (lf_verdict),
        .lf_done    (lf_done),

        .utx_data   (utx_data),
        .utx_valid  (utx_valid),
        .utx_ready  (utx_ready)
    );

    uart_tx #(
        .CLK_DIV (CLK_DIV)
    ) u_uart_tx (
        .clk       (clk),
        .rst_n     (rst_n),
        .utx_data  (utx_data),
        .utx_valid (utx_valid),
        .utx_ready (utx_ready),
        .utx_busy  (),
        .uart_tx   (uart_tx)
    );

    // BLINK_CYCLES binding rule (arch.md §4 BLK-010, rtl_coding_guidelines.md
    // §8): led_ctrl.v is copied byte-for-byte from v1 (its own file-local
    // default is still 5,000,000) — cnn_npu's own BLINK_CYCLES parameter
    // (default 100,000, REQ-026) is passed down via this explicit instance
    // override, which is what actually takes effect.
    led_ctrl #(
        .BLINK_CYCLES (BLINK_CYCLES)
    ) u_led_ctrl (
        .clk        (clk),
        .rst_n      (rst_n),
        .lc_pred    (lc_pred),
        .lc_verdict (lc_verdict),
        .lc_present (lc_present),
        .lc_busy    (lc_busy),
        .led        (led)
    );
endmodule

`default_nettype wire
