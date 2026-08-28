// auto-generated: golden FP directed vectors -> RTL unit test (fe-rtl P2)
`timescale 1ns / 1ps
module fp_unit_test;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    integer errors = 0;
    integer v;
    reg [2:0] kind;
    reg [31:0] a, b;
    reg [31:0] dout;
    reg [31:0] want;
    wire [15:0] y_bf16;
    wire [31:0] y_add, y_mul, y_sig;
    wire [8:0]  y_s256;
    fpu_bf16_round u0 (.a(a), .y(y_bf16));
    fpu_fp32_add   u1 (.a(a), .b(b), .y(y_add));
    fpu_fp32_mul   u2 (.a(a), .b(b), .y(y_mul));
    fpu_sigmoid    u3 (.z(a), .sigma(y_sig));
    fpu_sigma256   u4 (.sigma(a), .y(y_s256));
    initial begin
        for (v = 0; v < 70; v = v + 1) begin
            #1;
            case (v)
                0: begin kind <= 3'd0; a <= 32'h3f800000; b <= 32'h00000000; end
                1: begin kind <= 3'd0; a <= 32'h3f000000; b <= 32'h00000000; end
                2: begin kind <= 3'd0; a <= 32'h3e800000; b <= 32'h00000000; end
                3: begin kind <= 3'd0; a <= 32'h3f810000; b <= 32'h00000000; end
                4: begin kind <= 3'd0; a <= 32'h3f808080; b <= 32'h00000000; end
                5: begin kind <= 3'd0; a <= 32'h3f818000; b <= 32'h00000000; end
                6: begin kind <= 3'd0; a <= 32'h3f848000; b <= 32'h00000000; end
                7: begin kind <= 3'd0; a <= 32'h3f858000; b <= 32'h00000000; end
                8: begin kind <= 3'd0; a <= 32'hbfc00000; b <= 32'h00000000; end
                9: begin kind <= 3'd0; a <= 32'h00001000; b <= 32'h00000000; end
                10: begin kind <= 3'd0; a <= 32'h80000000; b <= 32'h00000000; end
                11: begin kind <= 3'd0; a <= 32'h00800000; b <= 32'h00000000; end
                12: begin kind <= 3'd0; a <= 32'h437f0000; b <= 32'h00000000; end
                13: begin kind <= 3'd0; a <= 32'h3f7fffff; b <= 32'h00000000; end
                14: begin kind <= 3'd0; a <= 32'h00000000; b <= 32'h00000000; end
                15: begin kind <= 3'd1; a <= 32'h3f800000; b <= 32'h3e800000; end
                16: begin kind <= 3'd1; a <= 32'h3f800000; b <= 32'hbf800000; end
                17: begin kind <= 3'd1; a <= 32'h3f800000; b <= 32'h33800001; end
                18: begin kind <= 3'd1; a <= 32'h3f800000; b <= 32'h33800000; end
                19: begin kind <= 3'd1; a <= 32'h3f800000; b <= 32'hbf7fffff; end
                20: begin kind <= 3'd1; a <= 32'h3f800000; b <= 32'h3f800000; end
                21: begin kind <= 3'd1; a <= 32'h00c00000; b <= 32'h80800000; end
                22: begin kind <= 3'd1; a <= 32'h3fc00000; b <= 32'h3f000000; end
                23: begin kind <= 3'd1; a <= 32'h3f800000; b <= 32'h3f000000; end
                24: begin kind <= 3'd1; a <= 32'h3f800000; b <= 32'h40000000; end
                25: begin kind <= 3'd2; a <= 32'h3fc00000; b <= 32'h3f000000; end
                26: begin kind <= 3'd2; a <= 32'h40000000; b <= 32'h40400000; end
                27: begin kind <= 3'd2; a <= 32'hc0000000; b <= 32'h40400000; end
                28: begin kind <= 3'd2; a <= 32'h1b800000; b <= 32'h1b800000; end
                29: begin kind <= 3'd2; a <= 32'h3fa00000; b <= 32'h3fa00000; end
                30: begin kind <= 3'd2; a <= 32'h3f800000; b <= 32'h3f800000; end
                31: begin kind <= 3'd3; a <= 32'h00000000; b <= 32'h00000000; end
                32: begin kind <= 3'd3; a <= 32'h3e800000; b <= 32'h00000000; end
                33: begin kind <= 3'd3; a <= 32'h3f000000; b <= 32'h00000000; end
                34: begin kind <= 3'd3; a <= 32'h3f800000; b <= 32'h00000000; end
                35: begin kind <= 3'd3; a <= 32'h3fc00000; b <= 32'h00000000; end
                36: begin kind <= 3'd3; a <= 32'h40000000; b <= 32'h00000000; end
                37: begin kind <= 3'd3; a <= 32'h40800000; b <= 32'h00000000; end
                38: begin kind <= 3'd3; a <= 32'h41000000; b <= 32'h00000000; end
                39: begin kind <= 3'd3; a <= 32'hbf000000; b <= 32'h00000000; end
                40: begin kind <= 3'd3; a <= 32'hc1000000; b <= 32'h00000000; end
                41: begin kind <= 3'd3; a <= 32'h40c00000; b <= 32'h00000000; end
                42: begin kind <= 3'd3; a <= 32'h3e000000; b <= 32'h00000000; end
                43: begin kind <= 3'd3; a <= 32'h3e400000; b <= 32'h00000000; end
                44: begin kind <= 3'd3; a <= 32'h3f400000; b <= 32'h00000000; end
                45: begin kind <= 3'd3; a <= 32'h3fa00000; b <= 32'h00000000; end
                46: begin kind <= 3'd4; a <= 32'h3f000000; b <= 32'h00000000; end
                47: begin kind <= 3'd4; a <= 32'h3f200000; b <= 32'h00000000; end
                48: begin kind <= 3'd4; a <= 32'h3f7d6000; b <= 32'h00000000; end
                49: begin kind <= 3'd4; a <= 32'h3f800000; b <= 32'h00000000; end
                50: begin kind <= 3'd4; a <= 32'h3d800000; b <= 32'h00000000; end
                51: begin kind <= 3'd4; a <= 32'h3f7b0000; b <= 32'h00000000; end
                52: begin kind <= 3'd4; a <= 32'h00000000; b <= 32'h00000000; end
                53: begin kind <= 3'd5; a <= 32'h000000c8; b <= 32'h00000012; end
                54: begin kind <= 3'd5; a <= 32'h0000007f; b <= 32'h00000012; end
                55: begin kind <= 3'd5; a <= 32'h00000080; b <= 32'h00000012; end
                56: begin kind <= 3'd5; a <= 32'h00000100; b <= 32'h00000055; end
                57: begin kind <= 3'd5; a <= 32'h00000000; b <= 32'h00000000; end
                58: begin kind <= 3'd5; a <= 32'h00000064; b <= 32'h00000021; end
                59: begin kind <= 3'd3; a <= 32'h40600000; b <= 32'h00000000; end
                60: begin kind <= 3'd3; a <= 32'h41600000; b <= 32'h00000000; end
                61: begin kind <= 3'd3; a <= 32'h41a00000; b <= 32'h00000000; end
                62: begin kind <= 3'd3; a <= 32'h42000000; b <= 32'h00000000; end
                63: begin kind <= 3'd1; a <= 32'h3f000000; b <= 32'hbfc00000; end
                64: begin kind <= 3'd1; a <= 32'hbfc00000; b <= 32'hbf000000; end
                65: begin kind <= 3'd6; a <= 32'h0a000064; b <= 32'h00000000; end
                66: begin kind <= 3'd6; a <= 32'h000a0a64; b <= 32'h00000000; end
                67: begin kind <= 3'd6; a <= 32'h64646463; b <= 32'h00000000; end
                68: begin kind <= 3'd6; a <= 32'h00000000; b <= 32'h00000000; end
                69: begin kind <= 3'd6; a <= 32'h64640100; b <= 32'h00000000; end
                default: ;
            endcase
            @(posedge clk); #1;
            case (kind)
                3'd0: dout <= {16'd0, y_bf16};
                3'd1: dout <= y_add;
                3'd2: dout <= y_mul;
                3'd3: dout <= y_sig;
                3'd4: dout <= {23'd0, y_s256};
                3'd5: begin // conf/verdict: conf=(a*100)>>8; verdict
                    dout <= (((a*100)>>8) << 2) | ((((a*100)>>8) < 50) ? 2'd2 : ((b[7:4] == b[3:0]) ? 2'd0 : 2'd1));
                end
                3'd6: begin // argmax4: a = {s3,s2,s1,s0}
                    if (a[31:24] > a[23:16] && a[31:24] > a[15:8] && a[31:24] > a[7:0]) dout <= (4'd3 << 8) | a[31:24];
                    else if (a[23:16] > a[15:8] && a[23:16] > a[7:0]) dout <= (4'd2 << 8) | a[23:16];
                    else if (a[15:8] > a[7:0]) dout <= (4'd1 << 8) | a[15:8];
                    else dout <= (4'd0 << 8) | a[7:0];
                end
            endcase
            case (v)
                0: want <= 32'h00003f80;
                1: want <= 32'h00003f00;
                2: want <= 32'h00003e80;
                3: want <= 32'h00003f81;
                4: want <= 32'h00003f81;
                5: want <= 32'h00003f82;
                6: want <= 32'h00003f84;
                7: want <= 32'h00003f86;
                8: want <= 32'h0000bfc0;
                9: want <= 32'h00000000;
                10: want <= 32'h00008000;
                11: want <= 32'h00000080;
                12: want <= 32'h0000437f;
                13: want <= 32'h00003f80;
                14: want <= 32'h00000000;
                15: want <= 32'h3fa00000;
                16: want <= 32'h00000000;
                17: want <= 32'h3f800001;
                18: want <= 32'h3f800000;
                19: want <= 32'h33800000;
                20: want <= 32'h40000000;
                21: want <= 32'h00000000;
                22: want <= 32'h40000000;
                23: want <= 32'h3fc00000;
                24: want <= 32'h40400000;
                25: want <= 32'h3f400000;
                26: want <= 32'h40c00000;
                27: want <= 32'hc0c00000;
                28: want <= 32'h00000000;
                29: want <= 32'h3fc80000;
                30: want <= 32'h3f800000;
                31: want <= 32'h3f000000;
                32: want <= 32'h3f1a0000;
                33: want <= 32'h3f2a0000;
                34: want <= 32'h3f400000;
                35: want <= 32'h3f4d0000;
                36: want <= 32'h3f560000;
                37: want <= 32'h3f660000;
                38: want <= 32'h3f720000;
                39: want <= 32'h3eac0000;
                40: want <= 32'h3d600000;
                41: want <= 32'h3f6e0000;
                42: want <= 32'h3f0d0000;
                43: want <= 32'h3f138000;
                44: want <= 32'h3f370000;
                45: want <= 32'h3f468000;
                46: want <= 32'h00000080;
                47: want <= 32'h000000a0;
                48: want <= 32'h000000fd;
                49: want <= 32'h00000100;
                50: want <= 32'h00000010;
                51: want <= 32'h000000fb;
                52: want <= 32'h00000000;
                53: want <= 32'h00000139;
                54: want <= 32'h000000c6;
                55: want <= 32'h000000c9;
                56: want <= 32'h00000190;
                57: want <= 32'h00000002;
                58: want <= 32'h0000009e;
                59: want <= 32'h3f630000;
                60: want <= 32'h3f778000;
                61: want <= 32'h3f7a0000;
                62: want <= 32'h3f7b0000;
                63: want <= 32'hbf800000;
                64: want <= 32'hc0000000;
                65: want <= 32'h00000064;
                66: want <= 32'h00000064;
                67: want <= 32'h00000164;
                68: want <= 32'h00000000;
                69: want <= 32'h00000264;
                default: ;
            endcase
            @(posedge clk); #1;
            if (dout !== want) begin
                $display("FAIL VEC %0d k=%0d din=0x%08X_%08X got=0x%08X want=0x%08X", v, kind, a, b, dout, want);
                errors = errors + 1;
            end
        end
        if (errors == 0) $display("PASS fp_unit_test: 70/70 golden FP vectors bit-exact");
        else $display("FAIL fp_unit_test: %0d/70 mismatches", errors);
        $finish;
    end
endmodule
