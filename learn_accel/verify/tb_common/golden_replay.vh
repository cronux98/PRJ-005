//---------------------------------------------------------------------
// tb_common/golden_replay.vh — golden-model replay harness (top level)
// Project  : rinriAI (PRJ-005) verification infrastructure
// Language : pure Verilog-2001 (include file, ifndef-guarded)
// Purpose  : Drive the full learn_accel top through the golden-vector
//            flow: load init weights via WADDR/WDATA, stream samples,
//            check PRED + counters per sample, dump and compare final
//            weights. Parameterized by the including TB's localparams
//            (FEATURES/HIDDEN/CLASSES/W_TOT/N_SAMPLES) and arrays
//            stim[]/exp[] (loaded via $readmemh from gen_vectors.py
//            output — the C-model-correct hex).
// Usage    : TB must declare the APB4 signals, stream signals, the
//            apb_write/apb_read/stream_byte/check_eq/check_eq1 tasks,
//            arrays `reg [31:0] stim [0:STIM_WORDS-1]; reg [31:0]
//            exp [0:EXP_WORDS-1];` and localparams STIM_WORDS,
//            EXP_WORDS = N_SAMPLES*5 + W_TOT, then include this file.
//---------------------------------------------------------------------
`ifndef TB_COMMON_GOLDEN_REPLAY_VH
`define TB_COMMON_GOLDEN_REPLAY_VH

// Wait for STATUS.done (step/halt completion) with timeout.
task gr_wait_done;
    integer tmo;
    begin
        tmo = 0;
        while (tmo < 2000000) begin
            apb_read(32'h08, rd);
            if (rd[1]) tmo = 2000000;   // done set
            else begin
                tmo = tmo + 1;
                @(posedge clk_core);
            end
        end
        if (tmo >= 2000000) begin
            apb_read(32'h08, rd);
            if (!rd[1]) begin
                $display("FAIL gr_wait_done: timeout waiting for STATUS.done @%0t", $time);
                errors = errors + 1;
            end
        end
    end
endtask

// Load W_TOT init weights from stim[0..W_TOT-1] via WADDR+WDATA auto-inc.
task gr_load_weights;
    integer i;
    begin
        apb_write(32'h1C, 32'h00000000);
        for (i = 0; i < W_TOT; i = i + 1)
            apb_write(32'h20, {16'h0000, stim[i][15:0]});
    end
endtask

// Dump W_TOT weights via WADDR+WDATA auto-inc reads; compare vs exp.
task gr_dump_weights;
    integer i;
    begin
        apb_write(32'h1C, 32'h00000000);
        for (i = 0; i < W_TOT; i = i + 1) begin
            apb_read(32'h20, rd);
            if (rd[15:0] !== exp[N_SAMPLES*5 + i][15:0]) begin
                $display("FAIL weight[%0d]: got=0x%04X want=0x%04X @%0t",
                         i, rd[15:0], exp[N_SAMPLES*5 + i][15:0], $time);
                errors = errors + 1;
            end
        end
    end
endtask

// Per-sample golden checks (pred + 3 counters) against exp words
// N_SAMPLES*5 layout: {pred, correct, sample, correct_cnt, error_cnt}.
task gr_check_sample;
    input integer sidx;
    begin
        apb_read(32'h18, rd);                       // PRED
        if (rd[7:0] !== exp[sidx*5 + 0][7:0]) begin
            $display("FAIL sample %0d pred: got=0x%02X want=0x%02X @%0t",
                     sidx, rd[7:0], exp[sidx*5 + 0][7:0], $time);
            errors = errors + 1;
        end
        apb_read(32'h0C, rd);                       // SAMPLE_COUNT
        if (rd !== exp[sidx*5 + 2]) begin
            $display("FAIL sample %0d sample_cnt: got=0x%08X want=0x%08X",
                     sidx, rd, exp[sidx*5 + 2]);
            errors = errors + 1;
        end
        apb_read(32'h10, rd);                       // CORRECT_COUNT
        if (rd !== exp[sidx*5 + 3]) begin
            $display("FAIL sample %0d correct_cnt: got=0x%08X want=0x%08X",
                     sidx, rd, exp[sidx*5 + 3]);
            errors = errors + 1;
        end
        apb_read(32'h14, rd);                       // ERROR_COUNT
        if (rd !== exp[sidx*5 + 4]) begin
            $display("FAIL sample %0d error_cnt: got=0x%08X want=0x%08X",
                     sidx, rd, exp[sidx*5 + 4]);
            errors = errors + 1;
        end
    end
endtask

// Full golden replay. mode: 0 = step mode (start per sample), 1 =
// continuous (CTRL.start, stream all, poll counters). freeze: skip
// backprop/update (expected data must then come from a freeze-expected
// file — see gen_vectors.py --freeze — because preds/counters/weights
// differ from the training run). lr: lr_shift to program (LRN_RATE).
task golden_replay;
    input        mode;
    input        freeze;
    input [3:0]  lr;
    integer sidx;
    integer p;
    begin
        apb_write(32'h04, {28'h0000000, lr});       // LRN_RATE
        apb_write(32'h00, 32'h00000010);            // CTRL.clr_stats: counters must
                                                    // start at 0 for the golden
                                                    // per-sample counter checks
        if (freeze) apb_write(32'h00, 32'h00000008); // CTRL[3]=freeze only
        else        apb_write(32'h00, 32'h00000000);
        gr_load_weights;

        if (!mode) begin
            // ---- step mode: exactly one sample per CTRL.step ----------
            // NOTE: CTRL is write-to-set for level bits, so the strobe
            // write must RE-SET CTRL[3] when freeze is requested (a bare
            // 0x02 would clear freeze in apb_regs).
            for (sidx = 0; sidx < N_SAMPLES; sidx = sidx + 1) begin
                apb_write(32'h00, (freeze ? 32'h0000000A : 32'h00000002));  // step[+freeze]
                for (p = 0; p < FEATURES; p = p + 1)
                    stream_byte(stim[W_TOT + sidx*(FEATURES+1) + p][7:0], 1'b0);
                stream_byte(stim[W_TOT + sidx*(FEATURES+1) + FEATURES][7:0], 1'b1);
                gr_wait_done;
                gr_check_sample(sidx);
            end
        end else begin
            // ---- continuous mode --------------------------------------
            apb_write(32'h00, (freeze ? 32'h00000009 : 32'h00000001));  // start[+freeze]
            for (sidx = 0; sidx < N_SAMPLES; sidx = sidx + 1) begin
                for (p = 0; p < FEATURES; p = p + 1)
                    stream_byte(stim[W_TOT + sidx*(FEATURES+1) + p][7:0], 1'b0);
                stream_byte(stim[W_TOT + sidx*(FEATURES+1) + FEATURES][7:0], 1'b1);
                // wait for this sample's counter increment
                begin : cont_wait
                    integer tmo;
                    tmo = 0;
                    while (tmo < 2000000) begin
                        apb_read(32'h0C, rd);
                        if (rd == (sidx + 32'd1)) tmo = 2000000;
                        else begin tmo = tmo + 1; @(posedge clk_core); end
                    end
                    if (tmo >= 2000000) begin
                        apb_read(32'h0C, rd);
                        if (rd !== (sidx + 32'd1)) begin
                            $display("FAIL cont wait sample %0d: cnt=0x%08X @%0t", sidx, rd, $time);
                            errors = errors + 1;
                        end
                    end
                end
                gr_check_sample(sidx);
            end
        end
        gr_dump_weights;
    end
endtask

`endif // TB_COMMON_GOLDEN_REPLAY_VH
