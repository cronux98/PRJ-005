# cnn (mnist_npu v2) — Verification Plan
Stage: fe-spec | Language: pure Verilog-2001/2005 testbenches (no SVA, no SV coverage)

> **Scope note:** this document specifies verification *intent* only. Writing or running a
> testbench is explicitly OUT OF SCOPE for fe-spec/fe-arch/fe-rtl (task brief: "TB is a LATER
> stage"). The items below are the targets that a later `fe-iverilog`/`fe-cocotb` stage must
> implement and pass; fe-rtl's own exit gate is limited to an `iverilog` **compile-only** sanity
> check (no vectors run).

## 1. Verification Strategy

- **Levels:** module (conv MAC, pool comparator, sigmoid LUT, UART TX, ROMs, feature-map RAM
  address map) -> integration (full `cnn_npu` top, free-running loop) -> golden-model comparison
  (bit-exact contract).
- **Stimulus style:** fully directed. The design is inference-only and free-running from
  `$readmemh`-initialised ROMs — there is no external stimulus port to randomise beyond `rst_n`
  timing.
- **Checking style:** self-checking scoreboard tasks (pure Verilog `task`/`function`, no SVA)
  comparing DUT outputs against the frozen `arch/golden_model/expected.hex` (per-image
  pred/confidence/verdict) and against the exact ASCII byte stream implied by the same file plus
  the UART line-format contract (REQ-032).
- **Golden-model role:** `arch/golden_model/golden_ref_model.c` + its `.hex` vector files are the
  single source of truth. They are pre-existing and FROZEN — fe-spec/fe-arch do **not** regenerate
  them. Every VP item below that checks data-path behaviour traces to a bit-exact comparison
  against these files.

## 2. Top Module Verification Intent

| VP-ID | Scenario | Stimulus | Pass criterion | Traces |
|---|---|---|---|---|
| VP-TOP-001 | Cold reset and reset-state check | Assert `rst_n` low >= `ASM-001` (2) cycles, release | `led[11:0] == 0` and `uart_tx == 1` throughout reset; first inference targets image index 0 immediately after release | REQ-034, REQ-030 |
| VP-TOP-002 | Full 100-image bit-exact pass | Let the free-running design process image indices 0..99 once (tiny `HOLD_CYCLES`/`BLINK_CYCLES`) | For every image i in 0..99: RTL `pred`, `confidence`, `verdict` == `expected.hex` word[4*i..4*i+3] exactly (0 mismatches) | REQ-001..REQ-018 |
| VP-TOP-003 | Free-running wraparound | Continue simulation past image index 99 into a second pass | Image index sequence continues 99 -> 0 -> 1 ...; second-pass image 0 result bit-identical to first-pass image 0 result | REQ-024 |
| VP-TOP-004 | UART byte-stream exact match | Capture `uart_tx` bit stream for all 100 images at the parameterized `CLK_DIV` | Decoded ASCII bytes match the exact line format (REQ-032) for the corresponding verdict, image index zero-padded to 3 digits, single trailing 0x0A, for all 100 images, 0 mismatches | REQ-031, REQ-032, REQ-033 |
| VP-TOP-005 | LED pattern correctness & exclusivity | Observe `led[9:0]`/`led[10]` at each image's result-presented instant, all 100 images | `led[9:0]` one-hot on `pred` and `led[9:0]==0` on TRASH are mutually exclusive per requirement; `led[10] == (verdict != 0)` for all 100 images | REQ-028, REQ-029 |
| VP-TOP-006 | LED[11] blink-window correctness | Observe `led[11]` transitions across one full image cycle (compute window + hold window) | `led[11]` toggles at `BLINK_CYCLES` half-period only while compute is in progress; constant (no toggle) for the entire `HOLD_CYCLES` hold window | REQ-027, REQ-026 |
| VP-TOP-007 | HOLD_CYCLES pacing accuracy | Measure cycle count between "result presented" and "next image's compute begins" | Measured hold interval == `HOLD_CYCLES` exactly, for every one of the 100 images | REQ-025 |
| VP-TOP-008 | Simulation-speed soak | Run the full VP-TOP-002 scenario at simulation-override `HOLD_CYCLES`/`BLINK_CYCLES` under `iverilog`/`vvp` | Full 100-image run completes in seconds wall-clock and a documented bounded cycle count (arch.md) | REQ-037 |

Includes, per the task's product requirements (no host bus / no interrupts / no arbitration in
this design): reset & output defaults (VP-TOP-001), full-throughput soak over the entire vector
set (VP-TOP-002/008), free-running/back-to-back sequencing with no idle gaps other than the
specified `HOLD_CYCLES` (VP-TOP-003/007), and the two output-encoding boundary behaviours unique to
this design — the TRASH all-LEDs-off case and the busy-blink window edges (VP-TOP-005/006).

## 3. Per-Module Verification Intent

### 3.1 mac_datapath (shared multiply-accumulate engine)
Functional intent: single 16x16->32-bit signed multiplier, sign-extended into one shared 64-bit
accumulator, sequenced by the control FSM across conv taps (9 or 72 per unit), pool comparisons,
and FC MAC steps (784 or 32 per unit), per REQ-004/005/008/010/011/017/018.

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-MAC-001 | Multiply-accumulate bit-exactness | For every conv/FC unit of every one of the 100 vector images, the pre-activation `z` value matches a reference recomputation of `acc64>>8` (clamped) from the same weights/activations | REQ-003, REQ-004, REQ-005, REQ-006, REQ-008, REQ-010, REQ-011 |
| VP-MAC-002 | Accumulator overflow margin | Directed vector(s) built from the extreme weight/activation magnitudes in `weights.hex`/`images.hex` confirm the running accumulator never wraps for the REQ-017 bound (dominant case: FC1, 784 taps at max magnitude) | REQ-017 |
| VP-MAC-003 | int16 saturation clamp | Directed vectors that would produce `acc64>>8` outside [-32768,32767] (constructed synthetically, not required to occur in the 100-image set) exercise both the positive and negative clamp | REQ-005 |

Coverage goals: both clamp directions of the saturator exercised at least once; the shared
multiplier observed driving conv1 (9-tap), conv2 (72-tap), FC1 (784-tap) and FC2 (32-tap) reduction
lengths at least once each.

### 3.2 pool_cmp (2x2 max-pool comparator)
Functional intent: 4-way max comparator shared by pool1 and pool2, per REQ-007/009.

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-POOL-001 | 2x2 max-pool bit-exactness | For every pool1/pool2 output unit of every one of the 100 vector images, RTL output matches golden p1/p2 | REQ-007, REQ-009 |

Coverage goals: all four 2x2 input orderings exercised (max in each of the four positions at least
once across the 100-image set).

### 3.3 relu (conv-path activation)
Functional intent: `h = max(z,0)`, applied after every conv1/conv2 unit, per REQ-006.

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-RELU-001 | ReLU clamp-to-zero | For directed vectors with z<0, z==0, z>0, h matches max(z,0) exactly; observed on both conv1 and conv2 outputs across the 100-image set | REQ-006 |

Coverage goals: all three z-sign cases (negative, zero, positive) observed on both conv layers.

### 3.4 sigmoid_lut (reused unchanged from v1)
Functional intent: 65536x8 ROM, address = 16-bit signed `z`, bit-exact to the golden rational
sigmoid approximation for every address (REQ-022).

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-LUT-001 | Exhaustive bit-exactness | `tools/check_lut.py` (reused from v1) recomputes `sigma(z) = 128 + trunc(128*z/(256+abs(z)))` for all 65536 z and diffs against the reused LUT hex; **must print PASS with 0 mismatches** | REQ-022 |
| VP-LUT-002 | Boundary addresses | Spot-check z = 0x0000, 0x7FFF, 0x8000, 0xFFFF against hand-derived values (identical to v1's boundary set) | REQ-022 |

Coverage goals: all 65536 entries (100% exhaustive).

### 3.5 weight_rom / image_rom / label_rom / fm_ram
Functional intent: `$readmemh`-initialised ROMs sourcing the frozen golden hex files (REQ-019,
REQ-020, REQ-021), plus the reused feature-map RAM's per-layer address map (REQ-023).

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-ROM-001 | Content fidelity | Read back every ROM word (26,698 / 78,400 / 100 words respectively) and compare against the source `.hex` file byte-for-byte | REQ-019, REQ-020, REQ-021 |
| VP-MEM-001 | Feature-map RAM hazard-free reuse | Over one full image inference, confirm no write to a given fm_ram address occurs before every read of the prior layer's value at that address has completed (per arch.md's address-map proof) | REQ-023 |
| VP-MEM-002 | FC1 flatten-order addressing | Confirm the address presented to fm_ram for FC1 input i equals oc*49+oy*7+ox for the corresponding pool2 output element | REQ-012 |

Coverage goals: 100% of ROM words compared at least once; both live regions of fm_ram exercised
across a full 6-layer pass.

### 3.6 uart_tx / uart_line_fmt (reused from v1)
Functional intent: 115200 8N1 transmitter with CLK_DIV=868, and the exact 3-format line generator,
per REQ-031, REQ-032, REQ-033.

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-UART-001 | Byte-exact line content | Decode the transmitted byte stream for one CORRECT, one INCORRECT, and one TRASH image (selected from the 100-vector set) and diff against the REQ-032 format | REQ-031, REQ-032 |
| VP-UART-002 | Bit-level frame timing | Measure start-bit width, each of 8 data-bit widths (LSB first), and stop-bit width against 868 cycles; confirm idle-high between frames | REQ-031, REQ-033 |

Coverage goals: all three verdict-line formats exercised; back-to-back frames and the inter-line
idle gap (the `HOLD_CYCLES` window) both observed.

### 3.7 led_ctrl (reused from v1)
Functional intent: derives `led[11:0]` from `pred`/`verdict` (REQ-028, REQ-029) and drives the
busy-blink window (REQ-027, REQ-026).

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-LED-001 | One-hot / trash-off encoding | For all 10 possible `pred` values and both TRASH/non-TRASH cases, `led[9:0]` matches REQ-028 exactly | REQ-028 |
| VP-LED-002 | Fail/trash indicator | `led[10]` matches `verdict != 0` for verdict in {0,1,2} | REQ-029 |
| VP-LED-003 | Blink timing | `led[11]` toggle period measured == `2 * BLINK_CYCLES` (100,000 default) clk_core cycles during the compute window; 0 toggles during the hold window | REQ-026, REQ-027 |

Coverage goals: all 10 `pred` values, all 3 `verdict` values, both edges of the blink-window
transition (compute-start and result-presented).

### 3.8 ctrl_fsm
Functional intent: sequences reset -> CONV1 -> POOL1 -> CONV2 -> POOL2 -> FC1 -> FC2 -> PRESENT ->
HOLD -> next image, per REQ-004..REQ-018, REQ-024, REQ-025, REQ-027.

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-CTRL-001 | Full state/arc coverage | Over the VP-TOP-002 100-image run, every FSM state defined in arch.md is entered at least once and every legal transition arc is exercised at least once | REQ-001, REQ-018 |
| VP-CTRL-002 | Illegal-state recovery & synthesis hygiene | By inspection: the `default:` arc of every `case` returns to a safe/reset state; no `always @*` block has a code path with an unassigned LHS (latch check); no module-scope `integer` is shared across two `always` blocks | REQ-035, REQ-036 |

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
| REQ-006 | VP-MAC-001, VP-RELU-001 | open |
| REQ-007 | VP-POOL-001 | open |
| REQ-008 | VP-MAC-001, VP-MAC-002 | open |
| REQ-009 | VP-POOL-001 | open |
| REQ-010 | VP-MAC-001, VP-TOP-002 | open |
| REQ-011 | VP-MAC-001, VP-TOP-002 | open |
| REQ-012 | VP-MEM-002 | open |
| REQ-013 | VP-ROM-001 | open |
| REQ-014 | VP-TOP-002 | open |
| REQ-015 | VP-TOP-002 | open |
| REQ-016 | VP-TOP-002 | open |
| REQ-017 | VP-MAC-002 | open |
| REQ-018 | VP-CTRL-001 | open |
| REQ-019 | VP-ROM-001 | open |
| REQ-020 | VP-ROM-001 | open |
| REQ-021 | VP-ROM-001 | open |
| REQ-022 | VP-LUT-001, VP-LUT-002 | open |
| REQ-023 | VP-MEM-001 | open |
| REQ-024 | VP-TOP-003 | open |
| REQ-025 | VP-TOP-007 | open |
| REQ-026 | VP-LED-003 | open |
| REQ-027 | VP-TOP-006, VP-LED-003 | open |
| REQ-028 | VP-TOP-005, VP-LED-001 | open |
| REQ-029 | VP-TOP-005, VP-LED-002 | open |
| REQ-030 | VP-TOP-001 | open |
| REQ-031 | VP-UART-001, VP-UART-002 | open |
| REQ-032 | VP-UART-001 | open |
| REQ-033 | VP-UART-002 | open |
| REQ-034 | VP-TOP-001 | open |
| REQ-035 | VP-CTRL-002 | open |
| REQ-036 | VP-CTRL-002 | open |
| REQ-037 | VP-TOP-008 | open |

Zero orphan REQs (every row has >=1 VP), zero orphan VP items (every VP-ID above appears in >=1
REQ's "Verified by" list — cross-checked by construction, both tables were authored together).
Status is `open` throughout fe-spec/fe-arch/fe-rtl: these stages do not execute the plan; a later
`fe-iverilog`/`fe-cocotb` stage flips status to `closed` on a passing run.

## 5. Verification Closure Criteria

Countable, to be evaluated by the later verification stage:

1. 100% of `must` requirements (REQ-001..REQ-037, all `must`) have >= 1 passing VP item.
2. 0 orphan REQs, 0 orphan VP items (per §4).
3. VP-LUT-001 passes with exactly 0/65536 mismatches (non-negotiable, unchanged from v1).
4. VP-TOP-002 passes with exactly 0/100 mismatches on pred, confidence, and verdict.
5. VP-TOP-004 passes with exactly 0 byte mismatches across the full 100-image UART stream.
6. VP-TOP-005 passes with exactly 0 LED-pattern mismatches (one-hot correctness and TRASH-off
   exclusivity) across all 100 images.
7. VP-CTRL-001 reports 100% FSM state coverage and 100% legal-arc coverage.
8. VP-TOP-008 completes within the documented cycle-count/wall-clock bound (seconds, per REQ-037).
9. All FSM states/arcs exercised; all case-statement `default:` arcs inspected (VP-CTRL-002).
