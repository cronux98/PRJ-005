//---------------------------------------------------------------------
// Module      : image_buffer
// Project     : cnn_soc                Technology : FPGA-generic (NOT Sky130 — spec.md §2.1)
// Traces      : REQ-020, REQ-030, BLK-011
// Description : 784 x 8-bit CPU-writable image buffer replacing image_rom
//               inside cnn_infer. Core read port keeps the exact 1-cycle
//               registered read timing of image_rom.v so ctrl_fsm ADDR->ACC
//               timing is preserved; CPU write port (from cnn_axi_slave)
//               loads the pixel bytes before each START.
// Clock/Reset : clk (CD_CORE, 100 MHz) / rst_n (fully SYNCHRONOUS active-low — no async)
// Assumptions : raddr,waddr always in [0,783] by construction (arch.md §4 BLK-011);
//               CPU never writes while the core reads, so same-address
//               read/write collisions (resolved READ-FIRST / old data) are
//               harmless by construction. Buffer contents are written before
//               every START and are therefore not reset (MEM-004).
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module image_buffer (
    input  wire         clk,        // core clock, 100 MHz
    input  wire         rst_n,      // synchronous active-low reset
    input  wire [9:0]   raddr,      // core read address 0..783
    output reg  [7:0]   rdata,      // registered read data, 1-cycle latency
    input  wire [9:0]   waddr,      // CPU write address 0..783 (cnn_axi_slave)
    input  wire [7:0]   wdata,      // CPU write data (pixel byte)
    input  wire         we          // CPU write enable
);
    // MEM-004: 784 x 8 storage; contents NOT reset (written before use).
    // NOTE: named img_mem (not the arch's "buf") because buf is a reserved
    // Verilog primitive-gate keyword (iverilog syntax error). The arch.md
    // §12 verification probe becomes u_cnn_infer.u_image_buffer.img_mem.
    reg [7:0] img_mem [0:783];

    // Single synchronous block: CPU write path (contents unreset) plus the
    // reset-able read-output register (image_rom.v:27-30 pattern). Read of
    // img_mem[raddr] uses the pre-write value (READ-FIRST) on same-address collision.
    always @(posedge clk) begin
        if (we) img_mem[waddr] <= wdata;          // CPU pixel write — contents not reset
        if (!rst_n) rdata <= 8'd0;                // read-output register reset
        else        rdata <= img_mem[raddr];      // registered 1-cycle read
    end
endmodule

`default_nettype wire
