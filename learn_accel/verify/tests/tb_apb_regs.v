//---------------------------------------------------------------------
// tb_apb_regs.v — module gate for BLK-002 apb_regs
// Project  : rinriAI (PRJ-005) — VP-APB-001, VP-APB-002 (REQ-009,010,020)
// Language : pure Verilog-2001, iverilog -g2001 -Wall
// DUT      : rtl/apb_regs.v + real rtl/weight_ram.v (tiny W_TOT=30) for
//            the WDATA bridge, stats/learner status driven by the TB.
// Coverage : reset values, access types, strobe self-clear, RO-write
//            ignore, rsvd-bit ignore, WADDR auto-increment, WDATA bridge,
//            init_busy drop, init_go gating + walk, PSLVERR reserved
//            addresses (0x28/0x3C/0x100/0xFFFFFFFC) with no side
//            effects, back-to-back + idle gaps.
// NOTE     : writing CTRL[5] (init_weights) while !busy triggers a real
//            bulk-init walk (spec REQ-020) — the TB accounts for it.
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_apb_regs;
    reg clk_core = 1'b0;
    reg rst_n    = 1'b0;

    // APB4 (IF-001)
    reg        apb_psel = 0, apb_penable = 0, apb_pwrite = 0;
    reg  [31:0] apb_paddr = 0, apb_pwdata = 0;
    wire [31:0] apb_prdata;
    wire        apb_pready, apb_pslverr;

    // Learner control / status
    wire        start_p, step_p, halt_p, freeze, clr_stats_p;
    wire [3:0]  lr_shift;
    reg         busy = 0, done = 0;

    // Weight RAM port B
    wire [15:0] b_addr, b_wdata, b_rdata;
    wire        b_we, init_go, init_busy;
    wire [15:0] init_val;

    // Stats side
    reg  [31:0] sample_count = 0, correct_count = 0, error_count = 0;
    reg         err = 0;
    reg  [7:0]  pred = 0;

    integer errors = 0;

    apb_regs dut (
        .clk_core (clk_core), .rst_n (rst_n),
        .psel (apb_psel), .penable (apb_penable), .pwrite (apb_pwrite),
        .paddr (apb_paddr), .pwdata (apb_pwdata), .prdata (apb_prdata),
        .pready (apb_pready), .pslverr (apb_pslverr),
        .start_p (start_p), .step_p (step_p), .halt_p (halt_p),
        .freeze (freeze), .lr_shift (lr_shift),
        .b_addr (b_addr), .b_wdata (b_wdata), .b_we (b_we),
        .b_rdata (b_rdata), .init_go (init_go), .init_val (init_val),
        .init_busy (init_busy),
        .sample_count (sample_count), .correct_count (correct_count),
        .error_count (error_count), .err (err), .pred (pred),
        .clr_stats_p (clr_stats_p),
        .busy (busy), .done (done)
    );

    // Real weight memory, tiny config (30 words) so the CSR bridge is real.
    weight_ram #(.W_TOT(30), .W_A(16)) wram (
        .clk_core (clk_core), .rst_n (rst_n),
        .a_addr (16'h0000), .a_wdata (16'h0000), .a_we (1'b0), .a_rdata (),
        .b_addr (b_addr), .b_wdata (b_wdata), .b_we (b_we),
        .b_rdata (b_rdata), .init_go (init_go), .init_val (init_val),
        .init_busy (init_busy)
    );

    `include "tb_common/clk_rst.vh"
    `include "tb_common/checker.vh"
    `include "tb_common/apb4_bfm.vh"

    reg [31:0] rd;

    // ---------------------------------------------------------------
    initial begin
        $dumpfile("tb_apb_regs.vcd");
        $dumpvars(0, tb_apb_regs);

        tb_reset;

        // ---- 1. Reset defaults (VP-TOP-001 class, REQ-013) -----------
        apb_read(32'h00, rd); check_eq(rd, 32'h00000000, "CTRL reset");
        apb_read(32'h04, rd); check_eq(rd, 32'h00000008, "LRN_RATE reset=8");
        apb_read(32'h08, rd); check_eq(rd, 32'h00000000, "STATUS reset");
        apb_read(32'h0C, rd); check_eq(rd, 32'h00000000, "SAMPLE reset");
        apb_read(32'h10, rd); check_eq(rd, 32'h00000000, "CORRECT reset");
        apb_read(32'h14, rd); check_eq(rd, 32'h00000000, "ERROR reset");
        apb_read(32'h18, rd); check_eq(rd, 32'h00000000, "PRED reset");
        apb_read(32'h1C, rd); check_eq(rd, 32'h00000000, "WADDR reset");
        apb_read(32'h20, rd); check_eq(rd, 32'h00000000, "WDATA reset");
        apb_read(32'h24, rd); check_eq(rd, 32'h00000000, "W_INIT_VAL reset");

        // ---- 2. RW round-trips + rsvd-bit ignore (VP-APB-001) --------
        apb_write(32'h04, 32'h00000005); apb_read(32'h04, rd);
        check_eq(rd, 32'h00000005, "LRN_RATE roundtrip");
        apb_write(32'h04, 32'hFFFFFFFF); apb_read(32'h04, rd);
        check_eq(rd, 32'h0000000F, "LRN_RATE rsvd bits ignored");

        apb_write(32'h1C, 32'h00001234); apb_read(32'h1C, rd);
        check_eq(rd, 32'h00001234, "WADDR roundtrip");
        apb_write(32'h1C, 32'hFFFFFFFF); apb_read(32'h1C, rd);
        check_eq(rd, 32'h0000FFFF, "WADDR rsvd bits ignored");

        apb_write(32'h24, 32'h0000ABCD); apb_read(32'h24, rd);
        check_eq(rd, 32'h0000ABCD, "W_INIT_VAL roundtrip");
        apb_write(32'h24, 32'hFFFF5555); apb_read(32'h24, rd);
        check_eq(rd, 32'h00005555, "W_INIT_VAL rsvd bits ignored");

        // ---- 3. CTRL: strobes read 0, freeze level reads back --------
        // 0x1F = start|step|halt|freeze|clr_stats (bits 0-4) — deliberately
        // NOT bit5 (init_weights): that strobe triggers a real bulk-init walk.
        apb_write(32'h00, 32'h0000001F); apb_read(32'h00, rd);
        check_eq(rd, 32'h00000008, "CTRL strobes read 0, freeze=1");
        check_eq1(freeze, 1'b1, "freeze level follows CTRL[3]");
        apb_write(32'h00, 32'h00000000); apb_read(32'h00, rd);
        check_eq(rd, 32'h00000000, "CTRL freeze clear");
        check_eq1(freeze, 1'b0, "freeze level cleared");

        // ---- 4. RO writes ignored (REQ-010) --------------------------
        apb_write(32'h08, 32'hDEADBEEF); apb_read(32'h08, rd);
        check_eq(rd, 32'h00000000, "STATUS write ignored");
        apb_write(32'h0C, 32'hDEADBEEF); apb_read(32'h0C, rd);
        check_eq(rd, 32'h00000000, "SAMPLE write ignored");
        apb_write(32'h18, 32'h000000FF); apb_read(32'h18, rd);
        check_eq(rd, 32'h00000000, "PRED write ignored");

        // ---- 5. STATUS assembly from live inputs (REQ-010) -----------
        busy = 1'b1; err = 1'b1; done = 1'b1; pred = 8'h07;
        sample_count = 32'hA5A5A5A5; correct_count = 32'h11111111;
        error_count = 32'h22222222;
        apb_read(32'h08, rd); check_eq(rd, 32'h00000007, "STATUS busy|done|err (frozen=0)");
        apb_write(32'h00, 32'h00000008);              // freeze=1
        apb_read(32'h08, rd); check_eq(rd, 32'h0000000F, "STATUS frozen=1");
        apb_read(32'h0C, rd); check_eq(rd, 32'hA5A5A5A5, "SAMPLE passthrough");
        apb_read(32'h10, rd); check_eq(rd, 32'h11111111, "CORRECT passthrough");
        apb_read(32'h14, rd); check_eq(rd, 32'h22222222, "ERROR passthrough");
        apb_read(32'h18, rd); check_eq(rd, 32'h00000007, "PRED passthrough");
        apb_write(32'h00, 32'h00000000);
        busy = 1'b0; err = 1'b0; done = 1'b0; pred = 8'h00;

        // ---- 6. WDATA bridge + auto-increment (REQ-006/020) ----------
        apb_write(32'h1C, 32'h00000000);              // WADDR=0
        apb_write(32'h20, 32'h00001111);              // mem[0]=0x1111
        apb_read (32'h1C, rd); check_eq(rd, 32'h00000001, "WADDR inc after WDATA write");
        apb_write(32'h20, 32'h00002222);              // mem[1]=0x2222
        apb_write(32'h20, 32'h00003333);              // mem[2]=0x3333
        apb_read (32'h1C, rd); check_eq(rd, 32'h00000003, "WADDR inc x3");
        apb_write(32'h1C, 32'h00000000);              // WADDR=0
        apb_read (32'h20, rd); check_eq(rd, 32'h00001111, "WDATA read mem[0]");
        apb_read (32'h1C, rd); check_eq(rd, 32'h00000001, "WADDR inc after WDATA read");
        apb_read (32'h20, rd); check_eq(rd, 32'h00002222, "WDATA read mem[1]");
        apb_read (32'h20, rd); check_eq(rd, 32'h00003333, "WDATA read mem[2]");
        apb_read (32'h20, rd); check_eq(rd, 32'h00000000, "WDATA read mem[3]=0");

        // ---- 7. WDATA write dropped while init_busy (arch 4.5) -------
        force dut.init_busy = 1'b1;
        apb_write(32'h1C, 32'h00000000);              // WADDR=0
        apb_write(32'h20, 32'h0000EEEE);              // dropped: b_we=0
        apb_read (32'h1C, rd); check_eq(rd, 32'h00000000, "WADDR NOT inc on dropped write");
        release dut.init_busy;
        apb_write(32'h20, 32'h0000EEEE);              // now real
        apb_read (32'h1C, rd); check_eq(rd, 32'h00000001, "WADDR inc after busy release");
        apb_write(32'h1C, 32'h00000000);
        apb_read (32'h20, rd); check_eq(rd, 32'h0000EEEE, "mem[0] written after release");

        // ---- 8. init_go gating on busy + bulk-init walk (REQ-020) ----
        busy = 1'b1;
        apb_write(32'h00, 32'h00000020);              // CTRL[5] write while busy
        check_eq1(init_go, 1'b0, "init_go suppressed while busy");
        busy = 1'b0;
        begin : strobe_init
            @(posedge clk_core);
            apb_psel <= 1'b1; apb_penable <= 1'b0; apb_pwrite <= 1'b1;
            apb_paddr <= 32'h00; apb_pwdata <= 32'h00000020;
            @(posedge clk_core);                      // ACCESS [B,C)
            apb_penable <= 1'b1;
            @(posedge clk_core);                      // commit edge C
            check_eq1(init_go, 1'b1, "init_go pulses in ACCESS");
            apb_psel <= 1'b0; apb_penable <= 1'b0;    // leave ACCESS
            @(posedge clk_core);
            check_eq1(init_go, 1'b0, "init_go low outside ACCESS");
        end
        // Wait for the 30-word walk, then verify all words = W_INIT_VAL
        while (init_busy) @(posedge clk_core);
        begin : walk_check
            integer i;
            apb_write(32'h1C, 32'h00000000);
            for (i = 0; i < 30; i = i + 1) begin
                apb_read(32'h20, rd);
                if (rd[15:0] !== 16'h5555) begin
                    $display("FAIL walk word %0d: got=0x%04X want=0x5555 @%0t", i, rd[15:0], $time);
                    errors = errors + 1;
                end
            end
        end
        // start/step/halt/clr_stats strobes: 1-cycle pulses in ACCESS
        begin : strobe_ctrl
            @(posedge clk_core);
            apb_psel <= 1'b1; apb_penable <= 1'b0; apb_pwrite <= 1'b1;
            apb_paddr <= 32'h00; apb_pwdata <= 32'h00000017;  // start|step|halt|clr
            @(posedge clk_core);
            apb_penable <= 1'b1;
            @(posedge clk_core);                      // commit edge
            check_eq1(start_p, 1'b1, "start_p pulses");
            check_eq1(step_p,  1'b1, "step_p pulses");
            check_eq1(halt_p,  1'b1, "halt_p pulses");
            check_eq1(clr_stats_p, 1'b1, "clr_stats_p pulses");
            apb_psel <= 1'b0; apb_penable <= 1'b0;
            @(posedge clk_core);
            check_eq1(start_p, 1'b0, "start_p 1-cycle");
            check_eq1(step_p,  1'b0, "step_p 1-cycle");
            check_eq1(halt_p,  1'b0, "halt_p 1-cycle");
            check_eq1(clr_stats_p, 1'b0, "clr_stats_p 1-cycle");
        end
        // Re-establish known memory state (walk overwrote everything)
        apb_write(32'h1C, 32'h00000000); apb_write(32'h20, 32'h0000EEEE);  // mem[0]=0xEEEE, waddr=1
        apb_write(32'h1C, 32'h00000013); apb_write(32'h20, 32'h00000000);  // mem[0x13]=0, waddr=0x14

        // ---- 9. PSLVERR on reserved addresses, no side effects -------
        begin : slverr_tests
            integer k;
            reg [31:0] bads [0:3];
            bads[0] = 32'h00000028;
            bads[1] = 32'h0000003C;
            bads[2] = 32'h00000100;
            bads[3] = 32'hFFFFFFFC;
            for (k = 0; k < 4; k = k + 1) begin
                apb_access_expect_err(1'b1, bads[k], 32'hCAFEBABE, rd);   // write
                apb_access_expect_err(1'b0, bads[k], 32'h00000000, rd);   // read
                check_eq(rd, 32'h00000000, "err read returns 0");
            end
        end
        // No side effects: WADDR, LRN_RATE, mem[0] untouched by the 8 errors
        apb_read(32'h1C, rd); check_eq(rd, 32'h00000014, "WADDR untouched by errors");
        apb_read(32'h04, rd); check_eq(rd, 32'h0000000F, "LRN_RATE untouched by errors");
        apb_write(32'h1C, 32'h00000000);
        apb_read(32'h20, rd); check_eq(rd, 32'h0000EEEE, "mem[0] untouched by errors");
        // Subsequent valid access still works
        apb_write(32'h04, 32'h00000007); apb_read(32'h04, rd);
        check_eq(rd, 32'h00000007, "valid access after errors");

        // ---- 10. Transfer sequences (VP-APB-002) ---------------------
        // Back-to-back burst via WDATA auto-inc (psel held high)
        apb_write(32'h1C, 32'h00000010);
        @(posedge clk_core);
        apb_psel <= 1'b1; apb_penable <= 1'b0; apb_pwrite <= 1'b1;
        apb_paddr <= 32'h20; apb_pwdata <= 32'h0000AAAA;
        @(posedge clk_core); apb_penable <= 1'b1;               // ACCESS1
        @(posedge clk_core); apb_penable <= 1'b0; apb_pwdata <= 32'h0000BBBB;  // SETUP2
        @(posedge clk_core); apb_penable <= 1'b1;               // ACCESS2
        @(posedge clk_core); apb_penable <= 1'b0; apb_pwdata <= 32'h0000CCCC;  // SETUP3
        @(posedge clk_core); apb_penable <= 1'b1;               // ACCESS3
        @(posedge clk_core); apb_penable <= 1'b0;
        apb_psel <= 1'b0; apb_pwrite <= 1'b0;
        apb_read(32'h1C, rd); check_eq(rd, 32'h00000013, "bb burst auto-inc 3");
        apb_write(32'h1C, 32'h00000010);
        apb_read(32'h20, rd); check_eq(rd, 32'h0000AAAA, "bb mem[0x10]");
        apb_read(32'h20, rd); check_eq(rd, 32'h0000BBBB, "bb mem[0x11]");
        apb_read(32'h20, rd); check_eq(rd, 32'h0000CCCC, "bb mem[0x12]");
        // write-after-read: read mem[0x13] (=0, set before errors), then write
        apb_read(32'h20, rd); check_eq(rd, 32'h00000000, "war read mem[0x13]");
        begin : war_write
            @(posedge clk_core);
            apb_psel <= 1'b1; apb_penable <= 1'b0; apb_pwrite <= 1'b1;
            apb_paddr <= 32'h20; apb_pwdata <= 32'h0000DDDD;
            @(posedge clk_core);
            apb_penable <= 1'b1;
            @(posedge clk_core);
            check_eq1(b_we, 1'b1, "b_we high in ACCESS (war write)");
            check_eq(b_addr, 16'h0014, "b_addr follows WADDR");
            apb_psel <= 1'b0; apb_penable <= 1'b0;
        end
        apb_read(32'h1C, rd); check_eq(rd, 32'h00000015, "WADDR 0x15 after war write");
        apb_write(32'h1C, 32'h00000014);
        apb_read(32'h20, rd); check_eq(rd, 32'h0000DDDD, "mem[0x14] written");
        // idle gaps: bus idle, state stable
        apb_idle_gap(16'd3);
        apb_read(32'h1C, rd); check_eq(rd, 32'h00000015, "waddr stable across idle gap");

        test_summary("tb_apb_regs");
        $finish;
    end

    // Watchdog
    initial begin
        #1_000_000;
        $display("TEST FAILED: timeout tb_apb_regs");
        $finish;
    end
endmodule

`default_nettype wire
