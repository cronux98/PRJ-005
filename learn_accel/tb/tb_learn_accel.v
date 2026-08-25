//---------------------------------------------------------------------
// Testbench : tb_learn_accel (source only — never executed by fe-rtl)
// Project   : rinriAI   Technology : Sky130 130 nm
// Purpose   : Golden-model acceptance test for the tiny configuration
//             FEATURES=4, HIDDEN=4, CLASSES=2, lr_shift=0.
//             Loads init weights via CSR (WADDR/WDATA), streams the 5
//             golden samples over the byte-stream port in STEP mode,
//             checks PRED/counters after each sample against
//             arch/golden_model/expected.hex, then streams a 6th sample
//             with an INVALID label (0x05 >= CLASSES=2) proving the
//             REQ-018 rejection (STATUS.err=1, counters unchanged, no
//             weight update), then reads back the final weights and
//             compares them too.
// Command   (user runs) :
//   iverilog -g2001 -Wall -o sim $(cat filelist.f) tb/tb_learn_accel.v && vvp sim
//---------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_learn_accel;
    // Clock / reset ---------------------------------------------------
    reg clk_core = 1'b0;
    reg rst_n    = 1'b0;
    always #10.0 clk_core = ~clk_core;                // 50 MHz

    // DUT ports -------------------------------------------------------
    reg        psel, penable, pwrite;
    reg  [31:0] paddr, pwdata;
    wire [31:0] prdata;
    wire        pready, pslverr;
    reg         s_valid, s_last;
    reg  [7:0]  s_data;
    wire        s_ready;

    learn_accel #(
        .FEATURES(4),
        .HIDDEN (4),
        .CLASSES(2)
    ) dut (
        .clk_core (clk_core),
        .rst_n    (rst_n),
        .psel     (psel),
        .penable  (penable),
        .pwrite   (pwrite),
        .paddr    (paddr),
        .pwdata   (pwdata),
        .prdata   (prdata),
        .pready   (pready),
        .pslverr  (pslverr),
        .s_valid  (s_valid),
        .s_ready  (s_ready),
        .s_data   (s_data),
        .s_last   (s_last)
    );

    // Register addresses (spec/arch.md section 7) ---------------------
    localparam [7:0] A_CTRL    = 8'h00, A_LRN_RATE = 8'h04, A_STATUS  = 8'h08,
                     A_SAMPLE  = 8'h0C, A_CORRECT  = 8'h10, A_ERROR   = 8'h14,
                     A_PRED    = 8'h18, A_WADDR    = 8'h1C, A_WDATA   = 8'h20;

    // Golden data ------------------------------------------------------
    // stimulus: 30 init weights + 6 samples x 5 bytes (5 valid + 1 invalid)
    // expected: 5 processed samples x 5 words + 30 final weight words
    //           (the rejected sample contributes NO row — it is not counted)
    reg [31:0] stim [0:59];
    reg [31:0] exp  [0:59];
    integer errors = 0;
    integer i, s, p;
    reg [31:0] rdata;

    // Tasks -----------------------------------------------------------
    task apb_write;                       // zero-wait APB4 write
        input [31:0] addr, data;
        begin
            @(posedge clk_core);
            psel <= 1'b1; penable <= 1'b0; pwrite <= 1'b1;
            paddr <= addr; pwdata <= data;
            @(posedge clk_core);
            penable <= 1'b1;
            @(posedge clk_core);
            psel <= 1'b0; penable <= 1'b0; pwrite <= 1'b0;
        end
    endtask

    task apb_read;                        // zero-wait APB4 read
        input  [31:0] addr;
        output [31:0] data;
        begin
            @(posedge clk_core);
            psel <= 1'b1; penable <= 1'b0; pwrite <= 1'b0;
            paddr <= addr;
            @(posedge clk_core);
            penable <= 1'b1;
            @(posedge clk_core);
            data = prdata;
            psel <= 1'b0; penable <= 1'b0;
        end
    endtask

    task check_eq;                        // pure-Verilog checker
        input [31:0] got, want; input [255:0] name;
        begin
            if (got !== want) begin
                $display("FAIL %0s: got=0x%08X want=0x%08X @%0t", name, got, want, $time);
                errors = errors + 1;
            end
        end
    endtask

    // Stream one byte, waiting for s_ready ----------------------------
    task stream_byte;
        input [7:0] byte; input last;
        begin
            while (!s_ready) @(posedge clk_core);
            s_valid <= 1'b1; s_data <= byte; s_last <= last;
            @(posedge clk_core);
            s_valid <= 1'b0; s_last <= 1'b0;
        end
    endtask

    // Wait until STATUS.done (step-mode completion) --------------------
    task wait_done;
        begin
            repeat (2000000) begin
                apb_read(A_STATUS, rdata);
                if (rdata[1]) disable wait_done;
                @(posedge clk_core);
            end
            $display("FAIL timeout waiting for STATUS.done");
            errors = errors + 1;
        end
    endtask

    integer sample_index;
    initial begin
        $dumpfile("tb_learn_accel.vcd");
        $dumpvars(0, tb_learn_accel);

        // Reset: 16 cycles minimum per spec (ASM-002, synchronous de-assert)
        repeat (16) @(posedge clk_core);
        rst_n <= 1'b1;

        // Load golden vectors
        $readmemh("arch/golden_model/stimulus.hex", stim);
        $readmemh("arch/golden_model/expected.hex",  exp);

        // Configure: lr_shift = 0 (golden vectors)
        apb_write(32'h00000004, 32'h00000000);

        // Load the 30 initial weights via WADDR + auto-incrementing WDATA
        apb_write(32'h0000001C, 32'h00000000);              // WADDR = 0
        for (i = 0; i < 30; i = i + 1)
            apb_write(32'h00000020, {16'h0000, stim[i][15:0]});

        // Process the 5 golden samples in STEP mode
        for (sample_index = 0; sample_index < 5; sample_index = sample_index + 1) begin
            apb_write(32'h00000000, 32'h00000002);          // CTRL.step
            for (p = 0; p < 4; p = p + 1) begin             // 4 pixel bytes
                stream_byte(stim[30 + sample_index*5 + p][7:0], 1'b0);
            end
            stream_byte(stim[30 + sample_index*5 + 4][7:0], 1'b1);  // label byte
            wait_done;
            // Golden per-sample checks (5 words per sample)
            apb_read(A_PRED,    rdata); check_eq(rdata[7:0], exp[sample_index*5 + 0][7:0], "pred");
            apb_read(A_SAMPLE,  rdata); check_eq(rdata,      exp[sample_index*5 + 2],     "sample_count");
            apb_read(A_CORRECT, rdata); check_eq(rdata,      exp[sample_index*5 + 3],     "correct_count");
            apb_read(A_ERROR,   rdata); check_eq(rdata,      exp[sample_index*5 + 4],     "error_count");
        end

        // Sample 6 (stimulus words 55..59): INVALID label 0x05 >= CLASSES=2.
        // REQ-018 rejection proof: sample_stream raises err_p (STATUS.err
        // sticky) and never asserts sample_valid, so the learner never
        // processes it — counters, PRED and weights must be unchanged, and
        // the step stays pending (no wait_done here).
        apb_write(32'h00000000, 32'h00000002);              // CTRL.step
        for (p = 0; p < 4; p = p + 1)                       // 4 pixel bytes
            stream_byte(stim[55 + p][7:0], 1'b0);
        stream_byte(stim[59][7:0], 1'b1);                   // invalid label byte 0x05
        apb_read(A_STATUS, rdata); check_eq(rdata & 32'h00000004, 32'h00000004, "err sticky (invalid label)");
        apb_read(A_SAMPLE,  rdata); check_eq(rdata, 32'h00000005, "sample_count (unchanged)");
        apb_read(A_CORRECT, rdata); check_eq(rdata, 32'h00000001, "correct_count (unchanged)");
        apb_read(A_ERROR,   rdata); check_eq(rdata, 32'h00000004, "error_count (unchanged)");
        apb_read(A_PRED,    rdata); check_eq(rdata[7:0], 8'h00,    "pred (unchanged)");

        // Final weight dump via WADDR + auto-incrementing WDATA reads
        apb_write(32'h0000001C, 32'h00000000);              // WADDR = 0
        for (i = 0; i < 30; i = i + 1) begin
            apb_read(A_WDATA, rdata);
            check_eq(rdata[15:0], exp[25 + i][15:0], "final weight");
        end

        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end

    // Timeout watchdog: a hung DUT must fail, not spin forever
    initial begin
        #2_000_000;
        $display("TEST FAILED: timeout");
        $finish;
    end

endmodule
