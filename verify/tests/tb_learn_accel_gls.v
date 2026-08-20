//---------------------------------------------------------------------
// tb_learn_accel_gls.v — GATE-LEVEL simulation TB (fe-gls)
// Project  : rinriAI (PRJ-005)
// DUT      : verify/synth/flow/run-003/synth/learn_accel_tiny_top_synth.v
//            (sky130_fd_sc_hd mapped, tiny 4x4x2 config)
// Checks   : golden-model replay on the NETLIST — same vectors + checks
//            as the RTL acceptance test (step mode). Catches X-prop,
//            structural races, mapping bugs.
// Compile  : iverilog -g2012 -DFUNCTIONAL netlist cell_models primitives
//            tb_learn_accel_gls.v  (see fe-gls skill)
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_learn_accel_gls;
    localparam FEATURES = 4, HIDDEN = 4, CLASSES = 2;
    localparam W_TOT = FEATURES*HIDDEN + HIDDEN + HIDDEN*CLASSES + CLASSES;
    localparam N_SAMPLES = 5;
    localparam STIM_WORDS = W_TOT + N_SAMPLES*(FEATURES+1);
    localparam EXP_WORDS  = N_SAMPLES*5 + W_TOT;

    reg clk_core = 1'b0;
    reg rst_n    = 1'b0;
    reg        apb_psel = 0, apb_penable = 0, apb_pwrite = 0;
    reg  [31:0] apb_paddr = 0, apb_pwdata = 0;
    wire [31:0] apb_prdata;
    wire        apb_pready, apb_pslverr;
    reg        s_valid = 0, s_last = 0;
    reg  [7:0] s_data = 0;
    wire       s_ready;

    integer errors = 0;
    reg [31:0] stim [0:STIM_WORDS-1];
    reg [31:0] exp  [0:EXP_WORDS-1];
    reg [31:0] rd;

    learn_accel_tiny_top dut (
        .clk_core (clk_core), .rst_n (rst_n),
        .psel (apb_psel), .penable (apb_penable), .pwrite (apb_pwrite),
        .paddr (apb_paddr), .pwdata (apb_pwdata), .prdata (apb_prdata),
        .pready (apb_pready), .pslverr (apb_pslverr),
        .s_valid (s_valid), .s_ready (s_ready), .s_data (s_data), .s_last (s_last)
    );

    `include "tb_common/clk_rst.vh"
    `include "tb_common/checker.vh"
    `include "tb_common/apb4_bfm.vh"
    `include "tb_common/stream_byte.vh"
    `include "tb_common/golden_replay.vh"

    // ---------------------------------------------------------------
    initial begin
        $dumpfile("tb_learn_accel_gls.vcd");
        $dumpvars(0, tb_learn_accel_gls);

        $readmemh("arch/golden_model/stimulus.hex", stim);
        $readmemh("verify/golden/tiny_shipped_corrected/expected.hex", exp);

        tb_reset;

        $display("-- GLS step mode --");
        golden_replay(1'b0, 1'b0, 4'd0);     // step, train

        if (errors == 0) $display("GLS_PASS");
        else begin $display("GLS_FAIL: %0d errors", errors); $finish; end
        $finish;
    end

    initial begin #100_000_000; $display("GLS_FAIL: timeout"); $finish; end
endmodule

`default_nettype wire
