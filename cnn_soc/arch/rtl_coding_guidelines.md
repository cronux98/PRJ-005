# Pure-Verilog RTL Coding Guidelines — cnn_soc
Binding on fe-rtl. Verilog-2001 (IEEE 1364-2001) only.

> **Project deviation (binding, do not "fix"):** the fe-arch skill default template uses an
> asynchronous reset (`always @(posedge clk or negedge rst_n)`). cnn_soc — by approved spec
> (RST-001, REQ-029, spec.md §2.1) and project precedent (cnn/mnist_npu, ex6) — uses a **fully
> synchronous** active-low reset. The template in §3 is the ONLY permitted sequential template.
> Same for technology: FPGA-generic — no Sky130 cell names, no Sky130-specific constructs.

## 1. Language subset

Allowed: `module`/`endmodule`, ANSI port lists, `wire`, `reg`, `integer` (block-local loop vars
ONLY — never a module-scope integer shared across two always blocks), `parameter`, `localparam`,
`generate`/`genvar`, `always @(posedge clk)`, `always @*`, `assign`, `case`/`casez` with
`default`, `function`, `task`, `` `define `` sparingly, `(* attributes *)`, `signed`,
`$readmemh` (ROM-init only, §14).
Forbidden: `always_ff`, `always_comb`, `always_latch`, `logic`, `bit`, `byte`, `int`, `enum`,
`typedef`, `struct`, `union`, `interface`, `package`, `import`, `assert`/`assume`/`cover`,
`property`, `sequence`, `covergroup`, `unique`, `priority`, `.*`, `do-while`, `++`/`--`,
`casex` (X-propagation hazard), SystemVerilog of any kind.

## 2. File and naming rules

One module per file; filename == module name + `.v`. Lower snake_case for modules and signals;
parameters in UPPER_SNAKE. Suffixes: `_n` active low, `_r` registered, `_nxt` next-state, `_en`
enable, `_valid`/`_ready` handshake, `_q`/`_d` flop output/input. AXI signals keep the exact
picorv32_axi names (`mem_axi_*`) at the top, and the per-slave prefixes from arch.md §6.2
(`boot_`, `sram_`, `vec_`, `apb_`, `cnn_`) on IFI-003 instances. Reused files (BLK-012..019) keep
their original names and style byte-for-byte — do not rename anything inside them.

## 3. Clocking and reset

Clock port name: `clk`. Reset port name: `rst_n`, active low, **fully synchronous** — every flop:

```verilog
always @(posedge clk) begin
    if (!rst_n) q <= RESET_VALUE;
    else        q <= d;
end
```

- **No** `negedge rst_n`, **no** async reset term anywhere (REQ-029). No reset synchroniser.
- Every flop has a defined reset value (see arch.md §4/§7 per block). Exception: RAM array
  contents (MEM-002 SRAM, MEM-004 image_buffer) are not reset — v1 firmware never reads unwritten
  SRAM (pure-ROM image, REQ-004) and the buffer is written before every START; their **read-output
  registers** ARE reset to 0 (cnn ROM pattern, `image_rom.v:27-30`).
- BLK-010's `rst_n` is the park signal `core_rst_n` (from BLK-009) — a normal synchronous input;
  treat it like any reset port (same template, same discipline).

## 4. Combinational logic

`always @*` with a default assignment to **every** LHS on the first line of the block; blocking
(`=`) assignments only. `case` statements always have `default:`. No latches — ever. Incomplete
sensitivity lists are forbidden (use `always @*`).

## 5. FSM style

Three-block style: state register (sequential), next-state (combinational), outputs (registered
where timing-critical). States as `localparam`. Encoding per arch.md §6 (all new FSMs binary).
Illegal states go to the reset state via `default:`. The transition tables in arch.md §6 are the
exact contract — every row, including the else-stays, must be implemented.

## 6. Assignment discipline

Non-blocking (`<=`) in sequential blocks; blocking (`=`) in combinational blocks. Never mix in
one block. Never assign the same reg from two always blocks.

## 7. Widths and constants

Every literal is sized and based (`8'h00`, `16'd1024`, `1'b0`). No bare integers in comparisons
or assignments. Widths must match on both sides; use explicit zero/sign extension. Datapath
widths per arch.md §5 (32-bit bus, 8-bit pixels, 12-bit LED, 4/7/2-bit CNN results, packing per
§7.3).

## 8. Parameterisation

`parameter` for user overrides, `localparam` for derived values. No magic numbers. Documented
ranges: `UART_CLK_DIV` 2..65535 (default 868; sim override e.g. 4); hex-file path parameters are
strings defaulting per arch.md §7.2 (relative to the **cnn_soc project root** — do not revert to
the cnn-root-relative `define defaults).

## 9. CDC

None. This design has exactly one clock domain and zero crossings (cdc_plan.md). No synchroniser
module, no async FIFO, no handshake crossing may be introduced. A comment claiming otherwise is a
design error.

## 10. Clock gating

None in v1 (power_plan.md). Never gate a clock with a raw AND/OR in RTL; never instantiate a
clock-gating cell (no Sky130 cells exist in this project); no scan-enable term (DFT is out of
scope).

## 11. Instantiation

Named port connections only (`.a(a)`), never positional. Named parameter overrides
`#(.W(8))`. The cnn leaf instances in BLK-010 must match the wiring list of arch.md §4 BLK-010
exactly (it mirrors `cnn_npu.v:99-233`); the sigmoid_lut address is **structural**:
`.addr(mac_z[15:0])` — do not route it through ctrl_fsm.

## 12. Comments and headers

Every file starts with the header block in §13. Every port, parameter and non-obvious expression
gets a `//` comment. No block comments in RTL. Do not edit the header comments of reused files.

## 13. File header template

```verilog
//---------------------------------------------------------------------
// Module      : <name>
// Project     : cnn_soc                Technology : FPGA-generic (NOT Sky130 — spec.md §2.1)
// Traces      : REQ-0xx, BLK-0xx
// Description : <what it does>
// Clock/Reset : clk (CD_CORE, 100 MHz) / rst_n (fully SYNCHRONOUS active-low — no async)
// Assumptions : <...>
// Source      : custom | reused from <path> (<licence>) — verbatim, zero edits
//---------------------------------------------------------------------
```

## 14. Prohibited constructs

- `initial` blocks in synthesisable RTL — **sole exception**: `initial $readmemh(<PARAM>,
  <array>);` ROM initialisation inside bootrom/vec_rom/weight_rom/sigmoid_lut (cnn precedent,
  arch.md §7.2). No other `initial` anywhere in `rtl/` (clock generators, stimulus, etc. live in
  `tb/` only).
- Delays (`#`) in RTL — never; `tb/` only.
- `casex`; multiple drivers; combinational loops; incomplete sensitivity lists; tri-state
  internal to the core (no pads exist — outputs are plain wires).
- DFT structures of any kind; SystemVerilog of any kind; Sky130 cell names of any kind.
- `default_nettype`: follow the cnn convention — `` `default_nettype none `` at the top of each
  new file (after the header), `` `default_nettype wire `` at the bottom. Do not add `include of
  cnn_defs.vh into new files unless a reused leaf requires it; new files define their own hex
  path parameters (arch.md §7.2).
