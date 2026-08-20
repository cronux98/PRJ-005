//---------------------------------------------------------------------
// tb_common/apb4_bfm.vh — reusable APB4 master BFM + scoreboard tasks
// Project  : rinriAI (PRJ-005) verification infrastructure
// Language : pure Verilog-2001 (include file, ifndef-guarded)
// Purpose  : Drive the APB4 slave (IF-001) with zero-wait single
//            transfers. Timing (matches tb/tb_learn_accel.v and the DUT's
//            combinational decode):
//              posedge A: drive psel=1, penable=0   -> SETUP   [A,B)
//              posedge B: drive penable=1            -> ACCESS  [B,C)
//              posedge C: DUT samples pwrite/paddr/pwdata (commit);
//                         BFM samples prdata/pready/pslverr, deasserts
//            Supports back-to-back, idle-gap, read-only, reserved-address
//            error injection (PSLVERR), and side-effect verification.
// Usage    : TB declares (regs for driven, wires for observed):
//            apb_psel, apb_penable, apb_pwrite, apb_paddr, apb_pwdata,
//            apb_prdata, apb_pready, apb_pslverr, plus `errors` and
//            check_eq1 from tb_common/checker.vh.
//---------------------------------------------------------------------
`ifndef TB_COMMON_APB4_BFM_VH
`define TB_COMMON_APB4_BFM_VH

// One zero-wait APB4 write. PREADY=1 in ACCESS, PSLVERR=0 (mapped addr).
task apb_write;
    input [31:0] addr;
    input [31:0] data;
    begin
        @(posedge clk_core);                 // A: SETUP
        apb_psel    <= 1'b1;
        apb_penable <= 1'b0;
        apb_pwrite  <= 1'b1;
        apb_paddr   <= addr;
        apb_pwdata  <= data;
        @(posedge clk_core);                 // B: ACCESS
        apb_penable <= 1'b1;
        @(posedge clk_core);                 // C: commit edge
        if (apb_pready !== 1'b1) begin
            $display("FAIL apb_write: pready not high in ACCESS @%0t", $time);
            errors = errors + 1;
        end
        if (apb_pslverr !== 1'b0) begin
            $display("FAIL apb_write: unexpected pslverr on addr 0x%08X @%0t", addr, $time);
            errors = errors + 1;
        end
        apb_psel    <= 1'b0;
        apb_penable <= 1'b0;
        apb_pwrite  <= 1'b0;
    end
endtask

// One zero-wait APB4 read: prdata sampled in the ACCESS phase (posedge C).
task apb_read;
    input  [31:0] addr;
    output [31:0] data;
    begin
        @(posedge clk_core);                 // A: SETUP
        apb_psel    <= 1'b1;
        apb_penable <= 1'b0;
        apb_pwrite  <= 1'b0;
        apb_paddr   <= addr;
        @(posedge clk_core);                 // B: ACCESS
        apb_penable <= 1'b1;
        @(posedge clk_core);                 // C: sample
        if (apb_pready !== 1'b1) begin
            $display("FAIL apb_read: pready not high in ACCESS @%0t", $time);
            errors = errors + 1;
        end
        if (apb_pslverr !== 1'b0) begin
            $display("FAIL apb_read: unexpected pslverr on addr 0x%08X @%0t", addr, $time);
            errors = errors + 1;
        end
        data = apb_prdata;
        apb_psel    <= 1'b0;
        apb_penable <= 1'b0;
    end
endtask

// Reserved-address access: expect PSLVERR=1 in ACCESS, no side effect.
// mode: 0 = read, 1 = write. Returns (for reads) prdata (must be 0).
task apb_access_expect_err;
    input        mode;
    input [31:0] addr;
    input [31:0] data;
    output[31:0] rdata;
    begin
        @(posedge clk_core);                 // A: SETUP
        apb_psel    <= 1'b1;
        apb_penable <= 1'b0;
        apb_pwrite  <= mode;
        apb_paddr   <= addr;
        apb_pwdata  <= data;
        @(posedge clk_core);                 // B: ACCESS
        apb_penable <= 1'b1;
        @(posedge clk_core);                 // C: check
        if (apb_pready !== 1'b1) begin
            $display("FAIL err-inject: pready not high in ACCESS @%0t", $time);
            errors = errors + 1;
        end
        if (apb_pslverr !== 1'b1) begin
            $display("FAIL err-inject: pslverr NOT asserted for addr 0x%08X @%0t", addr, $time);
            errors = errors + 1;
        end
        rdata = apb_prdata;
        apb_psel    <= 1'b0;
        apb_penable <= 1'b0;
        apb_pwrite  <= 1'b0;
    end
endtask

// Back-to-back write: psel held high; the next SETUP starts right after
// the previous ACCESS (caller drives the first SETUP itself, or uses
// apb_write_bb_first). Caller must deassert psel at the end via apb_idle_gap.
task apb_write_bb;
    input [31:0] addr;
    input [31:0] data;
    begin
        @(posedge clk_core);                 // next SETUP (psel already high)
        apb_penable <= 1'b0;
        apb_pwrite  <= 1'b1;
        apb_paddr   <= addr;
        apb_pwdata  <= data;
        @(posedge clk_core);                 // ACCESS
        apb_penable <= 1'b1;
        @(posedge clk_core);                 // commit edge
        apb_penable <= 1'b0;
    end
endtask

// Idle gap: hold the bus idle for n cycles (also deasserts psel).
task apb_idle_gap;
    input [15:0] n;
    integer g;
    begin
        apb_psel <= 1'b0; apb_penable <= 1'b0; apb_pwrite <= 1'b0;
        for (g = 0; g < n; g = g + 1) @(posedge clk_core);
    end
endtask

`endif // TB_COMMON_APB4_BFM_VH
