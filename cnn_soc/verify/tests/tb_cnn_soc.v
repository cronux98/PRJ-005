//---------------------------------------------------------------------
// tests/tb_cnn_soc.v — cnn_soc full-SoC acceptance test (100-image demo)
// Traces  : G1..G5 (PLAN.md §9, verification_plan.md VP-TOP-002..006)
// Purpose : Boot the committed 100-image demo firmware (bootrom-bake,
//           sw/firmware.hex) and self-check EVERY image against the frozen
//           golden package: UART byte stream (G1, independent decoder),
//           CNN_RESULT/CNN_EXP regs vs expected.hex (G2), LED encoding at
//           each presented instant (G3), reset hygiene + X/Z after release
//           (G4), boot liveness + bounded runtime + trap (G5).
//
// Run from : cnn_soc project root (so bootrom/vec_rom $readmemh paths and
//            this TB's ../cnn/... golden paths resolve).
// Sim pacing: UART_CLK_DIV=4 (arch.md §6.5 sim override; byte stream
//            unchanged — the decoder self-verifies each bit's width).
// Watchdog : fail out at 160M cycles (G5 bound is 150M).
//
// G2 expectation per image i (expected.hex, 4 words/image):
//   pred    == exp_mem[4i+0][3:0]   (CNN_RESULT[3:0])
//   conf    == exp_mem[4i+1][6:0]   (CNN_RESULT[14:8])
//   exp     == exp_mem[4i+2][3:0]   (CNN_EXP[3:0])
//   verdict == exp_mem[4i+3][1:0]   (CNN_RESULT[17:16])
// G3 expectation at the presented instant (firmware writes LED right after
//   reading RESULT, before the UART line):
//   led[9:0]  == one-hot(pred) (0 when verdict==2)
//   led[10]   == (verdict != 0)
//   led[11]   == 0
//---------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_cnn_soc;
    localparam SIM_CLKDIV = 4;          // arch.md §6.5 sim override
    localparam WATCHDOG   = 160_000_000; // cycles; G5 bound is 150M

    reg clk = 1'b0;
    reg rst_n;
    wire [11:0] led;
    wire        uart_tx;

    integer errors = 0;

    `include "verify/tb_common/clk_rst.vh"
    `include "verify/tb_common/checker.vh"
    `include "verify/tb_common/uart_monitor.vh"

    cnn_soc #(
        .UART_CLK_DIV (SIM_CLKDIV)
    ) dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .uart_tx (uart_tx),
        .led     (led)
    );

    // ---- G2 golden vectors: expected.hex (400 words: 100 x [pred,conf,exp,verdict]) ----
    reg [15:0] exp_mem [0:399];
    initial $readmemh("../cnn/arch/golden_model/expected.hex", exp_mem);

    // ---- watchdog: fail out rather than hang forever ----
    initial begin
        #(WATCHDOG * 10);   // 160M cycles * 10ns
        $display("FAIL tb_cnn_soc: WATCHDOG TIMEOUT @%0t (%.0fM cycles)", $time, $time/10000.0);
        errors = errors + 1;
        $display("FAIL tb_cnn_soc: %0d errors (watchdog abort)", errors);
        $finish;
    end

    // ---- G4: reset-window hygiene — led==0 and uart_tx==1 (idle mark)
    //      throughout every reset window (REQ-029). Skipped on the first
    //      edge (outputs still X before the reset NBA applies).
    integer rst_edges;
    initial rst_edges = 0;
    always @(posedge clk) begin
        rst_edges = rst_edges + 1;
        if (!rst_n && rst_edges > 1) begin
            if (led !== 12'h000) begin
                $display("FAIL G4_reset_led: led=%b during reset @%0t", led, $time);
                errors = errors + 1;
            end
            if (uart_tx !== 1'b1) begin
                $display("FAIL G4_reset_uart: uart_tx=%b during reset @%0t", uart_tx, $time);
                errors = errors + 1;
            end
        end
    end

    // ---- G4: no X/Z on outputs once reset is released (continuous scan) ----
    always @(posedge clk) begin
        if (rst_n) begin
            if (^led === 1'bx) begin
                $display("FAIL G4_no_x: led has X/Z bits = %b @%0t", led, $time);
                errors = errors + 1;
            end
            if (uart_tx === 1'bx) begin
                $display("FAIL G4_no_x: uart_tx is X @%0t", $time);
                errors = errors + 1;
            end
        end
    end

    // ---- G5: trap must never assert ----
    always @(posedge clk) begin
        if (rst_n && dut.u_picorv32.trap) begin
            $display("FAIL G5_trap: picorv32 trap asserted @%0t", $time);
            errors = errors + 1;
        end
    end

    // ---- G3: led[11] busy indicator while an inference is in flight ----
    always @(posedge clk) begin
        if (rst_n && dut.u_cnn_axi_slave.busy_r) begin
            if (led[11] !== 1'b1) begin
                $display("FAIL G3_busy: led[11]=%b while busy_r=1 @%0t", led[11], $time);
                errors = errors + 1;
            end
        end
    end

    // ---- G1: concurrent UART byte-stream capture (independent decoder) ----
    reg [1023:0] outdir;
    reg [2047:0] outfile;
    integer      uart_fd;
    integer      lc_nbytes;
    integer      first_line_cycles;   // cycles from reset release to 1st line end
    integer      t_reset_release;
    integer      uart_lines;          // count of complete UART lines captured
    initial begin
        first_line_cycles = -1;
        t_reset_release   = -1;
        uart_lines        = 0;
        if (!$value$plusargs("OUTDIR=%s", outdir)) outdir = "verify/run_tmp";
        $sformat(outfile, "%0s/uart_captured.txt", outdir);
        uart_fd = $fopen(outfile, "w");
        if (uart_fd == 0) begin
            $display("FAIL tb_cnn_soc: could not open %0s for write", outfile);
            errors = errors + 1;
        end
        forever begin
            uart_rx_line(uart_fd, SIM_CLKDIV, lc_nbytes);
            $fflush(uart_fd);   // unbuffer so we can monitor progress live
            uart_lines = uart_lines + 1;
            if (first_line_cycles < 0 && t_reset_release >= 0)
                first_line_cycles = ($time - t_reset_release) / 10000;   // ps -> cycles
        end
    end

    // ---- progress heartbeat: print sim time every 200k cycles (flushed;
    //      NOTE $time is in ps in this build — 10,000 units per cycle) ----
    always @(posedge clk) begin
        if (rst_n && ($time % 2_000_000_000 == 0)) begin
            $display("PROGRESS t=%0t (%.1fM cycles) done=%b busy=%b led=%b pc=0x%08x",
                     $time, $time/10000000.0, dut.u_cnn_axi_slave.done_r,
                     dut.u_cnn_axi_slave.busy_r, led, dut.u_picorv32.picorv32_core.reg_pc);
            $fflush();
        end
    end

    // ---- main checking process: 100 images ----
    integer iter;
    reg        prev_done;
    reg [31:0] res_r;
    reg [3:0]  exp_r;
    reg [3:0]  pred_c, exp_pred;
    reg [6:0]  conf_c, exp_conf;
    reg [3:0]  exp_label;
    reg [1:0]  verdict_c, exp_verdict;
    reg [9:0]  exp_led_digit;
    integer   eidx, si;
    integer   t_start_wall, t_done_first;

    initial begin
        t_start_wall = $time;
        // reset assert >= 10 cycles per PLAN.md §9 / VP-TOP-001 (house
        // tb_reset only does 5 — explicit 20-cycle reset here)
        rst_n = 1'b0;
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        t_reset_release = $time;
        t_done_first = -1;

        prev_done = 1'b0;

        for (iter = 0; iter < 100; iter = iter + 1) begin
            // ---- wait for the DONE rising edge (result latched) ----
            while (!dut.u_cnn_axi_slave.done_r) @(posedge clk);
            #1;
            if (t_done_first < 0) t_done_first = ($time - t_reset_release) / 10000;

            res_r = dut.u_cnn_axi_slave.result_r;
            exp_r = dut.u_cnn_axi_slave.exp_r;

            eidx        = iter * 4;
            exp_pred    = exp_mem[eidx + 0][3:0];
            exp_conf    = exp_mem[eidx + 1][6:0];
            exp_label   = exp_mem[eidx + 2][3:0];
            exp_verdict = exp_mem[eidx + 3][1:0];

            // ---- G2: result registers vs expected.hex ----
            pred_c    = res_r[3:0];
            conf_c    = res_r[14:8];
            verdict_c = res_r[17:16];
            check_eq(pred_c,    exp_pred,    "G2_pred: CNN_RESULT[3:0] vs expected.hex");
            check_eq(conf_c,    exp_conf,    "G2_conf: CNN_RESULT[14:8] vs expected.hex");
            check_eq(verdict_c, exp_verdict, "G2_verdict: CNN_RESULT[17:16] vs expected.hex");
            check_eq(exp_r,     exp_label,   "G2_exp: CNN_EXP[3:0] vs expected.hex");

            // ---- G3: LED at the presented instant (firmware wrote it right
            //      after RESULT read; wait for busy bit to drop) ----
            while (led[11] !== 1'b0) @(posedge clk);
            #1;
            exp_led_digit = (exp_verdict == 2'd2) ? 10'd0 : (10'd1 << exp_pred);
            check_eq({22'd0, led[9:0]}, {22'd0, exp_led_digit},
                     "G3_led_digit: led[9:0] one-hot / trash-off");
            check_eq1(led[10], (exp_verdict != 2'd0),
                      "G3_led_fail: led[10] == (verdict != CORRECT)");
            check_eq1(led[11], 1'b0, "G3_led_busy: led[11] == 0 at presented instant");

            // ---- wait for the next START (done_r falls) to arm the next edge.
            //      NOT after the last image — the firmware spins forever,
            //      so skip the wait on iter 99 (the UART-line drain below
            //      lets the final line finish before $finish).
            if (iter < 99) begin
                while (dut.u_cnn_axi_slave.done_r) @(posedge clk);
            end else begin
                #1000;
            end
        end

        // wait until the independent UART monitor has captured all 100
        // complete lines, then a small settle margin (< one line time),
        // instead of guessing a fixed drain window (drain race, was
        // finishing before the 100th line landed).
        while (uart_lines < 100) @(posedge clk);
        repeat (200) @(posedge clk);

        // ---- G5: bounded runtime + boot liveness ----
        check_cond(first_line_cycles >= 0, "G5_first_line: first UART line captured");
        if (first_line_cycles >= 0)
            check_cond(first_line_cycles < 1_500_000,
                       "G5_first_line: first line within 1.5M cycles of reset release");
        check_cond(t_done_first >= 0 && t_done_first < 1_000_000,
                   "G5_done_first: first DONE within 1M cycles (boot liveness)");
        check_cond(($time - t_start_wall) / 10000 < 150_000_000,
                   "G5_runtime: full 100-image demo within 150M cycles");

        $display("INFO: 100-image demo completed @%0t (%.1fM cycles total)", $time, ($time - t_start_wall)/10000000.0);
        $display("INFO: first DONE at %.1fM cycles, first UART line done at %.1fM cycles",
                 t_done_first/1000000.0, first_line_cycles/1000000.0);
        test_summary("tb_cnn_soc");
        $finish;
    end
endmodule
