//---------------------------------------------------------------------
// Module      : cnn_core
// Project     : cnn_systolic        Technology : Sky130 130 nm
// Traces      : REQ-020..REQ-028, BLK-009..BLK-017
// Description : Accelerator core integration wrapper (arch.md BLK-001
//               sub-structure): instantiates BLK-010..BLK-017 and the
//               bias regfile (MEM-005), muxes the shared memory ports
//               by ownership (conv_ctrl during conv/pool-drain, pool_unit
//               during pooling, fc_datapath during FC), and presents the
//               IFI-003 core interface (identical to cnn_soc's cnn_infer
//               so the reused cnn_axi_slave binds unchanged).
// Clock/Reset : clk (CD_CORE, 100 MHz) / rst_n (core park from the slave)
// Assumptions : single-shot per inference; no backpressure.
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module cnn_core #(
    parameter WEIGHTS_HEX_FILE = "arch/golden_model/weights_bf16.hex"
) (
    input  wire        clk,          // CD_CORE clock, 100 MHz
    input  wire        rst_n,        // core park reset (fully synchronous)
    input  wire [3:0]  exp_label,    // expected label (CNN_EXP)
    input  wire [9:0]  img_waddr,    // image pixel write address 0..783
    input  wire [7:0]  img_wdata,    // image pixel write data
    input  wire        img_we,       // image pixel write enable
    output wire [3:0]  pred,         // prediction 0..9
    output wire [6:0]  conf,         // confidence 0..100
    output wire [1:0]  verdict,      // 0/1/2
    output wire        busy,         // core busy (clock-gating point)
    output wire        present       // 1-cycle result strobe
);

    // ---- internal memory/array wiring ----
    wire [9:0]   img_raddr;
    wire [71:0]  img_rdata;
    wire [7:0]   p1_raddr;
    wire         p1_zero;
    wire [127:0] p1_rdata;
    wire [119:0] wp_addr;
    wire [127:0] wp_data;
    wire [14:0]  ctrl_ws_addr, fc_ws_addr;
    wire [15:0]  ws_data;
    wire [12:0]  ctrl_fm_raddr, pool_fm_raddr, fc_ff_addr;
    wire [15:0]  fm_rdata;
    wire [12:0]  ctrl_fm_waddr, pool_fm_waddr, fc_ff_waddr;
    wire [15:0]  ctrl_fm_wdata, pool_fm_wdata, fc_ff_wdata;
    wire         ctrl_fm_we, pool_fm_we, fc_ff_we;

    wire [127:0] act_in;
    wire         act_ld;
    wire [127:0] w_load_data;
    wire [63:0]  w_load_en;
    wire         w_swap;
    wire [255:0] bias_in;
    wire         bias_en;
    wire [7:0]   add_en;
    wire         drain_en;
    wire [255:0] dout;

    wire [6:0]   br_widx;
    wire [15:0]  br_wdata;
    wire         br_wen;
    wire [55:0]  br_a_idx;
    wire [127:0] br_a_data;
    wire [6:0]   fc_bias_idx;
    wire [15:0]  fc_bias;

    wire         pool_go, pool_done, pool_mode;
    wire         fc_go, fc_done, fc_mode;
    wire         pool_active, fc_active;
    wire [8:0]   fc_best_val;
    wire [3:0]   fc_best_idx;

    // ==================================================================
    // BLK-016: 9 pre-shifted image banks
    // ==================================================================
    img_banks u_img_banks (
        .clk     (clk),
        .rst_n   (rst_n),
        .iw_addr (img_waddr),
        .iw_data (img_wdata),
        .iw_en   (img_we),
        .ir_addr (img_raddr),
        .ir_data (img_rdata)
    );

    // ==================================================================
    // BLK-017: 8 per-channel pool1 banks
    // ==================================================================
    wire [7:0]   pool_p1_waddr;
    wire [127:0] pool_p1_wdata;
    wire [7:0]   pool_p1_we;

    p1_banks u_p1_banks (
        .clk      (clk),
        .rst_n    (rst_n),
        .p1_waddr (pool_p1_waddr),
        .p1_wdata (pool_p1_wdata),
        .p1_we    (pool_p1_we),
        .p1_raddr (p1_raddr),
        .p1_zero  (p1_zero),
        .p1_rdata (p1_rdata)
    );

    // ==================================================================
    // BLK-014: weight ROM (8 parallel ports + serial port)
    // ==================================================================
    weight_rom #(
        .WEIGHTS_HEX_FILE (WEIGHTS_HEX_FILE)
    ) u_weight_rom (
        .clk     (clk),
        .rst_n   (rst_n),
        .wp_addr (wp_addr),
        .wp_data (wp_data),
        .ws_addr (fc_active ? fc_ws_addr : ctrl_ws_addr),
        .ws_data (ws_data)
    );

    // ==================================================================
    // BLK-015: FM RAM (separate read/write ports, ownership-muxed)
    // ==================================================================
    fm_ram u_fm_ram (
        .clk   (clk),
        .rst_n (rst_n),
        .raddr (pool_active ? pool_fm_raddr : fc_active ? fc_ff_addr : ctrl_fm_raddr),
        .rdata (fm_rdata),
        .waddr (pool_active ? pool_fm_waddr : fc_active ? fc_ff_waddr : ctrl_fm_waddr),
        .wdata (pool_active ? pool_fm_wdata : fc_active ? fc_ff_wdata : ctrl_fm_wdata),
        .we    (pool_active ? pool_fm_we   : fc_active ? fc_ff_we   : ctrl_fm_we)
    );

    // ==================================================================
    // MEM-005: bias regfile (staging + 8 array reads + 1 FC read)
    // ==================================================================
    bias_regfile u_bias_regfile (
        .clk     (clk),
        .rst_n   (rst_n),
        .w_idx   (br_widx),
        .w_data  (br_wdata),
        .w_en    (br_wen),
        .a_idx   (br_a_idx),
        .a_data  (br_a_data),
        .fc_idx  (fc_bias_idx),
        .fc_data (fc_bias)
    );

    // ==================================================================
    // BLK-010: systolic array
    // ==================================================================
    systolic_array u_systolic_array (
        .clk         (clk),
        .rst_n       (rst_n),
        .act_in      (act_in),
        .act_ld      (act_ld),
        .w_load_data (w_load_data),
        .w_load_en   (w_load_en),
        .w_swap      (w_swap),
        .bias_in     (bias_in),
        .bias_en     (bias_en),
        .add_en      (add_en),
        .drain_en    (drain_en),
        .dout        (dout)
    );

    // ==================================================================
    // BLK-011: conv controller (owns the array feed + drain pipeline)
    // ==================================================================
    conv_ctrl u_conv_ctrl (
        .clk         (clk),
        .rst_n       (rst_n),
        .exp_label   (exp_label),
        .img_raddr   (img_raddr),
        .img_rdata   (img_rdata),
        .p1_raddr    (p1_raddr),
        .p1_zero     (p1_zero),
        .p1_rdata    (p1_rdata),
        .wp_addr     (wp_addr),
        .wp_data     (wp_data),
        .ws_addr     (ctrl_ws_addr),
        .ws_data     (ws_data),
        .fm_raddr    (ctrl_fm_raddr),
        .fm_rdata    (fm_rdata),
        .fm_waddr    (ctrl_fm_waddr),
        .fm_wdata    (ctrl_fm_wdata),
        .fm_we       (ctrl_fm_we),
        .act_in      (act_in),
        .act_ld      (act_ld),
        .w_load_data (w_load_data),
        .w_load_en   (w_load_en),
        .w_swap      (w_swap),
        .bias_in     (bias_in),
        .bias_en     (bias_en),
        .add_en      (add_en),
        .drain_en    (drain_en),
        .dout        (dout),
        .br_widx     (br_widx),
        .br_wdata    (br_wdata),
        .br_wen      (br_wen),
        .br_a_idx    (br_a_idx),
        .br_a_data   (br_a_data),
        .pool_go     (pool_go),
        .pool_mode   (pool_mode),
        .pool_done   (pool_done),
        .fc_go       (fc_go),
        .fc_mode     (fc_mode),
        .fc_done     (fc_done),
        .fc_best_val (fc_best_val),
        .fc_best_idx (fc_best_idx),
        .pred        (pred),
        .conf        (conf),
        .verdict     (verdict),
        .present     (present),
        .busy        (busy),
        .pool_active (pool_active),
        .fc_active   (fc_active)
    );

    // ==================================================================
    // BLK-012: pool unit (owns the p1 write port + FM port during pool)
    // ==================================================================
    pool_unit u_pool_unit (
        .clk        (clk),
        .rst_n      (rst_n),
        .pool_go    (pool_go),
        .pool_mode  (pool_mode),
        .pool_done  (pool_done),
        .fm_raddr   (pool_fm_raddr),
        .fm_rdata   (fm_rdata),
        .fm_waddr   (pool_fm_waddr),
        .fm_wdata   (pool_fm_wdata),
        .fm_we      (pool_fm_we),
        .p1_waddr   (pool_p1_waddr),
        .p1_wdata   (pool_p1_wdata),
        .p1_we      (pool_p1_we)
    );

    // ==================================================================
    // BLK-013: serial FP FC datapath (owns FM + serial weight ports)
    // ==================================================================
    fc_datapath u_fc_datapath (
        .clk         (clk),
        .rst_n       (rst_n),
        .fc_go       (fc_go),
        .fc_mode     (fc_mode),
        .fc_done     (fc_done),
        .ff_addr     (fc_ff_addr),
        .ff_rdata    (fm_rdata),
        .ff_waddr    (fc_ff_waddr),
        .ff_wdata    (fc_ff_wdata),
        .ff_we       (fc_ff_we),
        .ws_addr     (fc_ws_addr),
        .ws_data     (ws_data),
        .fc_bias     (fc_bias),
        .fc_bias_idx (fc_bias_idx),
        .best_val    (fc_best_val),
        .best_idx    (fc_best_idx)
    );

endmodule

`default_nettype wire
