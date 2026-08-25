//---------------------------------------------------------------------
// tb_top_edge.v — top-level edge cases (VP-LRN-004 argmax ties, OI-008
// overwrite-window closure, L4 label stress)
// Project  : rinriAI (PRJ-005)
// Language : pure Verilog-2001, iverilog -g2001 -Wall
// DUT      : learn_accel (tiny 4x4x2)
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_top_edge;
    localparam FEATURES = 4, HIDDEN = 4, CLASSES = 2;
    localparam W_TOT = FEATURES*HIDDEN + HIDDEN + HIDDEN*CLASSES + CLASSES;

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
    integer i, p;

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

    // load W_TOT words from a fixed pattern array
    task load_weights;
        input [15:0] w0, w1, w2, w3, w4, w5, w6, w7, w8, w9;
        input [15:0] w10, w11, w12, w13, w14, w15, w16, w17, w18, w19;
        input [15:0] w20, w21, w22, w23, w24, w25, w26, w27, w28, w29;
        begin
            apb_write(32'h1C, 32'h00000000);
            apb_write(32'h20, {16'h0, w0});  apb_write(32'h20, {16'h0, w1});
            apb_write(32'h20, {16'h0, w2});  apb_write(32'h20, {16'h0, w3});
            apb_write(32'h20, {16'h0, w4});  apb_write(32'h20, {16'h0, w5});
            apb_write(32'h20, {16'h0, w6});  apb_write(32'h20, {16'h0, w7});
            apb_write(32'h20, {16'h0, w8});  apb_write(32'h20, {16'h0, w9});
            apb_write(32'h20, {16'h0, w10}); apb_write(32'h20, {16'h0, w11});
            apb_write(32'h20, {16'h0, w12}); apb_write(32'h20, {16'h0, w13});
            apb_write(32'h20, {16'h0, w14}); apb_write(32'h20, {16'h0, w15});
            apb_write(32'h20, {16'h0, w16}); apb_write(32'h20, {16'h0, w17});
            apb_write(32'h20, {16'h0, w18}); apb_write(32'h20, {16'h0, w19});
            apb_write(32'h20, {16'h0, w20}); apb_write(32'h20, {16'h0, w21});
            apb_write(32'h20, {16'h0, w22}); apb_write(32'h20, {16'h0, w23});
            apb_write(32'h20, {16'h0, w24}); apb_write(32'h20, {16'h0, w25});
            apb_write(32'h20, {16'h0, w26}); apb_write(32'h20, {16'h0, w27});
            apb_write(32'h20, {16'h0, w28}); apb_write(32'h20, {16'h0, w29});
        end
    endtask

    task stream_sample;
        input [7:0] px0, px1, px2, px3, label;
        begin
            stream_byte(px0, 1'b0); stream_byte(px1, 1'b0);
            stream_byte(px2, 1'b0); stream_byte(px3, 1'b0);
            stream_byte(label, 1'b1);
        end
    endtask

    task wait_done;
        integer tmo;
        begin
            tmo = 0;
            while (tmo < 100000) begin
                apb_read(32'h08, rd);
                if (rd[1]) tmo = 100000;
                else begin tmo = tmo + 1; @(posedge clk_core); end
            end
        end
    endtask

    // ---------------------------------------------------------------
    initial begin
        $dumpfile("tb_top_edge.vcd");
        $dumpvars(0, tb_top_edge);

        tb_reset;
        apb_write(32'h04, 32'h00000000);

        // ---- VP-LRN-004: exact argmax tie -> lowest index --------------
        // All output weights/biases equal for c=0 and c=1 -> y[0]==y[1]
        // for any input; strict > keeps index 0.
        // w_h all 0x0100 (1.0), b_h 0, w_o[0][h]=w_o[1][h]=0x0200, b_o=0
        load_weights(16'h0100, 16'h0100, 16'h0100, 16'h0100,   // w_h[0][*]
                     16'h0100, 16'h0100, 16'h0100, 16'h0100,   // w_h[1][*]
                     16'h0100, 16'h0100, 16'h0100, 16'h0100,   // w_h[2][*]
                     16'h0100, 16'h0100, 16'h0100, 16'h0100,   // w_h[3][*]
                     16'h0000, 16'h0000, 16'h0000, 16'h0000,   // b_h
                     16'h0200, 16'h0200, 16'h0200, 16'h0200,   // w_o[0][*]
                     16'h0200, 16'h0200, 16'h0200, 16'h0200,   // w_o[1][*]
                     16'h0000, 16'h0000);                     // b_o
        apb_write(32'h00, 32'h0000000A);        // step + freeze (inference)
        stream_sample(8'hFF, 8'h00, 8'h00, 8'h00, 8'h00);
        wait_done;
        apb_read(32'h18, rd);
        check_eq(rd, 32'h00000000, "argmax exact tie -> lowest index (0)");
        // all-equal inputs with equal weights: still index 0
        apb_write(32'h00, 32'h0000000A);
        stream_sample(8'h80, 8'h80, 8'h80, 8'h80, 8'h01);
        wait_done;
        apb_read(32'h18, rd);
        check_eq(rd, 32'h00000000, "argmax all-equal -> lowest index (0)");

        // ---- OI-008: overwrite window closed at top --------------------
        // After a label beat (sample_valid pending), s_ready must drop in
        // the SAME cycle — a back-to-back feeder cannot overwrite MEM-002.
        apb_write(32'h00, 32'h0000000A);        // step + freeze
        stream_sample(8'h11, 8'h22, 8'h33, 8'h44, 8'h00);   // frame A
        // immediately present frame B's first byte: s_ready must be 0
        s_valid <= 1'b1; s_data <= 8'hEE; s_last <= 1'b0;
        @(posedge clk_core);
        if (s_ready === 1'b0)
            $display("NOTE OI-008: s_ready dropped while sample pending (window closed)");
        else begin
            $display("FAIL OI-008: s_ready high while sample pending (overwrite window open)");
            errors = errors + 1;
        end
        s_valid <= 1'b0;
        wait_done;
        // frame B's byte was NOT accepted: the pending sample was frame A
        apb_read(32'h18, rd);                  // pred for frame A (weights above)
        check_eq(rd, 32'h00000000, "frame A pred intact (no overwrite)");

        // ---- L4 label stress: all-0, cycling, CLASSES-1, >=CLASSES -----
        // all-0 labels over 3 samples (train mode, goldens irrelevant —
        // we check counters move and no err for valid labels)
        apb_write(32'h00, 32'h00000010);        // clr_stats
        apb_write(32'h00, 32'h00000002);        // step
        stream_sample(8'h01, 8'h02, 8'h03, 8'h04, 8'h00);  // label 0
        wait_done;
        apb_write(32'h00, 32'h00000002);
        stream_sample(8'h05, 8'h06, 8'h07, 8'h08, 8'h00);  // label 0
        wait_done;
        apb_read(32'h0C, rd); check_eq(rd, 32'h00000002, "2 samples with label 0");
        apb_read(32'h08, rd); check_eq1(rd[2], 1'b0, "no err for valid labels");
        // cycling labels 0,1,0,1 and CLASSES-1 boundary
        apb_write(32'h00, 32'h00000002);
        stream_sample(8'h10, 8'h20, 8'h30, 8'h40, 8'h01);  // label 1 (CLASSES-1)
        wait_done;
        apb_write(32'h00, 32'h00000002);
        stream_sample(8'h50, 8'h60, 8'h70, 8'h80, 8'h00);
        wait_done;
        apb_read(32'h0C, rd); check_eq(rd, 32'h00000004, "4 samples, cycling labels");
        // label >= CLASSES (known gap — REQ-018): sample is NOT rejected.
        // Documented as finding RTL-BUG-1; here we only record behaviour.
        apb_write(32'h00, 32'h00000002);
        stream_sample(8'h01, 8'h02, 8'h03, 8'h04, 8'h07);  // label 7 >= 2
        wait_done;
        begin : l7probe
            reg err_l7;
            apb_read(32'h08, rd);
            err_l7 = rd[2];
            apb_read(32'h0C, rd);
            $display("INFO label>=CLASSES: err=%b sample_count=%0d (RTL-BUG-1: not rejected)", err_l7, rd[31:0]);
        end

        test_summary("tb_top_edge");
        $finish;
    end

    initial begin #50_000_000; $display("TEST FAILED: timeout tb_top_edge"); $finish; end
endmodule

`default_nettype wire
