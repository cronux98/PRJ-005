//---------------------------------------------------------------------
// Module      : uart_tx
// Project     : mnist_npu                Technology : FPGA-generic (Artix-7 100T / Nexys A7 target)
// Traces      : REQ-021, REQ-031, BLK-009, FSM-003
// Description : Standard 115200 8N1 UART transmitter, one byte at a time,
//               parameterized CLK_DIV. uart_tx idles high (mark) between
//               frames and during reset (REQ-030/031). UART RX not
//               implemented (not required, project brief §4/§7).
// Clock/Reset : clk (CD_CORE, 100 MHz nominal) / rst_n (SYNCHRONOUS active-low, no async)
// Assumptions : utx_valid is asserted combinationally and held stable by the
//               producer (uart_line_fmt) until utx_ready is observed high
//               (IFI-007 semantics) — this module never needs to re-sample
//               utx_data after accepting it.
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module uart_tx #(
    parameter CLK_DIV = 868   // REQ-021: default round(100e6/115200); sim override e.g. 4
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [7:0]  utx_data,
    input  wire        utx_valid,
    output wire         utx_ready,
    output wire         utx_busy,

    output reg          uart_tx
);
    localparam [1:0] ST_UTX_IDLE  = 2'd0,
                     ST_UTX_START = 2'd1,
                     ST_UTX_DATA  = 2'd2,
                     ST_UTX_STOP  = 2'd3;

    reg [1:0]  state;
    reg [7:0]  shift_r;
    reg [2:0]  bit_cnt;
    reg [31:0] baud_cnt;   // width matches ctrl_fsm.hold_cnt style; comfortably covers any
                            // realistic CLK_DIV (default 868, sim override 2-16) without $clog2
    wire       baud_tick = (baud_cnt == CLK_DIV - 1);

    assign utx_ready = (state == ST_UTX_IDLE);
    assign utx_busy  = (state != ST_UTX_IDLE);

    always @(posedge clk) begin
        if (!rst_n) begin
            state    <= ST_UTX_IDLE;
            shift_r  <= 8'd0;
            bit_cnt  <= 3'd0;
            baud_cnt <= 0;
            uart_tx  <= 1'b1;   // idle-high (mark) — REQ-031
        end else begin
            case (state)
                ST_UTX_IDLE: begin
                    uart_tx  <= 1'b1;
                    baud_cnt <= 0;
                    if (utx_valid) begin
                        shift_r <= utx_data;
                        bit_cnt <= 3'd0;
                        state   <= ST_UTX_START;
                    end
                end

                ST_UTX_START: begin
                    uart_tx <= 1'b0;   // start bit
                    if (baud_tick) begin
                        baud_cnt <= 0;
                        bit_cnt  <= 3'd0;
                        state    <= ST_UTX_DATA;
                    end else begin
                        baud_cnt <= baud_cnt + 1'b1;
                    end
                end

                ST_UTX_DATA: begin
                    uart_tx <= shift_r[bit_cnt];   // LSB first
                    if (baud_tick) begin
                        baud_cnt <= 0;
                        if (bit_cnt == 3'd7) begin
                            state <= ST_UTX_STOP;
                        end else begin
                            bit_cnt <= bit_cnt + 3'd1;
                        end
                    end else begin
                        baud_cnt <= baud_cnt + 1'b1;
                    end
                end

                ST_UTX_STOP: begin
                    uart_tx <= 1'b1;   // stop bit (also idle level)
                    if (baud_tick) begin
                        baud_cnt <= 0;
                        state    <= ST_UTX_IDLE;
                    end else begin
                        baud_cnt <= baud_cnt + 1'b1;
                    end
                end

                default: begin
                    state   <= ST_UTX_IDLE;   // REQ-024 illegal-state recovery
                    uart_tx <= 1'b1;
                end
            endcase
        end
    end
endmodule

`default_nettype wire
