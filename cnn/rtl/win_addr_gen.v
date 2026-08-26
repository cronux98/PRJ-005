//---------------------------------------------------------------------
// Module      : win_addr_gen
// Project     : cnn (mnist_npu v2)      Technology : FPGA-generic (Artix-7 100T / Nexys A7 target)
// Traces      : REQ-004, REQ-006, REQ-007, REQ-008, REQ-009, REQ-012, REQ-013,
//               REQ-023, BLK-012
// Description : Purely combinational window-address generator. From
//               ctrl_fsm's current loop counters and layer_sel, computes
//               every ROM/RAM address needed this cycle (weight_rom bias +
//               tap addresses, image_rom address, fm_ram read/write
//               addresses) plus the zero-padding tap_valid flag for 3x3
//               conv taps. See arch.md §4 BLK-012 and §7.1 for the full
//               per-layer address-map derivation (weight offsets: conv1_w=0,
//               conv1_b=72, conv2_w=80, conv2_b=1232, fc1_w=1248,
//               fc1_b=26336, fc2_w=26368, fc2_b=26688; fm_ram Region A
//               base=0, Region B base=6272).
// Clock/Reset : none (purely combinational, no state)
// Assumptions : counters are always within the bounds ctrl_fsm's own loop
//               structure guarantees per layer (arch.md §6.1 loop bounds
//               table); every 20-bit intermediate below has generous
//               headroom over the largest real address (78,399), so no
//               product/sum below can silently truncate before the final
//               narrow assignment.
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module win_addr_gen (
    input  wire [2:0]  layer_sel,   // 0=CONV1,1=POOL1,2=CONV2,3=POOL2,4=FC1,5=FC2
    input  wire [4:0]  u_cnt,       // output unit/channel index
    input  wire [4:0]  y_cnt,       // output row (conv/pool)
    input  wire [4:0]  x_cnt,       // output col (conv/pool)
    input  wire [3:0]  ic_cnt,      // input channel (conv2 only, 0..7)
    input  wire [1:0]  iy_cnt,      // conv tap row 0..2
    input  wire [1:0]  ix_cnt,      // conv tap col 0..2
    input  wire [9:0]  i_cnt,       // FC input index 0..783/0..31
    input  wire [6:0]  img_idx,     // 0..99
    input  wire [1:0]  pool_tap,    // pool sub-tap select: [1]=dy,[0]=dx (== ctrl_fsm.phase[1:0] during READ0..READ3)

    output reg  [14:0] wrom_bias_addr,
    output reg  [14:0] wrom_tap_addr,
    output reg  [16:0] irom_addr,
    output reg  [12:0] fmram_rd_addr,
    output reg  [12:0] fmram_wr_addr,
    output reg          tap_valid
);
    localparam [2:0] LSEL_CONV1 = 3'd0,
                     LSEL_POOL1 = 3'd1,
                     LSEL_CONV2 = 3'd2,
                     LSEL_POOL2 = 3'd3,
                     LSEL_FC1   = 3'd4,
                     LSEL_FC2   = 3'd5;

    localparam [19:0] FM_REGION_B_BASE = 20'd6272;

    // ---- 20-bit zero-extended copies of every counter: generous headroom
    // (max real value used anywhere below is 78,399, far under 2^20) so
    // every intermediate product/sum below is computed without truncation. ----
    wire [19:0] u20   = {15'd0, u_cnt};
    wire [19:0] y20   = {15'd0, y_cnt};
    wire [19:0] x20   = {15'd0, x_cnt};
    wire [19:0] ic20  = {16'd0, ic_cnt};
    wire [19:0] iy20  = {18'd0, iy_cnt};
    wire [19:0] ix20  = {18'd0, ix_cnt};
    wire [19:0] i20   = {10'd0, i_cnt};
    wire [19:0] img20 = {13'd0, img_idx};
    wire [19:0] dy20  = {19'd0, pool_tap[1]};
    wire [19:0] dx20  = {19'd0, pool_tap[0]};

    // ---- conv1: zero-pad boundary check against a 28x28 input plane.
    // py/px = y/x_cnt + iy/ix_cnt - 1 (the 3x3 window offset), computed in
    // signed arithmetic so an out-of-bounds (negative or >27) tap is
    // detected exactly, then clamped to a safe in-range dummy index (0)
    // whose ROM data is discarded anyway (ctrl_fsm forces mac_a=0). ----
    wire signed [6:0] py1_s = $signed({2'b0, y_cnt}) + $signed({5'b0, iy_cnt}) - 7'sd1;
    wire signed [6:0] px1_s = $signed({2'b0, x_cnt}) + $signed({5'b0, ix_cnt}) - 7'sd1;
    wire              conv1_valid = (py1_s >= 7'sd0) && (py1_s <= 7'sd27) &&
                                     (px1_s >= 7'sd0) && (px1_s <= 7'sd27);
    wire [19:0]       py1_c = conv1_valid ? {13'd0, py1_s[6:0]} : 20'd0;
    wire [19:0]       px1_c = conv1_valid ? {13'd0, px1_s[6:0]} : 20'd0;

    // ---- conv2: zero-pad boundary check against a 14x14 input plane ----
    wire signed [6:0] py2_s = $signed({2'b0, y_cnt}) + $signed({5'b0, iy_cnt}) - 7'sd1;
    wire signed [6:0] px2_s = $signed({2'b0, x_cnt}) + $signed({5'b0, ix_cnt}) - 7'sd1;
    wire              conv2_valid = (py2_s >= 7'sd0) && (py2_s <= 7'sd13) &&
                                     (px2_s >= 7'sd0) && (px2_s <= 7'sd13);
    wire [19:0]       py2_c = conv2_valid ? {13'd0, py2_s[6:0]} : 20'd0;
    wire [19:0]       px2_c = conv2_valid ? {13'd0, px2_s[6:0]} : 20'd0;

    reg [19:0] bias_addr_w, tap_addr_w, irom_addr_w, fmram_rd_w, fmram_wr_w;

    always @* begin
        // defaults — every LHS assigned before the case, so no branch can
        // leave a signal unassigned (no latch risk, rtl_coding_guidelines.md §4).
        bias_addr_w = 20'd0;
        tap_addr_w  = 20'd0;
        irom_addr_w = 20'd0;
        fmram_rd_w  = 20'd0;
        fmram_wr_w  = 20'd0;
        tap_valid   = 1'b1;

        case (layer_sel)
            LSEL_CONV1: begin
                // conv1_b base 72; conv1_w base 0, tap = oc*9+iy*3+ix
                bias_addr_w = 20'd72 + u20;
                tap_addr_w  = u20 * 20'd9 + iy20 * 20'd3 + ix20;
                tap_valid   = conv1_valid;
                irom_addr_w = img20 * 20'd784 + py1_c * 20'd28 + px1_c;
                fmram_wr_w  = u20 * 20'd784 + y20 * 20'd28 + x20;             // Region A
            end

            LSEL_POOL1: begin
                fmram_rd_w = u20 * 20'd784 + (y20*20'd2 + dy20) * 20'd28 + (x20*20'd2 + dx20);   // Region A
                fmram_wr_w = FM_REGION_B_BASE + u20*20'd196 + y20*20'd14 + x20;                    // Region B
            end

            LSEL_CONV2: begin
                // conv2_b base 1232; conv2_w base 80, tap = (oc*8+ic)*9+iy*3+ix
                bias_addr_w = 20'd1232 + u20;
                tap_addr_w  = 20'd80 + (u20*20'd8 + ic20) * 20'd9 + iy20*20'd3 + ix20;
                tap_valid   = conv2_valid;
                fmram_rd_w  = FM_REGION_B_BASE + ic20*20'd196 + py2_c*20'd14 + px2_c;   // Region B (pool1 output)
                fmram_wr_w  = u20*20'd196 + y20*20'd14 + x20;                            // Region A
            end

            LSEL_POOL2: begin
                fmram_rd_w = u20*20'd196 + (y20*20'd2 + dy20)*20'd14 + (x20*20'd2 + dx20);   // Region A
                fmram_wr_w = FM_REGION_B_BASE + u20*20'd49 + y20*20'd7 + x20;                  // Region B
            end

            LSEL_FC1: begin
                // fc1_b base 26336; fc1_w base 1248, tap = i*32+j
                bias_addr_w = 20'd26336 + u20;
                tap_addr_w  = 20'd1248 + i20*20'd32 + u20;
                fmram_rd_w  = FM_REGION_B_BASE + i20;    // Region B, flattened pool2 output (== oc*49+oy*7+ox)
                fmram_wr_w  = u20;                        // Region A
            end

            LSEL_FC2: begin
                // fc2_b base 26688; fc2_w base 26368, tap = j*10+c
                bias_addr_w = 20'd26688 + u20;
                tap_addr_w  = 20'd26368 + i20*20'd10 + u20;
                fmram_rd_w  = i20;   // Region A, FC1 output h3
            end

            default: begin
                // illegal layer_sel: all outputs remain at the safe defaults above.
            end
        endcase

        wrom_bias_addr = bias_addr_w[14:0];
        wrom_tap_addr  = tap_addr_w[14:0];
        irom_addr      = irom_addr_w[16:0];
        fmram_rd_addr  = fmram_rd_w[12:0];
        fmram_wr_addr  = fmram_wr_w[12:0];
    end
endmodule

`default_nettype wire
