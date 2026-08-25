//---------------------------------------------------------------------
// Module      : div_seq
// Project     : rinriAI   Technology : Sky130 130 nm
// Traces      : REQ-004, REQ-011, BLK-007
// Description : Sequential sign-magnitude restoring integer divider that
//               computes trunc(num/den) toward zero (C99 '/' semantics)
//               for the sigmoid evaluation. num = 128*z (signed 32-bit),
//               den = 256+|z| (unsigned 17-bit); quotient is 17-bit signed.
//               Called by BLK-004 learner. Latency 33 cycles (32 iterations
//               of shift-subtract + 1 capture cycle) from div_start to
//               div_done. Truncation toward zero is exact by construction:
//               the magnitude is divided, then negated if num is negative.
// Clock/Reset : clk_core (CD_CORE) / rst_n (synchronous, active low)
// Assumptions : den >= 256 in this design (256+|z|), so den is always a
//               positive divisor and the quotient sign equals num[31].
//               den==0 cannot occur, but is handled (q=0) so the block
//               never produces garbage on a degenerate 0/0 input. The FSM
//               is counter-driven and therefore can never hang.
// Source      : custom (no external IP)
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none                 // catch implicit-wire typos

module div_seq (
    input  wire                clk_core,   // core clock, single domain CD_CORE
    input  wire                rst_n,      // synchronous active-low reset (ASM-002)
    input  wire                div_start,  // 1-cycle start pulse: capture num/den
    input  wire        [31:0]  div_num,    // dividend, signed (128*z)
    input  wire        [16:0]  div_den,    // divisor, unsigned (256+|z|)
    output reg                 div_busy,   // high from capture until div_done
    output reg                 div_done,   // 1-cycle pulse: div_q is valid this cycle
    output reg  signed [16:0]  div_q       // quotient, signed, valid with div_done
);

    // FSM-004 states (binary, reset = ST_IDLE) — arch.md 6.4
    localparam [1:0] ST_IDLE = 2'd0,      // waiting for div_start
                     ST_ITER = 2'd1,      // 32 shift-subtract iterations
                     ST_DONE = 2'd2;      // emit div_done, return to idle

    reg [1:0]  state_r, state_nxt;

    // Datapath registers
    reg [5:0]  iter_r;                     // iteration counter 0..32 (needs 6 bits)
    reg [17:0] acc_r;                      // running remainder; < den <= 2^17-1
    reg [31:0] mag_r;                      // |num|, shifted left MSB-first each step
    reg [31:0] q_mag_r;                    // accumulated quotient magnitude (qbits)
    reg [16:0] den_r;                      // captured divisor, stable per operation
    reg        sign_r;                     // captured num[31]: quotient sign

    // Combinational restoring-step values (pure function of the datapath regs)
    reg [17:0] acc_shifted;                // (acc_r << 1) with next mag bit shifted in
    reg [17:0] den_ext;                    // den_r zero-extended to 18 bits for compare
    reg        ge_c;                       // acc_shifted >= den ?  -> subtract this step
    reg        qbit_c;                     // quotient bit produced this step
    reg [17:0] acc_next_c;                 // remainder after the (restoring) subtract

    //-----------------------------------------------------------------
    // FSM-004 : state register (synchronous reset per ASM-002)
    //-----------------------------------------------------------------
    always @(posedge clk_core)
        if (!rst_n) state_r <= ST_IDLE;
        else        state_r <= state_nxt;

    //-----------------------------------------------------------------
    // FSM-004 : next-state (combinational, full coverage, default -> IDLE)
    //-----------------------------------------------------------------
    always @* begin
        state_nxt = state_r;                       // default: hold
        case (state_r)
            ST_IDLE : if (div_start)         state_nxt = ST_ITER;
            ST_ITER : if (iter_r == 6'd32)   state_nxt = ST_DONE;  // all 32 bits done
            ST_DONE :                        state_nxt = ST_IDLE;
            default :                        state_nxt = ST_IDLE;  // illegal-state recovery
        endcase
    end

    //-----------------------------------------------------------------
    // Restoring shift-subtract stage (combinational; blocking assigns).
    // Every LHS is assigned unconditionally on entry -> no latch.
    //-----------------------------------------------------------------
    always @* begin
        acc_shifted = {acc_r[16:0], mag_r[31]};    // bring in the next MSB of |num|
        den_ext     = {1'b0, den_r};               // 18-bit unsigned compare operand
        ge_c        = (acc_shifted >= den_ext);    // fits without subtract-and-restore
        qbit_c      = ge_c;                         // quotient bit = did it fit
        acc_next_c  = ge_c ? (acc_shifted - den_ext) : acc_shifted;
    end

    //-----------------------------------------------------------------
    // Datapath / outputs (sequential, non-blocking, synchronous reset).
    // div_done is a 1-cycle pulse: default low, raised only at finalize.
    //-----------------------------------------------------------------
    always @(posedge clk_core) begin
        if (!rst_n) begin
            div_busy <= 1'b0;
            div_done <= 1'b0;
            div_q    <= 17'd0;
            iter_r   <= 6'd0;
            acc_r    <= 18'd0;
            mag_r    <= 32'd0;
            q_mag_r  <= 32'd0;
            den_r    <= 17'd0;
            sign_r   <= 1'b0;
        end else begin
            div_done <= 1'b0;                       // pulse default; finalize overrides
            case (state_r)
                ST_IDLE : begin
                    if (div_start) begin
                        den_r    <= div_den;
                        sign_r   <= div_num[31];                       // den>0 -> q sign = num sign
                        mag_r    <= div_num[31] ? (~div_num + 32'd1)   // |num|
                                                : div_num;
                        acc_r    <= 18'd0;
                        q_mag_r  <= 32'd0;
                        iter_r   <= 6'd0;
                        div_busy <= 1'b1;
                    end
                end
                ST_ITER : begin
                    if (iter_r == 6'd32) begin
                        // Finalize: apply sign to the low 17 quotient bits (upper
                        // bits are zero by design: |q| <= 128*32767/256 < 2^14).
                        // den==0 guard keeps a degenerate 0/0 from emitting junk.
                        div_q    <= (den_r == 17'd0) ? 17'd0
                                  : (sign_r ? (17'd0 - q_mag_r[16:0]) : q_mag_r[16:0]);
                        div_busy <= 1'b0;
                        div_done <= 1'b1;
                    end else begin
                        acc_r    <= acc_next_c;                        // updated remainder
                        q_mag_r  <= {q_mag_r[30:0], qbit_c};           // shift in quotient bit
                        mag_r    <= {mag_r[30:0], 1'b0};               // consume the used MSB
                        iter_r   <= iter_r + 6'd1;
                    end
                end
                ST_DONE : begin
                    // div_done already defaulted low; nothing else to do this cycle.
                end
                default : begin
                    div_busy <= 1'b0;                                  // recovery: drop busy
                end
            endcase
        end
    end

endmodule

`default_nettype wire                  // restore default for downstream tools
