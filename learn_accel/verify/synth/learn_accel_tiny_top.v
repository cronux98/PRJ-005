//---------------------------------------------------------------------
// learn_accel_tiny_top.v — synthesis/equiv wrapper: learn_accel at the
// tiny config (4x4x2). The weight RAM (25,450x16 at defaults = 407 kbit)
// is the OI-001 SRAM-macro boundary; the tiny config makes the FF-array
// gate flow tractable while keeping the control logic representative.
// Test-side file (verify/synth/) — the source RTL is untouched.
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module learn_accel_tiny_top (
    input  wire        clk_core,
    input  wire        rst_n,
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire [31:0] paddr,
    input  wire [31:0] pwdata,
    output wire [31:0] prdata,
    output wire        pready,
    output wire        pslverr,
    input  wire        s_valid,
    output wire        s_ready,
    input  wire [7:0]  s_data,
    input  wire        s_last
);
    learn_accel #(.FEATURES(4), .HIDDEN(4), .CLASSES(2)) u_dut (
        .clk_core (clk_core), .rst_n (rst_n),
        .psel (psel), .penable (penable), .pwrite (pwrite),
        .paddr (paddr), .pwdata (pwdata), .prdata (prdata),
        .pready (pready), .pslverr (pslverr),
        .s_valid (s_valid), .s_ready (s_ready), .s_data (s_data), .s_last (s_last)
    );
endmodule

`default_nettype wire
