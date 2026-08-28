//---------------------------------------------------------------------
// Module      : pool_unit
// Project     : cnn_systolic        Technology : Sky130 130 nm
// Traces      : REQ-023, REQ-025, REQ-039, BLK-012
// Description : 2×2 max pooling (FSM-004, 6 cycles/unit).  pool1:
//               reads h1 (FM region A) → writes the 8 p1 banks in
//               parallel (only the addressed channel's bank enable is
//               set).  pool2: reads h2 (FM region A) → writes p2 at FM
//               6272+oc*49+oy*7+ox (region B).  The compare is a
//               SIGNED 16-bit compare of the BF16 bit patterns —
//               mirrors the golden's int16_t cast exactly (ReLU'd h1/h2
//               are non-negative in practice, but the golden's compare
//               semantics are the contract).  Self-contained unit
//               counters (oc, oy, ox); pool_done pulses at the end.
// Clock/Reset : clk (CD_CORE, 100 MHz) / rst_n (fully synchronous)
// Assumptions : launched by conv_ctrl (pool_go); owns the FM read port
//               and the p1/FM write ports while active.
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module pool_unit (
    input  wire         clk,          // CD_CORE clock, 100 MHz
    input  wire         rst_n,        // fully synchronous active-low reset
    input  wire         pool_go,      // 1-cycle launch
    input  wire         pool_mode,    // 0 = pool1 (h1→p1 banks), 1 = pool2 (h2→FM p2)
    output reg          pool_done,    // 1-cycle completion
    // FM read port (owned while active)
    output reg  [12:0]  fm_raddr,
    input  wire [15:0]  fm_rdata,
    // FM write port (pool2 only)
    output reg  [12:0]  fm_waddr,
    output reg  [15:0]  fm_wdata,
    output reg          fm_we,
    // p1 banks write port (pool1 only)
    output reg  [7:0]   p1_waddr,
    output reg  [127:0] p1_wdata,
    output reg  [7:0]   p1_we
);

    // FSM-004 : pool FSM (5 active phases + advance), reset = PH_R0
    localparam [2:0] PH_R0   = 3'd0;  // issue read (2oy,2ox)
    localparam [2:0] PH_R1   = 3'd1;  // issue read (2oy,2ox+1); latch a
    localparam [2:0] PH_R2   = 3'd2;  // issue read (2oy+1,2ox);   max
    localparam [2:0] PH_R3   = 3'd3;  // issue read (2oy+1,2ox+1); max
    localparam [2:0] PH_WB   = 3'd4;  // max with d
    localparam [2:0] PH_NEXT = 3'd5;  // write; advance counters
    localparam [2:0] PH_IDLE = 3'd6;

    reg [2:0]  ph;
    reg [4:0]  oy, ox;        // output coords (pool1 14×14, pool2 7×7)
    reg [3:0]  oc;            // channel
    reg [15:0] m;             // running max (BF16 bit pattern, signed compare)

    wire [3:0] oc_max = pool_mode ? 4'd15 : 4'd7;
    wire [4:0] oy_max = pool_mode ? 5'd6  : 5'd13;
    wire [4:0] ox_max = pool_mode ? 5'd6  : 5'd13;
    wire [4:0] wy = pool_mode ? 5'd14 : 5'd28;         // FM row stride
    wire [12:0] base = pool_mode ? ({8'd0, oc} * 13'd196)
                                 : ({8'd0, oc} * 13'd784);

    // Signed 16-bit max (golden int16_t compare on the BF16 patterns).
    wire [15:0] m_nxt = ($signed(m) >= $signed(fm_rdata)) ? m : fm_rdata;

    always @(posedge clk) begin
        if (!rst_n) begin
            ph        <= PH_IDLE;
            oy        <= 5'd0;
            ox        <= 5'd0;
            oc        <= 4'd0;
            m         <= 16'd0;
            fm_raddr  <= 13'd0;
            fm_waddr  <= 13'd0;
            fm_wdata  <= 16'd0;
            fm_we     <= 1'b0;
            p1_waddr  <= 8'd0;
            p1_wdata  <= 128'd0;
            p1_we     <= 8'd0;
            pool_done <= 1'b0;
        end else begin
            // Defaults (no latches).
            fm_we     <= 1'b0;
            p1_we     <= 8'd0;
            pool_done <= 1'b0;

            case (ph)
                PH_IDLE: begin
                    if (pool_go) begin
                        oy <= 5'd0; ox <= 5'd0; oc <= 4'd0;
                        ph <= PH_R0;
                    end
                end

                PH_R0: begin
                    // Issue read a = (2oy, 2ox); data at next cycle.
                    fm_raddr <= base + (oy * wy) + (ox << 1);
                    ph       <= PH_R1;
                end

                PH_R1: begin
                    // Latch a (fm_rdata = the PH_R0 read).
                    m        <= fm_rdata;
                    fm_raddr <= base + (oy * wy) + (ox << 1) + 13'd1;
                    ph       <= PH_R2;
                end

                PH_R2: begin
                    m        <= m_nxt;
                    fm_raddr <= base + ((oy + 5'd1) * wy) + (ox << 1);
                    ph       <= PH_R3;
                end

                PH_R3: begin
                    m        <= m_nxt;
                    fm_raddr <= base + ((oy + 5'd1) * wy) + (ox << 1) + 13'd1;
                    ph       <= PH_WB;
                end

                PH_WB: begin
                    // m_nxt now includes d (fm_rdata = the PH_R3 read).
                    m  <= m_nxt;
                    ph <= PH_NEXT;
                end

                PH_NEXT: begin
                    // Write the final max.
                    if (pool_mode) begin
                        // pool2: p2[oc*49+oy*7+ox] at FM 6272+.
                        fm_waddr <= 13'd6272 + (oc * 13'd49) + (oy * 5'd7) + ox;
                        fm_wdata <= m;
                        fm_we    <= 1'b1;
                    end else begin
                        // pool1: p1_banks[oc] at oy*14+ox (per-channel we).
                        p1_waddr <= (oy * 5'd14) + ox;
                        p1_wdata <= {8{m}};
                        p1_we    <= (8'd1 << oc);
                    end
                    // Advance (ox → oy → oc).
                    if (ox == ox_max) begin
                        ox <= 5'd0;
                        if (oy == oy_max) begin
                            oy <= 5'd0;
                            if (oc == oc_max) begin
                                ph        <= PH_IDLE;
                                pool_done <= 1'b1;
                            end else begin
                                oc <= oc + 4'd1;
                                ph <= PH_R0;
                            end
                        end else begin
                            oy <= oy + 5'd1;
                            ph <= PH_R0;
                        end
                    end else begin
                        ox <= ox + 5'd1;
                        ph <= PH_R0;
                    end
                end

                default: ph <= PH_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
