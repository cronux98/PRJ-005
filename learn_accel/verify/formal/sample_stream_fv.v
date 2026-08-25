//---------------------------------------------------------------------
// Module      : sample_stream
// Project     : rinriAI   Technology : Sky130 130 nm
// Traces      : REQ-008, REQ-016, REQ-018, BLK-003, FSM-002
// Description : Frames the incoming byte stream (IF-002) into samples of
//               FEATURES pixel bytes followed by one label byte carrying
//               s_last, stores pixels in MEM-002, detects malformed frames
//               (short frame or missing/extra last), presents sample_valid
//               and the captured label to the learner, and exposes the
//               combinational pixel read port used during forward/update.
// Clock/Reset : clk_core (CD_CORE) / rst_n (synchronous, active low)
// Assumptions : W_F is wide enough to hold the pixel count 0..FEATURES,
//               i.e. FEATURES <= 2**W_F - 1 (default 784 <= 4095). The
//               pixel read port (x_addr/x_rdata) is only exercised by the
//               learner while sample_stream is NOT writing MEM-002 (mutual
//               exclusion via accept_en, IFI-003/§8), so no read/write
//               collision policy is required here.
// Source      : custom (no external IP)
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none                       // typo'd implicit wires become errors

module sample_stream_fv #(
    parameter integer FEATURES = 784,       // pixels per sample, legal 1..4096
    parameter integer W_F      = 12         // pixel-counter width; must hold 0..FEATURES
) (
    input  wire                  clk_core,   // CD_CORE, 50 MHz
    input  wire                  rst_n,      // synchronous, active low (ASM-002)

    // External byte stream (IF-002) — IP is the sink; s_ready may deassert freely
    input  wire                  s_valid,    // upstream has a byte this cycle
    output wire                  s_ready,     // combinational: = accept_en (IFI-008)
    input  wire [7:0]            s_data,      // pixel byte, or label byte when s_last
    input  wire                  s_last,      // marks the final (label) byte of a frame

    // Learner interface (IFI-003)
    output reg                   sample_valid, // level: full sample captured, awaiting ack
    output wire [7:0]            label,        // level: captured label byte
    input  wire                  ack_p,        // 1-cycle learner accept pulse (clears level)
    input  wire [W_F-1:0]        x_addr,       // pixel read address
    output wire [7:0]            x_rdata,      // combinational pixel read data (MEM-002)

    // Stats interface (IFI-007)
    output reg                   err_p,        // 1-cycle malformed-sample pulse

    // Learner backpressure (IFI-008)
    input  wire                  accept_en,    // s_ready source: run_active && learner IDLE

    // ---- FORMAL PROBE (verify/formal/sample_stream_fv.v copy only) ----
    output wire                  fp_sstate     // FSM-002 state
);

    // FSM-002 states (binary, reset = WAIT). One extra state (RESYNC) drains a
    // malformed frame up to and including its s_last byte before reframing.
    localparam ST_WAIT   = 1'b0;
    localparam ST_RESYNC = 1'b1;

    // Pixel count that marks a full frame, sized to the counter so the
    // == / < comparisons match width exactly. Lossless because
    // FEATURES <= 2**W_F - 1 by the port assumption above.
    localparam [W_F-1:0] FEAT = FEATURES;

    // MEM-002 (sample RAM): pixel store. Single write path (WAIT good-pixel
    // beats); combinational read below. Reset-exempt — the write-before-read
    // protocol (a pixel is stored before the learner ever reads it) means
    // stale contents can never be observed, so no reset loop is spent on it.
    reg [7:0] mem [0:FEATURES-1];

    // FSM-002 registers, all owned by the single sequential block below.
    reg              state_r;               // ST_WAIT / ST_RESYNC
    reg [W_F-1:0]    px_cnt;                 // pixels stored so far, range 0..FEAT
    reg [7:0]        label_ff;               // captured label byte

    // s_ready is purely combinational per FSM-002 / IFI-008 — never registered,
    // so upstream sees ready in the same cycle the learner opens acceptance.
    assign s_ready = accept_en;

    // Combinational pixel read port (IFI-003). Single reader path; mem has one
    // writer (the sequential block), so this is not a multiply-driven net.
    assign x_rdata = mem[x_addr];

    // Formal probe (flat alias — copy only)
    assign fp_sstate = state_r;

    // Level output driven from the owned register.
    assign label = label_ff;

    // A transfer happens only when both sides agree this cycle.
    wire beat = s_valid & s_ready;

    // Single owner of every FSM-002 register (state_r, px_cnt, label_ff,
    // sample_valid, err_p) and of MEM-002. Synchronous active-low reset
    // (ASM-002): no negedge in the sensitivity list.
    always @(posedge clk_core) begin
        if (!rst_n) begin
            state_r      <= ST_WAIT;
            px_cnt       <= {W_F{1'b0}};
            label_ff     <= 8'h00;
            sample_valid <= 1'b0;
            err_p        <= 1'b0;
        end else begin
            // Defaults each cycle: err_p is a 1-cycle pulse (low unless asserted
            // on a malformed transition this cycle).
            err_p <= 1'b0;

            // Learner ack clears the level, in any state. Placed before the case
            // so that a simultaneous good-label capture (which re-asserts the
            // level) takes priority via last-write-wins — the freshly captured
            // sample stays valid.
            if (ack_p) begin
                sample_valid <= 1'b0;
            end

            case (state_r)
                ST_WAIT: begin
                    if (beat) begin
                        // Order per FSM-002 table (most-specific first). px_cnt is
                        // bounded to [0,FEAT], so exactly one arm fires; the check
                        // uses the CURRENT px_cnt (pixels already stored), never a
                        // pre-incremented value.
                        if (!s_last && (px_cnt < FEAT)) begin
                            // In-frame pixel byte: store and advance.
                            mem[px_cnt] <= s_data;
                            px_cnt      <= px_cnt + 1'b1;   // bounded, no wrap
                        end else if (s_last && (px_cnt == FEAT)) begin
                            // Valid end-of-sample: this byte is the label.
                            label_ff     <= s_data;
                            sample_valid <= 1'b1;
                            px_cnt       <= {W_F{1'b0}};
                        end else if (s_last && (px_cnt < FEAT)) begin
                            // Short frame: last arrived before FEATURES pixels.
                            err_p        <= 1'b1;
                            sample_valid <= 1'b0;
                            state_r      <= ST_RESYNC;
                        end else begin
                            // !s_last && px_cnt == FEAT: extra pixel, last missing.
                            err_p        <= 1'b1;
                            sample_valid <= 1'b0;
                            state_r      <= ST_RESYNC;
                        end
                    end
                    // no beat: hold (flops retain value).
                end

                ST_RESYNC: begin
                    // Drain the malformed frame; discard every byte until its
                    // terminating s_last, then reframe with a cleared counter.
                    if (beat && s_last) begin
                        px_cnt  <= {W_F{1'b0}};
                        state_r <= ST_WAIT;
                    end
                    // beat && !s_last: discard (no action). no beat: hold.
                end

                default: begin
                    // Illegal-state recovery (unreachable with 1-bit state, kept
                    // per coding law: every case has a default).
                    state_r <= ST_WAIT;
                end
            endcase
        end
    end

endmodule

`default_nettype wire                        // restore global default for downstream files
