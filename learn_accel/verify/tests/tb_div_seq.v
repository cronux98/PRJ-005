//---------------------------------------------------------------------
// tb_div_seq.v — module gate for BLK-007 div_seq
// Project  : rinriAI (PRJ-005) — L3 numeric edges (REQ-004, REQ-011)
// Language : pure Verilog-2001, iverilog -g2001 -Wall
// DUT      : rtl/div_seq.v
// Coverage : truncation toward zero both signs (C99 '/' semantics),
//            sigmoid-domain cases (num=128*z, den=256+|z| at z = 0,
//            ±1, ±2, ±3, ±255, ±256, ±257, ±32767, −32768), den=0
//            guard, protocol (busy/done timing, 33-cycle latency,
//            div_start ignored while busy, q valid with div_done).
// Expected values precomputed with an independent C99-trunc model.
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_div_seq;
    reg clk_core = 1'b0;
    reg rst_n    = 1'b0;

    reg        div_start = 0;
    reg  [31:0] div_num = 0;
    reg  [16:0] div_den = 0;
    wire       div_busy, div_done;
    wire signed [16:0] div_q;

    integer errors = 0;

    div_seq dut (
        .clk_core (clk_core), .rst_n (rst_n),
        .div_start (div_start), .div_num (div_num), .div_den (div_den),
        .div_busy (div_busy), .div_done (div_done), .div_q (div_q)
    );

    `include "tb_common/clk_rst.vh"
    `include "tb_common/checker.vh"

    // {num, den, expected_q} — C99 truncation toward zero
    reg [31:0]  t_num  [0:25];
    reg [16:0]  t_den  [0:25];
    reg signed [16:0] t_q [0:25];

    // ---------------------------------------------------------------
    integer i;          // module-scope loop vars (Verilog-2001)
    integer lat_cycles;

    initial begin
        $dumpfile("tb_div_seq.vcd");
        $dumpvars(0, tb_div_seq);

        t_num[0]=32'd0;        t_den[0]=17'd256;   t_q[0]=17'sd0;     // z=0
        t_num[1]=32'd128;      t_den[1]=17'd257;   t_q[1]=17'sd0;     // z=1
        t_num[2]=32'd256;      t_den[2]=17'd258;   t_q[2]=17'sd0;     // z=2
        t_num[3]=32'd384;      t_den[3]=17'd259;   t_q[3]=17'sd1;     // z=3
        t_num[4]=-32'd128;     t_den[4]=17'd257;   t_q[4]=17'sd0;     // z=-1
        t_num[5]=-32'd384;     t_den[5]=17'd259;   t_q[5]=-17'sd1;    // z=-3
        t_num[6]=32'd32640;    t_den[6]=17'd511;   t_q[6]=17'sd63;    // z=255
        t_num[7]=-32'd32640;   t_den[7]=17'd511;   t_q[7]=-17'sd63;   // z=-255
        t_num[8]=32'd32768;    t_den[8]=17'd512;   t_q[8]=17'sd64;    // z=256
        t_num[9]=-32'd32768;   t_den[9]=17'd512;   t_q[9]=-17'sd64;   // z=-256
        t_num[10]=32'd32896;   t_den[10]=17'd513;  t_q[10]=17'sd64;   // z=257
        t_num[11]=-32'd32896;  t_den[11]=17'd513;  t_q[11]=-17'sd64;  // z=-257
        t_num[12]=32'd4194176; t_den[12]=17'd33023; t_q[12]=17'sd127; // z=32767
        t_num[13]=-32'd4194176;t_den[13]=17'd33023; t_q[13]=-17'sd127;// z=-32767
        t_num[14]=-32'd4194304;t_den[14]=17'd33024; t_q[14]=-17'sd127;// z=-32768
        t_num[15]=32'd13;      t_den[15]=17'd4;    t_q[15]=17'sd3;    // 13/4
        t_num[16]=-32'd13056;  t_den[16]=17'd358;  t_q[16]=-17'sd36;  // -13056/358
        t_num[17]=-32'd13056;  t_den[17]=17'd358;  t_q[17]=-17'sd36;  // (dup)
        t_num[18]=32'd0;       t_den[18]=17'd256;  t_q[18]=17'sd0;    // 0/256
        t_num[19]=-32'd1;      t_den[19]=17'd256;  t_q[19]=17'sd0;    // -1/256 -> 0
        t_num[20]=32'd1;       t_den[20]=17'd256;  t_q[20]=17'sd0;    // 1/256 -> 0
        t_num[21]=-32'd4194304;t_den[21]=17'd33024; t_q[21]=-17'sd127;// minnum/maxden
        t_num[22]=32'd4194176; t_den[22]=17'd33023; t_q[22]=17'sd127; // maxnum/maxden
        t_num[23]=32'd128;     t_den[23]=17'd256;  t_q[23]=17'sd0;    // 128/256
        t_num[24]=32'd127;     t_den[24]=17'd256;  t_q[24]=17'sd0;    // 127/256
        t_num[25]=-32'd4194304;t_den[25]=17'd0;    t_q[25]=17'sd0;    // den=0 guard

        tb_reset;
        check_eq1(div_busy, 1'b0, "div_busy low after reset");
        check_eq1(div_done, 1'b0, "div_done low after reset");
        check_eq(div_q, 17'sd0, "div_q 0 after reset");

        // ---- 1. Table-driven divisions ---------------------------------
        for (i = 0; i < 26; i = i + 1) begin
            div_num  <= t_num[i];
            div_den  <= t_den[i];
            div_start <= 1'b1;
            @(posedge clk_core);
            div_start <= 1'b0;
            @(posedge clk_core);           // settle (DUT NBA visible)
            check_eq1(div_busy, 1'b1, "div_busy high after start");
            // wait for done
            while (!div_done) @(posedge clk_core);
            if (div_q !== t_q[i]) begin
                $display("FAIL div case %0d: num=%0d den=%0d got=%0d want=%0d", i, t_num[i], t_den[i], div_q, t_q[i]);
                errors = errors + 1;
            end
            @(posedge clk_core);           // div_done is 1-cycle: settle
            check_eq1(div_busy, 1'b0, "div_busy low after done");
        end

        // ---- 2. Latency: capture edge -> div_done sampled high ---------
        // 32 shift-subtract iterations + 1 finalize; div_done is a 1-cycle
        // pulse asserted at the 33rd posedge after capture, sampled at the
        // 34th (RTL comment "33 cycles from div_start to div_done" counts
        // posedges to the assert edge).
        begin : latency
            div_num  <= 32'd4194176;
            div_den  <= 17'd33023;
            div_start <= 1'b1;
            @(posedge clk_core);           // capture edge T0
            div_start <= 1'b0;
            lat_cycles = 0;
            while (!div_done) begin
                @(posedge clk_core);
                lat_cycles = lat_cycles + 1;
            end
            if (lat_cycles !== 34) begin
                $display("FAIL latency: %0d cycles (want 34 capture->done-sampled)", lat_cycles);
                errors = errors + 1;
            end
        end

        // ---- 3. div_start ignored while busy ----------------------------
        begin : busy_ignore
            div_num  <= 32'd384;           // would give q=1
            div_den  <= 17'd259;
            div_start <= 1'b1;
            @(posedge clk_core);           // capture
            div_start <= 1'b0;
            // re-assert start mid-operation: must be ignored
            div_start <= 1'b1;
            @(posedge clk_core);
            div_start <= 1'b0;
            while (!div_done) @(posedge clk_core);
            if (div_q !== 17'sd1) begin
                $display("FAIL start-while-busy: q=%0d (want 1 — original op)", div_q);
                errors = errors + 1;
            end
            @(posedge clk_core);
        end

        // ---- 4. div_done is a 1-cycle pulse -----------------------------
        begin : done_width
            reg d1;
            div_num <= 32'd13; div_den <= 17'd4;
            div_start <= 1'b1;
            @(posedge clk_core);
            div_start <= 1'b0;
            while (!div_done) @(posedge clk_core);
            @(posedge clk_core);           // done was high last cycle
            d1 = div_done;                 // must be 0 now
            if (d1 !== 1'b0) begin
                $display("FAIL div_done wider than 1 cycle");
                errors = errors + 1;
            end
        end

        test_summary("tb_div_seq");
        $finish;
    end

    // Watchdog
    initial begin
        #1_000_000;
        $display("TEST FAILED: timeout tb_div_seq");
        $finish;
    end
endmodule

`default_nettype wire
