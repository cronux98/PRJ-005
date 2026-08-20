//---------------------------------------------------------------------
// tb_common/clk_rst.vh — reusable clock/reset generation
// Project  : rinriAI (PRJ-005) verification infrastructure
// Language : pure Verilog-2001 (include file, ifndef-guarded)
// Purpose  : 50 MHz clock + synchronous active-low reset task (20-cycle
//            assert per ASM-002 min 16). TB declares `reg clk_core =
//            1'b0;` and `reg rst_n;` before including; the clock always
//            block starts on the include.
//---------------------------------------------------------------------
`ifndef TB_COMMON_CLK_RST_VH
`define TB_COMMON_CLK_RST_VH

// 50 MHz: 10 ns half period.
always #10.0 clk_core = ~clk_core;

task tb_reset;
    begin
        rst_n <= 1'b0;
        repeat (20) @(posedge clk_core);   // >= 16 cycles assert
        rst_n <= 1'b1;
        @(posedge clk_core);
    end
endtask

`endif // TB_COMMON_CLK_RST_VH
