//---------------------------------------------------------------------
// tests/tb_mac_datapath_unit.v — VP-MAC-001/002/003
// Traces  : REQ-002..REQ-005, REQ-008, REQ-028, REQ-029
// Method  : Directed vectors driven straight at mac_datapath's ports
//           (bypassing ctrl_fsm entirely). An INDEPENDENT behavioural
//           reference model (`refacc`, a 64-bit signed Verilog reg,
//           mirroring golden_ref_model.c's `long acc` — bias<<8 then
//           += a*b, no intermediate truncation) is kept in this TB and
//           cross-checked against mac_z every step — a different
//           implementation of the same algorithm, not a re-use of the
//           RTL's own 40-bit accumulator.
//---------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_mac_datapath_unit;
    reg clk = 1'b0;
    reg rst_n;
    integer errors = 0;

    `include "verify/tb_common/clk_rst.vh"
    `include "verify/tb_common/checker.vh"

    reg  signed [15:0] mac_a;
    reg  signed [15:0] mac_b;
    reg                 mac_bias_ld;
    reg  signed [15:0] mac_bias;
    reg                 mac_acc_en;
    wire signed [15:0] mac_z;

    mac_datapath dut (
        .clk(clk), .rst_n(rst_n),
        .mac_a(mac_a), .mac_b(mac_b),
        .mac_bias_ld(mac_bias_ld), .mac_bias(mac_bias),
        .mac_acc_en(mac_acc_en), .mac_z(mac_z)
    );

    // ---- independent behavioural reference (mirrors golden_ref_model.c) ----
    reg signed [63:0] refacc;
    function signed [15:0] ref_z;
        input signed [63:0] acc;
        reg signed [63:0] shifted;
        begin
            shifted = acc >>> 8;
            if (shifted > 64'sd32767)        ref_z = 16'sd32767;
            else if (shifted < -64'sd32768)  ref_z = -16'sd32768;
            else                             ref_z = shifted[15:0];
        end
    endfunction

    // NOTE: stimulus that must be sampled by the DUT's own NBA-driven
    // always block on a SPECIFIC edge, then cleared, must be driven with
    // NON-BLOCKING assignments here too — clearing it with a blocking `=`
    // right after the very `@(posedge clk)` it needs to be seen on races
    // against the DUT's always block for that same edge (order between
    // two processes woken by the same edge is not guaranteed). This is
    // the same reason tb_common/clk_rst.vh's tb_reset uses `rst_n <= ...`.
    task do_bias_ld;
        input signed [15:0] bias;
        begin
            mac_a       <= 16'sd0;
            mac_b       <= 16'sd0;
            mac_bias    <= bias;
            mac_bias_ld <= 1'b1;
            mac_acc_en  <= 1'b0;
            @(posedge clk);
            mac_bias_ld <= 1'b0;
            refacc = ($signed(bias)) <<< 8;
            #1;
            check_eq({16'd0, mac_z}, {16'd0, ref_z(refacc)}, "VP-MAC-001: mac_z after bias load");
        end
    endtask

    task do_acc_step;
        input signed [15:0] a;
        input signed [15:0] b;
        begin
            mac_a       <= a;
            mac_b       <= b;
            mac_bias_ld <= 1'b0;
            mac_acc_en  <= 1'b1;
            @(posedge clk);
            mac_acc_en  <= 1'b0;
            refacc = refacc + ($signed(a) * $signed(b));
            #1;
            check_eq({16'd0, mac_z}, {16'd0, ref_z(refacc)}, "VP-MAC-001: mac_z after accumulate step");
        end
    endtask

    integer i;
    initial begin
        tb_reset;

        // ---- VP-MAC-001: bias-only load, small positive bias ----
        do_bias_ld(16'sd100);   // acc = 100<<8 = 25600, z = 25600>>>8 = 100

        // ---- VP-MAC-001: a short accumulate sequence, mixed signs ----
        do_bias_ld(16'sd0);
        do_acc_step(16'sd200, 16'sd50);     // pixel-like * weight-like
        do_acc_step(16'sd10,  -16'sd300);
        do_acc_step(16'sd255, 16'sd128);
        do_acc_step(16'sd0,   16'sd12345);  // mac_a=0 (bias-load-style operand), product=0

        // ---- VP-MAC-002: accumulator overflow margin — a full 784-term
        // layer-1-scale accumulate at near-extreme operand magnitudes
        // (pixel 0..255, weight Q8.8 signed range) must not wrap the
        // 40-bit accumulator (REQ-028). Cross-checked against the same
        // 64-bit reference — if the RTL's 40 bits ever truncated where
        // the 64-bit reference didn't, mac_z would diverge here. ----
        do_bias_ld(16'sd0);
        for (i = 0; i < 784; i = i + 1)
            do_acc_step(16'sd255, 16'sd32767);   // max pixel * max positive weight, worst-case magnitude growth

        // ---- VP-MAC-003: positive saturation clamp ----
        do_bias_ld(16'sd0);
        for (i = 0; i < 20; i = i + 1)
            do_acc_step(16'sd255, 16'sd32767);
        check_eq({16'd0, mac_z}, {16'd0, 16'sd32767}, "VP-MAC-003: positive clamp reached +32767");

        // ---- VP-MAC-003: negative saturation clamp ----
        do_bias_ld(16'sd0);
        for (i = 0; i < 20; i = i + 1)
            do_acc_step(16'sd255, -16'sd32768);
        check_eq({16'd0, mac_z}, {16'd0, -16'sd32768}, "VP-MAC-003: negative clamp reached -32768");

        test_summary("tb_mac_datapath_unit");
        $finish;
    end
endmodule
