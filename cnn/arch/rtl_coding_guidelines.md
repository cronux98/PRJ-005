# Pure-Verilog RTL Coding Guidelines — cnn (mnist_npu v2)
Binding on fe-rtl. Verilog-2001/2005 only. Technology: FPGA-generic (Xilinx Artix-7 100T / Nexys
A7 eventual target) — see `arch.md` §2 for the documented deviation from the pipeline's Sky130
default; nothing below references a Sky130 cell or PDK-specific construct. This document mirrors
v1 `mnist_npu/arch/rtl_coding_guidelines.md` (same project, same conventions) with CNN-specific
additions (§7, §15) called out explicitly.

## 1. Language subset
Allowed: module/endmodule, ANSI or non-ANSI port lists, wire, reg, integer (block-local loop vars
ONLY — never a module-scope integer shared across two always blocks), parameter, localparam,
generate/genvar, always @(posedge clk) [see §3 for the mandatory SYNCHRONOUS-ONLY reset template],
always @*, assign, case/casez with default, function, task, `define sparingly, (* attributes *),
signed.
Forbidden: always_ff, always_comb, always_latch, logic, bit, byte, int, enum, typedef, struct,
union, interface, package, import, assert/assume/cover, property, sequence, covergroup, unique,
priority, .*, do-while, ++/--, casex (X-propagation hazard), `always @(posedge clk or negedge
rst_n)` (see §3 — this project uses fully synchronous reset, NOT async-assert/sync-deassert).

## 2. File and naming rules
One module per file; filename == module name + `.v`. Lower snake_case for modules, signals,
parameters in UPPER_SNAKE. Suffixes: `_n` active low, `_r` registered, `_nxt` next-state, `_en`
enable, `_valid`/`_ready` handshake, `_q`/`_d` flop output/input, `_cnt` counter. No port-direction
suffix convention is used in this project (ports are typed `input`/`output` explicitly; no `_i`/`_o`).
Files copied verbatim from v1 (`sigmoid_lut.v`, `uart_tx.v`, `led_ctrl.v`, `uart_line_fmt.v`) keep
their v1 filenames unchanged.

## 3. Clocking and reset — SYNCHRONOUS ONLY (project-specific override)
Clock port name: `clk`. Reset port name: `rst_n`, active low, **fully synchronous** — a deliberate,
task-mandated deviation from the pipeline's usual async-assert/sync-deassert default (see `arch.md`
§9, `spec.md` §5). There is exactly one clock domain in this design, so no reset synchroniser
(`rst_sync`) is instantiated or needed anywhere.

The sequential template is fixed and is **different from the pipeline's usual example**:
```verilog
// SYNCHRONOUS reset — the ONLY legal sequential template in this project.
// Do NOT write `always @(posedge clk or negedge rst_n)` anywhere in this design.
always @(posedge clk) begin
    if (!rst_n) q <= RESET_VALUE;
    else        q <= d;
end
```
Every flop has a defined reset value, except pure data-path pipeline registers explicitly listed in
`arch.md` as reset-exempt and qualified by a valid/enable signal instead (none exist in this
design — every register in `arch.md` §4/§5/§6 has a stated reset value).

## 4. Combinational logic
`always @*` with a default assignment to every LHS on the first line of the block; blocking (`=`)
assignments only. `case` statements always have `default:`. No latches — ever. `win_addr_gen`
(BLK-012) is entirely one such block: every one of its five outputs (`irom_addr`, `wrom_addr`,
`fmram_rd_addr`, `fmram_wr_addr`, `tap_valid`) must be given a default value (e.g. all-zero /
`tap_valid=1'b0`) before the `case (layer_sel)` block, so the `default:` branch (and any
unreachable layer_sel value) cannot infer a latch.

## 5. FSM style
Three-block style: state register (sequential, §3 template), next-state (combinational), outputs
(registered where timing-critical). States as `localparam`. Binary encoding for all FSMs in this
design (`ctrl_fsm` outer: 8 states/3-bit; `mac_phase`/`pool_phase`: 6 states/3-bit;
`present_phase`: 2 states/2-bit; `uart_line_fmt`: 3 states/2-bit, reused v1; `uart_tx`: 4
states/2-bit, reused v1) — none require one-hot (no state count exceeds 8 under tight timing per
`arch.md` §6). Illegal states go to the reset/idle state via `default:`. `ctrl_fsm`'s composite
state (`state` + `phase`) is coded as two separate `case` blocks (outer `case (state)`, and within
each outer branch a `case (phase)`), never as one flattened cross-product state, to keep each `case`
statement small and reviewable.

## 6. Assignment discipline
Non-blocking (`<=`) in sequential blocks; blocking (`=`) in combinational blocks. Never mixed in
one block. Never assign the same `reg` from two `always` blocks.

## 7. Widths and constants (CNN-specific addition: mixed loop-counter widths)
Every literal is sized and based (`8'h00`, `16'sd1024`, `1'b0`). No bare integers in comparisons or
assignments. Widths must match on both sides; use explicit zero/sign extension. This project mixes
signed (weights, `mac_z`, `acc`) and always-non-negative-but-not-declared-`signed` operands (pixel
bytes, feature-map words post-ReLU); every multiply/add site in `mac_datapath` must state, in a
comment, why the operand is safe to treat as the non-negative half of a signed range (see `arch.md`
§5 for the exact widths at every node). `ctrl_fsm`'s loop counters (`u_cnt[4:0]`, `y_cnt[4:0]`,
`x_cnt[4:0]`, `ic_cnt[3:0]`, `iy_cnt[1:0]`, `ix_cnt[1:0]`, `i_cnt[9:0]`) are reused across layers
with different effective ranges per layer (e.g. `u_cnt` is 0..7 in CONV1/POOL1 but 0..31 in FC1) —
every comparison against a layer-dependent bound must use the `localparam` bound for the *current*
layer (from `arch.md` §6.1's per-state loop bounds table), never a bare literal, so the same
counter's differing bounds per layer are always traceable to their source.

## 8. Parameterisation
`parameter` for user overrides (`HOLD_CYCLES`, `BLINK_CYCLES`, `CLK_DIV`, `WEIGHTS_HEX_FILE`,
`IMAGES_HEX_FILE`, `LABELS_HEX_FILE`, `LUT_HEX_FILE`), `localparam` for derived values (address-map
constants, FSM state encodings, per-layer loop bounds, `fm_ram` region base addresses 0/6272). No
magic numbers. Every parameter's default AND simulation-override value is documented in `arch.md`
§6.8 and restated in the module's file header comment. **`BLINK_CYCLES` binding rule:** `cnn_npu`'s
own top-level parameter defaults to 100,000 (REQ-026) and MUST be passed to `led_ctrl` via an
explicit instance parameter override (`#(.BLINK_CYCLES(BLINK_CYCLES))`); `led_ctrl.v`'s own
file-local default (5,000,000, inherited unchanged from v1) is intentionally NOT the value used at
the top level — do not "fix" this by editing `led_ctrl.v`, which must remain a byte-for-byte copy.

## 9. CDC
Not applicable — single clock domain, zero `CDC-###` entries (`cdc_plan.md`). No synchroniser
primitive of any kind may appear anywhere in this RTL.

## 10. Clock gating
Not applicable — `power_plan.md` §2 mandates **no clock gating anywhere** in this design. Every
flop is clocked by the undivided `clk` every cycle; the UART's `CLK_DIV` is a synchronous rate
*enable* (`baud_tick`), never a second clock or a gated clock net.

## 11. Instantiation
Named port connections only (`.a(a)`), never positional. Named parameter overrides `#(.W(8))`.

## 12. Comments and headers
Every file starts with the header block in §13. Every port, parameter and non-obvious expression
gets a `//` comment. No block comments in RTL. Files reused verbatim from v1 keep their existing v1
header (do not rewrite it — the header's `Project` line still correctly says `mnist_npu` since the
file itself is unchanged; note the reuse in `arch.md` and `ip/IP_PROVENANCE.md` instead).

## 13. File header template (for newly authored modules)
```
//---------------------------------------------------------------------
// Module      : <name>
// Project     : cnn (mnist_npu v2)      Technology : FPGA-generic (Artix-7 100T / Nexys A7 target)
// Traces      : REQ-0xx, BLK-0xx
// Description : <what it does>
// Clock/Reset : clk (CD_CORE, 100 MHz nominal) / rst_n (SYNCHRONOUS active-low, see §3 — no async)
// Assumptions : <...>
// Source      : custom
//---------------------------------------------------------------------
```

## 14. Prohibited constructs
`initial` blocks in synthesisable RTL (memory `$readmemh` initial blocks are the ONE sanctioned
exception — see `arch.md` §7, they load ROM/RAM contents at elaboration and infer correctly on
Xilinx BRAM); delays (`#`) in RTL; `casex`; multiple drivers; combinational loops; incomplete
sensitivity lists (use `always @*`); tri-state internal to the core; DFT structures of any kind;
SystemVerilog of any kind; asynchronous reset of any flop (§3); any clock other than `clk` (§10);
any CDC synchroniser primitive (§9); any host-bus/CSR/APB/AXI construct of any kind (REQ-024 — this
design has none and must never grow one without a new fe-spec pass).

## 15. Feature-map RAM addressing discipline (CNN-specific addition)
`fm_ram`'s two regions (base 0 / base 6272, `arch.md` §7.1) must be addressed only through
`win_addr_gen`'s `layer_sel`-selected formulas — never by an ad-hoc offset computed inline
elsewhere. This keeps the hazard-free reuse proof (arch.md §7.1) auditable against a single source
of address truth. `fm_ram` itself has no knowledge of "regions"; it is a flat `[0:7839]` array, and
the region boundary is purely an address-range convention enforced by `win_addr_gen` and `ctrl_fsm`.
