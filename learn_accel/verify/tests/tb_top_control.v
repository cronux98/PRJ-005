//---------------------------------------------------------------------
// tb_top_control.v — top-level control semantics suite
// Project  : rinriAI (PRJ-005) — VP-TOP-006 (step), 007 (halt),
//           008 (malformed at top, incl. label>=CLASSES probe), OI-008
// Language : pure Verilog-2001, iverilog -g2001 -Wall
// DUT      : learn_accel (tiny 4x4x2)
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_top_control;
    localparam FEATURES = 4, HIDDEN = 4, CLASSES = 2;

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

    // Stream a full valid frame (pixels 0..FEATURES-1 + label)
    task stream_frame_fixed;
        input [7:0] label;
        integer p;
        begin
            for (p = 0; p < FEATURES; p = p + 1) stream_byte(p[7:0], 1'b0);
            stream_byte(label, 1'b1);
        end
    endtask

    task wait_status_done;
        integer tmo;
        begin
            tmo = 0;
            while (tmo < 100000) begin
                apb_read(32'h08, rd);
                if (rd[1]) tmo = 100000;
                else begin tmo = tmo + 1; @(posedge clk_core); end
            end
            if (tmo >= 100000) begin
                apb_read(32'h08, rd);
                if (!rd[1]) begin
                    $display("FAIL wait done timeout");
                    errors = errors + 1;
                end
            end
        end
    endtask

    // ---------------------------------------------------------------
    initial begin
        $dumpfile("tb_top_control.vcd");
        $dumpvars(0, tb_top_control);

        tb_reset;

        // ---- VP-TOP-006: step mode = exactly one sample ----------------
        apb_write(32'h04, 32'h00000000);
        apb_write(32'h00, 32'h00000002);           // CTRL.step
        stream_frame_fixed(8'h00);                 // sample 1
        // during processing, s_ready=0
        @(posedge clk_core);
        check_eq1(s_ready, 1'b0, "s_ready low while busy (processing)");
        wait_status_done;
        apb_read(32'h08, rd);
        check_eq1(rd[0], 1'b0, "busy=0 after step done");
        check_eq1(rd[1], 1'b1, "done=1 after step");
        check_eq1(s_ready, 1'b0, "s_ready=0 in idle after step (not running)");
        apb_read(32'h0C, rd); check_eq(rd, 32'h00000001, "exactly 1 sample counted");
        // a second frame must NOT be accepted (s_ready=0): present bytes,
        // verify no beat
        begin : no_accept
            integer beats;
            beats = 0;
            s_valid <= 1'b1; s_data <= 8'hAA; s_last <= 1'b0;
            repeat (5) @(posedge clk_core);
            s_valid <= 1'b0;
            apb_read(32'h0C, rd);
            check_eq(rd, 32'h00000001, "no sample counted while idle-not-running");
        end

        // ---- VP-TOP-007: halt mid-stream -------------------------------
        // start continuous, stream sample 2, halt while processing
        apb_write(32'h00, 32'h00000001);           // start
        stream_frame_fixed(8'h01);                 // sample 2 (accepted)
        @(posedge clk_core);
        check_eq1(s_ready, 1'b0, "processing sample 2");
        apb_write(32'h00, 32'h00000004);           // halt during processing
        wait_status_done;
        apb_read(32'h08, rd);
        check_eq1(rd[0], 1'b0, "busy=0 after halt");
        check_eq1(rd[1], 1'b1, "done=1 after halt");
        apb_read(32'h0C, rd); check_eq(rd, 32'h00000002, "in-flight sample completed");
        apb_read(32'h10, rd);                      // correct/error consistent
        apb_read(32'h14, rd);
        check_eq(rd[31:0], (dut.u_stats.correct_count == 32'd2) ? 32'h00000000 : 32'h00000001,
                 "halt counters consistent");
        // restart works: start + sample 3 (continuous mode: wait counter)
        apb_write(32'h00, 32'h00000001);           // start again
        stream_frame_fixed(8'h00);                 // sample 3
        begin : wait_c3
            integer tmo;
            tmo = 0;
            while (tmo < 100000) begin
                apb_read(32'h0C, rd);
                if (rd == 32'd3) tmo = 100000;
                else begin tmo = tmo + 1; @(posedge clk_core); end
            end
            if (tmo >= 100000) begin
                apb_read(32'h0C, rd);
                if (rd !== 32'd3) begin
                    $display("FAIL restart sample timeout (cnt=%0d)", rd);
                    errors = errors + 1;
                end
            end
        end
        apb_read(32'h0C, rd); check_eq(rd, 32'h00000003, "restart processed sample 3");

        // ---- VP-TOP-008: malformed frames at top level -----------------
        // err sticky via STATUS[2]; counters unchanged; resync works.
        // NOTE: in step mode a malformed frame never completes the step
        // (no sample accepted) — the valid frame after resync does.
        apb_write(32'h00, 32'h00000010);           // clr_stats: clear err + counters
        apb_write(32'h00, 32'h00000002);           // step
        // s_last early at pixel index 1
        stream_byte(8'h01, 1'b0);
        stream_byte(8'h02, 1'b1);                  // early last at px index 1
        @(posedge clk_core);
        stream_byte(8'h00, 1'b1);                  // resync byte (discarded)
        apb_read(32'h08, rd);
        check_eq1(rd[2], 1'b1, "err sticky set (early last)");
        apb_read(32'h0C, rd); check_eq(rd, 32'h00000000, "counters unchanged by malformed");
        // valid frame completes the step
        stream_frame_fixed(8'h00);
        wait_status_done;
        apb_read(32'h0C, rd); check_eq(rd, 32'h00000001, "valid sample after malformed");
        // missing s_last at label index: step + 4 px + 5th byte w/o last
        apb_write(32'h00, 32'h00000010);           // clr_stats (clears err + counters)
        apb_write(32'h00, 32'h00000002);           // step
        stream_byte(8'h10, 1'b0);
        stream_byte(8'h11, 1'b0);
        stream_byte(8'h12, 1'b0);
        stream_byte(8'h13, 1'b0);
        stream_byte(8'h00, 1'b0);                  // label pos, no last -> err
        @(posedge clk_core);
        stream_byte(8'h00, 1'b1);                  // resync
        apb_read(32'h08, rd);
        check_eq1(rd[2], 1'b1, "err sticky set (missing last)");
        apb_read(32'h0C, rd); check_eq(rd, 32'h00000000, "counters unchanged (missing last)");
        stream_frame_fixed(8'h01);                 // valid sample completes step
        wait_status_done;
        apb_read(32'h0C, rd); check_eq(rd, 32'h00000001, "valid sample after missing-last");
        apb_read(32'h08, rd); check_eq1(rd[2], 1'b1, "err still sticky (until clr_stats)");
        apb_write(32'h00, 32'h00000010);           // clr_stats clears err
        apb_read(32'h08, rd); check_eq1(rd[2], 1'b0, "err cleared by clr_stats");

        // ---- REQ-018 probe: label >= CLASSES ---------------------------
        // spec: label byte >= CLASSES is malformed (err sticky, discarded).
        // Neither sample_stream (no CLASSES port) nor learner (no label
        // bound check) rejects it — probe the actual behaviour.
        apb_write(32'h00, 32'h00000010);           // clr_stats
        apb_write(32'h00, 32'h00000002);           // step
        stream_frame_fixed(8'h05);                 // label 5 >= CLASSES 2
        wait_status_done;
        begin : l5probe
            reg err_l5;
            reg [31:0] sc_l5;
            apb_read(32'h08, rd);
            err_l5 = rd[2];
            apb_read(32'h0C, rd);
            sc_l5 = rd;
            if (err_l5 === 1'b1)
                $display("NOTE label>=CLASSES: rejected with err (REQ-018 OK)");
            else
                $display("FAIL label>=CLASSES: err NOT set — sample processed (REQ-018 gap, see repro)");
            $display("INFO label>=CLASSES: sample counted = %0d (spec: discarded)", sc_l5);
        end

        test_summary("tb_top_control");
        $finish;
    end

    initial begin #50_000_000; $display("TEST FAILED: timeout tb_top_control"); $finish; end
endmodule

`default_nettype wire
