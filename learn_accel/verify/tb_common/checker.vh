//---------------------------------------------------------------------
// tb_common/checker.vh — reusable self-checking primitives
// Project  : rinriAI (PRJ-005) verification infrastructure
// Language : pure Verilog-2001 (include file, ifndef-guarded)
// Purpose  : check_eq / check_eq1 / check_cond / fail counter / summary.
//            Every TB declares `integer errors = 0;` before including.
//---------------------------------------------------------------------
`ifndef TB_COMMON_CHECKER_VH
`define TB_COMMON_CHECKER_VH

task check_eq;
    input [31:0] got;
    input [31:0] want;
    input [255:0] name;
    begin
        if (got !== want) begin
            $display("FAIL %0s: got=0x%08X want=0x%08X @%0t", name, got, want, $time);
            errors = errors + 1;
        end
    end
endtask

task check_eq1;
    input got;
    input want;
    input [255:0] name;
    begin
        if (got !== want) begin
            $display("FAIL %0s: got=%b want=%b @%0t", name, got, want, $time);
            errors = errors + 1;
        end
    end
endtask

task check_cond;
    input cond;
    input [255:0] name;
    begin
        if (!cond) begin
            $display("FAIL %0s @%0t", name, $time);
            errors = errors + 1;
        end
    end
endtask

task test_summary;
    input [255:0] tname;
    begin
        if (errors == 0) $display("PASS %0s", tname);
        else             $display("FAIL %0s: %0d errors", tname, errors);
    end
endtask

`endif // TB_COMMON_CHECKER_VH
