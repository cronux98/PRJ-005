//---------------------------------------------------------------------
// Module      : weight_rom_bbox (synth stub)
// Project     : cnn_systolic        Technology : Sky130 130 nm
// Traces      : REQ-040, OI-001/OI-003 resolution
// Description : SYNTHESIS BLACKBOX STUB for the weight_rom memory body.
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

module weight_rom #(
    parameter WEIGHTS_HEX_FILE = "arch/golden_model/weights_bf16.hex"
) (
    input  wire         clk,
    input  wire         rst_n,
    // flattened 8-port interface (port b = [15b +: 15] / [16b +: 16])
    input  wire [119:0] wp_addr,
    output wire [127:0] wp_data,
    input  wire [14:0]  ws_addr,
    output wire [15:0]  ws_data
);

    /* blackbox */

endmodule

`default_nettype wire
