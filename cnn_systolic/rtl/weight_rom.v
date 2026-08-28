//---------------------------------------------------------------------
// Module      : weight_rom
// Project     : cnn_systolic        Technology : Sky130 130 nm
// Traces      : REQ-028, REQ-039, REQ-040, BLK-014
// Description : BF16 weight storage, 26,698 × 16, loaded from
//               WEIGHTS_HEX_FILE (arch/golden_model/weights_bf16.hex —
//               the identical converted values the golden consumes,
//               ASM-009).  8 parallel read ports (the array's 8 banks —
//               free flat addressing; the arch's "bank = addr%8,
//               offset = addr/8" interleave is a PHYSICAL arrangement
//               that does not change values, systolic_dataflow.md §6)
//               + 1 serial port (FC weight reads + bias staging).
//               Registered single-cycle reads.  MEM-001.
//               OI-001: SRAM-macro mapping is a backend decision; this
//               RTL is the behavioral body (sim) — the gate flow uses
//               the synth bbox stub (see synth/README.md).
// Clock/Reset : clk (CD_CORE, 100 MHz) / rst_n (fully synchronous —
//               read data registers reset to 0; contents via $readmemh)
// Assumptions : WEIGHTS_HEX_FILE binds at vvp runtime.
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module weight_rom #(
    parameter WEIGHTS_HEX_FILE = "arch/golden_model/weights_bf16.hex"
) (
    input  wire         clk,          // CD_CORE clock, 100 MHz
    input  wire         rst_n,        // fully synchronous active-low reset
    // IFI-008 parallel ports (8 banks, flat word addresses 0..26697)
    // Port b = wp_addr[15*b +: 15] / wp_data[16*b +: 16] (flattened for
    // iverilog -g2005; unpacked array ports are SV-only in this build).
    input  wire [119:0] wp_addr,
    output reg  [127:0] wp_data,
    // IFI-012 serial port (FC reads + bias staging)
    input  wire [14:0]  ws_addr,
    output reg  [15:0]  ws_data
);

    // MEM-001 : 26,698 x 16 BF16 weight ROM.
    reg [15:0] mem [0:26697];

    // Sole permitted initial block (guidelines §14): ROM initialisation.
    initial $readmemh(WEIGHTS_HEX_FILE, mem);

    genvar b;
    generate
        for (b = 0; b < 8; b = b + 1) begin : g_bank
            always @(posedge clk) begin
                if (!rst_n) wp_data[16*b +: 16] <= 16'd0;
                else        wp_data[16*b +: 16] <= mem[wp_addr[15*b +: 15]];
            end
        end
    endgenerate

    always @(posedge clk) begin
        if (!rst_n) ws_data <= 16'd0;
        else        ws_data <= mem[ws_addr];
    end

endmodule

`default_nettype wire
