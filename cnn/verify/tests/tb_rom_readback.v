//---------------------------------------------------------------------
// tests/tb_rom_readback.v — VP-ROM-001: content fidelity of weight_rom /
// image_rom / label_rom against their source .hex files.
// Traces  : REQ-012, REQ-013, REQ-014
// Method  : Independently $readmemh the SAME frozen hex files into
//           reference arrays inside this TB (no relation to the RTL's
//           own `rom` arrays other than the golden hex source), then
//           drive addr=0..N-1 sequentially through each ROM's real
//           clocked read port and compare the returned data (1-cycle
//           latency) against the reference array — a genuine port-
//           level readback of every word, not a hierarchical peek.
//---------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_rom_readback;
    reg clk = 1'b0;
    reg rst_n;
    integer errors = 0;

    `include "verify/tb_common/clk_rst.vh"
    `include "verify/tb_common/checker.vh"

    // ---- weight_rom: 25,450 x 16-bit signed ----
    reg [14:0]        waddr;
    wire signed [15:0] wdata;
    reg  signed [15:0] wref [0:26697];
    initial $readmemh("arch/golden_model/weights.hex", wref);

    weight_rom u_wrom (.clk(clk), .rst_n(rst_n), .addr(waddr), .rdata(wdata));

    // ---- image_rom: 78,400 x 8-bit unsigned ----
    reg [16:0] iaddr;
    wire [7:0] idata;
    reg [7:0]  iref [0:78399];
    initial $readmemh("arch/golden_model/images.hex", iref);

    image_rom u_irom (.clk(clk), .rst_n(rst_n), .addr(iaddr), .rdata(idata));

    // ---- label_rom: 100 x 8-bit unsigned ----
    reg [6:0] laddr;
    wire [7:0] ldata;
    reg [7:0]  lref [0:99];
    initial $readmemh("arch/golden_model/labels.hex", lref);

    label_rom u_lrom (.clk(clk), .rst_n(rst_n), .addr(laddr), .rdata(ldata));

    integer i;
    initial begin
        tb_reset;

        // weight_rom: full 25,450-word readback
        for (i = 0; i < 26698; i = i + 1) begin
            waddr = i[14:0];
            @(posedge clk);
            #1;
            check_eq({16'd0, wdata}, {16'd0, wref[i]}, "VP-ROM-001: weight_rom word");
        end

        // image_rom: full 78,400-word readback
        for (i = 0; i < 78400; i = i + 1) begin
            iaddr = i[16:0];
            @(posedge clk);
            #1;
            check_eq({24'd0, idata}, {24'd0, iref[i]}, "VP-ROM-001: image_rom word");
        end

        // label_rom: full 100-word readback
        for (i = 0; i < 100; i = i + 1) begin
            laddr = i[6:0];
            @(posedge clk);
            #1;
            check_eq({24'd0, ldata}, {24'd0, lref[i]}, "VP-ROM-001: label_rom word");
        end

        test_summary("tb_rom_readback");
        $finish;
    end
endmodule
