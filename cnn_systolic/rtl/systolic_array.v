//---------------------------------------------------------------------
// Module      : systolic_array
// Project     : cnn_systolic        Technology : Sky130 130 nm
// Traces      : REQ-022, REQ-023, REQ-024, BLK-010
// Description : 8×8 weight-stationary BF16 systolic PE grid with FP32
//               accumulate.  The BIT-EXACT accumulate-order contract
//               (systolic_dataflow.md §1): per output channel the FP32
//               add sequence is bias, then one product per sub-pass, in
//               the pinned sub-pass order.  Implemented as a LEFT-TO-
//               RIGHT PARTIAL-SUM CHAIN with per-column commit strobes:
//               col 0 adds (bias + prod0), col 1 adds (acc0 + prod1),
//               ..., col 7 adds (acc6 + prod7) — identical add order to
//               the golden's per-oc sequential loop (the golden computes
//               rows sequentially, the array in parallel — rows share no
//               state, bit-identical).  add_en[c] commits col c's add
//               one cycle after col c-1's (register-to-register chain,
//               one fp32_add per stage → ~5-6 ns stage, closes 10 ns).
//               Two-stage MAC: stage-1 prod = fpu_bf16_mul(w_a, act[c])
//               (exact, BF16×BF16), stage-2 acc = fpu_fp32_add(acc_in,
//               prod).  The 8 activations of a sub-pass are latched in
//               PARALLEL at act_ld (sub-pass cycle 0); the arch's
//               "wavefront 1 column/cycle" prose is ambiguous (a
//               1-col/cycle chain cannot deliver act_c to col c by cycle
//               c); the parallel latch reproduces the same per-PE
//               product values and add order — the contract's substance.
//               Weight shadow-load: w_load_data per column, w_load_en
//               per PE (bit r*8+c); swap at sub-pass boundaries.
//               Drain: dout[r] = acc[r][7] (the full sum), captured at
//               drain_en.
// Clock/Reset : clk (CD_CORE, 100 MHz) / rst_n (fully synchronous)
// Assumptions : sub-pass timing owned by conv_ctrl (10 cycles: act_ld
//               at t0, adds at t2..t9, swap at t9); bias_in rows are
//               the expanded BF16 biases for the active oc-group.
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module systolic_array (
    input  wire         clk,          // CD_CORE clock, 100 MHz
    input  wire         rst_n,        // fully synchronous active-low reset
    // IFI-006 feed
    input  wire [127:0] act_in,       // 8 columns x 16b BF16 (lane c = col c)
    input  wire         act_ld,       // latch act lanes (sub-pass cycle 0)
    input  wire [127:0] w_load_data,  // shadow weight load data (col c = [16*c +: 16])
    input  wire [63:0]  w_load_en,    // per-PE enable (bit r*8+c)
    input  wire         w_swap,       // w_a <= w_s (sub-pass boundary)
    input  wire [255:0] bias_in,      // 8 rows x 32b FP32 bias (row r = [32*r +: 32])
    input  wire         bias_en,      // preload accs with bias (ST_BIAS; harmless with chain)
    input  wire [7:0]   add_en,       // per-column add commit strobe (col c at sub_t == c+2)
    input  wire         drain_en,     // capture dout <= acc[r][7]
    output wire [255:0] dout          // 8 rows x 32b FP32 sums (row r = [32*r +: 32])
);

    // PE state: weights (active/shadow), accumulator, stage-1 product.
    reg [15:0] w_a [0:63];
    reg [15:0] w_s [0:63];
    reg [31:0] acc  [0:63];
    reg [31:0] prod [0:63];

    // Per-column activation register (shared across the 8 rows).
    reg [15:0] act [0:7];

    // Drain capture register (held until the next drain).
    reg [255:0] dout_r;

    genvar r, c;
    generate
        for (r = 0; r < 8; r = r + 1) begin : g_row
            for (c = 0; c < 8; c = c + 1) begin : g_col
                // Partial-sum chain: col 0's input is the bias row, col c's
                // input is col c-1's accumulator (register-to-register).
                wire [31:0] acc_in = (c == 0) ? bias_in[32*r +: 32]
                                              : acc[r*8 + (c-1)];
                wire [31:0] prod_nxt;
                wire [31:0] acc_nxt;

                fpu_bf16_mul u_mul (
                    .a (w_a[r*8+c]),
                    .b (act[c]),
                    .y (prod_nxt)
                );

                fpu_fp32_add u_add (
                    .a (acc_in),
                    .b (prod[r*8+c]),
                    .y (acc_nxt)
                );

                // RESET-EXEMPT (arch.md §4 BLK-010: "the PE stage-1 product
                // register may be reset-exempt if flushed by advance
                // qualification — document it"): EVERY PE flop is written
                // before use by the FSM schedule — acc <= bias_init (ST_BIAS),
                // w_s <= shadow load + w_swap, act <= act_ld (sub-pass t0),
                // prod <= stage-1 mul, dout_r <= drain capture — so the
                // park reset term is omitted here.  This removes ~6.5k flops
                // from the unbuffered core_rst_n fanout tree (P4 timing fix;
                // validated functionally by the P6 SoC diff).
                always @(posedge clk) begin
                    if (w_load_en[r*8+c]) w_s[r*8+c] <= w_load_data[16*c +: 16];
                    if (w_swap)           w_a[r*8+c] <= w_s[r*8+c];
                    prod[r*8+c] <= prod_nxt;
                    if (bias_en)          acc[r*8+c] <= bias_in[32*r +: 32];
                    else if (add_en[c])   acc[r*8+c] <= acc_nxt;
                end
            end
        end
    endgenerate

    // Activation latch (parallel, per column).
    genvar cc;
    generate
        for (cc = 0; cc < 8; cc = cc + 1) begin : g_act
            // Reset-exempt (act_ld overwrites before the stage-1 mul uses it).
            always @(posedge clk) begin
                if (act_ld) act[cc] <= act_in[16*cc +: 16];
            end
        end
    endgenerate

    // Drain: full sums live in the LAST column of each row.
    genvar dr;
    generate
        for (dr = 0; dr < 8; dr = dr + 1) begin : g_drain
            // Reset-exempt (drain_en captures before the FM writes use it).
            always @(posedge clk) begin
                if (drain_en) dout_r[32*dr +: 32] <= acc[dr*8 + 7];
            end
        end
    endgenerate

    assign dout = dout_r;

endmodule

`default_nettype wire
