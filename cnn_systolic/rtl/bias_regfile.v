//---------------------------------------------------------------------
// Module      : bias_regfile
// Project     : cnn_systolic        Technology : Sky130 130 nm
// Traces      : REQ-039, BLK-011, MEM-005
// Description : 66 × 16 BF16 bias staging register file (MEM-005):
//               conv1_b 8 (idx 0..7) | conv2_b 16 (8..23) |
//               fc1_b 32 (24..55) | fc2_b 10 (56..65).  Staged once per
//               layer start by conv_ctrl (serial reads from the weight
//               ROM, 1 word/cycle).  Combinational read ports: 8 array
//               ports (one per PE row, driven by conv_ctrl) + 1 FC port
//               (driven by fc_datapath).
// Clock/Reset : clk (CD_CORE, 100 MHz) / rst_n (fully synchronous —
//               all entries 0)
// Assumptions : staged before first use (layer schedule).
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module bias_regfile (
    input  wire        clk,          // CD_CORE clock, 100 MHz
    input  wire        rst_n,        // fully synchronous active-low reset
    // staging write port
    input  wire [6:0]  w_idx,        // 0..65
    input  wire [15:0] w_data,
    input  wire        w_en,
    // 8 array read ports (row r = PE row r's bias) — flattened for iverilog
    // -g2005: port r = a_idx[7*r +: 7] / a_data[16*r +: 16].
    input  wire [55:0]  a_idx,
    output wire [127:0] a_data,
    // FC read port
    input  wire [6:0]   fc_idx,
    output wire [15:0]  fc_data
);

    reg [15:0] regs [0:65];

    // RESET-EXEMPT: every entry is staged (w_en) at its layer start before
    // first read (conv1 8, conv2 16, fc1 32, fc2 10 = 66 per inference), so
    // the park-reset term is omitted (removes ~1k flops from the core_rst_n
    // fanout tree; P4 timing fix).
    always @(posedge clk) begin
        if (w_en) regs[w_idx] <= w_data;
    end

    genvar r;
    generate
        for (r = 0; r < 8; r = r + 1) begin : g_rd
            assign a_data[16*r +: 16] = regs[a_idx[7*r +: 7]];
        end
    endgenerate

    assign fc_data = regs[fc_idx];

endmodule

`default_nettype wire
