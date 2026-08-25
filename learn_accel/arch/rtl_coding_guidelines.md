# Pure-Verilog RTL Coding Guidelines — rinriAI
Binding on fe-rtl. Verilog-2001/2005 only.

## 1. Language subset
Allowed: module/endmodule, ANSI or non-ANSI port lists, wire, reg, integer (block-local
loop vars ONLY — never a module-scope integer shared across two always blocks), parameter,
localparam, generate/genvar, always @(posedge clk [or negedge rst_n]), always @*, assign,
case/casez with default, function, task, `define sparingly, (* attributes *), signed.
Forbidden: always_ff, always_comb, always_latch, logic, bit, byte, int, enum, typedef,
struct, union, interface, package, import, assert/assume/cover, property, sequence,
covergroup, unique, priority, .*, do-while, ++/--, casex (X-propagation hazard).

## 2. File and naming rules
One module per file; filename == module name + `.v`. Lower snake_case for modules and
signals; parameters in UPPER_SNAKE. Suffixes: `_p` 1-cycle pulse, `_n` active low,
`_r` registered, `_ff` flop, `_nxt` next-state, `_en` enable, `_valid`/`_ready`
handshake, `_q`/`_d` flop output/input, `_i`/`_o` port-direction suffixes on ports.
Module names are fixed by `arch/arch_manifest.yaml` module_list.

## 3. Clocking and reset
Clock port name: `clk_core`. Reset port name: `rst_n`, active low, **synchronous**
(project decision ASM-002 — assert and de-assert on posedge clk_core; the fe-arch default
async-assert template does NOT apply here). Fixed sequential template:

    always @(posedge clk_core)
      if (!rst_n) q <= RESET_VALUE;
      else        q <= d;

Every flop has a defined reset value, except pure data-path pipeline registers
explicitly listed in arch.md as reset-exempt (none in this design — all regs reset).

## 4. Combinational logic
always @* with a default assignment to every LHS on the first line of the block; blocking
(=) assignments only. case statements always have `default:`. No latches — ever.

## 5. FSM style
Three-block style: state register (sequential), next-state (combinational), outputs
(registered where timing-critical). States as localparam. Encodings per arch.md section 6
(FSM-001..004, all binary). Illegal states go to the reset state via `default:`.

## 6. Assignment discipline
Non-blocking (<=) in sequential blocks; blocking (=) in combinational blocks. Never mix
in one block. Never assign the same reg from two always blocks.

## 7. Widths and constants
Every literal is sized and based (8'h00, 16'd1024, 1'b0). No bare integers in
comparisons or assignments. Widths must match on both sides; use explicit zero/sign
extension.

## 8. Parameterisation
parameter for user overrides, localparam for derived values. No magic numbers. Derive:
W_TOT = FEATURES*HIDDEN + HIDDEN + HIDDEN*CLASSES + CLASSES; W_F = clog2(FEATURES+1)
(implement with a localparam function or a generate-if chain; document the choice);
W_H, W_C likewise; W_A = 16. Document legal ranges; illegal values are caught only by
the TB (no synthesis-safe guard required beyond comments).

## 9. CDC
None exist (single domain). No synchronisers, no CDC modules. If one is ever added it
must follow cdc_plan.md — do not add ad-hoc synchronisers.

## 10. Clock gating
Enable-based gating only (PWR-001..004): write `if (en)` around register updates, never
`assign` a clock. No explicit ICG cell instantiation in this RTL; if one is added later
it must be `sky130_fd_sc_hd__dlclkp_1` (non-scan). No scan-enable term ever.

## 11. Instantiation
Named port connections only (.a(a)), never positional. Named parameter overrides
#(.W(8)).

## 12. Comments and headers
Every file starts with the header block in section 13. Every port, parameter and
non-obvious expression gets a `//` comment. No block comments in RTL.

## 13. File header template
    //---------------------------------------------------------------------
    // Module      : <name>
    // Project     : rinriAI   Technology : Sky130 130 nm
    // Traces      : REQ-0xx, BLK-0xx
    // Description : <what it does>
    // Clock/Reset : clk_core (CD_CORE) / rst_n (synchronous, active low)
    // Assumptions : <...>
    // Source      : custom (no external IP)
    //---------------------------------------------------------------------

## 14. Prohibited constructs
initial blocks in synthesisable RTL; delays (#) in RTL (simulation-only `#` belongs
exclusively in tb/, never in rtl/); `casex`; multiple drivers; combinational loops;
incomplete sensitivity lists (use always @*); tri-state internal to the core;
DFT structures of any kind (no scan, no `sdlclkp`, no JTAG/BIST); SystemVerilog of any
kind. Blackbox stubs in rtl/blackbox/ (if any are ever added) are pure port shells: no
`#`, no `initial`, no clock generation, no oscillators — the harness owns all clocks.

## 15. Fixed-point helpers (bit-exactness contract, arch.md section 5)
Implement these exactly as specified; they appear verbatim in the golden model:

- `trunc_pow2(x, n)`: `(x >= 0) ? (x >> n) : -((-x) >> n)` — magnitude-shift-negate
  idiom; never a bare `>>>`.
- `sat16(x)`: clamp to [-32768, 32767].
- Sigmoid: `q = trunc_div(128*z, 256+|z|)` via BLK-007 div_seq (sign-magnitude
  restoring, truncation toward zero); `sigma = 128 + q`.
- MAC: 48-bit signed accumulator; bias pre-loaded as `bias << 8`; conversion
  `z = sat16(trunc_pow2(acc, 8))`.
- Updates: `upd = trunc_pow2(delta * a_prev, lr_shift + 8)`; `w_new = sat16(w - upd)`;
  bias: `upd = trunc_pow2(delta, lr_shift)`.
- MAC order is strictly increasing index (f, h, c) — never reorder for bit-exactness.
