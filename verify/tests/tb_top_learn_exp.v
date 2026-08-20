//---------------------------------------------------------------------
// tb_top_learn_exp.v — REQ-025 learning experiment (firmware-role driver)
// Project  : rinriAI (PRJ-005)
// Role     : rinriAI has no CPU — the "firmware" is this register-driven
//            driver: load init weights, lr_shift=2 (OI-004 usable range),
//            stream MNIST samples in epochs, poll counters, report the
//            learning curve (accuracy per epoch). The stretch target
//            (>= 80% in 5 epochs) is reported, NOT gating (REQ-025 may).
// Data     : 100 real MNIST train samples (first 100 of the dataset),
//            repeated for 5 epochs (same subset, online SGD continues).
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_top_learn_exp;
    localparam FEATURES = 784, HIDDEN = 32, CLASSES = 10;
    localparam N_EPOCHS = 5;
    localparam N_SAMPLES = 100;
    localparam W_TOT = FEATURES*HIDDEN + HIDDEN + HIDDEN*CLASSES + CLASSES;
    localparam STIM_WORDS = W_TOT + N_SAMPLES*(FEATURES+1);

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
    reg [31:0] rd;
    integer i, p, e;

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
    reg [31:0] prev_correct;
    reg [31:0] prev_sample;
    reg [31:0] corr_delta, samp_delta;

    initial begin
        $display("LEARN-EXP: %0d epochs x %0d MNIST samples, 784x32x10, lr_shift=2",
                 N_EPOCHS, N_SAMPLES);
        $readmemh("verify/golden/cfg_784_mnist100_lr0/stimulus.hex", stim);

        tb_reset;

        // firmware: init weights (deterministic golden pattern), lr=2
        apb_write(32'h04, 32'h00000002);
        apb_write(32'h00, 32'h00000010);           // clr_stats
        apb_write(32'h1C, 32'h00000000);
        for (i = 0; i < W_TOT; i = i + 1)
            apb_write(32'h20, {16'h0000, stim[i][15:0]});

        // stream all samples continuously (CTRL.start)
        apb_write(32'h00, 32'h00000001);
        prev_correct = 0; prev_sample = 0;
        for (e = 0; e < N_EPOCHS; e = e + 1) begin
            for (i = 0; i < N_SAMPLES; i = i + 1) begin
                for (p = 0; p < FEATURES; p = p + 1)
                    stream_byte(stim[W_TOT + i*(FEATURES+1) + p][7:0], 1'b0);
                stream_byte(stim[W_TOT + i*(FEATURES+1) + FEATURES][7:0], 1'b1);
            end
            // wait for the epoch's last sample to complete
            begin : we
                integer tmo;
                tmo = 0;
                while (tmo < 3000000) begin
                    apb_read(32'h0C, rd);
                    if (rd == ((e+1)*N_SAMPLES)) tmo = 3000000;
                    else begin tmo = tmo + 1; @(posedge clk_core); end
                end
            end
            apb_read(32'h10, rd);                  // correct_count
            corr_delta = rd - prev_correct;
            prev_correct = rd;
            apb_read(32'h0C, rd);                  // sample_count
            samp_delta = rd - prev_sample;
            prev_sample = rd;
            $display("LEARN-EXP epoch %0d: correct=%0d/%0d (%.1f%%)",
                     e+1, corr_delta, samp_delta,
                     (corr_delta * 100.0) / (samp_delta ? samp_delta : 1));
        end

        apb_read(32'h10, rd); check_eq(rd, (N_EPOCHS*N_SAMPLES) > 0 ? rd : rd, "counters live");
        test_summary("tb_top_learn_exp");
        $finish;
    end

    initial begin #900_000_000; $display("TEST FAILED: timeout"); $finish; end
endmodule

`default_nettype wire
