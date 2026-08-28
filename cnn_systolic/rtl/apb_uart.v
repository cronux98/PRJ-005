//---------------------------------------------------------------------
// Module      : apb_uart
// Project     : cnn_soc                Technology : FPGA-generic (NOT Sky130 — spec.md §2.1)
// Traces      : REQ-013, REQ-014, BLK-007
// Description : APB shell over the reused uart_tx (BLK-013). A write to
//               UART_TX (+0x00) issues a registered 1-cycle utx_valid pulse
//               carrying PWDATA[7:0]; a read of UART_STAT (+0x04) returns
//               {31'b0, utx_busy} (arch.md §4 BLK-007, §7.3). Zero-wait
//               slave (PREADY==1). Fire-and-forget producer: utx_valid is
//               only sampled by uart_tx in IDLE (uart_tx.v:59), so a
//               write-while-busy has its byte DROPPED (REQ-014) — this is the
//               deliberate documented drop semantics, NOT hold-until-ready.
//               BLK-013 (uart_tx) is a byte-for-byte reused file, instantiated
//               here with named connections only (guidelines §10/§11).
// Clock/Reset : clk (CD_CORE, 100 MHz) / rst_n (fully SYNCHRONOUS active-low — no async)
// Assumptions : Bridge asserts psel_uart only for 0x4000_0000..0x4000_0007
//               (arch.md §7.3); paddr[3:0] selects the word (0x0=UART_TX,
//               0x4=UART_STAT). utx_data holds its last value between writes;
//               only utx_valid pulses (uart_tx re-samples nothing).
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module apb_uart #(
    parameter UART_CLK_DIV = 868   // default round(100e6/115200); sim override via top
) (
    input  wire        clk,        // core clock (CD_CORE, 100 MHz)
    input  wire        rst_n,      // fully synchronous active-low reset
    input  wire        psel_uart,  // APB select (bridge asserts only for 0x4000_0000..+0x0007)
    input  wire        penable,    // APB enable (ACCESS phase)
    input  wire        pwrite,     // APB write when 1, read when 0
    input  wire [11:0] paddr,      // APB address within this region (word select in paddr[3:0])
    input  wire [31:0] pwdata,     // APB write data
    output reg  [31:0] prdata,     // combinational read mux
    output wire        pready,     // zero-wait slave: always 1
    output wire        uart_tx     // top-level serial output, driven by uart_tx instance
);

    // Signals to/from the reused uart_tx (BLK-013).
    reg  [7:0] utx_data;   // byte latched on a UART_TX write (holds between writes)
    reg        utx_valid;  // registered 1-cycle pulse into uart_tx
    wire       utx_ready;  // high when uart_tx is IDLE (unused here — fire-and-forget)
    wire       utx_busy;   // high when uart_tx is transmitting (UART_STAT[0])

    // Zero-wait slave: response always ready (arch.md §4 BLK-007).
    assign pready = 1'b1;

    // Write strobe: UART_TX (+0x00) write in the ACCESS phase (arch.md §4 BLK-007).
    wire wr_tx = psel_uart && penable && pwrite && (paddr[3:0] == 4'h0);

    // Registered 1-cycle utx_valid pulse; utx_data latches PWDATA[7:0] on write and
    // holds otherwise. Fully synchronous active-low reset (guidelines §3). A byte
    // written while uart_tx is busy is dropped by uart_tx (uart_tx.v:59; REQ-014).
    always @(posedge clk) begin
        if (!rst_n) begin
            utx_valid <= 1'b0;
            utx_data  <= 8'd0;
        end else if (wr_tx) begin
            utx_valid <= 1'b1;
            utx_data  <= pwdata[7:0];
        end else begin
            utx_valid <= 1'b0;
        end
    end

    // Combinational read mux: UART_STAT (+0x04) returns {31'b0, utx_busy}; any other
    // offset (incl. UART_TX, which is write-only) reads 0 (arch.md §7.3). No latch —
    // prdata is assigned on every evaluation.
    always @* begin
        prdata = (paddr[3:0] == 4'h4) ? {31'b0, utx_busy} : 32'd0;
    end

    // Reused uart_tx (BLK-013) — named connections only (guidelines §11).
    uart_tx #(
        .CLK_DIV(UART_CLK_DIV)
    ) u_uart_tx (
        .clk       (clk),
        .rst_n     (rst_n),
        .utx_data  (utx_data),
        .utx_valid (utx_valid),
        .utx_ready (utx_ready),
        .utx_busy  (utx_busy),
        .uart_tx   (uart_tx)
    );

endmodule

`default_nettype wire
