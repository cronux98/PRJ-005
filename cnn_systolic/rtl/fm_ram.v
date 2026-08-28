//---------------------------------------------------------------------
// Module      : fm_ram
// Project     : cnn_systolic        Technology : Sky130 130 nm
// Traces      : REQ-039, REQ-040, BLK-015
// Description : 8,192 × 16 BF16 feature-map RAM (MEM-004).  Region map
//               (arch.md §7.3): h1 0..6271, h2 0..3135 (reuses h1's
//               region), p2 6,272..7,055, h3 0..31.  Separate registered
//               read port + write port; hazard-free by construction
//               (layer FSM serialises layers — arch.md §7 proof).
//               OI-001: SRAM-macro mapping is a backend decision (gate
//               flow uses the synth bbox stub).
// Clock/Reset : clk (CD_CORE, 100 MHz) / rst_n (fully synchronous —
//               read-data register resets to 0; array contents are NOT
//               reset — written before read by the hazard-free schedule)
// Assumptions : no same-cycle read+write to the same address that needs
//               the new value (single-port semantics: read gets old).
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module fm_ram (
    input  wire         clk,          // CD_CORE clock, 100 MHz
    input  wire         rst_n,        // fully synchronous active-low reset
    // read port
    input  wire [12:0]  raddr,
    output reg  [15:0]  rdata,
    // write port
    input  wire [12:0]  waddr,
    input  wire [15:0]  wdata,
    input  wire         we
);

    reg [15:0] mem [0:8191];

    always @(posedge clk) begin
        if (!rst_n) rdata <= 16'd0;
        else        rdata <= mem[raddr];
        if (we) mem[waddr] <= wdata;
    end

endmodule

`default_nettype wire
