//---------------------------------------------------------------------
// tb_top_mnist.v — L4 dataset-derived soak: 100 real MNIST training
// samples at the DEFAULT 784x32x10 config, back-to-back train mode.
// Project  : rinriAI (PRJ-005) — L4, VP-TOP-013 class, REQ-011
// Language : pure Verilog-2001, iverilog -g2001 -Wall
// Golden   : verify/golden/cfg_784_mnist100_lr0 (gen_vectors.py --idx)
// Checks   : zero dropped/duplicated bytes; final counters + ALL final
//            weights bit-exact vs the golden model run on the same data.
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_top_mnist;
    localparam FEATURES = 784, HIDDEN = 32, CLASSES = 10;
    localparam N_SAMPLES = 100;
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

    // ---------------------------------------------------------------
    initial begin
        $display("MNIST soak: %0d real samples, 784x32x10", N_SAMPLES);
        $readmemh("verify/golden/cfg_784_mnist100_lr0/stimulus.hex", stim);
        $readmemh("verify/golden/cfg_784_mnist100_lr0/expected.hex",  exp);

        tb_reset;

        apb_write(32'h04, 32'h00000000);           // lr_shift=0
        apb_write(32'h00, 32'h00000010);           // clr_stats
        apb_write(32'h1C, 32'h00000000);
        for (i = 0; i < W_TOT; i = i + 1)
            apb_write(32'h20, {16'h0000, stim[i][15:0]});

        apb_write(32'h00, 32'h00000001);           // start
        for (i = 0; i < N_SAMPLES; i = i + 1) begin
            for (p = 0; p < FEATURES; p = p + 1)
                stream_byte(stim[W_TOT + i*(FEATURES+1) + p][7:0], 1'b0);
            stream_byte(stim[W_TOT + i*(FEATURES+1) + FEATURES][7:0], 1'b1);
        end

        begin : wait_end
            integer tmo;
            tmo = 0;
            while (tmo < 3000000) begin
                apb_read(32'h0C, rd);
                if (rd == N_SAMPLES) tmo = 3000000;
                else begin tmo = tmo + 1; @(posedge clk_core); end
            end
            if (tmo >= 3000000) begin
                apb_read(32'h0C, rd);
                if (rd !== N_SAMPLES) begin
                    $display("FAIL mnist soak: sample_count=0x%08X (want %0d)", rd, N_SAMPLES);
                    errors = errors + 1;
                end
            end
        end

        apb_read(32'h0C, rd); check_eq(rd, exp[N_SAMPLES*5 - 3], "mnist final sample_count");
        apb_read(32'h10, rd); check_eq(rd, exp[N_SAMPLES*5 - 2], "mnist final correct_count");
        apb_read(32'h14, rd); check_eq(rd, exp[N_SAMPLES*5 - 1], "mnist final error_count");
        $display("INFO mnist accuracy on %0d train samples: %0d/%0d (%0.1f%%)",
                 N_SAMPLES, exp[N_SAMPLES*5 - 2], N_SAMPLES,
                 (exp[N_SAMPLES*5 - 2] * 100.0) / N_SAMPLES);

        apb_write(32'h1C, 32'h00000000);
        for (i = 0; i < W_TOT; i = i + 1) begin
            apb_read(32'h20, rd);
            if (rd[15:0] !== exp[N_SAMPLES*5 + i][15:0]) begin
                $display("FAIL mnist weight %0d: got=0x%04X want=0x%04X", i, rd[15:0], exp[N_SAMPLES*5 + i][15:0]);
                errors = errors + 1;
            end
        end

        test_summary("tb_top_mnist");
        $finish;
    end

    initial begin #600_000_000; $display("TEST FAILED: timeout tb_top_mnist"); $finish; end
endmodule

`default_nettype wire
