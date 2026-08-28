//---------------------------------------------------------------------
// Module      : p1_banks
// Project     : cnn_systolic        Technology : Sky130 130 nm
// Traces      : REQ-023, REQ-024, REQ-039, BLK-017
// Description : 8 per-channel pool1 banks (MEM-003), bank ic =
//               p1[ic][oy*14+ox], 196 used of 256.  Pool1 writes all 8
//               banks in parallel at oy*14+ox (per-channel write
//               enables); conv2 reads all 8 at the shared address
//               (oy+iy-1)*14+(ox+ix-1) with a combinational zero mux
//               (p1_zero) for out-of-range taps.  Registered 1-cycle
//               reads.  IFI-010/IFI-005.
//               OI-001: SRAM-macro mapping is a backend decision (gate
//               flow uses the synth bbox stub).
// Clock/Reset : clk (CD_CORE, 100 MHz) / rst_n (fully synchronous —
//               read-data register resets to 0; array contents written
//               by pool1 before conv2 reads them — no reset needed)
// Assumptions : pool1 writes every address 0..195 of every bank before
//               conv2 reads (hazard-free by the layer schedule).
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module p1_banks (
    input  wire         clk,          // CD_CORE clock, 100 MHz
    input  wire         rst_n,        // fully synchronous active-low reset
    // IFI-010 write port (pool1): shared address, per-channel we/data
    input  wire [7:0]   p1_waddr,
    input  wire [127:0] p1_wdata,     // channel c = p1_wdata[16*c +: 16]
    input  wire [7:0]   p1_we,        // bit c = bank c write enable
    // IFI-005 read port (conv2): shared address + OOB zero
    input  wire [7:0]   p1_raddr,
    input  wire         p1_zero,      // 1 = all lanes read 0 (tap OOB)
    output wire [127:0] p1_rdata      // channel c = p1_rdata[16*c +: 16]
);

    // MEM-003 : 8 x 256 x 16 pool1 banks (196 used).
    reg [15:0] mem [0:7][0:255];

    reg [127:0] rdata_raw;   // registered read; OOB zero mux is combinational

    integer c;

    // Write: pool1 stores one unit per cycle; only the addressed channel's
    // bank is written (p1_we[c]), all 8 share the address.
    always @(posedge clk) begin
        if (p1_we[0]) mem[0][p1_waddr] <= p1_wdata[15:0];
        if (p1_we[1]) mem[1][p1_waddr] <= p1_wdata[31:16];
        if (p1_we[2]) mem[2][p1_waddr] <= p1_wdata[47:32];
        if (p1_we[3]) mem[3][p1_waddr] <= p1_wdata[63:48];
        if (p1_we[4]) mem[4][p1_waddr] <= p1_wdata[79:64];
        if (p1_we[5]) mem[5][p1_waddr] <= p1_wdata[95:80];
        if (p1_we[6]) mem[6][p1_waddr] <= p1_wdata[111:96];
        if (p1_we[7]) mem[7][p1_waddr] <= p1_wdata[127:112];
    end

    // Registered shared-address read; OOB zero mux applied at the output.
    always @(posedge clk) begin
        if (!rst_n) rdata_raw <= 128'd0;
        else begin
            rdata_raw[15:0]   <= mem[0][p1_raddr];
            rdata_raw[31:16]  <= mem[1][p1_raddr];
            rdata_raw[47:32]  <= mem[2][p1_raddr];
            rdata_raw[63:48]  <= mem[3][p1_raddr];
            rdata_raw[79:64]  <= mem[4][p1_raddr];
            rdata_raw[95:80]  <= mem[5][p1_raddr];
            rdata_raw[111:96] <= mem[6][p1_raddr];
            rdata_raw[127:112]<= mem[7][p1_raddr];
        end
    end

    // Out-of-range tap (conv2): all lanes read 0 (zero-padding, golden
    // act2() OOB rule).  Applied AFTER the registered read so the address
    // itself can be out of the written range.
    assign p1_rdata = p1_zero ? 128'd0 : rdata_raw;

endmodule

`default_nettype wire
