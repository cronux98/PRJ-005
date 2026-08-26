//---------------------------------------------------------------------
// Module      : apb_gpio
// Project     : cnn_soc                Technology : FPGA-generic (NOT Sky130 — spec.md §2.1)
// Traces      : REQ-006, REQ-030, REQ-015, REQ-026, BLK-008
// Description : APB GPIO peripheral. Single 12-bit RW GPIO_OUT register at
//               0x4000_1000 driving top-level led[11:0] (arch.md §4 BLK-008,
//               §7.3). Any APB write (address ignored — the bridge selects
//               this slave only for its 4-byte region) loads PWDATA[11:0] into
//               led; reads return {20'b0, led}. Zero-wait slave (PREADY==1).
// Clock/Reset : clk (CD_CORE, 100 MHz) / rst_n (fully SYNCHRONOUS active-low — no async)
// Assumptions : Bridge asserts psel only for 0x4000_1000..0x4000_1003, so the
//               word-aligned paddr need not be decoded (arch.md §4 BLK-008).
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module apb_gpio (
    input  wire        clk,      // core clock (CD_CORE, 100 MHz)
    input  wire        rst_n,    // fully synchronous active-low reset
    input  wire        psel,     // APB select (bridge asserts only for this region)
    input  wire        penable,  // APB enable (ACCESS phase)
    input  wire        pwrite,   // APB write when 1, read when 0
    input  wire [11:0] paddr,    // word-aligned APB address within this region (unused — single reg)
    input  wire [31:0] pwdata,   // APB write data
    output reg  [31:0] prdata,   // combinational read mux
    output wire        pready,   // zero-wait slave: always 1
    output reg  [11:0] led       // 12-bit LED output to top pin (GPIO_OUT)
);

    // Zero-wait slave: response always ready (arch.md §4 BLK-008).
    assign pready = 1'b1;

    // GPIO_OUT register (sole flop). Any write in the ACCESS phase loads the
    // low 12 bits of PWDATA; address ignored per arch.md §4 BLK-008. Fully
    // synchronous active-low reset (guidelines §3).
    always @(posedge clk) begin
        if (!rst_n)                        led <= 12'd0;
        else if (psel && penable && pwrite) led <= pwdata[11:0];
        else                                led <= led;
    end

    // Combinational read mux: {20'b0, led} (arch.md §5 GPIO_OUT read). No
    // latch — prdata is assigned unconditionally each evaluation.
    always @* begin
        prdata = {20'd0, led};
    end

endmodule

`default_nettype wire
