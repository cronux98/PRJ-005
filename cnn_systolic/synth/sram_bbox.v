//---------------------------------------------------------------------
// Module      : sram_bbox (synth stub)
// Project     : cnn_systolic        Technology : Sky130 130 nm
// Traces      : REQ-040, OI-001/OI-003 resolution
// Description : SYNTHESIS BLACKBOX STUB for the sram memory body.
//               Same module name + ports as the behavioral RTL body so
//               the top instantiations bind with ZERO RTL edits.  The
//               gate netlist keeps this cell opaque (memory timing is a
//               backend/OpenRAM concern — real sky130 SRAM macros land
//               at PnR; the front-end STA treats memories as untimed
//               boundaries, fe-opensta practice).  Simulation uses the
//               REAL body from filelist.f.
// Source      : custom (fe-rtl P2)
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module sram  (
        output  sram_awready,
        output  sram_wready,
        output  sram_bvalid,
        output  sram_arready,
        output  sram_rvalid,
        output [31:0] sram_rdata,
        input  clk,
        input  rst_n,
        input  sram_awvalid,
        input  sram_wvalid,
        input  sram_bready,
        input  sram_arvalid,
        input  sram_rready,
        input [31:0] sram_awaddr,
        input [31:0] sram_wdata,
        input [31:0] sram_araddr,
        input [2:0] sram_awprot,
        input [2:0] sram_arprot,
        input [3:0] sram_wstrb
);

    /* blackbox */

endmodule

`default_nettype wire
