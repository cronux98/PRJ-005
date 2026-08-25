`timescale 1ns/1ps
module xcheck_tb;
  reg clk = 1'b0;
  always #5 clk = ~clk;
  integer x_events = 0;
  reg scan_en = 1'b0;
  wire [11:0] led;
  wire uart_tx;
  reg rst_n = 1'b1;

  mnist_npu dut (
    .led(led),
    .uart_tx(uart_tx),
    .clk(clk),
    .rst_n(rst_n)
  );

  always @(posedge clk) if (scan_en && (^led === 1'bx)) begin
    $display("X-LEAK %0t led", $time); x_events = x_events + 1;
  end
  always @(posedge clk) if (scan_en && (uart_tx === 1'bx || uart_tx === 1'bz)) begin
    $display("X-LEAK %0t uart_tx", $time); x_events = x_events + 1;
  end

  initial begin
    $display("XCHECK: top=mnist_npu clk=clk rst=rst_n rst_active=0");
    rst_n = 1'b0;  // assert reset
    repeat (4) @(posedge clk);
    repeat (5) @(posedge clk);
    rst_n = 1'b1;  // deassert reset
    repeat (2) @(posedge clk);
    repeat (10) @(posedge clk);
    scan_en = 1'b1;
    repeat (20) @(posedge clk);
    scan_en = 1'b0;
    $display("XCHECK SUMMARY: %0d X/Z events on outputs", x_events);
    $finish;
  end
endmodule
