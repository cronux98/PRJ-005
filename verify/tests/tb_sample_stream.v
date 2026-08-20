//---------------------------------------------------------------------
// tb_sample_stream.v — module gate for BLK-003 sample_stream
// Project  : rinriAI (PRJ-005) — VP-SIN-001, VP-SIN-002 (REQ-008,016,018)
// Language : pure Verilog-2001, iverilog -g2001 -Wall
// DUT      : rtl/sample_stream.v (FEATURES=4, W_F=4)
// Coverage : framing (pixels + label), label capture + ack clear,
//            x_rdata pixel readback, malformed cases (s_last early at
//            every pixel index 0..3, missing s_last at label, empty
//            frame), err_p 1-cycle pulse + resync, backpressure
//            mid-frame (zero byte loss), back-to-back frames, and the
//            documented stream-overwrite window (OI-008 — closed at top
//            level by accept_en gating; verified as open here).
// NOTE     : label>=CLASSES detection is NOT in this block (no CLASSES
//            parameter) — expected in BLK-004/top (watch-item for Phase B).
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_sample_stream;
    localparam FEATURES = 4;
    localparam W_F      = 4;

    reg clk_core = 1'b0;
    reg rst_n    = 1'b0;

    reg        s_valid = 0, s_last = 0;
    reg  [7:0] s_data = 0;
    wire       s_ready;
    wire       sample_valid, err_p;
    wire [7:0] label;
    reg        ack_p = 0;
    reg  [W_F-1:0] x_addr = 0;
    wire [7:0] x_rdata;

    // accept_en with backpressure-injection mux (str_hold_ready contract)
    reg accept_en_base = 1'b1;           // TB drives: 1 = learner accepting
    reg accept_en_override = 1'b1;       // str_hold_ready drives this low
    wire accept_en = accept_en_base & accept_en_override;

    reg [15:0] err_cnt = 0;              // counts err_p pulses (1 per malformed)
    always @(posedge clk_core) if (err_p) err_cnt <= err_cnt + 1'b1;
    // err_p width monitor: flags any pulse wider than 1 cycle
    reg err_p_d1 = 0, err_p_wide = 0;
    always @(posedge clk_core) begin
        err_p_d1 <= err_p;
        if (err_p && err_p_d1) err_p_wide <= 1'b1;
    end

    integer errors = 0;

    sample_stream #(.FEATURES(FEATURES), .W_F(W_F)) dut (
        .clk_core (clk_core), .rst_n (rst_n),
        .s_valid (s_valid), .s_ready (s_ready), .s_data (s_data), .s_last (s_last),
        .sample_valid (sample_valid), .label (label),
        .ack_p (ack_p), .x_addr (x_addr), .x_rdata (x_rdata),
        .err_p (err_p), .accept_en (accept_en)
    );

    `include "tb_common/clk_rst.vh"
    `include "tb_common/checker.vh"
    `include "tb_common/stream_gen.vh"

    reg [7:0] pixels [0:255];
    integer i;                          // loop var (module scope, Verilog-2001)

    // ---------------------------------------------------------------
    initial begin
        $dumpfile("tb_sample_stream.vcd");
        $dumpvars(0, tb_sample_stream);

        // pixel pattern for frames
        for (i = 0; i < 256; i = i + 1) pixels[i] = i[7:0];

        tb_reset;
        check_eq1(sample_valid, 1'b0, "sample_valid low after reset");
        check_eq1(s_ready, 1'b1, "s_ready = accept_en = 1 after reset (idle)");

        // ---- 1. Good frame: label capture + pixel readback -----------
        stream_frame(8'h01, 1'b0, 32'hDEADBEEF);
        check_eq1(sample_valid, 1'b1, "sample_valid set after good frame");
        check_eq(label, 8'h01, "label captured");
        x_addr = 0;  #1; check_eq(x_rdata, 8'h00, "x[0] readback");
        x_addr = 1;  #1; check_eq(x_rdata, 8'h01, "x[1] readback");
        x_addr = 2;  #1; check_eq(x_rdata, 8'h02, "x[2] readback");
        x_addr = 3;  #1; check_eq(x_rdata, 8'h03, "x[3] readback");
        check_eq1(err_p, 1'b0, "no err on good frame");
        // ack clears the level
        stream_ack;
        @(posedge clk_core);
        check_eq1(sample_valid, 1'b0, "sample_valid cleared by ack_p");

        // ---- 2. Back-to-back frames ----------------------------------
        stream_frame(8'h00, 1'b0, 32'h00000001);
        check_eq1(sample_valid, 1'b1, "frame2 captured");
        check_eq(label, 8'h00, "frame2 label");
        stream_ack;
        stream_frame(8'h01, 1'b0, 32'h00000002);
        check_eq1(sample_valid, 1'b1, "frame3 captured (back-to-back)");
        check_eq(label, 8'h01, "frame3 label");
        stream_ack;

        // ---- 3. Malformed: s_last early at every pixel index ---------
        begin : malformed_early
            integer k;
            for (k = 0; k < FEATURES; k = k + 1) begin
                stream_malformed_early_last(k[15:0]);
                @(posedge clk_core);
                check_eq1(sample_valid, 1'b0, "sample_valid low during malformed");
                // err_p pulsed exactly once for this malformed frame
                check_eq(err_cnt, k[15:0] + 1, "err_p once per malformed frame");
                stream_resync_byte;                  // exit RESYNC (byte discarded)
                check_eq1(sample_valid, 1'b0, "still no sample_valid after resync");
                // following valid frame works
                stream_frame(8'h00, 1'b0, 32'h00000000);
                check_eq1(sample_valid, 1'b1, "valid frame after malformed");
                check_eq(label, 8'h00, "label after resync");
                stream_ack;
            end
        end
        // err_p 1-cycle property: never two consecutive high cycles
        check_eq1(err_p_wide, 1'b0, "err_p never wider than 1 cycle");

        // ---- 4. Malformed: missing s_last at label index -------------
        // send 4 pixels then a 5th byte with s_last=0 -> err + RESYNC
        stream_byte(8'hAA, 1'b0);
        stream_byte(8'hBB, 1'b0);
        stream_byte(8'hCC, 1'b0);
        stream_byte(8'hDD, 1'b0);
        stream_byte(8'hEE, 1'b0);                    // label position, no s_last
        @(posedge clk_core);
        check_eq1(sample_valid, 1'b0, "no sample_valid on missing-last frame");
        stream_resync_byte;
        stream_frame(8'h01, 1'b0, 32'h00000005);
        check_eq1(sample_valid, 1'b1, "valid frame after missing-last");
        check_eq(label, 8'h01, "label after missing-last resync");
        stream_ack;

        // ---- 5. Malformed: empty frame (s_last on first byte) ---------
        stream_byte(8'h00, 1'b1);                    // s_last at pixel index 0
        @(posedge clk_core);
        check_eq1(sample_valid, 1'b0, "no sample_valid on empty frame");
        stream_resync_byte;
        stream_frame(8'h00, 1'b0, 32'h00000006);
        check_eq1(sample_valid, 1'b1, "valid frame after empty-frame resync");
        stream_ack;

        // ---- 6. Backpressure mid-frame (VP-SIN-002) ------------------
        // Drop accept_en mid-frame; s_valid held; release; zero byte loss.
        begin : backpressure
            // frame of 4 distinct pixels + label; pause between beats 1-2
            accept_en_override <= 1'b1;
            s_valid <= 1'b1; s_data <= 8'h10; s_last <= 1'b0;
            @(posedge clk_core);                     // beat 1 (pixel 0)
            s_valid <= 1'b1; s_data <= 8'h11; s_last <= 1'b0;
            // pause BEFORE beat 2: accept_en drops, s_valid held
            accept_en_base <= 1'b0;
            @(posedge clk_core);                     // no beat (s_ready=0)
            check_eq1(s_ready, 1'b0, "s_ready low under backpressure");
            @(posedge clk_core);
            accept_en_base <= 1'b1;                  // release
            @(posedge clk_core);                     // beat 2 now (pixel 1)
            s_valid <= 1'b1; s_data <= 8'h12; s_last <= 1'b0;
            @(posedge clk_core);                     // beat 3 (pixel 2)
            s_valid <= 1'b1; s_data <= 8'h13; s_last <= 1'b0;
            @(posedge clk_core);                     // beat 4 (pixel 3)
            s_valid <= 1'b1; s_data <= 8'h14; s_last <= 1'b1;
            @(posedge clk_core);                     // beat 5 = label
            s_valid <= 1'b0; s_last <= 1'b0;
            @(posedge clk_core);                     // settle
            check_eq1(sample_valid, 1'b1, "frame complete after backpressure");
            check_eq(label, 8'h14, "label after backpressure");
            x_addr = 0; #1; check_eq(x_rdata, 8'h10, "bp x[0]");
            x_addr = 1; #1; check_eq(x_rdata, 8'h11, "bp x[1] (held through pause)");
            x_addr = 2; #1; check_eq(x_rdata, 8'h12, "bp x[2]");
            x_addr = 3; #1; check_eq(x_rdata, 8'h13, "bp x[3]");
            stream_ack;
        end
        // random backpressure via stream_gen
        stream_frame(8'h01, 1'b1, 32'hCAFEF00D);
        check_eq1(sample_valid, 1'b1, "frame complete with random backpressure");
        check_eq(label, 8'h01, "label with random backpressure");
        stream_ack;

        // ---- 7. ack_p + label-capture same cycle: capture wins ---------
        begin : ack_prio
            // send frame bytes up to the label
            stream_byte(8'h20, 1'b0);
            stream_byte(8'h21, 1'b0);
            stream_byte(8'h22, 1'b0);
            stream_byte(8'h23, 1'b0);
            // label byte with ack_p asserted AT the beat cycle only
            s_valid <= 1'b1; s_data <= 8'h09; s_last <= 1'b1;
            ack_p <= 1'b1;                       // pending ack at the beat edge
            if (!s_ready) while (!s_ready) @(posedge clk_core);
            else @(posedge clk_core);            // beat edge: ack_p=1 AND capture
            ack_p <= 1'b0;                       // drop ack right after the beat
            s_valid <= 1'b0; s_last <= 1'b0;
            @(posedge clk_core);                 // settle
            check_eq1(sample_valid, 1'b1, "capture wins over ack (level stays)");
            check_eq(label, 8'h09, "label captured despite ack");
            stream_ack;
        end

        // ---- 8. OI-008 overwrite window (documented, closed at top) ---
        // With accept_en=1 and sample_valid=1 (ack pending), new beats DO
        // overwrite MEM-002. The top gates accept_en with !sample_valid
        // (doc/README.md OI-008) — verified at integration (Phase B).
        begin : oi008
            stream_frame(8'h05, 1'b0, 32'h00000007);   // frame A, label 5
            check_eq1(sample_valid, 1'b1, "frame A captured");
            // WITHOUT ack, feed frame B's first byte (accept_en still 1)
            stream_byte(8'hF0, 1'b0);
            x_addr = 0; #1;
            if (x_rdata === 8'hF0)
                $display("NOTE OI-008: overwrite window confirmed open at module level (top must gate accept_en)");
            else begin
                $display("FAIL OI-008 expectation: x[0]=%02x (expected overwrite 0xF0)", x_rdata);
                errors = errors + 1;
            end
            // drain frame B properly to leave clean state
            stream_byte(8'hF1, 1'b0);
            stream_byte(8'hF2, 1'b0);
            stream_byte(8'hF3, 1'b0);
            stream_byte(8'h07, 1'b1);
            check_eq1(sample_valid, 1'b1, "frame B captured");
            stream_ack;
        end

        test_summary("tb_sample_stream");
        $finish;
    end

    // Watchdog
    initial begin
        #1_000_000;
        $display("TEST FAILED: timeout tb_sample_stream");
        $finish;
    end
endmodule

`default_nettype wire
