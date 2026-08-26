//---------------------------------------------------------------------
// tests/tb_uart_realdiv.v — VP-UART-002 at the REAL production CLK_DIV
// Traces  : REQ-021, REQ-031
// Purpose : arch.md sec 8 explicitly calls for re-running the bit-level
//           frame-timing check at least once with CLK_DIV=868 (the real
//           round(100e6/115200) divider), since the main regression
//           uses a small sim-override divider for speed. HOLD_CYCLES/
//           BLINK_CYCLES stay at small sim overrides (they don't affect
//           UART framing); only CLK_DIV is production-real here. Runs
//           2 images (000 CORRECT, 008 TRASH) — compute time is
//           independent of CLK_DIV so this stays cheap even though the
//           UART frame time itself is ~217x longer than the main run.
//---------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_uart_realdiv;
    localparam SIM_HOLD   = 4;
    localparam SIM_BLINK  = 4;
    localparam REAL_CLKDIV = 868;   // REQ-021 default: round(100e6/115200)

    reg clk = 1'b0;
    reg rst_n;
    wire [11:0] led;
    wire        uart_tx;
    integer errors = 0;

    `include "verify/tb_common/clk_rst.vh"
    `include "verify/tb_common/checker.vh"
    `include "verify/tb_common/uart_monitor.vh"

    cnn_npu #(
        .HOLD_CYCLES  (SIM_HOLD),
        .BLINK_CYCLES (SIM_BLINK),
        .CLK_DIV      (REAL_CLKDIV)
    ) dut (
        .clk(clk), .rst_n(rst_n), .led(led), .uart_tx(uart_tx)
    );

    reg [1023:0] outdir;
    reg [2047:0] outfile;
    integer      uart_fd;
    integer      lc_nbytes;
    integer      line;

    initial begin
        if (!$value$plusargs("OUTDIR=%s", outdir)) outdir = "verify/run_tmp";
        $sformat(outfile, "%0s/uart_realdiv_captured.txt", outdir);
        uart_fd = $fopen(outfile, "w");

        tb_reset;

        for (line = 0; line < 2; line = line + 1) begin
            uart_rx_line(uart_fd, REAL_CLKDIV, lc_nbytes);
        end
        $fclose(uart_fd);

        check_eq(errors, 0, "VP-UART-002: 0 bit-width violations at real CLK_DIV=868");
        test_summary("tb_uart_realdiv");
        $finish;
    end
endmodule
