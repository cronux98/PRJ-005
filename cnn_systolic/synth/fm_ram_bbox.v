//---------------------------------------------------------------------
// Module      : fm_ram_bbox (synth stub)
// Project     : cnn_systolic        Technology : Sky130 130 nm
// Traces      : REQ-040, OI-001/OI-003 resolution
// Description : SYNTHESIS BLACKBOX STUB for the fm_ram memory body.
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

module fm_ram  (
        output [15:0] rdata,
        input  clk,
        input  rst_n,
        input [12:0] raddr,
        input [12:0] waddr,
        input [15:0] wdata,
        input  we
);

    /* blackbox */

endmodule

`default_nettype wire
