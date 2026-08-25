//---------------------------------------------------------------------
// tests/tb_sigmoid_lut_unit.v — VP-LUT-002: boundary address spot checks
// Traces  : REQ-006
// Note    : VP-LUT-001 (exhaustive 65536/65536 bit-exactness) is proven
//           by tools/check_lut.py (already part of the fe-rtl exit gate
//           per WORKLOG.md; re-run by scripts/run_tests.sh as an
//           independent Python-side re-verification of the same
//           frozen rtl/sigmoid_lut.hex this module $readmemh's).
//           sigma(z) = 128 + trunc(128*z/(256+|z|)):
//             z=0x0000 (z=0)      -> sigma=128
//             z=0x7FFF (z=32767)  -> sigma=255
//             z=0x8000 (z=-32768) -> sigma=1
//             z=0xFFFF (z=-1)     -> sigma=128 (truncation flattens -1 and 0)
//---------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_sigmoid_lut_unit;
    reg clk = 1'b0;
    reg rst_n;
    integer errors = 0;

    `include "verify/tb_common/clk_rst.vh"
    `include "verify/tb_common/checker.vh"

    reg  [15:0] addr;
    wire [7:0]  rdata;

    sigmoid_lut u_lut (.clk(clk), .rst_n(rst_n), .addr(addr), .rdata(rdata));

    task check_addr;
        input [15:0] a;
        input [7:0]  want;
        input [255:0] name;
        begin
            addr = a;
            @(posedge clk);
            #1;
            check_eq({24'd0, rdata}, {24'd0, want}, name);
        end
    endtask

    initial begin
        tb_reset;
        check_addr(16'h0000, 8'd128, "VP-LUT-002: z=0x0000 (z=0) -> sigma=128");
        check_addr(16'h7FFF, 8'd255, "VP-LUT-002: z=0x7FFF (z=32767) -> sigma=255");
        check_addr(16'h8000, 8'd1,   "VP-LUT-002: z=0x8000 (z=-32768) -> sigma=1");
        check_addr(16'hFFFF, 8'd128, "VP-LUT-002: z=0xFFFF (z=-1) -> sigma=128 (truncation flattens -1,0)");
        test_summary("tb_sigmoid_lut_unit");
        $finish;
    end
endmodule
