//---------------------------------------------------------------------
// Module      : learn_accel
// Project     : rinriAI   Technology : Sky130 130 nm
// Traces      : REQ-001, REQ-008, REQ-009, REQ-012, REQ-014, REQ-015,
//               REQ-022  (arch.md 4.1, BLK-001; top of the design)
// Description : Top-level structural wiring of the six sub-blocks:
//               apb_regs (BLK-002), sample_stream (BLK-003), learner
//               (BLK-004), weight_ram (BLK-005), stats (BLK-006).
//               div_seq (BLK-007) is instantiated INSIDE learner.
//               No logic of its own: wires, parameter plumbing, and the
//               combinational s_ready == accept_en path (IFI-008).
// Clock/Reset : clk_core (CD_CORE) / rst_n (synchronous, active low)
// Assumptions : Sub-block port names/directions/widths as authored in
//               rtl/ (each verified against interface_defs.yaml
//               IFI-001..IFI-009). s_ready is combinational and equals
//               accept_en per IFI-008 with the OI-008 fix (accept_en
//               includes !sample_valid inside learner). The equation is
//               realised inside sample_stream (`assign s_ready =
//               accept_en`), so this top connects the s_ready port
//               directly to sample_stream.s_ready — a single driver and
//               no redundant top-level assign, functionally identical
//               to `assign s_ready = accept_en` at this level.
//               sample_stream takes the CLASSES parameter for its
//               REQ-018 label-range rejection (out-of-range label byte
//               -> err_p, sample discarded, resync per FSM-002).
// Source      : custom (no external IP)
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none                 // typo'd implicit wires become errors

module learn_accel #(
    parameter integer FEATURES = 784,   // input pixels, legal 1..4096
    parameter integer HIDDEN   = 32,    // hidden units, legal 1..512
    parameter integer CLASSES  = 10,    // output classes, legal 1..256
    parameter integer W_F      = 12,    // pixel counter / x_addr width
    parameter integer W_H      = 6,     // hidden counter width
    parameter integer W_C      = 4,     // class counter width
    parameter integer W_A      = 16     // weight-RAM word-address width
) (
    // Clock / reset ---------------------------------------------------
    input  wire        clk_core,        // CD_CORE, 50 MHz (CLK-001)
    input  wire        rst_n,           // synchronous active-low (RST-001, ASM-002)

    // APB4 slave (IF-001) ---------------------------------------------
    input  wire        psel,            // slave select
    input  wire        penable,         // access-phase qualifier
    input  wire        pwrite,          // 1 = write, 0 = read
    input  wire [31:0] paddr,           // byte address
    input  wire [31:0] pwdata,          // write data
    output wire [31:0] prdata,          // read data
    output wire        pready,          // zero-wait ready
    output wire        pslverr,         // unmapped-address error

    // Sample byte stream (IF-002) -------------------------------------
    input  wire        s_valid,         // upstream has a byte this cycle
    output wire        s_ready,         // combinational: = accept_en (IFI-008)
    input  wire [7:0]  s_data,          // pixel byte, or label byte when s_last
    input  wire        s_last           // final (label) byte of a frame
);

    // Total stored words (arch.md 7); 25450 at defaults (REQ-022).
    localparam integer W_TOT = FEATURES*HIDDEN + HIDDEN + HIDDEN*CLASSES + CLASSES;

    //-----------------------------------------------------------------
    // Internal interface nets (interface_defs.yaml IFI-001..IFI-009)
    //-----------------------------------------------------------------

    // IFI-001 ctrl_learner : apb_regs -> learner
    wire        start_p;                // 1-cycle start strobe
    wire        step_p;                 // 1-cycle step strobe
    wire        halt_p;                 // 1-cycle halt strobe
    wire        freeze;                 // level: inference-only
    wire [3:0]  lr_shift;               // level: eta = 2^-lr_shift

    // IFI-002 learner_stats : learner -> stats
    wire        sample_done_p;          // 1-cycle pulse per processed sample
    wire        correct_p;              // 1-cycle pulse: pred == label
    wire        error_p;                // 1-cycle pulse: pred != label
    wire [7:0]  pred_l;                 // learner argmax level (OI-005)

    // IFI-003 stream_learner : sample_stream <-> learner
    wire        sample_valid;           // level: full sample captured
    wire [7:0]  label;                  // level: captured label byte
    wire        ack_p;                  // learner accept pulse
    wire [W_F-1:0] x_addr;              // pixel read address
    wire [7:0]  x_rdata;                // combinational pixel read data

    // IFI-004 learner_wram : learner <-> weight_ram port A
    wire [15:0] a_addr;                 // port A address
    wire [15:0] a_wdata;                // port A write data
    wire        a_we;                   // port A write enable
    wire [15:0] a_rdata;                // port A combinational read data

    // IFI-005 csr_wram : apb_regs <-> weight_ram port B + bulk init
    wire [15:0] b_addr;                 // port B address (WADDR)
    wire [15:0] b_wdata;                // port B write data (WDATA[15:0])
    wire        b_we;                   // port B write enable
    wire [15:0] b_rdata;                // port B combinational read data
    wire        init_go;                // bulk-init start (gated on !busy)
    wire [15:0] init_val;               // bulk-init fill value
    wire        init_busy;              // bulk-init in progress

    // IFI-006 stats_csr : stats -> apb_regs
    wire [31:0] sample_count;           // saturating sample counter
    wire [31:0] correct_count;          // saturating correct counter
    wire [31:0] error_count;            // saturating error counter
    wire        err;                    // sticky malformed-sample flag
    wire [7:0]  pred_s;                 // stats PRED register
    wire        clr_stats_p;            // 1-cycle clear-counters strobe

    // IFI-007 stream_stats : sample_stream -> stats
    wire        err_p;                  // malformed-sample pulse

    // IFI-008 learner_stream : learner -> sample_stream
    wire        accept_en;              // s_ready source (OI-008 fix)

    // IFI-009 learner_csr : learner -> apb_regs
    wire        busy;                   // run_active
    wire        done;                   // step/halt completed

    //-----------------------------------------------------------------
    // BLK-002 : APB4 register block (no parameters)
    //-----------------------------------------------------------------
    apb_regs u_apb_regs (
        .clk_core      (clk_core),
        .rst_n         (rst_n),
        .psel          (psel),
        .penable       (penable),
        .pwrite        (pwrite),
        .paddr         (paddr),
        .pwdata        (pwdata),
        .prdata        (prdata),
        .pready        (pready),
        .pslverr       (pslverr),
        .start_p       (start_p),
        .step_p        (step_p),
        .halt_p        (halt_p),
        .freeze        (freeze),
        .lr_shift      (lr_shift),
        .b_addr        (b_addr),
        .b_wdata       (b_wdata),
        .b_we          (b_we),
        .b_rdata       (b_rdata),
        .init_go       (init_go),
        .init_val      (init_val),
        .init_busy     (init_busy),
        .sample_count  (sample_count),
        .correct_count (correct_count),
        .error_count   (error_count),
        .err           (err),
        .pred          (pred_s),
        .clr_stats_p   (clr_stats_p),
        .busy          (busy),
        .done          (done)
    );

    //-----------------------------------------------------------------
    // BLK-003 : byte-stream framing + sample RAM (MEM-002)
    //-----------------------------------------------------------------
    sample_stream #(
        .FEATURES (FEATURES),
        .CLASSES  (CLASSES),        // REQ-018: label-range check on the final beat
        .W_F      (W_F)
    ) u_sample_stream (
        .clk_core      (clk_core),
        .rst_n         (rst_n),
        .s_valid       (s_valid),
        .s_ready       (s_ready),        // = accept_en (see header note)
        .s_data        (s_data),
        .s_last        (s_last),
        .sample_valid  (sample_valid),
        .label         (label),
        .ack_p         (ack_p),
        .x_addr        (x_addr),
        .x_rdata       (x_rdata),
        .err_p         (err_p),
        .accept_en     (accept_en)
    );

    //-----------------------------------------------------------------
    // BLK-004 : training/inference core (instantiates BLK-007 div_seq)
    //-----------------------------------------------------------------
    learner #(
        .FEATURES (FEATURES),
        .HIDDEN   (HIDDEN),
        .CLASSES  (CLASSES),
        .W_F      (W_F),
        .W_H      (W_H),
        .W_C      (W_C)
    ) u_learner (
        .clk_core       (clk_core),
        .rst_n          (rst_n),
        .start_p        (start_p),
        .step_p         (step_p),
        .halt_p         (halt_p),
        .freeze         (freeze),
        .lr_shift       (lr_shift),
        .sample_done_p  (sample_done_p),
        .correct_p      (correct_p),
        .error_p        (error_p),
        .pred           (pred_l),
        .sample_valid   (sample_valid),
        .label          (label),
        .ack_p          (ack_p),
        .x_addr         (x_addr),
        .x_rdata        (x_rdata),
        .a_addr         (a_addr),
        .a_wdata        (a_wdata),
        .a_we           (a_we),
        .a_rdata        (a_rdata),
        .accept_en      (accept_en),
        .busy           (busy),
        .done           (done)
    );

    //-----------------------------------------------------------------
    // BLK-005 : weight memory MEM-001 (port A = learner, port B = CSR)
    //-----------------------------------------------------------------
    weight_ram #(
        .W_TOT (W_TOT),
        .W_A   (W_A)
    ) u_weight_ram (
        .clk_core   (clk_core),
        .rst_n      (rst_n),
        .a_addr     (a_addr),
        .a_wdata    (a_wdata),
        .a_we       (a_we),
        .a_rdata    (a_rdata),
        .b_addr     (b_addr),
        .b_wdata    (b_wdata),
        .b_we       (b_we),
        .b_rdata    (b_rdata),
        .init_go    (init_go),
        .init_val   (init_val),
        .init_busy  (init_busy)
    );

    //-----------------------------------------------------------------
    // BLK-006 : saturating counters, sticky err, PRED register
    //-----------------------------------------------------------------
    stats u_stats (
        .clk_core       (clk_core),
        .rst_n          (rst_n),
        .sample_done_p  (sample_done_p),
        .correct_p      (correct_p),
        .error_p        (error_p),
        .err_p          (err_p),
        .clr_stats_p    (clr_stats_p),
        .pred_i         (pred_l),
        .sample_count   (sample_count),
        .correct_count  (correct_count),
        .error_count    (error_count),
        .err            (err),
        .pred           (pred_s)
    );

endmodule

`default_nettype wire                  // restore default for downstream tools
