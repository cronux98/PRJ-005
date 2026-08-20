//---------------------------------------------------------------------
// tb_common/stream_byte.vh — core byte-stream driver (IF-002)
// Project  : rinriAI (PRJ-005) verification infrastructure
// Language : pure Verilog-2001 (include file, ifndef-guarded)
// Purpose  : LFSR-32 helper + the single-byte valid/ready driver used by
//            every stream test. Extended tasks (frames, malformed,
//            backpressure) live in stream_gen.vh.
// Usage    : TB declares stream signals (s_valid, s_ready, s_data,
//            s_last) + localparam FEATURES, then includes this file.
// Beat semantics: the beat is the FIRST posedge after assertion where
// s_ready is high. If s_ready is already high at assertion, the beat is
// the next posedge; if it is low, the posedge where it rises IS the beat
// (an extra cycle would duplicate the byte). One settle cycle after the
// beat keeps caller checks free of delta-cycle races.
//---------------------------------------------------------------------
`ifndef TB_COMMON_STREAM_BYTE_VH
`define TB_COMMON_STREAM_BYTE_VH

// Galois LFSR-32 (polynomial x^32+x^22+x^2+x+1, maximal length 2^32-1).
// Pure combinational function; caller keeps state in a reg.
function [31:0] lfsr32;
    input [31:0] state;
    begin
        lfsr32 = (state >> 1) ^ (state[0] ? 32'h0020_0003 : 32'h0000_0000);
    end
endfunction

// Stream one byte with the valid/ready handshake (see header for beat
// semantics). Holds s_valid stable while stalled: zero bytes lost.
task stream_byte;
    input [7:0] d;
    input       last;
    begin
        s_valid <= 1'b1;
        s_data  <= d;
        s_last  <= last;
        if (!s_ready) begin
            while (!s_ready) @(posedge clk_core);  // beat at the ready-rising edge
        end else begin
            @(posedge clk_core);                   // beat at the next posedge
        end
        s_valid <= 1'b0;
        s_last  <= 1'b0;
        @(posedge clk_core);             // settle: DUT NBA visible
    end
endtask

`endif // TB_COMMON_STREAM_BYTE_VH
