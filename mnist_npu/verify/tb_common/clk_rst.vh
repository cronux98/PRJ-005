//---------------------------------------------------------------------
// tb_common/clk_rst.vh — reusable clock/reset generation
// Project  : mnist_npu (PRJ-005) frontend verification infrastructure
// Language : pure Verilog-2001 (include file, ifndef-guarded)
// Purpose  : 100 MHz clock (10 ns period, matches arch.md CD_CORE) +
//            SYNCHRONOUS active-low reset task (>= ASM-001's 2-cycle
//            minimum assert width; 5 cycles used for margin). TB
//            declares `reg clk = 1'b0;` and `reg rst_n;` before
//            including; the clock always block starts on the include.
//---------------------------------------------------------------------
`ifndef TB_COMMON_CLK_RST_VH
`define TB_COMMON_CLK_RST_VH

always #5.0 clk = ~clk;   // 10ns period == 100MHz nominal (arch.md CLK-001)

task tb_reset;
    begin
        rst_n <= 1'b0;
        repeat (5) @(posedge clk);   // >= ASM-001 (2 cycles) minimum assert
        rst_n <= 1'b1;
        @(posedge clk);
    end
endtask

`endif // TB_COMMON_CLK_RST_VH
