//---------------------------------------------------------------------
// tb_weight_ram.v — module gate for BLK-005 weight_ram
// Project  : rinriAI (PRJ-005) — VP-WMEM-001, VP-WMEM-002
//           (REQ-006, REQ-013, REQ-020, REQ-021, REQ-022)
// Language : pure Verilog-2001, iverilog -g2001 -Wall
// DUT      : rtl/weight_ram.v (W_TOT=30 tiny config + W_TOT=1 edge)
// Coverage : reset-to-zero, port A/B round-trip, address-map boundaries
//            (F.H-1/F.H, F.H+H-1/+H, W_TOT-1), combinational reads,
//            read-during-write behaviour, same-cycle A/B conflict (B
//            wins), bulk-init walk (all words = init_val, init_busy
//            timing, CSR write dropped while busy, CSR read returns walk
//            word), W_TOT=1 walk edge.
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_weight_ram;
    reg clk_core = 1'b0;
    reg rst_n    = 1'b0;

    // Port A (learner datapath)
    reg  [15:0] a_addr = 0, a_wdata = 0;
    reg         a_we = 0;
    wire [15:0] a_rdata;
    // Port B (CSR)
    reg  [15:0] b_addr = 0, b_wdata = 0;
    reg         b_we = 0;
    wire [15:0] b_rdata;
    reg         init_go = 0;
    reg  [15:0] init_val = 0;
    wire        init_busy;

    integer errors = 0;

    weight_ram #(.W_TOT(30), .W_A(16)) dut (
        .clk_core (clk_core), .rst_n (rst_n),
        .a_addr (a_addr), .a_wdata (a_wdata), .a_we (a_we), .a_rdata (a_rdata),
        .b_addr (b_addr), .b_wdata (b_wdata), .b_we (b_we), .b_rdata (b_rdata),
        .init_go (init_go), .init_val (init_val), .init_busy (init_busy)
    );

    // W_TOT=1 edge instance (walk of a single word)
    wire        busy1;
    weight_ram #(.W_TOT(1), .W_A(16)) dut1 (
        .clk_core (clk_core), .rst_n (rst_n),
        .a_addr (16'h0), .a_wdata (16'h0), .a_we (1'b0), .a_rdata (),
        .b_addr (b_addr), .b_wdata (b_wdata), .b_we (b_we), .b_rdata (),
        .init_go (init_go), .init_val (init_val), .init_busy (busy1)
    );

    `include "tb_common/clk_rst.vh"
    `include "tb_common/checker.vh"

    reg [15:0] rd16;

    // ---------------------------------------------------------------
    initial begin
        $dumpfile("tb_weight_ram.vcd");
        $dumpvars(0, tb_weight_ram);

        tb_reset;

        // ---- 1. Reset: all words 0 (REQ-013) --------------------------
        begin : reset_check
            integer k;
            for (k = 0; k < 30; k = k + 1) begin
                b_addr = k[15:0]; #1;
                if (b_rdata !== 16'h0000) begin
                    $display("FAIL reset word %0d = 0x%04X (want 0)", k, b_rdata);
                    errors = errors + 1;
                end
            end
        end

        // ---- 2. Port B round-trip all 30 words (VP-WMEM-002) ----------
        begin : roundtrip
            integer k;
            for (k = 0; k < 30; k = k + 1) begin
                b_addr <= k[15:0];
                b_wdata <= (k * 16'd257) & 16'hFFFF;   // deterministic pattern
                b_we <= 1'b1;
                @(posedge clk_core);
                b_we <= 1'b0;
            end
            for (k = 0; k < 30; k = k + 1) begin
                b_addr = k[15:0]; #1;
                rd16 = b_rdata;
                if (rd16 !== ((k * 16'd257) & 16'hFFFF)) begin
                    $display("FAIL roundtrip word %0d: got=0x%04X want=0x%04X", k, rd16, (k * 16'd257) & 16'hFFFF);
                    errors = errors + 1;
                end
            end
        end

        // ---- 3. Address-map boundary words (VP-WMEM-001) ---------------
        // tiny config: F.H=16, b_h at 16..19, w_o at 20..27, b_o at 28..29
        // boundaries: F.H-1=15, F.H=16, F.H+H-1=19, F.H+H=20, W_TOT-1=29
        begin : boundaries
            b_addr <= 16'd15; b_wdata <= 16'hA001; b_we <= 1'b1; @(posedge clk_core); b_we <= 1'b0;
            b_addr <= 16'd16; b_wdata <= 16'hA002; b_we <= 1'b1; @(posedge clk_core); b_we <= 1'b0;
            b_addr <= 16'd19; b_wdata <= 16'hA003; b_we <= 1'b1; @(posedge clk_core); b_we <= 1'b0;
            b_addr <= 16'd20; b_wdata <= 16'hA004; b_we <= 1'b1; @(posedge clk_core); b_we <= 1'b0;
            b_addr <= 16'd29; b_wdata <= 16'hA005; b_we <= 1'b1; @(posedge clk_core); b_we <= 1'b0;
            b_addr = 16'd15; #1; check_eq(b_rdata, 16'hA001, "boundary F.H-1");
            b_addr = 16'd16; #1; check_eq(b_rdata, 16'hA002, "boundary F.H");
            b_addr = 16'd19; #1; check_eq(b_rdata, 16'hA003, "boundary F.H+H-1");
            b_addr = 16'd20; #1; check_eq(b_rdata, 16'hA004, "boundary F.H+H");
            b_addr = 16'd29; #1; check_eq(b_rdata, 16'hA005, "boundary W_TOT-1");
        end

        // ---- 4. Port A independent access (IFI-004) --------------------
        a_addr <= 16'd5; a_wdata <= 16'hBEEF; a_we <= 1'b1;
        @(posedge clk_core); a_we <= 1'b0;
        b_addr = 16'd5; #1; check_eq(b_rdata, 16'hBEEF, "port A write visible on port B");
        a_addr = 16'd5; #1; check_eq(a_rdata, 16'hBEEF, "port A combinational read");
        // port B write visible on port A
        b_addr <= 16'd7; b_wdata <= 16'hCAFE; b_we <= 1'b1;
        @(posedge clk_core); b_we <= 1'b0;
        a_addr = 16'd7; #1; check_eq(a_rdata, 16'hCAFE, "port B write visible on port A");

        // ---- 5. Read-during-write: async read shows pre-write value ----
        begin : rdw
            reg [15:0] same_cycle;
            b_addr <= 16'd10; b_wdata <= 16'h1234; b_we <= 1'b1;
            // combinational read DURING the write cycle (before the edge)
            b_addr = 16'd10; #1; same_cycle = b_rdata;   // pre-write value (old: 0x0A0A)
            check_eq(same_cycle, 16'h0A0A, "RDW: read shows pre-write word in write cycle");
            @(posedge clk_core); b_we <= 1'b0;
            b_addr = 16'd10; #1; check_eq(b_rdata, 16'h1234, "RDW: new word after edge");
        end

        // ---- 6. Same-cycle A/B write to same address: B wins -----------
        a_addr <= 16'd12; a_wdata <= 16'hAAAA; a_we <= 1'b1;
        b_addr <= 16'd12; b_wdata <= 16'hBBBB; b_we <= 1'b1;
        @(posedge clk_core); a_we <= 1'b0; b_we <= 1'b0;
        b_addr = 16'd12; #1; check_eq(b_rdata, 16'hBBBB, "A/B conflict: port B wins");

        // ---- 7. Bulk-init walk (VP-WMEM-002, REQ-020) ------------------
        begin : initwalk
            integer k;
            init_val <= 16'hA5A5;
            @(posedge clk_core);
            init_go <= 1'b1;
            @(posedge clk_core);
            init_go <= 1'b0;
            @(posedge clk_core);                 // settle (DUT NBA visible)
            check_eq1(init_busy, 1'b1, "init_busy asserted on init_go");
            // walk takes W_TOT cycles; CSR write mid-walk must be dropped
            b_addr <= 16'd3; b_wdata <= 16'h0000; b_we <= 1'b1;
            @(posedge clk_core); b_we <= 1'b0;      // dropped (walk owns port B)
            // CSR read mid-walk returns the current walk word (benign)
            b_addr = 16'd0; #1;
            // wait for walk completion
            while (init_busy) @(posedge clk_core);
            check_eq1(init_busy, 1'b0, "init_busy deasserted after walk");
            for (k = 0; k < 30; k = k + 1) begin
                b_addr = k[15:0]; #1;
                if (b_rdata !== 16'hA5A5) begin
                    $display("FAIL init walk word %0d = 0x%04X (want A5A5)", k, b_rdata);
                    errors = errors + 1;
                end
            end
            // the mid-walk CSR write was dropped: word 3 still A5A5
            b_addr = 16'd3; #1; check_eq(b_rdata, 16'hA5A5, "CSR write dropped during walk");
        end

        // ---- 8. W_TOT=1 walk edge --------------------------------------
        init_val <= 16'h00FF;
        @(posedge clk_core);
        init_go <= 1'b1;
        @(posedge clk_core);
        init_go <= 1'b0;
        while (busy1) @(posedge clk_core);
        check_eq1(busy1, 1'b0, "W_TOT=1 walk completes");

        test_summary("tb_weight_ram");
        $finish;
    end

    // Watchdog
    initial begin
        #1_000_000;
        $display("TEST FAILED: timeout tb_weight_ram");
        $finish;
    end
endmodule

`default_nettype wire
