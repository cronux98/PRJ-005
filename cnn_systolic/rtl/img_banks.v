//---------------------------------------------------------------------
// Module      : img_banks
// Project     : cnn_systolic        Technology : Sky130 130 nm
// Traces      : REQ-020, REQ-024, REQ-039, BLK-016
// Description : 9 pre-shifted 784×8 image banks (MEM-002, sized 1024).
//               Bank t (t = iy*3+ix) at address (oy,ox) holds
//               img[(oy+iy-1)*28 + (ox+ix-1)] or 0 for out-of-range
//               taps — zero-padding BY CONSTRUCTION (write-side shift):
//               the broadcast write port stores pixel img[py*28+px]
//               into bank t at (py-iy+1)*28 + (px-ix+1) when in range,
//               so out-of-range taps are never written and read back 0
//               (banks are zero-initialised at reset).
//               Read: 9 parallel ports, shared address oy*28+ox,
//               registered 1-cycle.  IFI-004/IFI-005.
//               OI-001: SRAM-macro mapping is a backend decision (gate
//               flow uses the synth bbox stub).
// Clock/Reset : clk (CD_CORE, 100 MHz) / rst_n (fully synchronous —
//               banks zero-initialised: the write-side-shift padding
//               contract requires unwritten taps to read 0)
// Assumptions : iw_addr is a pixel index 0..783 (py*28+px); ir_addr is
//               an (oy,ox) bank address 0..783.  Read address is always
//               in range for the tap banks (taps may hold 0).
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module img_banks (
    input  wire         clk,          // CD_CORE clock, 100 MHz
    input  wire         rst_n,        // fully synchronous active-low reset
    // IFI-004 broadcast write (pixel index py*28+px)
    input  wire [9:0]   iw_addr,
    input  wire [7:0]   iw_data,
    input  wire         iw_en,
    // IFI-005 shared read (bank t = ir_data[8*t +: 8])
    input  wire [9:0]   ir_addr,
    output reg  [71:0]  ir_data
);

    // MEM-002 : 9 x 1024 x 8 image banks (784 used).
    reg [7:0] mem [0:8][0:1023];

    integer i, t;

    // divmod by 28 (pixel index -> py, px).  Combinational shift-subtract.
    function [10:0] divmod28;
        input [9:0] a;
        integer i;
        reg [9:0] q;
        reg [4:0] r;
        begin
            q = 10'd0;
            r = 5'd0;
            for (i = 9; i >= 0; i = i - 1) begin
                r = {r[3:0], a[i]};
                if (r >= 5'd28) begin
                    r = r - 5'd28;
                    q[i] = 1'b1;
                end
            end
            divmod28 = {q[5:0], r};
        end
    endfunction

    wire [10:0] dm  = divmod28(iw_addr);
    wire [5:0]  py  = dm[10:5];              // pixel row
    wire [4:0]  px  = dm[4:0];               // pixel column

    // Zero-initialise: unwritten (out-of-range-tap) addresses must read 0.
    always @(posedge clk) begin
        if (!rst_n) begin
            for (t = 0; t < 9; t = t + 1)
                for (i = 0; i < 1024; i = i + 1)
                    mem[t][i] <= 8'd0;
        end else if (iw_en) begin
            // Write-side shift: pixel (py,px) -> bank t at (oy,ox) =
            // (py-iy+1, px-ix+1).  In-range iff the shifted coords are in
            // 0..27.  Each bank's shifts/ranges are constant per tap.
            // Bank 0 (iy=0,ix=0): oy=py+1, ox=px+1, need py<=26, px<=26
            if ((py <= 6'd26) && (px <= 5'd26))
                mem[0][((py + 6'd1) * 10'd28) + (px + 5'd1)] <= iw_data;
            // Bank 1 (iy=0,ix=1): oy=py+1, ox=px, need py<=26
            if (py <= 6'd26)
                mem[1][((py + 6'd1) * 10'd28) + px] <= iw_data;
            // Bank 2 (iy=0,ix=2): oy=py+1, ox=px-1, need py<=26, px>=1
            if ((py <= 6'd26) && (px >= 5'd1))
                mem[2][((py + 6'd1) * 10'd28) + (px - 5'd1)] <= iw_data;
            // Bank 3 (iy=1,ix=0): oy=py, ox=px+1, need px<=26
            if (px <= 5'd26)
                mem[3][(py * 10'd28) + (px + 5'd1)] <= iw_data;
            // Bank 4 (iy=1,ix=1): oy=py, ox=px, always in range
            mem[4][(py * 10'd28) + px] <= iw_data;
            // Bank 5 (iy=1,ix=2): oy=py, ox=px-1, need px>=1
            if (px >= 5'd1)
                mem[5][(py * 10'd28) + (px - 5'd1)] <= iw_data;
            // Bank 6 (iy=2,ix=0): oy=py-1, ox=px+1, need py>=1, px<=26
            if ((py >= 6'd1) && (px <= 5'd26))
                mem[6][((py - 6'd1) * 10'd28) + (px + 5'd1)] <= iw_data;
            // Bank 7 (iy=2,ix=1): oy=py-1, ox=px, need py>=1
            if (py >= 6'd1)
                mem[7][((py - 6'd1) * 10'd28) + px] <= iw_data;
            // Bank 8 (iy=2,ix=2): oy=py-1, ox=px-1, need py>=1, px>=1
            if ((py >= 6'd1) && (px >= 5'd1))
                mem[8][((py - 6'd1) * 10'd28) + (px - 5'd1)] <= iw_data;
        end
    end

    // Registered shared-address read: 9 banks in parallel.
    always @(posedge clk) begin
        if (!rst_n) ir_data <= 72'd0;
        else begin
            ir_data[7:0]    <= mem[0][ir_addr];
            ir_data[15:8]   <= mem[1][ir_addr];
            ir_data[23:16]  <= mem[2][ir_addr];
            ir_data[31:24]  <= mem[3][ir_addr];
            ir_data[39:32]  <= mem[4][ir_addr];
            ir_data[47:40]  <= mem[5][ir_addr];
            ir_data[55:48]  <= mem[6][ir_addr];
            ir_data[63:56]  <= mem[7][ir_addr];
            ir_data[71:64]  <= mem[8][ir_addr];
        end
    end

endmodule

`default_nettype wire
