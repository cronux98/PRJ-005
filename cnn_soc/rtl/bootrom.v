//---------------------------------------------------------------------
// Module      : bootrom
// Project     : cnn_soc                Technology : FPGA-generic (NOT Sky130 — spec.md §2.1)
// Traces      : REQ-003, REQ-004, REQ-008, BLK-003
// Description : 4 KB read-only boot memory at 0x0000_0000. Firmware is baked
//               via `initial $readmemh(BOOT_HEX_FILE, rom)` and executes in
//               place (instruction fetches are ordinary reads; arprot ignored).
//               Simplified-AXI4-Lite (IFI-003) slave, boot_ prefix. Writes are
//               accepted and IGNORED (read-only memory — no storage update).
//               Registered little-endian word read; addr[1:0] ignored (the CPU
//               extracts byte lanes, picorv32 native behaviour).
// Clock/Reset : clk (CD_CORE, 100 MHz) / rst_n (fully SYNCHRONOUS active-low — no async)
// Assumptions : Address is range-bounded by the interconnect decode (BLK-002),
//               so araddr[11:2] is always a legal word index (out-of-range
//               impossible). $readmemh binds BOOT_HEX_FILE at vvp runtime, so
//               the compile gate passes even before sw/firmware.hex exists.
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

module bootrom #(
    parameter BOOT_HEX_FILE = "sw/firmware.hex"   // cnn_soc-root-relative firmware image (MEM-001)
) (
    input  wire         clk,             // CD_CORE clock, 100 MHz
    input  wire         rst_n,           // fully synchronous active-low reset
    // --- IFI-003 write address channel ---
    input  wire         boot_awvalid,    // write address valid
    output reg          boot_awready,    // write address accepted (1-cycle)
    input  wire [31:0]  boot_awaddr,     // write address (ignored — RO memory)
    input  wire [2:0]   boot_awprot,     // protection hint (ignored)
    // --- IFI-003 write data channel ---
    input  wire         boot_wvalid,     // write data valid
    output reg          boot_wready,     // write data accepted (1-cycle)
    input  wire [31:0]  boot_wdata,      // write data (ignored — RO memory)
    input  wire [3:0]   boot_wstrb,      // byte enables (ignored — RO memory)
    // --- IFI-003 write response channel ---
    output reg          boot_bvalid,     // write response valid (1-cycle pulse)
    input  wire         boot_bready,     // write response accepted (not waited on)
    // --- IFI-003 read address channel ---
    input  wire         boot_arvalid,    // read address valid
    output reg          boot_arready,    // read address accepted (1-cycle)
    input  wire [31:0]  boot_araddr,     // read address (byte-addressed)
    input  wire [2:0]   boot_arprot,     // protection hint (ignored)
    // --- IFI-003 read data channel ---
    output reg          boot_rvalid,     // read data valid (1-cycle pulse)
    input  wire         boot_rready,     // read data accepted (not waited on)
    output reg  [31:0]  boot_rdata       // read data (little-endian word)
);

    // FSM-002 state encoding (binary; arch.md §6.2)
    localparam [1:0] ST_IDLE     = 2'd0; // idle: accept a read or a (ignored) write
    localparam [1:0] ST_WRESP    = 2'd1; // write response cycle (bvalid)
    localparam [1:0] ST_RRESP    = 2'd2; // memory-access cycle (load rdata)
    localparam [1:0] ST_RRESP_DLY = 2'd3; // read response cycle (rvalid)

    // MEM-001 : 4,096 x 8 boot memory, baked from BOOT_HEX_FILE
    reg [7:0] rom [0:4095];              // byte-addressable ROM array

    // Sole permitted initial block (guidelines §14): ROM initialisation only.
    initial $readmemh(BOOT_HEX_FILE, rom);

    reg [1:0]  state;                    // FSM-002 state register
    reg [31:0] addr_r;                   // registered read address (full 32-bit capture)

    // Word index = addr_r[11:2]; byte base = word*4. addr_r[1:0] ignored.
    wire [11:0] byte0 = {addr_r[11:2], 2'b00}; // base byte offset of the addressed word

    // Fully-synchronous FSM: state register, address capture, handshake
    // outputs, and registered read — all in one clocked block (§3 template).
    // Every one-cycle output is explicitly deasserted in every state where it
    // is not asserted (no latches).
    always @(posedge clk) begin
        if (!rst_n) begin
            state        <= ST_IDLE;
            addr_r       <= 32'd0;
            boot_awready <= 1'b0;
            boot_wready  <= 1'b0;
            boot_bvalid  <= 1'b0;
            boot_arready <= 1'b0;
            boot_rvalid  <= 1'b0;
            boot_rdata   <= 32'd0;
        end else begin
            // Default deassertions: one-cycle handshake pulses fall unless a
            // state below re-asserts them this edge.
            boot_awready <= 1'b0;
            boot_wready  <= 1'b0;
            boot_bvalid  <= 1'b0;
            boot_arready <= 1'b0;
            boot_rvalid  <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (boot_awvalid && boot_wvalid) begin
                        // Write request: accept and IGNORE (RO memory, no store).
                        boot_awready <= 1'b1;
                        boot_wready  <= 1'b1;
                        state        <= ST_WRESP;
                    end else if (boot_arvalid) begin
                        // Read request: accept and capture full address.
                        boot_arready <= 1'b1;
                        addr_r       <= boot_araddr;
                        state        <= ST_RRESP;
                    end else begin
                        state <= ST_IDLE;
                    end
                end

                ST_WRESP: begin
                    // 1-cycle write response (no BRESP); do not wait for bready.
                    boot_bvalid <= 1'b1;
                    state       <= ST_IDLE;
                end

                ST_RRESP: begin
                    // Memory-access cycle: registered little-endian word read.
                    boot_rdata <= {rom[byte0 + 12'd3],
                                   rom[byte0 + 12'd2],
                                   rom[byte0 + 12'd1],
                                   rom[byte0 + 12'd0]};
                    state      <= ST_RRESP_DLY;
                end

                ST_RRESP_DLY: begin
                    // 1-cycle read response (no RRESP); rdata stable from ST_RRESP.
                    boot_rvalid <= 1'b1;
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
