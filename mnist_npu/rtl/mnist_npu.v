//---------------------------------------------------------------------
// Module      : mnist_npu
// Project     : mnist_npu                Technology : FPGA-generic (Artix-7 100T / Nexys A7 target)
// Traces      : all REQs (top-level integration), BLK-001
// Description : Top-level integration of the free-running MNIST inference
//               NPU. Single clock domain, fully synchronous reset. No host
//               interface: after reset, infers image indices 0..99 forever,
//               presenting each result on led[11:0] and one exact UART line
//               (project brief §4-§7; spec/spec.md, arch/arch.md).
// Clock/Reset : clk (CD_CORE, 100 MHz nominal) / rst_n (SYNCHRONOUS active-low, no async)
// Assumptions : none beyond those documented in each leaf module.
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none
`include "rtl/mnist_npu_defs.vh"

module mnist_npu #(
    parameter HOLD_CYCLES      = 50000000,                 // REQ-016
    parameter BLINK_CYCLES     = 5000000,                  // REQ-020
    parameter CLK_DIV          = 868,                      // REQ-021
    parameter MAX_LINE_LEN     = 80,                       // BLK-011
    parameter WEIGHTS_HEX_FILE = `MNIST_NPU_WEIGHTS_HEX,   // REQ-012
    parameter IMAGES_HEX_FILE  = `MNIST_NPU_IMAGES_HEX,    // REQ-013
    parameter LABELS_HEX_FILE  = `MNIST_NPU_LABELS_HEX,    // REQ-014
    parameter LUT_HEX_FILE     = `MNIST_NPU_SIGMOID_LUT_HEX // REQ-006
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
    wire [4:0]         hram_addr;
    wire [15:0]        hram_wdata;
    wire               hram_we;
    wire [15:0]        hram_rdata;

    // ---- ctrl_fsm <-> mac_datapath ----
    wire signed [15:0] mac_a;
    wire signed [15:0] mac_b;
    wire                mac_bias_ld;
    wire signed [15:0] mac_bias;
    wire                mac_acc_en;
    wire signed [15:0] mac_z;

    // ---- mac_datapath -> sigmoid_lut (structural, bypasses ctrl_fsm — arch.md §4 BLK-004) ----
    wire [7:0] lut_data;

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

    hidden_ram u_hidden_ram (
        .clk   (clk),
        .rst_n (rst_n),
        .addr  (hram_addr),
        .wdata (hram_wdata),
        .we    (hram_we),
        .rdata (hram_rdata)
    );

    sigmoid_lut #(
        .LUT_HEX_FILE (LUT_HEX_FILE)
    ) u_sigmoid_lut (
        .clk   (clk),
        .rst_n (rst_n),
        .addr  (mac_z[15:0]),   // structural: address = z's raw two's-complement bit pattern (REQ-006)
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
        .mac_z        (mac_z)
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

        .hram_addr   (hram_addr),
        .hram_wdata  (hram_wdata),
        .hram_we     (hram_we),
        .hram_rdata  (hram_rdata),

        .mac_a       (mac_a),
        .mac_b       (mac_b),
        .mac_bias_ld (mac_bias_ld),
        .mac_bias    (mac_bias),
        .mac_acc_en  (mac_acc_en),

        .lut_data    (lut_data),

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
