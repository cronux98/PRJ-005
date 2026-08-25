//---------------------------------------------------------------------
// Module      : uart_line_fmt
// Project     : mnist_npu                Technology : FPGA-generic (Artix-7 100T / Nexys A7 target)
// Traces      : REQ-021, REQ-022, BLK-011, FSM-002
// Description : Composes the exact ASCII line (REQ-022) for the current
//               result and streams it, one byte at a time, to uart_tx via
//               the valid/ready handshake (IFI-007). See arch.md §6.2 for
//               the field-by-field byte layout. Composition is a single
//               combinational field generator (always @*, local integer
//               write-pointer `p` — block-local, not shared across always
//               blocks) whose result is registered once per line into
//               line_buf/line_len.
// Clock/Reset : clk (CD_CORE, 100 MHz nominal) / rst_n (SYNCHRONOUS active-low, no async)
// Assumptions : lf_pred/lf_conf/lf_exp/lf_idx/lf_verdict are stable for the
//               entire cycle lf_start is asserted (ctrl_fsm ST_RESULT).
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module uart_line_fmt #(
    parameter MAX_LINE_LEN = 80   // longest real line is 69 bytes (worst-case defensive), see arch.md §4 BLK-011
) (
    input  wire         clk,
    input  wire         rst_n,

    // ctrl_fsm port (IFI-009)
    input  wire         lf_start,
    input  wire [3:0]   lf_pred,
    input  wire [6:0]   lf_conf,
    input  wire [3:0]   lf_exp,
    input  wire [6:0]   lf_idx,
    input  wire [1:0]   lf_verdict,
    output reg           lf_done,

    // uart_tx port (IFI-007), this module is the source side. utx_valid/
    // utx_data are COMBINATIONAL functions of (state, byte_idx, line_buf)
    // only — never of utx_ready (satisfies IFI-007's valid_may_depend_
    // on_ready:false) — held level-stable for as long as state==ST_LF_SEND
    // and byte_idx is unchanged; byte_idx/state only advance on a cycle
    // where utx_ready was independently observed high, so each byte is
    // accepted exactly once (no combinational valid/ready loop, no
    // registered-vs-registered double-fire).
    output wire [7:0]   utx_data,
    output wire          utx_valid,
    input  wire          utx_ready
);
    localparam [1:0] ST_LF_IDLE    = 2'd0,
                     ST_LF_COMPOSE = 2'd1,
                     ST_LF_SEND    = 2'd2;

    reg [1:0] state;
    reg [3:0] pred_r;
    reg [6:0] conf_r;
    reg [3:0] exp_r;
    reg [6:0] idx_r;
    reg [1:0] verdict_r;

    reg [7:0] line_buf [0:MAX_LINE_LEN-1];
    reg [6:0] line_len;
    reg [6:0] byte_idx;

    assign utx_valid = (state == ST_LF_SEND);
    assign utx_data  = line_buf[byte_idx];

    // ---- decimal digit extraction (combinational, small constants) ----
    wire [6:0] idx_tens  = idx_r / 7'd10;
    wire [6:0] idx_ones  = idx_r % 7'd10;
    wire [6:0] conf_h100 = lf_conf / 7'd100;         // 0 or 1 (defensive; REQ-010 states 0..100)
    wire [6:0] conf_rem  = lf_conf % 7'd100;
    wire [6:0] conf_tens = conf_rem / 7'd10;
    wire [6:0] conf_ones = conf_rem % 7'd10;

    // ---- combinational field generator: fills line_buf_nxt/line_len_nxt
    // from the LATCHED pred_r/conf_r/exp_r/idx_r/verdict_r (valid throughout
    // ST_LF_COMPOSE). Local integer `p` is a block-local write pointer, not
    // shared across always blocks (rtl_coding_guidelines.md §1). ----
    reg [7:0] line_buf_nxt [0:MAX_LINE_LEN-1];
    reg [6:0] line_len_nxt;
    integer   p;

    always @* begin
        // default: clear every byte position so no stale/undefined byte can
        // ever be sent even if line_len is computed incorrectly.
        for (p = 0; p < MAX_LINE_LEN; p = p + 1)
            line_buf_nxt[p] = 8'h00;

        p = 0;
        line_buf_nxt[p] = "I"; p = p + 1;
        line_buf_nxt[p] = "M"; p = p + 1;
        line_buf_nxt[p] = "G"; p = p + 1;
        line_buf_nxt[p] = " "; p = p + 1;

        // %03u image index — hundreds digit is always "0" since idx_r<=99
        line_buf_nxt[p] = "0";                      p = p + 1;
        line_buf_nxt[p] = "0" + idx_tens[3:0];       p = p + 1;
        line_buf_nxt[p] = "0" + idx_ones[3:0];       p = p + 1;

        line_buf_nxt[p] = ":"; p = p + 1;
        line_buf_nxt[p] = " "; p = p + 1;

        if (verdict_r == 2'd2) begin
            line_buf_nxt[p] = "N"; p = p + 1;
            line_buf_nxt[p] = "O"; p = p + 1;
            line_buf_nxt[p] = "T"; p = p + 1;
            line_buf_nxt[p] = " "; p = p + 1;
            line_buf_nxt[p] = "A"; p = p + 1;
            line_buf_nxt[p] = " "; p = p + 1;
            line_buf_nxt[p] = "N"; p = p + 1;
            line_buf_nxt[p] = "U"; p = p + 1;
            line_buf_nxt[p] = "M"; p = p + 1;
            line_buf_nxt[p] = "B"; p = p + 1;
            line_buf_nxt[p] = "E"; p = p + 1;
            line_buf_nxt[p] = "R"; p = p + 1;
        end else begin
            line_buf_nxt[p] = "T"; p = p + 1;
            line_buf_nxt[p] = "h"; p = p + 1;
            line_buf_nxt[p] = "i"; p = p + 1;
            line_buf_nxt[p] = "s"; p = p + 1;
            line_buf_nxt[p] = " "; p = p + 1;
            line_buf_nxt[p] = "i"; p = p + 1;
            line_buf_nxt[p] = "s"; p = p + 1;
            line_buf_nxt[p] = " "; p = p + 1;
            line_buf_nxt[p] = "n"; p = p + 1;
            line_buf_nxt[p] = "u"; p = p + 1;
            line_buf_nxt[p] = "m"; p = p + 1;
            line_buf_nxt[p] = "b"; p = p + 1;
            line_buf_nxt[p] = "e"; p = p + 1;
            line_buf_nxt[p] = "r"; p = p + 1;
            line_buf_nxt[p] = " "; p = p + 1;
            line_buf_nxt[p] = "0" + pred_r; p = p + 1;
        end

        line_buf_nxt[p] = " "; p = p + 1;
        line_buf_nxt[p] = "|"; p = p + 1;
        line_buf_nxt[p] = " "; p = p + 1;
        line_buf_nxt[p] = "c"; p = p + 1;
        line_buf_nxt[p] = "o"; p = p + 1;
        line_buf_nxt[p] = "n"; p = p + 1;
        line_buf_nxt[p] = "f"; p = p + 1;
        line_buf_nxt[p] = "i"; p = p + 1;
        line_buf_nxt[p] = "d"; p = p + 1;
        line_buf_nxt[p] = "e"; p = p + 1;
        line_buf_nxt[p] = "n"; p = p + 1;
        line_buf_nxt[p] = "c"; p = p + 1;
        line_buf_nxt[p] = "e"; p = p + 1;
        line_buf_nxt[p] = " "; p = p + 1;

        // variable-width confidence, no leading zeros (REQ-010: 0..100)
        if (conf_h100 != 7'd0) begin
            line_buf_nxt[p] = "0" + conf_h100[3:0]; p = p + 1;
            line_buf_nxt[p] = "0" + conf_tens[3:0]; p = p + 1;
            line_buf_nxt[p] = "0" + conf_ones[3:0]; p = p + 1;
        end else if (conf_tens != 7'd0) begin
            line_buf_nxt[p] = "0" + conf_tens[3:0]; p = p + 1;
            line_buf_nxt[p] = "0" + conf_ones[3:0]; p = p + 1;
        end else begin
            line_buf_nxt[p] = "0" + conf_ones[3:0]; p = p + 1;
        end

        line_buf_nxt[p] = "%"; p = p + 1;
        line_buf_nxt[p] = " "; p = p + 1;
        line_buf_nxt[p] = "|"; p = p + 1;
        line_buf_nxt[p] = " "; p = p + 1;
        line_buf_nxt[p] = "e"; p = p + 1;
        line_buf_nxt[p] = "x"; p = p + 1;
        line_buf_nxt[p] = "p"; p = p + 1;
        line_buf_nxt[p] = "e"; p = p + 1;
        line_buf_nxt[p] = "c"; p = p + 1;
        line_buf_nxt[p] = "t"; p = p + 1;
        line_buf_nxt[p] = "e"; p = p + 1;
        line_buf_nxt[p] = "d"; p = p + 1;
        line_buf_nxt[p] = " "; p = p + 1;

        line_buf_nxt[p] = "0" + exp_r; p = p + 1;

        line_buf_nxt[p] = " "; p = p + 1;
        line_buf_nxt[p] = "|"; p = p + 1;
        line_buf_nxt[p] = " "; p = p + 1;

        if (verdict_r == 2'd0) begin
            line_buf_nxt[p] = "C"; p = p + 1;
            line_buf_nxt[p] = "O"; p = p + 1;
            line_buf_nxt[p] = "R"; p = p + 1;
            line_buf_nxt[p] = "R"; p = p + 1;
            line_buf_nxt[p] = "E"; p = p + 1;
            line_buf_nxt[p] = "C"; p = p + 1;
            line_buf_nxt[p] = "T"; p = p + 1;
        end else if (verdict_r == 2'd1) begin
            line_buf_nxt[p] = "I"; p = p + 1;
            line_buf_nxt[p] = "N"; p = p + 1;
            line_buf_nxt[p] = "C"; p = p + 1;
            line_buf_nxt[p] = "O"; p = p + 1;
            line_buf_nxt[p] = "R"; p = p + 1;
            line_buf_nxt[p] = "R"; p = p + 1;
            line_buf_nxt[p] = "E"; p = p + 1;
            line_buf_nxt[p] = "C"; p = p + 1;
            line_buf_nxt[p] = "T"; p = p + 1;
        end else begin
            line_buf_nxt[p] = "T"; p = p + 1;
            line_buf_nxt[p] = "R"; p = p + 1;
            line_buf_nxt[p] = "A"; p = p + 1;
            line_buf_nxt[p] = "S"; p = p + 1;
            line_buf_nxt[p] = "H"; p = p + 1;
        end

        line_buf_nxt[p] = 8'h0A; p = p + 1;   // LF only, no CR — REQ-022

        line_len_nxt = p[6:0];
    end

    // ---- sequential: FSM-002 state, latch inputs, register composed line,
    // stream bytes to uart_tx via the valid/ready handshake. ----
    always @(posedge clk) begin
        if (!rst_n) begin
            state     <= ST_LF_IDLE;
            pred_r    <= 4'd0;
            conf_r    <= 7'd0;
            exp_r     <= 4'd0;
            idx_r     <= 7'd0;
            verdict_r <= 2'd0;
            line_len  <= 7'd0;
            byte_idx  <= 7'd0;
            lf_done   <= 1'b0;
        end else begin
            lf_done   <= 1'b0;   // default: 1-cycle strobe

            case (state)
                ST_LF_IDLE: begin
                    if (lf_start) begin
                        pred_r    <= lf_pred;
                        conf_r    <= lf_conf;
                        exp_r     <= lf_exp;
                        idx_r     <= lf_idx;
                        verdict_r <= lf_verdict;
                        state     <= ST_LF_COMPOSE;
                    end
                end

                ST_LF_COMPOSE: begin
                    line_len <= line_len_nxt;
                    byte_idx <= 7'd0;
                    state    <= ST_LF_SEND;
                end

                ST_LF_SEND: begin
                    // utx_valid is already asserted combinationally (state==ST_LF_SEND).
                    // A transfer occurs exactly when utx_ready is observed high this
                    // cycle; advance (or finish) on that same edge, once.
                    if (utx_ready) begin
                        if (byte_idx == line_len - 7'd1) begin
                            lf_done <= 1'b1;
                            state   <= ST_LF_IDLE;
                        end else begin
                            byte_idx <= byte_idx + 7'd1;
                        end
                    end
                end

                default: state <= ST_LF_IDLE;   // REQ-024 illegal-state recovery
            endcase
        end
    end

    // register the composed line array itself (separate always block, since
    // Verilog-2001 cannot assign a `reg` memory array to another array in a
    // single non-blocking statement across differently-scoped always blocks
    // without this explicit per-word copy).
    integer w;
    always @(posedge clk) begin
        if (state == ST_LF_COMPOSE) begin
            for (w = 0; w < MAX_LINE_LEN; w = w + 1)
                line_buf[w] <= line_buf_nxt[w];
        end
    end
endmodule

`default_nettype wire
