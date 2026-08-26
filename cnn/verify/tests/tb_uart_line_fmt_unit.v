//---------------------------------------------------------------------
// tests/tb_uart_line_fmt_unit.v — VP-UART-001: byte-exact line content,
// all three verdict formats + confidence boundary values.
// Traces  : REQ-021, REQ-022
// Motivation: the top-level 200-image run (tb_mnist_top.v) only ever
//           exercises CORRECT/TRASH lines (the first 100 golden images
//           contain zero INCORRECT verdicts — confirmed by grepping
//           expected_outputs.txt). This unit test drives uart_line_fmt
//           directly (bypassing ctrl_fsm) with synthetic verdict=1
//           (INCORRECT) plus confidence boundary values (0,1,9,10,99,
//           100) that don't occur in the 100-image golden set either,
//           so REQ-022's format contract is exercised more completely
//           than the golden vectors alone permit. utx_ready is tied
//           high (always-accept), and the expected byte sequence is
//           built from scratch in this TB (independent decimal-ASCII
//           encoding, not the RTL's own field generator).
//---------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_uart_line_fmt_unit;
    reg clk = 1'b0;
    reg rst_n;
    integer errors = 0;

    `include "verify/tb_common/clk_rst.vh"
    `include "verify/tb_common/checker.vh"

    reg        lf_start;
    reg [3:0]  lf_pred;
    reg [6:0]  lf_conf;
    reg [3:0]  lf_exp;
    reg [6:0]  lf_idx;
    reg [1:0]  lf_verdict;
    wire        lf_done;

    wire [7:0] utx_data;
    wire        utx_valid;
    reg         utx_ready;

    uart_line_fmt dut (
        .clk(clk), .rst_n(rst_n),
        .lf_start(lf_start), .lf_pred(lf_pred), .lf_conf(lf_conf),
        .lf_exp(lf_exp), .lf_idx(lf_idx), .lf_verdict(lf_verdict), .lf_done(lf_done),
        .utx_data(utx_data), .utx_valid(utx_valid), .utx_ready(utx_ready)
    );

    // ---- always-accept byte sink ----
    reg [7:0] captured [0:99];
    integer   ccount;
    always @(posedge clk) begin
        if (!rst_n) begin
            ccount <= 0;
        end else if (utx_valid && utx_ready) begin
            captured[ccount] <= utx_data;
            ccount <= ccount + 1;
        end
    end

    // ---- independent expected-byte-sequence builder (scratch decimal
    // ASCII encoder, not the RTL's field generator) ----
    reg [7:0] exp_bytes [0:99];
    integer   ep;

    task push_byte;
        input [7:0] b;
        begin
            exp_bytes[ep] = b;
            ep = ep + 1;
        end
    endtask

    task push_str8;   // pushes exactly 1 ASCII char
        input [7:0] c;
        begin
            push_byte(c);
        end
    endtask

    // pushes a value 0..9 as a single ASCII digit
    task push_digit1;
        input [3:0] v;
        begin
            push_byte(8'h30 + {4'd0, v});
        end
    endtask

    // pushes idx as 3-digit zero-padded (0..99, hundreds digit always "0")
    task push_idx3;
        input [6:0] v;
        reg [6:0] tens, ones;
        begin
            tens = v / 7'd10;
            ones = v % 7'd10;
            push_byte(8'h30);
            push_byte(8'h30 + tens[3:0]);
            push_byte(8'h30 + ones[3:0]);
        end
    endtask

    // pushes confidence with NO leading zeros (0..100)
    task push_conf;
        input [6:0] v;
        reg [6:0] h, rem, t, o;
        begin
            h   = v / 7'd100;
            rem = v % 7'd100;
            t   = rem / 7'd10;
            o   = rem % 7'd10;
            if (h != 0) begin
                push_byte(8'h30 + h[3:0]);
                push_byte(8'h30 + t[3:0]);
                push_byte(8'h30 + o[3:0]);
            end else if (t != 0) begin
                push_byte(8'h30 + t[3:0]);
                push_byte(8'h30 + o[3:0]);
            end else begin
                push_byte(8'h30 + o[3:0]);
            end
        end
    endtask

    integer k;
    task build_expected;
        input [6:0] idx;
        input [3:0] pred;
        input [6:0] conf;
        input [3:0] exp_lbl;
        input [1:0] verdict;
        begin
            ep = 0;
            push_byte("I"); push_byte("M"); push_byte("G"); push_byte(" ");
            push_idx3(idx);
            push_byte(":"); push_byte(" ");
            if (verdict == 2'd2) begin
                push_byte("N"); push_byte("O"); push_byte("T"); push_byte(" ");
                push_byte("A"); push_byte(" ");
                push_byte("N"); push_byte("U"); push_byte("M"); push_byte("B"); push_byte("E"); push_byte("R");
            end else begin
                push_byte("T"); push_byte("h"); push_byte("i"); push_byte("s"); push_byte(" ");
                push_byte("i"); push_byte("s"); push_byte(" ");
                push_byte("n"); push_byte("u"); push_byte("m"); push_byte("b"); push_byte("e"); push_byte("r"); push_byte(" ");
                push_digit1(pred);
            end
            push_byte(" "); push_byte("|"); push_byte(" ");
            push_byte("c"); push_byte("o"); push_byte("n"); push_byte("f"); push_byte("i");
            push_byte("d"); push_byte("e"); push_byte("n"); push_byte("c"); push_byte("e"); push_byte(" ");
            push_conf(conf);
            push_byte("%"); push_byte(" "); push_byte("|"); push_byte(" ");
            push_byte("e"); push_byte("x"); push_byte("p"); push_byte("e"); push_byte("c");
            push_byte("t"); push_byte("e"); push_byte("d"); push_byte(" ");
            push_digit1(exp_lbl);
            push_byte(" "); push_byte("|"); push_byte(" ");
            if (verdict == 2'd0) begin
                push_byte("C"); push_byte("O"); push_byte("R"); push_byte("R"); push_byte("E"); push_byte("C"); push_byte("T");
            end else if (verdict == 2'd1) begin
                push_byte("I"); push_byte("N"); push_byte("C"); push_byte("O"); push_byte("R"); push_byte("R"); push_byte("E"); push_byte("C"); push_byte("T");
            end else begin
                push_byte("T"); push_byte("R"); push_byte("A"); push_byte("S"); push_byte("H");
            end
            push_byte(8'h0A);
        end
    endtask

    task run_case;
        input [6:0] idx;
        input [3:0] pred;
        input [6:0] conf;
        input [3:0] exp_lbl;
        input [1:0] verdict;
        input [255:0] name;
        integer j, tmo;
        begin
            build_expected(idx, pred, conf, exp_lbl, verdict);

            // NBA throughout: clearing lf_start right after the @(posedge
            // clk) it must be seen HIGH on would otherwise race against
            // uart_line_fmt's own always block for that same edge (see the
            // matching note in tb_mac_datapath_unit.v).
            ccount     <= 0;
            lf_pred    <= pred;
            lf_conf    <= conf;
            lf_exp     <= exp_lbl;
            lf_idx     <= idx;
            lf_verdict <= verdict;
            lf_start   <= 1'b1;
            @(posedge clk);
            lf_start <= 1'b0;

            tmo = 0;
            while (!lf_done && tmo < 2000) begin
                @(posedge clk);
                tmo = tmo + 1;
            end
            check_cond(lf_done, {"VP-UART-001: lf_done seen for ", name});

            check_eq(ccount, ep, {"VP-UART-001: byte count matches for ", name});
            for (j = 0; j < ep && j < 100; j = j + 1)
                check_eq({24'd0, captured[j]}, {24'd0, exp_bytes[j]}, {"VP-UART-001: byte content for ", name});

            @(posedge clk);   // 1 idle cycle between cases
        end
    endtask

    initial begin
        utx_ready = 1'b1;
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk);

        run_case(7'd5,  4'd3, 7'd77,  4'd3, 2'd0, "CORRECT");
        run_case(7'd42, 4'd2, 7'd60,  4'd5, 2'd1, "INCORRECT");
        run_case(7'd99, 4'd0, 7'd10,  4'd8, 2'd2, "TRASH");
        run_case(7'd0,  4'd0, 7'd0,   4'd0, 2'd2, "TRASH conf=0 boundary");
        run_case(7'd1,  4'd1, 7'd1,   4'd1, 2'd0, "CORRECT conf=1 boundary");
        run_case(7'd2,  4'd2, 7'd9,   4'd2, 2'd0, "CORRECT conf=9 (1-digit max)");
        run_case(7'd3,  4'd3, 7'd10,  4'd3, 2'd0, "CORRECT conf=10 (2-digit min)");
        run_case(7'd4,  4'd4, 7'd99,  4'd4, 2'd1, "INCORRECT conf=99 (2-digit max)");
        run_case(7'd6,  4'd6, 7'd100, 4'd6, 2'd0, "CORRECT conf=100 (3-digit defensive case)");

        test_summary("tb_uart_line_fmt_unit");
        $finish;
    end
endmodule
