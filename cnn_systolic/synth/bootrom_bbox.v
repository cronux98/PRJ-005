//---------------------------------------------------------------------
// Module      : bootrom_bbox (synth stub)
// Project     : cnn_systolic        Technology : Sky130 130 nm
// Traces      : REQ-040, OI-001/OI-003 resolution
// Description : SYNTHESIS BLACKBOX STUB for the bootrom memory body.
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

module bootrom #(
        parameter BOOT_HEX_FILE = "sw/firmware.hex"
    ) (
        output  boot_awready,
        output  boot_wready,
        output  boot_bvalid,
        output  boot_arready,
        output  boot_rvalid,
        output [31:0] boot_rdata,
        input  clk,
        input  rst_n,
        input  boot_awvalid,
        input  boot_wvalid,
        input  boot_bready,
        input  boot_arvalid,
        input  boot_rready,
        input [31:0] boot_awaddr,
        input [31:0] boot_wdata,
        input [31:0] boot_araddr,
        input [2:0] boot_awprot,
        input [2:0] boot_arprot,
        input [3:0] boot_wstrb
);

    /* blackbox */

endmodule

`default_nettype wire
