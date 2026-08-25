`timescale 1ns / 1ps
`default_nettype none
module fv_min2;
    reg clk_core = 1'b0;
    reg rst_n    = 1'b0;
    reg        psel = 0, penable = 0, pwrite = 0;
    reg  [31:0] paddr = 0, pwdata = 0;
    reg        s_valid = 0, s_last = 0;
    reg  [7:0] s_data = 0;
    learn_accel #(.FEATURES(4),.HIDDEN(4),.CLASSES(2)) dut (
        .clk_core(clk_core), .rst_n(rst_n),
        .psel(psel), .penable(penable), .pwrite(pwrite),
        .paddr(paddr), .pwdata(pwdata), .prdata(), .pready(), .pslverr(),
        .s_valid(s_valid), .s_ready(), .s_data(s_data), .s_last(s_last));
    always @(posedge clk_core) begin
        if ($initstate) assume (rst_n == 1'b0);
        if (rst_n && !$initstate) begin
            if (dut.sample_valid) assert (!dut.s_ready);
        end
    end
endmodule
