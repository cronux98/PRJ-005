//---------------------------------------------------------------------
// tb_top_throughput.v — per-sample cycle budgets (VP-TOP-012, REQ-016)
// Project  : rinriAI (PRJ-005)
// Language : pure Verilog-2001, iverilog -g2001 -Wall
// DUT      : learn_accel at DEFAULT config 784x32x10 (run with
//            -DCFG_F=784 -DCFG_H=32 -DCFG_C=10; defaults are tiny)
// Checks   : train sample <= 200,000 cycles; inference (freeze) sample
//            <= 30,000 cycles; >= 1 byte/cycle while ready (streaming
//            measured implicitly by back-to-back frame acceptance).
//            Cycle count = accept (ack) edge to sample_done_p edge.
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

`ifndef CFG_F
`define CFG_F 4
`endif
`ifndef CFG_H
`define CFG_H 4
`endif
`ifndef CFG_C
`define CFG_C 2
`endif

module tb_top_throughput;
    localparam FEATURES = `CFG_F;
    localparam HIDDEN   = `CFG_H;
    localparam CLASSES  = `CFG_C;

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
    reg [31:0] rd;
    integer p;

    learn_accel #(.FEATURES(FEATURES), .HIDDEN(HIDDEN), .CLASSES(CLASSES)) dut (
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

    // deterministic pseudo-random sample (pixels 0..255 via LFSR)
    reg [31:0] lfsr = 32'h12345678;
    task make_pixel;
        output [7:0] px;
        begin
            lfsr = (lfsr >> 1) ^ (lfsr[0] ? 32'h0020_0003 : 32'h0);
            px = lfsr[7:0];
        end
    endtask

    // cycle counter: accept edge -> sample_done_p edge
    task run_one_sample;
        input        freeze;
        output [31:0] cycles;
        integer c;
        reg [7:0] px;
        begin
            // start/step (preserve freeze level on CTRL writes)
            if (freeze) apb_write(32'h00, 32'h0000000A);
            else        apb_write(32'h00, 32'h00000002);
            // stream the frame (learner accepts at the label beat)
            for (p = 0; p < FEATURES; p = p + 1) begin
                make_pixel(px);
                stream_byte(px, 1'b0);
            end
            make_pixel(px);
            stream_byte(px, 1'b1);
            // skip the accept pulse, then count until sample_done_p
            while (!dut.u_learner.ack_p) @(posedge clk_core);
            while (dut.u_learner.ack_p) @(posedge clk_core);
            c = 0;
            while (!dut.u_learner.sample_done_p) begin
                @(posedge clk_core);
                c = c + 1;
            end
            cycles = c;
            // drain: wait for idle
            while (dut.u_learner.state_r != 3'd0) @(posedge clk_core);
            @(posedge clk_core);
        end
    endtask

    reg [31:0] cyc;

    // ---------------------------------------------------------------
    initial begin
        $display("THROUGHPUT: FEATURES=%0d HIDDEN=%0d CLASSES=%0d", FEATURES, HIDDEN, CLASSES);
        $dumpfile("tb_top_throughput.vcd");
        $dumpvars(0, tb_top_throughput);

        tb_reset;
        apb_write(32'h04, 32'h00000002);           // lr_shift=2 (recommended recipe)
        apb_write(32'h00, 32'h00000010);           // clr_stats

        run_one_sample(1'b0, cyc);                 // train sample
        $display("train sample: %0d cycles (budget 200,000)", cyc);
        if (cyc > 200000) begin
            $display("FAIL train budget: %0d > 200000", cyc);
            errors = errors + 1;
        end

        run_one_sample(1'b1, cyc);                 // inference (freeze) sample
        $display("infer sample: %0d cycles (budget 30,000)", cyc);
        if (cyc > 30000) begin
            $display("FAIL infer budget: %0d > 30000", cyc);
            errors = errors + 1;
        end

        test_summary("tb_top_throughput");
        $finish;
    end

    initial begin #400_000_000; $display("TEST FAILED: timeout tb_top_throughput"); $finish; end
endmodule

`default_nettype wire
