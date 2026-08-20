# rinriAI — Front-End Specification
Document ID: SPEC-LEARN-ACCEL-v1.0 | Stage: fe-spec | Technology: SkyWater Sky130, 130 nm

## 1. Scope and Overview

`rinriAI` is a small, learning (online-training) neural-network accelerator IP:
a two-layer MLP (parameterized `FEATURES × HIDDEN × CLASSES`, default **784×32×10** for
MNIST-class data) that performs **online stochastic gradient descent training on-device** —
forward pass, backpropagation, and weight update per received sample — plus inference.
Firmware drives the IP through an APB4 register interface and streams dataset samples
(byte streams, MNIST-class format: pixel bytes + label) into a streaming sample port.
Learning is verified by firmware and simulation reading accuracy/error counters and,
optionally, dumping trained weights.

The design is deterministic and **bit-exact against a C golden reference model** (produced by
fe-arch) using 16-bit signed fixed-point (Q8.8) arithmetic throughout the training datapath.

## 2. Global Constraints

These constraints are inherited by every downstream stage (fe-arch, fe-rtl):

| Constraint | Rule |
|---|---|
| Technology | SkyWater **SKY130** open PDK only, **130 nm**. No other node may be named, assumed, or benchmarked against. |
| RTL language | **Pure Verilog-2001 or earlier.** No SystemVerilog, no VHDL. |
| Analog | Existing Sky130 macros may be instantiated as black boxes with a Verilog stub + SDC constraint. **No custom analog design.** This IP uses no analog macros (pads external, ASM-003). |
| DFT | **None.** No scan, BIST, JTAG/TAP, MBIST, compression. Observability is register-mapped (counters, weight dump) only. |
| Tool execution | fe-spec/fe-arch/fe-rtl **write files only**. No simulator, synthesizer, linter, formal tool, waveform viewer, or build script is run by the pipeline stages. |
| Guessing | Missing mandatory input -> structured halt. Documented assumptions (ASM-###) only. |

**Pure-Verilog implications:** no `always_ff`/`always_comb`/`logic`/`enum`/`typedef`/`struct`/
`union`/`interface`/`assert`/`property`/`covergroup`. Only `reg`, `wire`, `parameter`,
`localparam`, `always @(posedge clk ...)`, `always @*`, `//` comments. Verification intent is
expressed as directed/constrained-random testbench scenarios and checker tasks, never SVA.

## 3. Functional Description

### 3.1 Learned function (the algorithm the IP implements)

Two-layer MLP with sigmoid hidden and output activations, quadratic cost, online SGD.

- Forward (per sample): `a_h = sigmoid(Σ_f W_h[h][f]·x[f] + b_h[h])` for h in [0,HIDDEN);
  `y_c = sigmoid(Σ_h W_o[c][h]·a_h + b_o[c])` for c in [0,CLASSES). Predicted class =
  `argmax_c y_c`, **lowest index on ties**.
- Cost: `C = ½·Σ_c (y_c − t_c)²` where `t` is the one-hot label vector.
- Backprop (per sample, training mode only): `δ_o[c] = (y_c − t_c)·y_c·(1−y_c)`
  (sigmoid derivative via the stored activation: `σ′(z) = σ(z)·(1−σ(z))`);
  `δ_h[h] = (Σ_c W_o[c][h]·δ_o[c])·a_h·(1−a_h)`.
- Update (online SGD, `η = 2^(−lr_shift)`): `W_o[c][h] ← W_o[c][h] − η·δ_o[c]·a_h`;
  `b_o[c] ← b_o[c] − η·δ_o[c]`; `W_h[h][f] ← W_h[h][f] − η·δ_h[h]·x[f]`;
  `b_h[h] ← b_h[h] − η·δ_h[h]`.
- Ground truth: Nielsen, *Neural Networks and Deep Learning*, ch. 1–2 (online SGD,
  quadratic cost, backprop). The exact fixed-point rules (rounding, saturation, MAC order,
  sigmoid LUT definition) are pinned by fe-arch in `arch/arch.md` and are the bit-exactness
  contract; this spec fixes only the Q8.8 format (REQ-004) and the algorithm above.

### 3.2 Operation modes

- **Idle** (after reset, after halt completes, after a step completes): no sample acceptance
  (`s_ready` deasserted), `STATUS.busy=0`.
- **Running** (`CTRL.start` or `CTRL.step`): sample bytes are accepted (`s_ready` high while
  the learner is not busy); each fully received valid sample is processed (forward always;
  backprop + update when `CTRL.freeze=0`), then counters update.
- **Freeze** (`CTRL.freeze=1`): inference-only — weights are never modified; counters still
  update (evaluation mode on a test stream).
- **Step**: exactly one sample is processed, then back to idle with `STATUS.done=1`.
- **Halt**: stop accepting after the in-flight sample completes.

### 3.3 Sample stream

One sample = `FEATURES` pixel bytes (8-bit, value = gray level 0..255) followed by one label
byte (true class, 0..CLASSES−1) asserted with `s_last`. Q8.8 conversion: pixel byte `b`
becomes fixed-point value `b` (real value `b/256`). Label byte ≥ CLASSES, `s_last` too early,
or missing `s_last` at the label byte → malformed sample: `STATUS.err` sticky set, sample
discarded, framing resyncs at the next `s_last` (REQ-018).

### 3.4 Counter semantics

Per fully processed valid sample: `SAMPLE_COUNT++`; `CORRECT_COUNT++` if argmax == label
else `ERROR_COUNT++`. Counters saturate at 0xFFFFFFFF (no wrap). `CTRL.clr_stats` clears all
three counters and `STATUS.err`.

## 4. External Interfaces

Signals and timing budgets are in `interfaces.yaml` (IF-001, IF-002); this section fixes the
protocol framing.

### 4.1 IF-001 — APB4 slave (firmware control plane)

- 32-bit data, 32-bit byte address, zero-wait-state single transfers, `PREADY` asserted in
  the ACCESS phase, `PSLVERR` for reserved addresses (outside 0x00..0x24).
- Full-word accesses only (no PSTRB/PPROT requirement).
- Writes to read-only registers and reserved bits: ignored, no side effects.
- All timing synchronous to `clk_core`.

### 4.2 IF-002 — sample stream (dataset feed)

- Byte stream with `s_valid`/`s_ready` handshake and `s_last` marker; both directions
  synchronous to `clk_core`.
- Transfer on `s_valid && s_ready` at the rising edge. `s_ready` deasserted while the learner
  is busy (backpressure; no beats lost if the master holds `s_valid`).
- Framing: byte index 0..FEATURES−1 = pixels; byte index FEATURES = label with `s_last=1`.
- Malformed framing per §3.3/REQ-018.

### 4.3 Clock and reset (also in `interfaces.yaml`)

- `clk_core`: 50 MHz nominal, single domain CD_CORE, external pad source.
- `rst_n`: active-low, **synchronous** (assert and de-assert on clock edge), min assert
  16 cycles. No cross-domain sequencing (single domain).

## 5. Clock and Reset Architecture

| Item | Value |
|---|---|
| Clock domains | 1: CD_CORE (`clk_core`, 50 MHz, 50% duty, 0.1 ns jitter budget) |
| Reset | `rst_n`, active-low, synchronous, min assert 16 cycles |
| CDC | None. Every input (APB4, sample stream) is synchronous to `clk_core`. `cdc_paths = 0`. |
| Timing budgets | Input/output delay 6.0 ns (30% of 20 ns); clock uncertainty 5% setup / 0.1 ns hold (ASM-009) |

## 6. Register Map

Base-address-independent (offset-addressed). All registers 32 bits, little-endian, word
aligned. `RW` = read/write; `RO` = read-only (writes ignored); self-clearing strobes read
back 0.

| Offset | Name | Access | Reset | Bits | Description |
|---|---|---|---|---|---|
| 0x00 | CTRL | RW | 0x00000000 | [0] | `start` (self-clearing): begin continuous processing |
| | | | | [1] | `step` (self-clearing): process exactly one sample |
| | | | | [2] | `halt` (self-clearing): stop after current sample |
| | | | | [3] | `freeze`: 1 = inference-only (no weight updates) |
| | | | | [4] | `clr_stats` (self-clearing): clear counters + err |
| | | | | [5] | `init_weights` (self-clearing): all weights ← W_INIT_VAL |
| | | | | [31:6] | reserved (read 0, write ignored) |
| 0x04 | LRN_RATE | RW | 0x00000008 | [3:0] | `lr_shift`; η = 2^(−lr_shift); 0..15 |
| | | | | [31:4] | reserved |
| 0x08 | STATUS | RO | 0x00000000 | [0] | `busy`: accepting or processing |
| | | | | [1] | `done`: step/halt completed, idle |
| | | | | [2] | `err`: sticky malformed-sample error (cleared by clr_stats) |
| | | | | [3] | `frozen`: reflects CTRL.freeze |
| | | | | [31:4] | reserved (read 0) |
| 0x0C | SAMPLE_COUNT | RO | 0x00000000 | [31:0] | samples fully processed (saturating) |
| 0x10 | CORRECT_COUNT | RO | 0x00000000 | [31:0] | correct classifications (saturating) |
| 0x14 | ERROR_COUNT | RO | 0x00000000 | [31:0] | incorrect classifications (saturating) |
| 0x18 | PRED | RO | 0x00000000 | [7:0] | last predicted class (lowest index on tie) |
| | | | | [31:8] | reserved (read 0) |
| 0x1C | WADDR | RW | 0x00000000 | [15:0] | weight-memory word address; auto-increments after each WDATA access |
| | | | | [31:16] | reserved |
| 0x20 | WDATA | RW | 0x00000000 | [15:0] | weight word: write → mem[WADDR] = [15:0], WADDR++; read → mem[WADDR], WADDR++ |
| | | | | [31:16] | reserved (read 0) |
| 0x24 | W_INIT_VAL | RW | 0x00000000 | [15:0] | value written to all words by CTRL.init_weights |
| | | | | [31:16] | reserved |

**Weight memory address map** (word addresses, `W_TOT = F·H + H + H·C + C` = 25,450 at
defaults; must be ≤ 65535, REQ-022):

| Range | Contents |
|---|---|
| `0 .. F·H−1` | hidden weights `W_h[h][f]`, row-major with h outer: `addr = h·F + f` |
| `F·H .. F·H+H−1` | hidden biases `b_h[h]`: `addr = F·H + h` |
| `F·H+H .. F·H+H+H·C−1` | output weights `W_o[c][h]`, row-major with c outer: `addr = F·H+H + c·H + h` |
| `F·H+H+H·C .. W_TOT−1` | output biases `b_o[c]`: `addr = F·H+H+H·C + c` |

## 7. Requirements

Numbered requirements live in `requirements.yaml` (REQ-001..REQ-025, IDs stable across the
pipeline). Summary:

| ID | Title | Priority |
|---|---|---|
| REQ-001 | Two-layer MLP topology, parameterized (784/32/10 defaults) | must |
| REQ-002 | Forward pass / inference with argmax (lowest index on tie) | must |
| REQ-003 | Online SGD training: backprop + weight update per sample | must |
| REQ-004 | 16-bit signed Q8.8 fixed point, 32-bit accumulators | must |
| REQ-005 | Power-of-two learning rate η = 2^(−lr_shift), lr_shift 0..15, reset 8 | must |
| REQ-006 | Weight memory: W_TOT × 16-bit, CSR-addressable (WADDR/WDATA auto-inc) | must |
| REQ-007 | SAMPLE/CORRECT/ERROR counters, saturating, CSR-readable | must |
| REQ-008 | Streaming sample input: FEATURES pixels + label, valid/ready/last | must |
| REQ-009 | APB4 slave, zero wait states, PSLVERR on reserved address | must |
| REQ-010 | Register map exactly as §6 | must |
| REQ-011 | Bit-exact agreement with fe-arch golden model | must |
| REQ-012 | Single clock domain, synchronous active-low reset | must |
| REQ-013 | Reset values as §6 | must |
| REQ-014 | Pure Verilog-2001, no latches/loops/`#`/initial in RTL | must |
| REQ-015 | Timing closure at 50 MHz Sky130 HD with §5 budgets | must |
| REQ-016 | ≤ 200k cycles/train sample, ≤ 30k cycles/inference (defaults); ≥ 1 byte/cycle stream | must |
| REQ-017 | start/step/halt semantics (§3.2) | must |
| REQ-018 | Malformed-sample handling: err sticky, discard, resync | must |
| REQ-019 | Counter saturation at 0xFFFFFFFF; clr_stats | must |
| REQ-020 | Weight load/dump via WADDR/WDATA; bulk init via W_INIT_VAL | must |
| REQ-021 | Biases stored, trained, addressable | must |
| REQ-022 | Parameter constraints: F ≤ 4096, H ≤ 512, C ≤ 256, W_TOT ≤ 65535 | must |
| REQ-023 | Dynamic power ≤ 5 mW @ 50 MHz 1.8 V (excl. memory) | should |
| REQ-024 | Area ≤ 100 kGE excl. weight memory | should |
| REQ-025 | Firmware experiment demonstrates learning (stretch: ≥ 80% in 5 epochs) | may |

## 8. Error, Interrupt and Exception Behaviour

- **APB reserved address** (outside 0x00..0x24): `PSLVERR` in ACCESS phase; no register or
  memory side effect.
- **Writes to RO registers / reserved bits**: ignored, no side effect.
- **Malformed sample** (s_last before index FEATURES; missing s_last at index FEATURES;
  label ≥ CLASSES): `STATUS.err` sticky set, sample discarded (no processing, no counter
  change), framing resyncs at next s_last. `err` cleared only by `CTRL.clr_stats`.
- **Counter overflow**: saturate (no wrap), REQ-019.
- **Interrupts**: none. Status is polled via STATUS (ASM-006). This is a deliberate scope
  decision, not an omission.
- **Recovery**: any error state is cleared by `clr_stats`; the design never locks up — a
  stuck `s_valid` master with deasserted `s_ready` is resolved by the master dropping
  `s_valid` (standard backpressure; the IP never drops accepted bytes).

## 9. Power and Area Targets

- Dynamic power ≤ 5 mW at 50 MHz, 1.8 V, typical corner, excluding weight memory (REQ-023).
- Standard-cell area ≤ 100 kGE excluding weight memory (REQ-024). Weight memory at defaults:
  25,450 × 16 bit ≈ 407 kbit (dominant; budgeted separately, OI-001).

## 10. IP Reuse Plan

| IPR | Block | Decision | Source | Licence | Status |
|---|---|---|---|---|---|
| IPR-001 | apb4_slave_regs | **custom** | none — authored fresh | n/a | rejected (no external IP policy) |
| IPR-002 | sigmoid_lut | **custom** | none — LUT defined by fe-arch golden model | n/a | rejected (no external IP policy) |
| IPR-003 | weight_ram | **custom** | none — parameterized inferred dual-port RAM | n/a | rejected (no external IP policy) |

Survey was performed (search commands recorded in `requirements.yaml`); candidates found
(vyges/uart-controller — SystemVerilog APB3; ForrestBlue/cortexm0ds CMSDK APB4 example —
ARM example code; neoaashish/Verilog_ASIC, Csuk0914/dnn-rtl — sigmoid LUT references) are
**not** adopted: Rinri directive 2026-08-20 = author everything fresh; **no external IP**,
no pinned commits, no invented SHAs anywhere in this repo.

## 11. Assumptions (ASM-001..ASM-009)

All listed in `requirements.yaml` with `requires_confirmation: true`, acknowledged for this
run (`assumptions_acknowledged: true` in `spec_manifest.yaml` — the run directive delegated
defaults: "use defaults / you decide / assume sensible values").

| ID | Assumption |
|---|---|
| ASM-001 | Core clock 50 MHz, single external clock (default) |
| ASM-002 | Reset active-low, synchronous (per guidance), min assert 16 cycles |
| ASM-003 | Deployment: standalone IP macro in SoC/testbench; 1.8 V core; pads external |
| ASM-004 | Q8.8 fixed point (16-bit signed, 8 frac bits) |
| ASM-005 | Sigmoid (exact LUT) + quadratic cost; no softmax (RTL simplicity) |
| ASM-006 | No interrupt; polling only |
| ASM-007 | Counters saturate at 2^32−1 |
| ASM-008 | Weights reset to 0; firmware loads init weights |
| ASM-009 | SDC placeholders: 5% period setup uncertainty / 0.1 ns hold; 30% I/O delays |

## 12. Open Issues (OI-001..OI-003)

| ID | Issue | Blocks | Owner |
|---|---|---|---|
| OI-001 | Weight RAM target: inferred dual-port reg array (default) vs Sky130 SRAM macro blackbox; macro-replacement boundary documented at fe-arch/fe-rtl | none | architect |
| OI-002 | Verify sky130_sram_* cell names against installed PDK if macro path is ever taken | none | user |
| OI-003 | REQ-025 stretch target needs downstream firmware/experiment harness | none | user |

## 13. Verification Closure Criteria

Countable closure (full detail in `verification_plan.md`):

1. 100 % of `must` requirements (REQ-001..022) have ≥ 1 passing VP item.
2. 0 orphan REQs; 0 orphan VP items (traceability matrix complete).
3. RTL-vs-golden-model mismatch count = 0 over the shipped vector set and the
   full-config generated set (REQ-011).
4. All FSM states/arcs exercised (idle/running/step/halt/freeze, malformed resync).
5. Every register verified for reset value, access type, and reserved-address PSLVERR.
6. All error-injection cases (PSLVERR, malformed samples, saturation) produce the specified
   status.
7. `should`/`may` items (REQ-023..025) reported with measured numbers, not gating closure.

## 14. Glossary

| Term | Meaning |
|---|---|
| Online SGD | Stochastic gradient descent with one weight update per received sample |
| Q8.8 | 16-bit signed fixed point: 1 sign + 7 integer + 8 fractional bits; value = raw/256 |
| W_TOT | Total weight-memory words = F·H + H + H·C + C (25,450 at defaults) |
| argmax | Index of the largest output; lowest index wins on ties |
| MNIST-class dataset | 28×28 grayscale, 10 classes, IDX byte format (MNIST / Fashion-MNIST / Kuzushiji-MNIST) |
| Golden model | `arch/golden_model/golden_ref_model.c` — integer-only C reference; bit-exactness bar |
| LUT | Look-up table (sigmoid) |
| kGE | Thousand gate equivalents |
