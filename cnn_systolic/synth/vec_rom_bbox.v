//---------------------------------------------------------------------
// Module      : vec_rom_bbox (synth stub)
// Project     : cnn_systolic        Technology : Sky130 130 nm
// Traces      : REQ-040, OI-001/OI-003 resolution
// Description : SYNTHESIS BLACKBOX STUB for the vec_rom memory body.
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

module vec_rom #(
        parameter IMAGES_HEX_FILE = "arch/golden_model/stimulus.hex", parameter LABELS_HEX_FILE = "arch/golden_model/labels.hex"
    ) (
        output  vec_awready,
        output  vec_wready,
        output  vec_bvalid,
        output  vec_arready,
        output  vec_rvalid,
        output [31:0] vec_rdata,
        input  clk,
        input  rst_n,
        input  vec_awvalid,
        input  vec_wvalid,
        input  vec_bready,
        input  vec_arvalid,
        input  vec_rready,
        input [31:0] vec_awaddr,
        input [31:0] vec_wdata,
        input [31:0] vec_araddr,
        input [2:0] vec_awprot,
        input [2:0] vec_arprot,
        input [3:0] vec_wstrb
);

    /* blackbox */

endmodule

`default_nettype wire
