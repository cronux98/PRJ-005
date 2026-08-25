# mnist_npu — Verification Plan
Stage: fe-spec | Language: pure Verilog-2001/2005 testbenches (no SVA, no SV coverage)

> **Scope note:** this document specifies verification *intent* only. Writing or running a
> testbench is explicitly OUT OF SCOPE for fe-spec/fe-arch/fe-rtl (see project brief §8: "No
> testbenches: verification is a separate later stage"). The items below are the targets that a
> later `fe-iverilog`/`fe-cocotb` stage must implement and pass; fe-rtl's own exit gate is limited
> to an `iverilog` **compile-only** sanity check (no vectors run).

## 1. Verification Strategy

- **Levels:** module (LUT, MAC datapath, UART TX, ROMs) → integration (full `mnist_npu` top,
  free-running loop) → golden-model comparison (bit-exact contract).
- **Stimulus style:** fully directed. The design is inference-only and free-running from
  `$readmemh`-initialised ROMs — there is no external stimulus port to randomise beyond `rst_n`
  timing. Constrained-random is limited to reset-assert-width sweeps and (for CDC-style
  robustness, though this design has no CDC) not applicable here.
- **Checking style:** self-checking scoreboard tasks (pure Verilog `task`/`function`, no SVA)
  comparing DUT outputs against the frozen `arch/golden_model/expected.hex` (per-image
  pred/confidence/verdict) and against the exact ASCII byte stream implied by the same file plus
  the UART line-format contract (REQ-022).
- **Golden-model role:** `arch/golden_model/golden_ref_model.c` + its `.hex` vector files are the
  single source of truth. They are pre-existing and FROZEN (see project brief §3, and arch.md §11
  in the next stage) — fe-spec/fe-arch do **not** regenerate them. Every VP item below that checks
  data-path behaviour traces to a bit-exact comparison against these files.

## 2. Top Module Verification Intent

| VP-ID | Scenario | Stimulus | Pass criterion | Traces |
|---|---|---|---|---|
| VP-TOP-001 | Cold reset and reset-state check | Assert `rst_n` low >= `ASM-001` (2) cycles, release | `led[11:0] == 0` and `uart_tx == 1` throughout reset; first inference targets image index 0 immediately after release | REQ-023, REQ-030 |
| VP-TOP-002 | Full 100-image bit-exact pass | Let the free-running design process image indices 0..99 once (tiny `HOLD_CYCLES`/`BLINK_CYCLES`) | For every image i in 0..99: RTL `pred`, `confidence`, `verdict` == `expected.hex` word[4*i..4*i+3] exactly (0 mismatches) | REQ-001..REQ-011, REQ-028, REQ-029 |
| VP-TOP-003 | Free-running wraparound | Continue simulation past image index 99 into a second pass | Image index sequence continues 99 -> 0 -> 1 ...; second-pass image 0 result bit-identical to first-pass image 0 result | REQ-015 |
| VP-TOP-004 | UART byte-stream exact match | Capture `uart_tx` bit stream for all 100 images at the parameterized `CLK_DIV` | Decoded ASCII bytes match the exact line format (REQ-022) for the corresponding verdict, image index zero-padded to 3 digits, single trailing 0x0A, for all 100 images, 0 mismatches | REQ-021, REQ-022, REQ-031 |
| VP-TOP-005 | LED pattern correctness & exclusivity | Observe `led[9:0]`/`led[10]` at each image's result-presented instant, all 100 images | `led[9:0]` one-hot on `pred` and `led[9:0]==0` on TRASH are mutually exclusive per requirement; `led[10] == (verdict != 0)` for all 100 images | REQ-017, REQ-018 |
| VP-TOP-006 | LED[11] blink-window correctness | Observe `led[11]` transitions across one full image cycle (compute window + hold window) | `led[11]` toggles at `BLINK_CYCLES` half-period only while compute is in progress; constant (no toggle) for the entire `HOLD_CYCLES` hold window | REQ-019, REQ-020 |
| VP-TOP-007 | HOLD_CYCLES pacing accuracy | Measure cycle count between "result presented" and "next image's compute begins" | Measured hold interval == `HOLD_CYCLES` exactly, for every one of the 100 images | REQ-016 |
| VP-TOP-008 | Simulation-speed soak | Run the full VP-TOP-002 scenario at simulation-override `HOLD_CYCLES`/`BLINK_CYCLES` (4-16) under `iverilog`/`vvp` | Full 100-image run completes in well under 1 minute wall-clock and a documented bounded cycle count (arch.md) | REQ-026 |

Includes, per the brief's product requirements (no host bus / no interrupts / no arbitration in
this design, so those generic fe-spec categories are N/A and noted as such): reset & output
defaults (VP-TOP-001), full-throughput soak over the entire vector set (VP-TOP-002/008),
free-running/back-to-back sequencing with no idle gaps other than the specified `HOLD_CYCLES`
(VP-TOP-003/007), and the two output-encoding boundary behaviours unique to this design — the
TRASH all-LEDs-off case and the busy-blink window edges (VP-TOP-005/006).

## 3. Per-Module Verification Intent

### 3.1 mac_datapath (shared multiply-accumulate engine)
Functional intent: single 16x16->32-bit signed multiplier feeding one shared accumulator,
sequenced by the control FSM across 784 (layer 1) or 32 (layer 2) MAC steps per unit, per REQ-004,
REQ-008, REQ-028, REQ-029.

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-MAC-001 | Multiply-accumulate bit-exactness | For every hidden/output unit of every one of the 100 vector images, the pre-LUT `z` value matches a reference recomputation of `acc>>8` (clamped) from the same weights/pixels | REQ-003, REQ-004, REQ-005, REQ-008 |
| VP-MAC-002 | Accumulator overflow margin | Directed vector(s) built from the extreme weight/pixel magnitudes in `weights.hex`/`images.hex` confirm the running accumulator never wraps for the REQ-028 bound | REQ-028 |
| VP-MAC-003 | int16 saturation clamp | Directed vectors that would produce `acc>>8` outside [-32768,32767] (constructed synthetically, not required to occur in the 100-image set) exercise both the positive and negative clamp | REQ-005 |

Coverage goals: both clamp directions of the saturator exercised at least once; the shared
multiplier observed driving both a layer-1 (8-bit x 16-bit effective range) and a layer-2 (9-bit x
16-bit effective range) operand pair.

### 3.2 sigmoid_lut
Functional intent: 65536x8 ROM, address = 16-bit signed `z`, bit-exact to the golden rational
sigmoid approximation for every address (REQ-006). This is the single highest-priority module
check in the whole plan per the project brief's non-negotiable LUT contract.

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-LUT-001 | Exhaustive bit-exactness | `tools/check_lut.py` recomputes `sigma(z) = 128 + trunc(128*z/(256+abs(z)))` for all 65536 z and diffs against the generated LUT hex; **must print PASS with 0 mismatches** before fe-rtl is considered complete | REQ-006 |
| VP-LUT-002 | Boundary addresses | Spot-check z = 0x0000 (z=0, sigma=128), 0x7FFF (z=32767, sigma=255), 0x8000 (z=-32768, sigma=1), 0xFFFF (z=-1, sigma=128 — truncation toward zero flattens both z=-1 and z=0 to the same sigma) against hand-derived values | REQ-006 |

Coverage goals: all 65536 entries (100% exhaustive — this is a ROM table, not a state space, so
100% coverage is achievable and required).

### 3.3 weight_rom / image_rom / label_rom
Functional intent: `$readmemh`-initialised ROMs sourcing the frozen golden hex files, per REQ-012,
REQ-013, REQ-014.

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-ROM-001 | Content fidelity | Read back every ROM word (25,450 / 78,400 / 100 words respectively) and compare against the source `.hex` file byte-for-byte | REQ-012, REQ-013, REQ-014 |

Coverage goals: 100% of ROM words compared at least once.

### 3.4 uart_tx
Functional intent: 115200 8N1 transmitter, parameterized `CLK_DIV`, per REQ-021, REQ-022, REQ-031.

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-UART-001 | Byte-exact line content | Decode the transmitted byte stream for one CORRECT, one INCORRECT, and one TRASH image (selected from the 100-vector set) and diff against the REQ-022 format | REQ-021, REQ-022 |
| VP-UART-002 | Bit-level frame timing | Measure start-bit width, each of 8 data-bit widths (LSB first), and stop-bit width against `CLK_DIV` cycles; confirm idle-high between frames | REQ-021, REQ-031 |

Coverage goals: all three verdict-line formats exercised; back-to-back frames (two consecutive
bytes with no idle gap) and the inter-line idle gap (the `HOLD_CYCLES` window) both observed.

### 3.5 led_ctrl
Functional intent: derives `led[11:0]` from `pred`/`verdict` (REQ-017, REQ-018) and drives the
busy-blink window (REQ-019, REQ-020).

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-LED-001 | One-hot / trash-off encoding | For all 10 possible `pred` values and both TRASH/non-TRASH cases, `led[9:0]` matches REQ-017 exactly | REQ-017 |
| VP-LED-002 | Fail/trash indicator | `led[10]` matches `verdict != 0` for verdict in {0,1,2} | REQ-018 |
| VP-LED-003 | Blink timing | `led[11]` toggle period measured == `2 * BLINK_CYCLES` clk_core cycles during the compute window; 0 toggles during the hold window | REQ-019, REQ-020 |

Coverage goals: all 10 `pred` values, all 3 `verdict` values, both edges of the blink-window
transition (compute-start and result-presented).

### 3.6 ctrl_fsm
Functional intent: sequences reset -> layer-1 MAC loop -> layer-1 activation -> layer-2 MAC loop ->
layer-2 activation -> argmax/confidence/verdict -> result-present -> hold -> next image, per
REQ-004..REQ-011, REQ-015, REQ-016, REQ-019.

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-CTRL-001 | Full state/arc coverage | Over the VP-TOP-002 100-image run, every FSM state defined in arch.md is entered at least once and every legal transition arc is exercised at least once | REQ-001, REQ-029 |
| VP-CTRL-002 | Illegal-state recovery & synthesis hygiene | By inspection: the `default:` arc of every `case` returns to a safe/reset state; no `always @*` block has a code path with an unassigned LHS (latch check); no module-scope `integer` is shared across two `always` blocks | REQ-024, REQ-025 |

Coverage goals: 100% FSM state coverage, 100% legal-arc coverage, over a single 100-image pass
(VP-TOP-002/VP-TOP-003 together exercise this at least 1.5x over).

## 4. Traceability Matrix

| REQ-ID | Verified by | Status |
|---|---|---|
| REQ-001 | VP-TOP-002, VP-CTRL-001 | open |
| REQ-002 | VP-TOP-002 | open |
| REQ-003 | VP-MAC-001 | open |
| REQ-004 | VP-MAC-001, VP-MAC-002 | open |
| REQ-005 | VP-MAC-003 | open |
| REQ-006 | VP-LUT-001, VP-LUT-002 | open |
| REQ-007 | VP-TOP-002 | open |
| REQ-008 | VP-MAC-001, VP-TOP-002 | open |
| REQ-009 | VP-TOP-002 | open |
| REQ-010 | VP-TOP-002 | open |
| REQ-011 | VP-TOP-002 | open |
| REQ-012 | VP-ROM-001 | open |
| REQ-013 | VP-ROM-001 | open |
| REQ-014 | VP-ROM-001 | open |
| REQ-015 | VP-TOP-003 | open |
| REQ-016 | VP-TOP-007 | open |
| REQ-017 | VP-TOP-005, VP-LED-001 | open |
| REQ-018 | VP-TOP-005, VP-LED-002 | open |
| REQ-019 | VP-TOP-006, VP-LED-003 | open |
| REQ-020 | VP-LED-003 | open |
| REQ-021 | VP-UART-001, VP-UART-002 | open |
| REQ-022 | VP-UART-001 | open |
| REQ-023 | VP-TOP-001 | open |
| REQ-024 | VP-CTRL-002 | open |
| REQ-025 | VP-CTRL-002 | open |
| REQ-026 | VP-TOP-008 | open |
| REQ-028 | VP-MAC-002 | open |
| REQ-029 | VP-CTRL-001 | open |
| REQ-030 | VP-TOP-001 | open |
| REQ-031 | VP-UART-002 | open |

Zero orphan REQs (every row has >=1 VP), zero orphan VP items (every VP-ID above appears in >=1
REQ's "Verified by" list — cross-checked by construction, both tables were authored together).
Status is `open` throughout fe-spec/fe-arch/fe-rtl: these stages do not execute the plan; a later
`fe-iverilog`/`fe-cocotb` stage flips status to `closed` on a passing run.

## 5. Verification Closure Criteria

Countable, to be evaluated by the later verification stage:

1. 100% of `must` requirements (REQ-001..REQ-031, all `must`) have >= 1 passing VP item.
2. 0 orphan REQs, 0 orphan VP items (per §4).
3. VP-LUT-001 passes with exactly 0/65536 mismatches (non-negotiable per project brief §5).
4. VP-TOP-002 passes with exactly 0/100 mismatches on pred, confidence, and verdict.
5. VP-TOP-004 passes with exactly 0 byte mismatches across the full 100-image UART stream.
6. VP-TOP-005 passes with exactly 0 LED-pattern mismatches (one-hot correctness and TRASH-off
   exclusivity) across all 100 images.
7. VP-CTRL-001 reports 100% FSM state coverage and 100% legal-arc coverage.
8. VP-TOP-008 completes within the documented cycle-count/wall-clock bound.
9. All FSM states/arcs exercised; all case-statement `default:` arcs inspected (VP-CTRL-002).
