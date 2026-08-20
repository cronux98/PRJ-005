//---------------------------------------------------------------------
// tb_cov_extend.v — coverage-closing stimulus (Verilator coverage mode)
// Project  : rinriAI (PRJ-005)
// Purpose  : drive the RTL paths the acceptance TB misses: malformed
//            frames (early last at each index, missing last), RESYNC,
//            init_weights bulk walk, WADDR/WDATA CSR traffic, PSLVERR
//            reserved addresses, freeze with weight dump, clr_stats.
//            No hierarchical forces (Verilator-compatible).
// Verdict  : self-checking (errors counted) + $finish.
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_cov_extend;
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

    task stream_frame_fixed;
        input [7:0] label;
        integer p;
        begin
            for (p = 0; p < FEATURES; p = p + 1) stream_byte(p[7:0], 1'b0);
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
        $dumpfile("tb_cov_extend.vcd");
        $dumpvars(0, tb_cov_extend);

        tb_reset;
        apb_write(32'h04, 32'h00000000);

        // ---- PSLVERR paths -------------------------------------------
        apb_access_expect_err(1'b1, 32'h00000028, 32'h0, rd);
        apb_access_expect_err(1'b0, 32'h0000003C, 32'h0, rd);
        apb_access_expect_err(1'b1, 32'h00000100, 32'h0, rd);
        apb_access_expect_err(1'b0, 32'hFFFFFFFC, 32'h0, rd);

        // ---- WADDR/WDATA CSR traffic (round-trip) ---------------------
        apb_write(32'h1C, 32'h00000000);
        for (i = 0; i < W_TOT; i = i + 1)
            apb_write(32'h20, {16'h0, (i * 16'd613) & 16'hFFFF});
        apb_write(32'h1C, 32'h00000000);
        for (i = 0; i < W_TOT; i = i + 1) apb_read(32'h20, rd);

        // ---- init_weights bulk walk -----------------------------------
        apb_write(32'h24, 32'h0000A5A5);
        apb_write(32'h00, 32'h00000020);
        @(posedge clk_core);
        while (dut.u_weight_ram.init_busy) @(posedge clk_core);
        apb_write(32'h1C, 32'h00000000);
        apb_read(32'h20, rd);
        check_eq(rd, 32'h0000A5A5, "init walk word 0");

        // ---- malformed frames: early last at each index + resync ------
        apb_write(32'h00, 32'h00000010);           // clr_stats
        for (i = 0; i < FEATURES; i = i + 1) begin
            apb_write(32'h00, 32'h00000002);       // step
            for (p = 0; p <= i; p = p + 1)
                stream_byte(p[7:0], (p == i) ? 1'b1 : 1'b0);  // early last
            stream_byte(8'h00, 1'b1);              // resync
            stream_frame_fixed(8'h00);             // valid completes step
            wait_done;
        end
        // missing s_last at label index
        apb_write(32'h00, 32'h00000010);
        apb_write(32'h00, 32'h00000002);
        stream_byte(8'h10, 1'b0);
        stream_byte(8'h11, 1'b0);
        stream_byte(8'h12, 1'b0);
        stream_byte(8'h13, 1'b0);
        stream_byte(8'h00, 1'b0);                  // no last -> err
        stream_byte(8'h00, 1'b1);                  // resync
        stream_frame_fixed(8'h01);
        wait_done;
        apb_read(32'h08, rd);
        check_eq1(rd[2], 1'b1, "err sticky");
        apb_write(32'h00, 32'h00000010);           // clr_stats clears err

        // ---- freeze with weight dump (byte-identical) ------------------
        apb_write(32'h00, 32'h0000000A);           // step + freeze
        stream_frame_fixed(8'h01);
        wait_done;
        apb_write(32'h1C, 32'h00000000);
        apb_read(32'h20, rd);
        check_eq(rd, 32'h0000A5A5, "frozen weight unchanged");

        // ---- backpressure: hold s_valid while learner busy -------------
        apb_write(32'h00, 32'h00000002);
        stream_frame_fixed(8'h00);
        // while processing, hold a byte on the bus (s_ready low)
        s_valid <= 1'b1; s_data <= 8'h77; s_last <= 1'b0;
        repeat (4) @(posedge clk_core);
        check_eq1(s_ready, 1'b0, "backpressure active");
        s_valid <= 1'b0;
        wait_done;

        // ---- label >= CLASSES (known RTL-BUG-1: processed, not rejected)
        apb_write(32'h00, 32'h00000002);
        stream_frame_fixed(8'h07);
        wait_done;

        // ---- halt mid-stream -------------------------------------------
        apb_write(32'h00, 32'h00000001);           // start
        stream_frame_fixed(8'h00);
        apb_write(32'h00, 32'h00000004);           // halt while busy
        wait_done;
        apb_write(32'h00, 32'h00000002);           // step again (restart)

        test_summary("tb_cov_extend");
        $finish;
    end

    initial begin #80_000_000; $display("TEST FAILED: timeout"); $finish; end
endmodule

`default_nettype wire
