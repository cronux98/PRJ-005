//---------------------------------------------------------------------
// Module      : led_ctrl
// Project     : mnist_npu                Technology : FPGA-generic (Artix-7 100T / Nexys A7 target)
// Traces      : REQ-017, REQ-018, REQ-019, REQ-020, REQ-030, BLK-010
// Description : Derives led[11:0] from ctrl_fsm's presented result and
//               busy/blink status. led[9:0]: one-hot predicted digit, all
//               zero on TRASH (REQ-017). led[10]: 1 when verdict!=CORRECT
//               (REQ-018). led[11]: blinks at BLINK_CYCLES half-period while
//               lc_busy is high, steady off once presented (REQ-019/020).
// Clock/Reset : clk (CD_CORE, 100 MHz nominal) / rst_n (SYNCHRONOUS active-low, no async)
// Assumptions : lc_pred/lc_verdict are stable combinational functions of
//               ctrl_fsm's registers, valid whenever lc_present pulses.
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module led_ctrl #(
    parameter BLINK_CYCLES = 5000000   // REQ-020: default ~10Hz @100MHz; sim override 2-4
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [3:0]  lc_pred,
    input  wire [1:0]  lc_verdict,
    input  wire         lc_present,
    input  wire         lc_busy,

    output wire [11:0] led
);
    reg [3:0]  pred_r;
    reg [1:0]  verdict_r;
    reg [31:0] blink_cnt;
    reg         blink_toggle_r;

    always @(posedge clk) begin
        if (!rst_n) begin
            pred_r         <= 4'd0;
            verdict_r      <= 2'd0;
            blink_cnt      <= 32'd0;
            blink_toggle_r <= 1'b0;
        end else begin
            // REQ-017/018: latch the presented result
            if (lc_present) begin
                pred_r    <= lc_pred;
                verdict_r <= lc_verdict;
            end

            // REQ-019/020: blink only while busy; free-running toggle counter
            // resets whenever not busy so the blink always restarts cleanly
            // at the start of the next image's compute window.
            if (lc_busy) begin
                if (blink_cnt == BLINK_CYCLES - 1) begin
                    blink_cnt      <= 32'd0;
                    blink_toggle_r <= ~blink_toggle_r;
                end else begin
                    blink_cnt <= blink_cnt + 32'd1;
                end
            end else begin
                blink_cnt      <= 32'd0;
                blink_toggle_r <= 1'b0;
            end
        end
    end

    // led[9:0]: one-hot on pred_r, all-zero on TRASH (verdict_r==2) — REQ-017
    wire [9:0] led_digit = (verdict_r == 2'd2) ? 10'd0 : (10'd1 << pred_r);
    // led[10]: fail/trash indicator — REQ-018
    wire       led_fail  = (verdict_r != 2'd0);
    // led[11]: busy-blink, steady off once presented — REQ-019
    wire       led_blink = lc_busy ? blink_toggle_r : 1'b0;

    assign led = {led_blink, led_fail, led_digit};
endmodule

`default_nettype wire
