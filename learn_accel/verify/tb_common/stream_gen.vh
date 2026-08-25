//---------------------------------------------------------------------
// tb_common/stream_gen.vh — extended stream generator (IF-002)
// Project  : rinriAI (PRJ-005) verification infrastructure
// Language : pure Verilog-2001 (include file, ifndef-guarded)
// Purpose  : Frame builder (directed + LFSR constrained-random with
//            malformed-frame injection + backpressure control) on top of
//            tb_common/stream_byte.vh.
//            Valid frame = FEATURES pixel bytes (s_last=0) then one label
//            byte (s_last=1). Malformed variants per REQ-018:
//              M_LAST_EARLY  : s_last at pixel index i (< FEATURES)
//              M_NO_LAST     : label-position byte without s_last
//              M_EMPTY       : s_last on the very first byte (i=0)
//            After a malformed frame the DUT is in RESYNC; the caller
//            must send one resync byte (s_last=1, discarded) before the
//            next valid frame.
// Usage    : TB declares stream signals (s_valid, s_ready, s_data,
//            s_last), a module-level pixel array `reg [7:0]
//            pixels [0:255];` (Verilog-2001 cannot pass arrays as task
//            ports), regs accept_en_override + ack_p, localparam
//            FEATURES, then includes this file (pulls in stream_byte.vh).
//            Backpressure injection: TB muxes accept_en as
//            `accept_en_base & accept_en_override` (str_hold_ready
//            drives the override).
//---------------------------------------------------------------------
`ifndef TB_COMMON_STREAM_GEN_VH
`define TB_COMMON_STREAM_GEN_VH
`include "tb_common/stream_byte.vh"

// Hold the s_ready path (accept_en) low for n+1 cycles, then restore.
// The TB must wire its accept_en driver so this task can override it
// (see tb_sample_stream.v for the mux pattern).
task str_hold_ready;
    input       hold;                    // 1 = hold low
    input [2:0] n;                       // cycles 0..7 -> hold n+1
    integer c;
    begin
        if (hold) begin
            accept_en_override <= 1'b0;
            for (c = 0; c <= n; c = c + 1) @(posedge clk_core);
            accept_en_override <= 1'b1;
        end
    end
endtask

// Stream one valid frame (FEATURES pixels + label) from the TB's
// module-level `pixels` array. Optionally random backpressure pauses.
task stream_frame;
    input [7:0] label;
    input       bp_en;                   // 1 = inject random backpressure pauses
    input [31:0] seed;
    integer i;
    reg [31:0] st;
    begin
        st = seed;
        for (i = 0; i < FEATURES; i = i + 1) begin
            if (bp_en && (st[3:0] < 4'd6)) begin   // ~37% chance of a pause
                st = lfsr32(st);
                str_hold_ready(1'b1, st[2:0]);     // drop accept for 1..8 cycles
                st = lfsr32(st);
            end
            stream_byte(pixels[i], 1'b0);
            st = lfsr32(st);
        end
        stream_byte(label, 1'b1);
    end
endtask

// Malformed frame: s_last asserted at pixel index `at` (0..FEATURES-1).
// The DUT flags err and enters RESYNC; caller then sends the resync byte.
task stream_malformed_early_last;
    input [15:0] at;                     // pixel index where s_last fires
    integer i;
    begin
        for (i = 0; i < FEATURES && i <= at; i = i + 1)
            stream_byte(pixels[i], (i == at) ? 1'b1 : 1'b0);
    end
endtask

// Resync byte: s_last=1, discarded by the DUT to exit RESYNC.
task stream_resync_byte;
    begin
        stream_byte(8'h00, 1'b1);
    end
endtask

// Ack pulse: assert mid-cycle (negedge), sampled at the posedge, then
// deassert with a non-blocking assignment so the DUT sees ack_p=1 at the
// edge and the deassert cannot race ahead of the DUT's sampling.
task stream_ack;
    begin
        @(negedge clk_core);
        ack_p <= 1'b1;
        @(posedge clk_core);             // DUT samples ack_p=1 here
        ack_p <= 1'b0;
        @(negedge clk_core);
    end
endtask

`endif // TB_COMMON_STREAM_GEN_VH
