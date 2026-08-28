# Pure-Verilog RTL Coding Guidelines — cnn_systolic
Binding on fe-rtl. Verilog-2001 only (IEEE 1364-2001; no SystemVerilog of any kind).

## 1. Language subset
Allowed: module/endmodule, ANSI or non-ANSI port lists, wire, reg, integer (block-local loop
vars ONLY — never a module-scope integer shared across two always blocks), parameter,
localparam, generate/genvar, always @(posedge clk [or negedge rst_n]), always @*, assign,
case/casez with default, function, task, `define sparingly, (* attributes *), signed.
Forbidden: always_ff, always_comb, always_latch, logic, bit, byte, int, enum, typedef, struct,
union, interface, package, import, assert/assume/cover, property, sequence, covergroup,
unique, priority, .*, do-while, ++/--, casex (X-propagation hazard).

## 2. File and naming rules
One module per file; filename == module name + `.v`. Lower snake_case modules/signals,
UPPER_SNAKE parameters. Suffixes: `_n` active low, `_r` registered, `_nxt` next-state, `_en`
enable, `_valid/_ready` handshake, `_q/_d` flop output/input, `_sync` CDC-synchronised.
FP datapath names (fixed across modules): `fp32_add`, `fp32_mul`, `bf16_to_fp32`,
`fp32_to_bf16` (or `bf16_round`), `fpu_*` for signals of the FP units. No port-direction
suffixes (`_i`/`_o`) — the project does not use them.

## 3. Clocking and reset
Clock port name: `clk` (single domain). Reset: `rst_n`, active low, **fully synchronous** —
the fixed sequential template is:
    always @(posedge clk)
      if (!rst_n) q <= RESET_VALUE;
      else        q <= d;
**No `negedge rst_n` anywhere** (REQ-035). Every flop has a defined reset value; the only
exceptions are SRAM-macro blackbox internals and pure pipeline registers explicitly listed in
arch.md as reset-exempt (the PE stage-1 product register may be reset-exempt if flushed by
`advance` qualification — document it in the header).

## 4. Combinational logic
always @* with a default assignment to every LHS on the first line of the block; blocking (=)
assignments only. case statements always have `default:`. No latches — ever.

## 5. FSM style
Three-block style: state register (sequential), next-state (combinational), outputs (registered
where timing-critical). States as localparam. Encodings per arch.md §6 (all binary). Illegal
states go to the reset state via `default:`.

## 6. Assignment discipline
Non-blocking (<=) in sequential blocks; blocking (=) in combinational blocks. Never mix in one
block. Never assign the same reg from two always blocks.

## 7. Widths and constants
Every literal sized and based (8'h00, 16'd1024, 1'b0). No bare integers in comparisons or
assignments. Widths match on both sides; explicit zero/sign extension. The FP32 units operate
on 32-bit IEEE bit patterns (`[31:0]`); never treat them as signed integers.

## 8. Parameterisation
parameter for user overrides, localparam for derived values. No magic numbers. The FP constants
(sigmoid coefficients, breakpoints) must be written as the exact 32-bit hex bit patterns of
`piecewise_sigmoid.md` §2 (`32'h3E800000`, ...) with a `//` comment naming the dyadic value —
never as decimal literals or `$itor`/real expressions.

## 9. CDC
Zero CDC paths exist in this design (cdc_plan.md). No synchronisers, no async FIFOs. The only
generated clock is the PWR-001 ICG output; instantiate `sky130_fd_sc_hd__dlclkp_1` with the
enable `core_clk_en` and declare the gated clock in sdc_spec.json.

## 10. Clock gating
Enable-based gating only; the ICG cell per power_plan.md PWR-001; never gate a clock with a raw
AND/OR in RTL; no scan-enable term (DFT is out of scope); no `sky130_fd_sc_hd__sdlclkp*` cells.

## 11. Instantiation
Named port connections only (.a(a)), never positional. Named parameter overrides #(.W(8)).
SRAM-macro blackboxes: instantiate via the stub modules (sky130_sram_* names PDK-verified at
fe-rtl, OI-001) with named ports only; every stub carries the `/* blackbox */` attribute and a
header naming the OI-001 status.

## 12. Comments and headers
Every file starts with the header block in section 13. Every port, parameter and non-obvious
expression gets a `//` comment. No block comments in RTL.

## 13. File header template
    //---------------------------------------------------------------------
    // Module      : <name>
    // Project     : cnn_systolic        Technology : Sky130 130 nm
    // Traces      : REQ-0xx, BLK-0xx
    // Description : <what it does>
    // Clock/Reset : clk (CD_CORE, 100 MHz) / rst_n (fully synchronous, active-low)
    // Assumptions : <...>
    // Source      : custom | reused from <repo> (<licence>) | blackbox <cell>
    //---------------------------------------------------------------------

## 14. Prohibited constructs
initial blocks in synthesisable RTL (except `$readmemh` ROM initialisation);
delays (#) in RTL; `casex`; multiple drivers; combinational loops; incomplete sensitivity lists
(use always @*); tri-state internal to the core (pads only); DFT structures of any kind;
SystemVerilog of any kind; real/float in RTL (the FP units are bit-pattern logic, never real).

## 15. FP unit contract (the bit-exact core — read arch/systolic_dataflow.md first)
- `fp32_add`: full IEEE-754 add on bit patterns: zero-operand shortcuts (x + ±0 = x; +0 + -0 =
  +0), exponent alignment with guard/round/sticky (26-bit intermediate minimum), add/subtract,
  leading-zero normalize, RN-even rounding at the 24-bit boundary, mantissa-overflow shift,
  **FTZ**: subnormal result (exp field would be 0 with nonzero mantissa) → ±0 (keep sign of the
  exact result); overflow (unreachable by range analysis) → ±Inf per IEEE.
- `fp32_mul`: sign XOR, exponent add − bias, 24×24 mantissa product, normalize, RN-even round
  to 24 bits, FTZ on subnormal results. (BF16×BF16 operands produce ≤ 16-bit significands —
  exact; the general path exists for the sigmoid.)
- `bf16_round` (FP32→BF16): keep top 7 mantissa bits; round bit = mant[15], sticky = |mant[14:0]|;
  RN-even (round && (sticky || keep[0])); keep overflow → mantissa 0, exp+1; FTZ: subnormal or
  zero input → ±0 (sign kept); result bit pattern = {s, exp[7:0], keep[6:0]}.
- `bf16_to_fp32` (expand): {s, exp, keep, 16'b0} — exact.
- pixel→BF16: value = p/256: p==0 → 16'h0000; else e = 7 − clz8(p); bits = {1'b0, 119+e[7:0],
  (p << (7-e)) & 7'h7F} — implement with a small shifter; no FP path.
- sigmoid: segment compare on |z| (unsigned bit compare after sign clear); scale-mul
  (mantissa × k, exponent − s, normalize, RN-even — bit-identical to fp32_mul(m, x), see
  piecewise_sigmoid.md §3.2); then fp32_add with c; sign fold fp32_sub(1.0, s).
- sigma256: {exp+8} exact scale; fp32_add +0.5; truncate (drop fraction) → 9-bit integer.
- The **order** of fp32 operations must follow systolic_dataflow.md §3-5 exactly — this is the
  bit-exactness contract; never fuse, reorder, or tree-reduce the adds.
