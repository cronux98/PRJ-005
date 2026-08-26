//---------------------------------------------------------------------
// tests/tb_reset.v — VP-TOP-001: cold reset and reset-state check
// Traces  : REQ-023, REQ-030
// Purpose : Assert rst_n low for >= ASM-001 (2 cycles), hold it low for
//           a stretch long enough to prove NOTHING toggles during reset
//           (led==0, uart_tx==1 throughout), release, then confirm the
//           first inference targets image index 0 immediately.
//---------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_reset;
    reg clk = 1'b0;
    reg rst_n;
    wire [11:0] led;
    wire        uart_tx;
    integer errors = 0;

    always #5.0 clk = ~clk;   // 10ns period, 100MHz nominal

    cnn_npu #(.HOLD_CYCLES(8), .BLINK_CYCLES(4), .CLK_DIV(4)) dut (
        .clk(clk), .rst_n(rst_n), .led(led), .uart_tx(uart_tx)
    );

    `include "verify/tb_common/checker.vh"

    integer i;
    initial begin
        rst_n = 1'b0;
        // hold reset for 20 cycles (>> ASM-001's 2-cycle minimum), checking
        // led/uart_tx stay at their reset defaults every single cycle.
        // #1 settle delay: reading a DUT-internal signal immediately after
        // @(posedge clk) races against the DUT's own always blocks for that
        // same edge (relative process scheduling order between separate
        // always/initial blocks triggered by the same edge is not
        // guaranteed) — confirmed empirically (a raw post-edge read here
        // intermittently saw the PRE-edge value; a 1-time-unit settle
        // delay makes it deterministic, matching the pattern already used
        // in tb_rom_readback.v/tb_sigmoid_lut_unit.v/tb_mac_datapath_unit.v).
        for (i = 0; i < 20; i = i + 1) begin
            @(posedge clk);
            #1;
            check_eq({20'd0, led}, 32'd0, "VP-TOP-001: led==0 throughout reset");
            check_eq1(uart_tx, 1'b1, "VP-TOP-001/REQ-030: uart_tx idle-high throughout reset");
        end

        rst_n <= 1'b1;
        @(posedge clk);
        #1;

        // First inference targets image index 0 immediately after release:
        // ctrl_fsm's own reset value is img_idx<=0, and it must remain 0
        // through this first image's entire pass (checked via hierarchical
        // peek — no host-visible register exists to read this any other way).
        check_eq({25'd0, dut.u_ctrl_fsm.img_idx}, 32'd0, "VP-TOP-001: img_idx==0 immediately after reset release");
        check_eq({28'd0, dut.u_ctrl_fsm.state}, 32'd0, "VP-TOP-001: first state after release is ST_CONV1 (compute started)");

        test_summary("tb_reset");
        $finish;
    end
endmodule
