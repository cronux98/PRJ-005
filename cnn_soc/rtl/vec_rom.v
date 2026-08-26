//---------------------------------------------------------------------
// Module      : vec_rom
// Project     : cnn_soc                Technology : FPGA-generic (NOT Sky130 — spec.md §2.1)
// Traces      : REQ-010, BLK-005
// Description : 78,500 B read-only vector source at 0x1000_0000 — the CPU's
//               image/label source. images.hex (78,400 B) is baked at
//               +0x0000..+0x1323F, labels.hex (100 B) at +0x13240..+0x132A3,
//               via two `initial $readmemh(<PARAM>, rom, start, end)` calls
//               (MEM-003, Verilog-2001 start/end args). Simplified-AXI4-Lite
//               (IFI-003) slave, vec_ prefix. Writes are accepted and IGNORED
//               (read-only memory — no storage update). Registered little-endian
//               word read; addr[1:0] ignored (the CPU extracts byte lanes,
//               picorv32 native behaviour).
// Clock/Reset : clk (CD_CORE, 100 MHz) / rst_n (fully SYNCHRONOUS active-low — no async)
// Assumptions : Address is range-bounded by the interconnect decode (A[31:28]==
//               4'h1, BLK-002); firmware only accesses valid addresses, so
//               indices beyond the 78,500-byte array are documented don't-care
//               (arch.md §4 BLK-005) — the byte0 arithmetic is the arch formula
//               verbatim, never clamped or masked. The two $readmemh calls bind
//               IMAGES_HEX_FILE/LABELS_HEX_FILE at vvp runtime, so the compile
//               gate passes even before the golden hex files exist.
// Source      : custom
//
// FSM-002 : axil_slave_accept (arch.md §6.2) — 3 states, reset = ST_IDLE
//   | State        | Condition             | Next         | Registered actions this cycle           |
//   |--------------|-----------------------|--------------|-----------------------------------------|
//   | ST_IDLE      | awvalid && wvalid      | ST_WRESP     | awready<=1; wready<=1 (write IGNORED)    |
//   | ST_IDLE      | arvalid               | ST_RRESP     | arready<=1; addr_r<=araddr (32-bit)     |
//   | ST_IDLE      | else                  | ST_IDLE      | —                                       |
//   | ST_WRESP     | always                | ST_IDLE      | bvalid<=1 (exactly 1 cycle; no BRESP)   |
//   | ST_RRESP     | always                | ST_RRESP_DLY | memory-access edge: rdata<={rom[a+3..0]}|
//   | ST_RRESP_DLY | always                | ST_IDLE      | rvalid<=1 (exactly 1 cycle; no RRESP)   |
//   | (any other)  | default:              | ST_IDLE      | illegal-state recovery                  |
//   Timing: write accept N -> bvalid N+1; read accept N -> rvalid N+2. Slaves
//   never wait for bready/rready (adapter holds mem_valid until the pulse,
//   picorv32.v:2785-2787). rdata is stable across the rvalid cycle (loaded at
//   the previous edge, ST_RRESP).
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module vec_rom #(
    parameter IMAGES_HEX_FILE = "../cnn/arch/golden_model/images.hex", // cnn_soc-root-relative image vectors (MEM-003)
    parameter LABELS_HEX_FILE = "../cnn/arch/golden_model/labels.hex"  // cnn_soc-root-relative label bytes  (MEM-003)
) (
    input  wire         clk,            // CD_CORE clock, 100 MHz
    input  wire         rst_n,          // fully synchronous active-low reset
    // --- IFI-003 write address channel ---
    input  wire         vec_awvalid,    // write address valid
    output reg          vec_awready,    // write address accepted (1-cycle)
    input  wire [31:0]  vec_awaddr,     // write address (ignored — RO memory)
    input  wire [2:0]   vec_awprot,     // protection hint (ignored)
    // --- IFI-003 write data channel ---
    input  wire         vec_wvalid,     // write data valid
    output reg          vec_wready,     // write data accepted (1-cycle)
    input  wire [31:0]  vec_wdata,      // write data (ignored — RO memory)
    input  wire [3:0]   vec_wstrb,      // byte enables (ignored — RO memory)
    // --- IFI-003 write response channel ---
    output reg          vec_bvalid,     // write response valid (1-cycle pulse)
    input  wire         vec_bready,     // write response accepted (not waited on)
    // --- IFI-003 read address channel ---
    input  wire         vec_arvalid,    // read address valid
    output reg          vec_arready,    // read address accepted (1-cycle)
    input  wire [31:0]  vec_araddr,     // read address (byte-addressed)
    input  wire [2:0]   vec_arprot,     // protection hint (ignored)
    // --- IFI-003 read data channel ---
    output reg          vec_rvalid,     // read data valid (1-cycle pulse)
    input  wire         vec_rready,     // read data accepted (not waited on)
    output reg  [31:0]  vec_rdata       // read data (little-endian word)
);

    // FSM-002 state encoding (binary; arch.md §6.2)
    localparam [1:0] ST_IDLE      = 2'd0; // idle: accept a read or a (ignored) write
    localparam [1:0] ST_WRESP     = 2'd1; // write response cycle (bvalid)
    localparam [1:0] ST_RRESP     = 2'd2; // memory-access cycle (load rdata)
    localparam [1:0] ST_RRESP_DLY = 2'd3; // read response cycle (rvalid)

    // MEM-003 : 78,500 x 8 vector ROM, baked from the two golden hex files.
    reg [7:0] rom [0:78499];             // byte-addressable ROM array

    // Sole permitted initial blocks (guidelines §14): ROM initialisation only.
    // Verilog-2001 start/end arguments place each region at its arch.md offset.
    initial $readmemh(IMAGES_HEX_FILE, rom, 0,     78399); // images at +0x0000..+0x1323F
    initial $readmemh(LABELS_HEX_FILE, rom, 78400, 78499); // labels at +0x13240..+0x132A3

    reg [1:0]  state;                    // FSM-002 state register
    reg [31:0] addr_r;                   // registered read address (full 32-bit capture)

    // Word index = addr_r[16:2]; byte base = word*4. addr_r[1:0] ignored.
    // 17-bit offset spans the 78,500-byte array (word 19624 -> bytes 78496..78499,
    // the last label word). Formula is verbatim arch.md §4 BLK-005 — never masked.
    wire [16:0] byte0 = {addr_r[16:2], 2'b00}; // base byte offset of the addressed word

    // Fully-synchronous FSM: state register, address capture, handshake
    // outputs, and registered read — all in one clocked block (§3 template).
    // Every one-cycle output is explicitly deasserted in every state where it
    // is not asserted (no latches).
    always @(posedge clk) begin
        if (!rst_n) begin
            state       <= ST_IDLE;
            addr_r      <= 32'd0;
            vec_awready <= 1'b0;
            vec_wready  <= 1'b0;
            vec_bvalid  <= 1'b0;
            vec_arready <= 1'b0;
            vec_rvalid  <= 1'b0;
            vec_rdata   <= 32'd0;
        end else begin
            // Default deassertions: one-cycle handshake pulses fall unless a
            // state below re-asserts them this edge.
            vec_awready <= 1'b0;
            vec_wready  <= 1'b0;
            vec_bvalid  <= 1'b0;
            vec_arready <= 1'b0;
            vec_rvalid  <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (vec_awvalid && vec_wvalid) begin
                        // Write request: accept and IGNORE (RO memory, no store).
                        vec_awready <= 1'b1;
                        vec_wready  <= 1'b1;
                        state       <= ST_WRESP;
                    end else if (vec_arvalid) begin
                        // Read request: accept and capture full address.
                        vec_arready <= 1'b1;
                        addr_r      <= vec_araddr;
                        state       <= ST_RRESP;
                    end else begin
                        state <= ST_IDLE;
                    end
                end

                ST_WRESP: begin
                    // 1-cycle write response (no BRESP); do not wait for bready.
                    vec_bvalid <= 1'b1;
                    state      <= ST_IDLE;
                end

                ST_RRESP: begin
                    // Memory-access cycle: registered little-endian word read.
                    vec_rdata <= {rom[byte0 + 17'd3],
                                  rom[byte0 + 17'd2],
                                  rom[byte0 + 17'd1],
                                  rom[byte0 + 17'd0]};
                    state     <= ST_RRESP_DLY;
                end

                ST_RRESP_DLY: begin
                    // 1-cycle read response (no RRESP); rdata stable from ST_RRESP.
                    vec_rvalid <= 1'b1;
                    state      <= ST_IDLE;
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
