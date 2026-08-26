//---------------------------------------------------------------------
// Module      : sram
// Project     : cnn_soc                Technology : FPGA-generic (NOT Sky130 — spec.md §2.1)
// Traces      : REQ-009, REQ-030, BLK-004
// Description : 128 KB read/write data memory at 0x0001_0000
//               (0x0001_0000..0x0002_FFFF); v1 use = firmware stack
//               (top 0x0003_0000). Simplified-AXI4-Lite (IFI-003) slave,
//               sram_ prefix. Byte-enable writes applied at the write-accept
//               edge; registered little-endian word read. word index =
//               addr_r[16:2] for reads, sram_awaddr[16:2] for writes;
//               addr[1:0] ignored (picorv32 native byte-lane extraction).
// Clock/Reset : clk (CD_CORE, 100 MHz) / rst_n (fully SYNCHRONOUS active-low — no async)
// Assumptions : Address is range-bounded by the interconnect decode (BLK-002),
//               so addr[16:2] is always a legal word index (out-of-range
//               impossible). MEM-002 contents are NOT reset-initialised: the
//               v1 pure-ROM firmware never reads unwritten SRAM (REQ-004) —
//               contents undefined is documented, not a hazard. No $readmemh,
//               no initial blocks.
// Source      : custom
//
// FSM-002 : axil_slave_accept (arch.md §6.2) — 3 states, reset = ST_IDLE
//   | State        | Condition             | Next         | Registered actions this cycle           |
//   |--------------|-----------------------|--------------|-----------------------------------------|
//   | ST_IDLE      | awvalid && wvalid      | ST_WRESP     | awready<=1; wready<=1; wstrb lanes stored|
//   | ST_IDLE      | arvalid               | ST_RRESP     | arready<=1; addr_r<=araddr (32-bit)     |
//   | ST_IDLE      | else                  | ST_IDLE      | —                                       |
//   | ST_WRESP     | always                | ST_IDLE      | bvalid<=1 (exactly 1 cycle; no BRESP)   |
//   | ST_RRESP     | always                | ST_RRESP_DLY | memory-access edge: rdata<=mem[addr_r]  |
//   | ST_RRESP_DLY | always                | ST_IDLE      | rvalid<=1 (exactly 1 cycle; no RRESP)   |
//   | (any other)  | default:              | ST_IDLE      | illegal-state recovery                  |
//   Timing: write accept N -> bvalid N+1; read accept N -> rvalid N+2. Slaves
//   never wait for bready/rready (adapter holds mem_valid until the pulse,
//   picorv32.v:2785-2787). rdata is stable across the rvalid cycle (loaded at
//   the previous edge, ST_RRESP).
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module sram (
    input  wire         clk,            // CD_CORE clock, 100 MHz
    input  wire         rst_n,          // fully synchronous active-low reset
    // --- IFI-003 write address channel ---
    input  wire         sram_awvalid,   // write address valid
    output reg          sram_awready,   // write address accepted (1-cycle)
    input  wire [31:0]  sram_awaddr,    // write address (byte-addressed)
    input  wire [2:0]   sram_awprot,    // protection hint (ignored)
    // --- IFI-003 write data channel ---
    input  wire         sram_wvalid,    // write data valid
    output reg          sram_wready,    // write data accepted (1-cycle)
    input  wire [31:0]  sram_wdata,     // write data (little-endian word)
    input  wire [3:0]   sram_wstrb,     // byte enables (per-lane write)
    // --- IFI-003 write response channel ---
    output reg          sram_bvalid,    // write response valid (1-cycle pulse)
    input  wire         sram_bready,    // write response accepted (not waited on)
    // --- IFI-003 read address channel ---
    input  wire         sram_arvalid,   // read address valid
    output reg          sram_arready,   // read address accepted (1-cycle)
    input  wire [31:0]  sram_araddr,    // read address (byte-addressed)
    input  wire [2:0]   sram_arprot,    // protection hint (ignored)
    // --- IFI-003 read data channel ---
    output reg          sram_rvalid,    // read data valid (1-cycle pulse)
    input  wire         sram_rready,    // read data accepted (not waited on)
    output reg  [31:0]  sram_rdata      // read data (little-endian word)
);

    // FSM-002 state encoding (binary; arch.md §6.2)
    localparam [1:0] ST_IDLE      = 2'd0; // idle: accept a read or a write
    localparam [1:0] ST_WRESP     = 2'd1; // write response cycle (bvalid)
    localparam [1:0] ST_RRESP     = 2'd2; // memory-access cycle (load rdata)
    localparam [1:0] ST_RRESP_DLY = 2'd3; // read response cycle (rvalid)

    // MEM-002 : 32,768 x 32 read/write data memory. NOT reset-initialised —
    // stack-only use (REQ-004); contents undefined, documented not a hazard.
    reg [31:0] mem [0:32767];            // word-addressable data memory

    reg [1:0]  state;                    // FSM-002 state register
    reg [31:0] addr_r;                   // registered read address (full 32-bit capture)

    // Word index = addr[16:2]; addr[1:0] ignored. 15-bit index spans the
    // 32,768-word (128 KB) array (arch.md §4 BLK-004 / MEM-002).
    wire [14:0] w = sram_awaddr[16:2];   // write word index (this-edge accept address)

    // Fully-synchronous FSM: state register, address capture, handshake
    // outputs, byte-enable writes, and registered read — all in one clocked
    // block (§3 template). Every one-cycle output is explicitly deasserted in
    // every state where it is not asserted (no latches).
    always @(posedge clk) begin
        if (!rst_n) begin
            state        <= ST_IDLE;
            addr_r       <= 32'd0;
            sram_awready <= 1'b0;
            sram_wready  <= 1'b0;
            sram_bvalid  <= 1'b0;
            sram_arready <= 1'b0;
            sram_rvalid  <= 1'b0;
            sram_rdata   <= 32'd0;
            // mem[] contents untouched by reset (MEM-002).
        end else begin
            // Default deassertions: one-cycle handshake pulses fall unless a
            // state below re-asserts them this edge.
            sram_awready <= 1'b0;
            sram_wready  <= 1'b0;
            sram_bvalid  <= 1'b0;
            sram_arready <= 1'b0;
            sram_rvalid  <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (sram_awvalid && sram_wvalid) begin
                        // Write request: accept and apply byte-enable lanes.
                        sram_awready <= 1'b1;
                        sram_wready  <= 1'b1;
                        if (sram_wstrb[0]) mem[w][7:0]   <= sram_wdata[7:0];
                        if (sram_wstrb[1]) mem[w][15:8]  <= sram_wdata[15:8];
                        if (sram_wstrb[2]) mem[w][23:16] <= sram_wdata[23:16];
                        if (sram_wstrb[3]) mem[w][31:24] <= sram_wdata[31:24];
                        state        <= ST_WRESP;
                    end else if (sram_arvalid) begin
                        // Read request: accept and capture full address.
                        sram_arready <= 1'b1;
                        addr_r       <= sram_araddr;
                        state        <= ST_RRESP;
                    end else begin
                        state <= ST_IDLE;
                    end
                end

                ST_WRESP: begin
                    // 1-cycle write response (no BRESP); do not wait for bready.
                    sram_bvalid <= 1'b1;
                    state       <= ST_IDLE;
                end

                ST_RRESP: begin
                    // Memory-access cycle: registered word read.
                    sram_rdata <= mem[addr_r[16:2]];
                    state      <= ST_RRESP_DLY;
                end

                ST_RRESP_DLY: begin
                    // 1-cycle read response (no RRESP); rdata stable from ST_RRESP.
                    sram_rvalid <= 1'b1;
                    state       <= ST_IDLE;
                end

                default: begin
                    // Illegal-state recovery.
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
