//---------------------------------------------------------------------
// tb_common/uart_monitor.vh — independent protocol-level UART monitor
// Project  : mnist_npu (PRJ-005) frontend verification infrastructure
// Language : pure Verilog-2001 (include file, ifndef-guarded)
// Purpose  : Decode the DUT's `uart_tx` pin bit-by-bit (start/8 data
//            LSB-first/stop, REQ-021) using ONLY the pin + `clk` + the
//            known CLK_DIV — no reference to any RTL-internal signal,
//            so this is a genuinely independent re-implementation of
//            the UART protocol (not a re-use of uart_tx.v's own FSM).
//            Verifies each bit's width is exactly CLK_DIV clk cycles
//            (VP-UART-002) by sampling every cycle of every bit window
//            and requiring a constant value throughout.
// Design note (debug history): an earlier version synchronized frame
//            starts with `@(negedge uart_tx)` followed by `@(posedge
//            clk)` bit-window counting. That mixed-event-type wait
//            produced a spurious extra sampled cycle at every frame
//            start/stop (confirmed a TB artifact, not an RTL bug, by
//            cross-checking with a plain `@(posedge clk)`-only polling
//            monitor against `dut.u_uart_tx.{state,baud_cnt}` — the
//            pin genuinely holds each symbol for exactly CLK_DIV
//            cycles). Rewritten below to use ONLY `@(posedge clk)`
//            level-polling, never `@(negedge <non-clock net>)`, which
//            eliminates the cross-event-region ambiguity entirely.
// Usage    : TB declares `integer errors = 0;` (checker.vh) and a
//            `uart_tx` wire (hierarchical DUT pin) before including.
//            Call `uart_rx_frame(byte, CLK_DIV_LOCAL);` in a loop, or
//            `uart_rx_line(fd, CLK_DIV_LOCAL);` to capture a full
//            line (through the 0x0A terminator) to an open file.
//---------------------------------------------------------------------
`ifndef TB_COMMON_UART_MONITOR_VH
`define TB_COMMON_UART_MONITOR_VH

task uart_rx_frame;
    output [7:0] data_out;
    input  integer clkdiv;
    integer bi, ci;
    reg [7:0] data;
    reg       bitval;
    begin
        // ---- synchronize to frame start: poll every clk cycle (no
        // @(negedge) anywhere) until uart_tx reads 0 (idle -> start). ----
        @(posedge clk);
        while (uart_tx !== 1'b0) @(posedge clk);
        // this is cycle 0 of the start bit.

        // ---- start bit: must read 0 for all clkdiv cycles ----
        for (ci = 1; ci < clkdiv; ci = ci + 1) begin
            @(posedge clk);
            if (uart_tx !== 1'b0) begin
                $display("FAIL uart_start_bit_width: cycle %0d/%0d uart_tx=%b (want 0) @%0t",
                          ci, clkdiv, uart_tx, $time);
                errors = errors + 1;
            end
        end

        // ---- 8 data bits, LSB first (REQ-021) ----
        data = 8'h00;
        for (bi = 0; bi < 8; bi = bi + 1) begin
            @(posedge clk);   // first cycle of this data-bit window
            bitval = uart_tx;
            data[bi] = bitval;
            for (ci = 1; ci < clkdiv; ci = ci + 1) begin
                @(posedge clk);
                if (uart_tx !== bitval) begin
                    $display("FAIL uart_data_bit_width: bit %0d cycle %0d/%0d uart_tx=%b (want %b) @%0t",
                              bi, ci, clkdiv, uart_tx, bitval, $time);
                    errors = errors + 1;
                end
            end
        end

        // ---- stop bit: must read 1 for all clkdiv cycles (REQ-031 idle level) ----
        for (ci = 0; ci < clkdiv; ci = ci + 1) begin
            @(posedge clk);
            if (uart_tx !== 1'b1) begin
                $display("FAIL uart_stop_bit_width: cycle %0d/%0d uart_tx=%b (want 1) @%0t",
                          ci, clkdiv, uart_tx, $time);
                errors = errors + 1;
            end
        end

        data_out = data;
    end
endtask

// Capture one full line (bytes up to and including the 0x0A terminator)
// into an already-open file descriptor `fd`. Returns the byte count.
task uart_rx_line;
    input  integer fd;
    input  integer clkdiv;
    output integer nbytes;
    reg [7:0] b;
    integer   n;
    begin
        n = 0;
        b = 8'h00;
        while (b !== 8'h0A) begin
            uart_rx_frame(b, clkdiv);
            $fwrite(fd, "%c", b);
            n = n + 1;
            if (n > 200) begin
                $display("FAIL uart_rx_line: runaway line (>200 bytes, no 0x0A) @%0t", $time);
                errors = errors + 1;
                b = 8'h0A;   // force exit
            end
        end
        nbytes = n;
    end
endtask

`endif // TB_COMMON_UART_MONITOR_VH
