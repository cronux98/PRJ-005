//---------------------------------------------------------------------
// Module      : p1_banks_bbox (synth stub)
// Project     : cnn_systolic        Technology : Sky130 130 nm
// Traces      : REQ-040, OI-001/OI-003 resolution
// Description : SYNTHESIS BLACKBOX STUB for the p1_banks memory body.
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

module p1_banks  (
        output [127:0] p1_rdata,
        input  clk,
        input  rst_n,
        input [7:0] p1_waddr,
        input [7:0] p1_raddr,
        input [127:0] p1_wdata,
        input [7:0] p1_we,
        input  p1_zero
);

    /* blackbox */

endmodule

`default_nettype wire
