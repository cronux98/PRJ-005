# rinriAI — Verification Plan
Stage: fe-spec | Language: pure Verilog-2001 testbenches (no SVA, no SV coverage)

## 1. Verification Strategy

- **Levels:** module (apb_regs, sample_stream, learner, weight_mem, stats) → integration
  (learn_accel top) → firmware experiment (register-driven flow, REQ-025).
- **Stimulus style:** directed tests for protocol/error/reset cases; constrained-random
  (pure-Verilog LFSR PRNG) for soak traffic; dataset-derived byte streams for learning
  checks; parameterized DUT instances (default 784×32×10 and tiny 4×4×2 / 8×4×3) for the
  golden-model comparison.
- **Checking style:** self-checking scoreboards implemented as Verilog `task`/`function`;
  APB4 write/read reference model for registers; byte-exact sample-stream generator;
  golden-model comparison via precomputed vectors (`arch/golden_model/{stimulus,expected}.hex`
  from fe-arch) — the C golden model is the reference for all datapath checks.
- **Bit-exactness contract:** the fe-arch golden model defines the exact fixed-point rules
  (Q8.8, rounding/truncation, saturation, MAC accumulation order, sigmoid LUT values).
  fe-cocotb replays `{stimulus,expected}.hex` as the scoreboard reference; mismatch count = 0
  is the REQ-011 acceptance bar.
- **Methods:** `simulation` for behaviour, `inspection` for style/CDC, `analysis` for
  timing/power/area (downstream fe-opensta/STA/power tools).

## 2. Top Module Verification Intent (learn_accel)

| VP-ID | Scenario | Stimulus | Pass criterion | Traces |
|---|---|---|---|---|
| VP-TOP-001 | Cold reset and register defaults | rst_n asserted ≥ 16 cycles; read all registers and sampled weights | Every register and every weight word equals the §6 reset values (CTRL=0, LRN_RATE=8, counters=0, W=0) | REQ-010, REQ-012, REQ-013 |
| VP-TOP-002 | APB4 basic read/write | Directed: write then read-back each RW register; read RO registers | Round-trip equality; 1-cycle transfers (PREADY=1 in ACCESS); RO reads return live values | REQ-009, REQ-010 |
| VP-TOP-003 | APB4 reserved address | Directed: read/write addresses 0x28, 0x3C, 0x100, 0xFFFFFFFC | PSLVERR=1 in ACCESS phase; no register/memory side effect; subsequent valid access works | REQ-009 |
| VP-TOP-004 | Full learning flow vs golden model | Load init weights (from golden model), lr_shift=8, stream shipped stimulus.hex samples (tiny config), train mode | After each sample: PRED, SAMPLE/CORRECT/ERROR counts and final weight dump match expected.hex bit-exactly | REQ-001..004, REQ-007, REQ-008, REQ-011 |
| VP-TOP-005 | Inference-only flow (freeze) | freeze=1; stream samples over pre-trained weights | PRED/counters match golden inference vectors; weight dump identical before/after (no update) | REQ-002, REQ-003, REQ-006 |
| VP-TOP-006 | Step mode | CTRL.step; stream 3 samples | Exactly 1 sample processed (SAMPLE_COUNT +1), then idle, done=1, s_ready=0; busy=0 | REQ-017 |
| VP-TOP-007 | Halt mid-stream | start; pause mid-sample (drop s_valid); halt during processing | In-flight sample completes (counters +1 if valid), then idle with done=1; restart works | REQ-017, REQ-008 |
| VP-TOP-008 | Malformed samples | Directed: s_last early; missing s_last at label; label ≥ CLASSES; then a valid sample | err set exactly once per malformed sample; counters unchanged; valid sample after resync processes correctly | REQ-018 |
| VP-TOP-009 | Counter saturation and clear | Preload counters near 0xFFFFFFFF (long soak or directed), continue; then clr_stats | Counters clamp at 0xFFFFFFFF (no wrap); clr_stats zeroes counters and err | REQ-007, REQ-019, REQ-013 |
| VP-TOP-010 | Weight load/dump and bulk init | Write all W_TOT words via WADDR/WDATA pattern; read back; init_weights with W_INIT_VAL; run inference | Full round-trip equality; all words = W_INIT_VAL after init; forward results reflect loaded weights (golden) | REQ-006, REQ-020, REQ-021 |
| VP-TOP-011 | Learning-rate sweep | lr_shift = 0,1,2,4,8,15 with identical samples/weights | Weight deltas scale exactly by 2^(−lr_shift) vs lr_shift=0; matches golden model per value | REQ-005 |
| VP-TOP-012 | Throughput budgets | Default config; measure cycles per train sample and per inference sample; stream back-to-back | train ≤ 200,000 cycles; infer ≤ 30,000 cycles; ≥ 1 byte/cycle while ready | REQ-016, REQ-008 |
| VP-TOP-013 | Long soak, back-to-back | 10,000 samples (LFSR-generated valid frames), train mode | Zero dropped/duplicated bytes; final counters and sampled weights match golden model run | REQ-008, REQ-011 |
| VP-TOP-014 | STA sign-off (analysis) | Downstream fe-opensta on synthesized netlist | Zero setup/hold violations at 25 MHz nominal (40.000 ns) with §5 budgets (6.0 ns I/O, 1.0 ns setup unc, 0.1 ns hold); measured tt 37.5 MHz / ss_n40C_1v44 9.2 MHz reported (2026-08-20), ss is NOT a closure target | REQ-015 |
| VP-TOP-015 | Parameter sweep | Instances 4/4/2 and 8/4/3; golden vectors for each | Elaboration clean; predictions/counters match golden model for both configs | REQ-022, REQ-001, REQ-011 |
| VP-TOP-016 | Structural style review (inspection) | Read all RTL | Zero latches, zero combinational loops, zero `#`, zero initial blocks in rtl/, posedge-clk-only seq logic, pure Verilog-2001 | REQ-014, REQ-012 |
| VP-TOP-017 | Power estimate (analysis) | Downstream power tool at 25 MHz nominal, 1.8 V, typical (orig. 50 MHz superseded) | Report ≤ 5 mW dynamic excluding memory | REQ-023 |
| VP-TOP-018 | Area estimate (analysis) | Downstream synthesis report | Standard-cell area ≤ 100 kGE excluding weight memory | REQ-024 |
| VP-TOP-019 | Firmware experiment demo | Firmware flow per REQ-025: init weights, lr_shift=8, stream MNIST-class samples, poll counters, print accuracy | Experiment log shows learning (accuracy rises); stretch ≥ 80% in 5 epochs — reported, not gating | REQ-025 |

Coverage goals (top): APB state machine — SETUP/ACCESS, back-to-back, idle-gap,
read-only-write, reserved-address; sample-stream — full-frame, backpressure (s_ready low
mid-frame), s_last at every index 0..FEATURES, label boundary values 0, CLASSES−1, CLASSES;
learner — idle/running/step/halt/freeze FSM arcs, counter boundaries (0→1, 0xFFFFFFFF),
argmax tie; saturation of MAC accumulator at extremes.

## 3. Per-Module Verification Intent

### 3.1 apb_regs (APB4 register block, IF-001)
Functional intent: decode APB4 transfers into the §6 register map; enforce access types,
self-clearing strobes, WADDR auto-increment, PSLVERR on reserved addresses; expose status
and counters to firmware.

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-APB-001 | Register semantics | Directed writes/reads per access type; strobe bits self-clear; RO writes ignored; rsvd bits ignored | Every §6 access rule holds; WADDR increments after each WDATA access | REQ-009, REQ-010 |
| VP-APB-002 | Transfer sequences | Back-to-back, idle gaps, write-after-read, stall-less bursts | PREADY=1 in ACCESS every transfer; no data corruption; PSLVERR only on reserved addresses | REQ-009 |

### 3.2 sample_stream (IF-002 framing)
Functional intent: byte framing with valid/ready/last; pixel counter; label capture;
malformed detection; backpressure during busy; frame resync after s_last.

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-SIN-001 | Framing and malformed detection | s_last at each pixel index; missing s_last at label index; label ≥ CLASSES | Byte index FEATURES label captured; each malformed case → err + discard + resync (REQ-018 exact) | REQ-008, REQ-018 |
| VP-SIN-002 | Backpressure | s_ready low mid-frame (learner busy); s_valid held; release | No byte lost/duplicated; transfer resumes; full-frame integrity | REQ-008, REQ-016 |

### 3.3 learner (forward + backprop + update datapath)
Functional intent: sequential MAC forward (hidden then output), sigmoid LUT activation,
argmax; backprop deltas; online SGD update with shift-based η; freeze gating; FSM
idle/running with busy signaling.

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-LRN-001 | Forward pass bit-exactness | Directed + golden vectors; boundary activations (z = 0, ±saturation, LUT edges) | Hidden/output activations and PRED match golden model exactly (Q8.8 rules) | REQ-002, REQ-004, REQ-001 |
| VP-LRN-002 | Backprop deltas | Golden vectors for δ_o, δ_h (incl. hidden-layer error) | δ values match golden model; biases update per REQ-021 | REQ-003, REQ-021, REQ-011 |
| VP-LRN-003 | Weight update and freeze | lr_shift sweep; freeze=1 mid-training | Update exactly w − η·δ·a with shift η; freeze → zero delta, weights untouched | REQ-003, REQ-005 |
| VP-LRN-004 | Argmax and ties | Directed output vectors incl. exact ties, all-equal | Lowest index returned on ties; matches golden model | REQ-002, REQ-007 |

### 3.4 weight_mem (parameterized dual-port weight memory)
Functional intent: W_TOT × 16-bit storage; datapath read port + CSR read/write port;
address-map layout of §6; auto-increment handling; init_weights bulk write.

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-WMEM-001 | Address map and arbitration | Walk all 25,450 addresses (tiny config: all words); concurrent CSR write during training | Layout exactly per §6; CSR and datapath accesses never corrupt; boundary addresses F·H−1/F·H, F·H+H−1/+H, W_TOT−1 | REQ-006, REQ-020 |
| VP-WMEM-002 | Full round-trip + bulk init | Pattern write-all, read-back-all; init_weights | Bit-exact round-trip; all words = W_INIT_VAL | REQ-006, REQ-020 |

### 3.5 stats (counters)
Functional intent: SAMPLE/CORRECT/ERROR counting, saturation, clr_stats, err sticky.

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-STAT-001 | Counting, saturation, clear | 1-sample, N-sample, saturation boundary, clr_stats mid-run | Exactly one increment per accepted sample; clamp at 0xFFFFFFFF; clr_stats zeroes all + err | REQ-007, REQ-019, REQ-013 |

Coverage goals (module): all FSM states and legal arcs; all case-branch defaults (address
decode, framing decode); pixel counter roll-over; MAC accumulator extremes; LUT boundary
indices; all W_TOT boundary addresses; error injections per REQ-018.

## 4. Traceability Matrix

| REQ-ID | Verified by | Status |
|---|---|---|
| REQ-001 | VP-TOP-004, VP-TOP-015, VP-LRN-001 | planned |
| REQ-002 | VP-TOP-004, VP-TOP-005, VP-LRN-001, VP-LRN-004 | planned |
| REQ-003 | VP-TOP-004, VP-LRN-002, VP-LRN-003 | planned |
| REQ-004 | VP-TOP-004, VP-LRN-001 | planned |
| REQ-005 | VP-TOP-011, VP-LRN-003 | planned |
| REQ-006 | VP-TOP-010, VP-WMEM-001, VP-WMEM-002 | planned |
| REQ-007 | VP-TOP-004, VP-TOP-009, VP-STAT-001 | planned |
| REQ-008 | VP-TOP-004, VP-TOP-013, VP-SIN-001, VP-SIN-002 | planned |
| REQ-009 | VP-TOP-002, VP-TOP-003, VP-APB-001, VP-APB-002 | planned |
| REQ-010 | VP-TOP-001, VP-TOP-002, VP-APB-001 | planned |
| REQ-011 | VP-TOP-004, VP-TOP-013, VP-LRN-002, VP-LRN-003 | planned |
| REQ-012 | VP-TOP-001, VP-TOP-016 | planned |
| REQ-013 | VP-TOP-001, VP-STAT-001 | planned |
| REQ-014 | VP-TOP-016 | planned |
| REQ-015 | VP-TOP-014 | planned |
| REQ-016 | VP-TOP-012 | planned |
| REQ-017 | VP-TOP-006, VP-TOP-007 | planned |
| REQ-018 | VP-TOP-008, VP-SIN-001 | planned |
| REQ-019 | VP-TOP-009, VP-STAT-001 | planned |
| REQ-020 | VP-TOP-010, VP-WMEM-001, VP-WMEM-002 | planned |
| REQ-021 | VP-TOP-010, VP-LRN-002 | planned |
| REQ-022 | VP-TOP-015 | planned |
| REQ-023 | VP-TOP-017 | planned |
| REQ-024 | VP-TOP-018 | planned |
| REQ-025 | VP-TOP-019 | planned |

## 5. Verification Closure Criteria

1. 100 % of `must` requirements (REQ-001..022) have ≥ 1 passing VP item.
2. 0 orphan REQs; 0 orphan VP items (matrix above is complete in both directions).
3. RTL-vs-golden-model mismatch count = 0 over the full shipped vector set and the
   generated full-config (784×32×10) vector set.
4. All FSM states/arcs exercised (idle/running/step/halt/freeze; malformed resync; APB
   SETUP/ACCESS; stream backpressure).
5. All register reset values, access types and the reserved-address PSLVERR path verified.
6. All error-injection cases produce the specified status (err sticky, PSLVERR, saturation).
7. `should`/`may` items (REQ-023..025) reported with measured numbers; they do not gate
   closure.
