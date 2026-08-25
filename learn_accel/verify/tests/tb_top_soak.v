//---------------------------------------------------------------------
// tb_top_soak.v — long soak, back-to-back continuous training
// Project  : rinriAI (PRJ-005) — VP-TOP-013 (REQ-008, REQ-011), L4
// Language : pure Verilog-2001, iverilog -g2001 -Wall
// DUT      : learn_accel, any config (defaults: tiny 4x4x2, 10,000
//            LFSR samples). Override with -DCFG_F/-DCFG_H/-DCFG_C/
//            -DCFG_N/-DCFG_VTAG (vector tag under verify/golden/).
// Checks   : zero dropped/duplicated bytes (final SAMPLE_COUNT exact),
//            final counters and ALL final weights match the golden model
//            run bit-exactly.
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
`ifndef CFG_N
`define CFG_N 10000
`endif
`ifndef CFG_VTAG
`define CFG_VTAG "verify/golden/soak_10k/stimulus.hex"
`define CFG_VEXP "verify/golden/soak_10k/expected.hex"
`else
`define CFG_VEXP "verify/golden/`CFG_VTAG/expected.hex"
`define CFG_VTAG "verify/golden/`CFG_VTAG/stimulus.hex"
`endif

module tb_top_soak;
    localparam FEATURES = `CFG_F;
    localparam HIDDEN   = `CFG_H;
    localparam CLASSES  = `CFG_C;
    localparam N_SAMPLES = `CFG_N;
    localparam W_TOT = FEATURES*HIDDEN + HIDDEN + HIDDEN*CLASSES + CLASSES;
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
    integer i;
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

    // ---------------------------------------------------------------
    initial begin
        $display("SOAK: %0d samples, %0dx%0dx%0d", N_SAMPLES, FEATURES, HIDDEN, CLASSES);
`ifndef CFG_NO_DUMP
        $dumpfile("tb_top_soak.vcd");
        $dumpvars(0, tb_top_soak);
`endif
        $readmemh(`CFG_VTAG, stim);
        $readmemh(`CFG_VEXP, exp);

        tb_reset;

        // load init weights
        apb_write(32'h04, 32'h00000000);           // lr_shift=0
        apb_write(32'h00, 32'h00000010);           // clr_stats
        apb_write(32'h1C, 32'h00000000);
        for (i = 0; i < W_TOT; i = i + 1)
            apb_write(32'h20, {16'h0000, stim[i][15:0]});

        // continuous run: stream all samples back-to-back
        apb_write(32'h00, 32'h00000001);           // start
        for (i = 0; i < N_SAMPLES; i = i + 1) begin
            for (p = 0; p < FEATURES; p = p + 1)
                stream_byte(stim[W_TOT + i*(FEATURES+1) + p][7:0], 1'b0);
            stream_byte(stim[W_TOT + i*(FEATURES+1) + FEATURES][7:0], 1'b1);
        end

        // wait for the final sample to complete
        begin : wait_end
            integer tmo;
            tmo = 0;
            while (tmo < 5000000) begin
                apb_read(32'h0C, rd);
                if (rd == N_SAMPLES) tmo = 5000000;
                else begin tmo = tmo + 1; @(posedge clk_core); end
            end
            if (tmo >= 5000000) begin
                apb_read(32'h0C, rd);
                if (rd !== N_SAMPLES) begin
                    $display("FAIL soak: sample_count=0x%08X (want %0d) — dropped/duplicated bytes",
                             rd, N_SAMPLES);
                    errors = errors + 1;
                end
            end
        end

        // final counters vs golden
        apb_read(32'h0C, rd); check_eq(rd, exp[N_SAMPLES*5 - 3], "soak final sample_count");
        apb_read(32'h10, rd); check_eq(rd, exp[N_SAMPLES*5 - 2], "soak final correct_count");
        apb_read(32'h14, rd); check_eq(rd, exp[N_SAMPLES*5 - 1], "soak final error_count");

        // final weights vs golden (all words)
        apb_write(32'h1C, 32'h00000000);
        for (i = 0; i < W_TOT; i = i + 1) begin
            apb_read(32'h20, rd);
            if (rd[15:0] !== exp[N_SAMPLES*5 + i][15:0]) begin
                $display("FAIL soak weight %0d: got=0x%04X want=0x%04X", i, rd[15:0], exp[N_SAMPLES*5 + i][15:0]);
                errors = errors + 1;
            end
        end

        test_summary("tb_top_soak");
        $finish;
    end

    initial begin #900_000_000; $display("TEST FAILED: timeout tb_top_soak"); $finish; end
endmodule

`default_nettype wire
