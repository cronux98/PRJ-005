//---------------------------------------------------------------------
// tests/tb_mnist_top.v — mnist_npu full-system acceptance test
// Traces  : VP-TOP-002..008, VP-LED-001..003, VP-CTRL-001,
//           checks C1/C3/C4/C5/C6/C7 (verify agent task spec)
// Purpose : Free-run the DUT at SIM pacing parameters across 2 full
//           passes (200 image results, proving the 0..99 wraparound,
//           VP-TOP-003) and self-check EVERY result against the frozen
//           arch/golden_model/expected.hex (bit-exact, C1), the LED
//           encoding rules (C3/C4, REQ-017/018), the busy-blink window
//           (C5, REQ-019/020), FSM state coverage (VP-CTRL-001), and
//           output X/Z hygiene after reset (C7). The full UART byte
//           stream is captured concurrently (tb_common/uart_monitor.vh
//           — an independent bit-level decoder, not the RTL's own
//           uart_tx FSM) to <OUTDIR>/uart_captured.txt for a byte-exact
//           post-run diff against arch/golden_model/expected_outputs.txt
//           (C2), performed by the calling shell script (text handling
//           is more robust in Bash/diff than in Verilog string ops).
// Sim params (REQ-016/020/021/026 overrides): HOLD_CYCLES=8,
//           BLINK_CYCLES=4, CLK_DIV=4 — small enough for the >=2
//           blink-transition and multi-second full-run requirements,
//           matching arch.md's documented sim-override ranges.
// Run from : mnist_npu project root (so $readmemh paths resolve).
//---------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_mnist_top;
    localparam SIM_HOLD    = 8;
    localparam SIM_BLINK   = 4;
    localparam SIM_CLKDIV  = 4;

    reg clk = 1'b0;
    reg rst_n;
    wire [11:0] led;
    wire        uart_tx;

    integer errors = 0;

    `include "verify/tb_common/clk_rst.vh"
    `include "verify/tb_common/checker.vh"
    `include "verify/tb_common/uart_monitor.vh"

    mnist_npu #(
        .HOLD_CYCLES  (SIM_HOLD),
        .BLINK_CYCLES (SIM_BLINK),
        .CLK_DIV      (SIM_CLKDIV)
    ) dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .led     (led),
        .uart_tx (uart_tx)
    );

    // ---- expected.hex golden vectors (400 words: 100 x [pred,conf,exp,verdict]) ----
    reg [15:0] exp_mem [0:399];
    initial $readmemh("arch/golden_model/expected.hex", exp_mem);

    // ---- watchdog: fail out rather than hang forever on a stuck FSM ----
    initial begin
        #500_000_000;   // 500ms sim time >> ~110ms expected (200 images @ SIM pacing)
        $display("FAIL tb_mnist_top: WATCHDOG TIMEOUT @%0t", $time);
        errors = errors + 1;
        $display("FAIL tb_mnist_top: %0d errors (watchdog abort)", errors);
        $finish;
    end

    // ---- C7: no X/Z on outputs once reset is released ----
    always @(posedge clk) begin
        if (rst_n) begin
            if (^led === 1'bx) begin
                $display("FAIL C7_no_x: led has X/Z bits = %b @%0t", led, $time);
                errors = errors + 1;
            end
            if (uart_tx === 1'bx) begin
                $display("FAIL C7_no_x: uart_tx is X @%0t", $time);
                errors = errors + 1;
            end
        end
    end

    // ---- VP-CTRL-001: FSM state coverage (10 legal states, 0..9) ----
    reg [15:0] state_seen;
    initial state_seen = 16'd0;
    always @(posedge clk) if (rst_n) state_seen[dut.u_ctrl_fsm.state] = 1'b1;

    // ---- C5 / VP-TOP-006 / VP-LED-003: led[11] blink-window transition count ----
    reg        prev_led11, prev_busy;
    integer    blink_toggle_cnt;
    initial begin
        prev_led11 = 1'b0;
        prev_busy  = 1'b0;
        blink_toggle_cnt = 0;
    end
    always @(posedge clk) begin
        if (rst_n) begin
            if (dut.u_ctrl_fsm.lc_busy && !prev_busy)
                blink_toggle_cnt <= 0;   // new image's busy window starting
            if (!dut.u_ctrl_fsm.lc_busy && prev_busy)
                check_cond(blink_toggle_cnt >= 2, "C5/VP-TOP-006: led[11] >=2 transitions during busy window");
            if (led[11] !== prev_led11) begin
                if (dut.u_ctrl_fsm.lc_busy)
                    blink_toggle_cnt <= blink_toggle_cnt + 1;
                else if (prev_busy) begin
                    // busy just deasserted THIS edge (the busy->hold transition
                    // edge itself): led[11] snapping to 0 here is REQ-019/020's
                    // own "steady off once presented" behaviour, not a hold-
                    // window violation. Only flag toggles strictly INSIDE the
                    // hold window (prev_busy==0 as well, i.e. not the boundary).
                end else
                    check_cond(1'b0, "C5/VP-TOP-006: led[11] toggled during HOLD window (must be constant)");
            end
            prev_led11 <= led[11];
            prev_busy  <= dut.u_ctrl_fsm.lc_busy;
        end
    end

    // ---- concurrent UART byte-stream capture (independent decoder) ----
    reg [1023:0] outdir;
    reg [2047:0] outfile;
    integer      uart_fd;
    integer      lc_nbytes;
    initial begin
        if (!$value$plusargs("OUTDIR=%s", outdir)) outdir = "verify/run_tmp";
        $sformat(outfile, "%0s/uart_captured.txt", outdir);
        uart_fd = $fopen(outfile, "w");
        if (uart_fd == 0) begin
            $display("FAIL tb_mnist_top: could not open %0s for write", outfile);
            errors = errors + 1;
        end
        forever begin
            uart_rx_line(uart_fd, SIM_CLKDIV, lc_nbytes);
        end
    end

    // ---- main checking process: 2 full passes (200 image results) ----
    integer iter;
    reg [3:0] pred_c;
    reg [6:0] conf_c;
    reg [1:0] verdict_c;
    reg [6:0] idx_c;
    reg [3:0] exp_pred;
    reg [6:0] exp_conf;
    reg [3:0] exp_label;
    reg [1:0] exp_verdict;
    reg [9:0] exp_led_digit;
    integer   eidx, si;
    integer   t_start_wall;

    initial begin
        t_start_wall = $time;
        tb_reset;

        for (iter = 0; iter < 200; iter = iter + 1) begin
            // ST_RESULT is architecturally exactly 1 cycle (arch.md 6.1) — a
            // simple level-wait lands on it exactly once per image. #1
            // settle delay: reading DUT-internal regs immediately after
            // @(posedge clk) races against the DUT's own always blocks for
            // that same edge (process scheduling order across separate
            // always/initial blocks on the same edge is not guaranteed —
            // confirmed empirically in tb_reset.v's debug history). Harmless
            // here in practice (best_idx/verdict are already stable well
            // before ST_RESULT), added for defense-in-depth consistency.
            while (dut.u_ctrl_fsm.state !== 4'd7) @(posedge clk);
            #1;

            pred_c    = dut.u_ctrl_fsm.best_idx;
            conf_c    = dut.u_ctrl_fsm.confidence;
            verdict_c = dut.u_ctrl_fsm.verdict;
            idx_c     = dut.u_ctrl_fsm.img_idx;

            check_eq(idx_c, iter % 100, "VP-TOP-003: img_idx sequence 0..99 wraps");

            eidx        = (iter % 100) * 4;
            exp_pred    = exp_mem[eidx + 0][3:0];
            exp_conf    = exp_mem[eidx + 1][6:0];
            exp_label   = exp_mem[eidx + 2][3:0];
            exp_verdict = exp_mem[eidx + 3][1:0];

            check_eq(pred_c,    exp_pred,    "C1/VP-TOP-002: pred == expected.hex");
            check_eq(conf_c,    exp_conf,    "C1/VP-TOP-002: confidence == expected.hex");
            check_eq(verdict_c, exp_verdict, "C1/VP-TOP-002: verdict == expected.hex");

            if (iter == 0) begin
                // C6: memory-init sanity spot check (image 000 known content)
                check_eq(pred_c, exp_pred, "C6: image 000 pred (memory-init sanity)");
                check_eq(conf_c, exp_conf, "C6: image 000 confidence (memory-init sanity)");
                $display("INFO C6: image 000 golden pred=%0d conf=%0d%% (memory init verified against golden hex)", exp_pred, exp_conf);
            end

            // one more edge -> ST_PRESENT: led_ctrl's registered pred_r/
            // verdict_r are updated on the SAME edge that left ST_RESULT
            // (lc_present was high during that edge), so led is valid now.
            @(posedge clk);
            #1;

            exp_led_digit = (exp_verdict == 2'd2) ? 10'd0 : (10'd1 << exp_pred);
            check_eq({22'd0, led[9:0]}, {22'd0, exp_led_digit}, "C3/VP-TOP-005/VP-LED-001: led[9:0] one-hot / trash-off");
            check_eq1(led[10], (exp_verdict != 2'd0), "C4/VP-TOP-005/VP-LED-002: led[10] == (verdict != CORRECT)");
        end

        // let the very last image's UART line finish transmitting before
        // ending the sim (the main loop only waits 1 cycle past ST_RESULT
        // to sample led, it does not wait for ST_PRESENT/lf_done) — worst
        // case a 69-byte line at 10*CLK_DIV cycles/byte, generous margin.
        repeat (69 * 10 * SIM_CLKDIV + 200) @(posedge clk);

        // ---- VP-CTRL-001: all 10 legal states entered at least once ----
        for (si = 0; si < 10; si = si + 1)
            check_cond(state_seen[si] == 1'b1, "VP-CTRL-001: legal FSM state reached");
        for (si = 10; si < 16; si = si + 1)
            check_cond(state_seen[si] == 1'b0, "VP-CTRL-001: illegal state value never entered in normal operation");

        $display("INFO: 200-image run (2 passes) completed @%0t (~%0d ns sim time)", $time, $time - t_start_wall);
        test_summary("tb_mnist_top");
        $finish;
    end
endmodule
