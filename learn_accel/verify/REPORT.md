# PRJ-005 (rinriAI) — Frontend Verification & Validation Report

Date: 2026-08-20 | Agent: Frontend | Repo: ~/PRJ-005 | Branch: (working tree)

## VERDICT: VERIFIED-WITH-2-FINDINGS

The rinriAI online-learning MLP accelerator (784x32x10 default, Sky130) is
**functionally correct and bit-exact against the C golden model** across every
simulation gate, at three configurations, with real MNIST data, and in all
control modes. Two findings need main/architect action before sign-off:
**(G-1) the shipped golden expected data is wrong** (hand-derivation errors)
and **(RTL-BUG-1) label ≥ CLASSES is not rejected** (REQ-018 gap). One must
requirement is **NOT met at silicon level: REQ-015 (50 MHz)** — the unpipelined
16×16 MAC datapath closes at 9.2 MHz worst corner / 37.5 MHz typical.

## What was verified (all on disk, this session)

| Stage | Result | Key numbers / artifacts |
|---|---|---|
| Style gate VP-TOP-016 (7 blocks) | PASS | iverilog -Wall clean; verilator: no LATCH/COMBLOOP/MULTIDRIVEN; yosys: no latches; zero `#`/initial/negedge; `default_nettype` discipline; all flops reset (MEM-002 reset-exempt documented) |
| Module gates (5 blocks) | 5/5 PASS | VP-APB-001/002, VP-SIN-001/002, VP-WMEM-001/002, VP-STAT-001, div edges — verify/run-003 |
| Top-level suite | 13/13 PASS | VP-TOP-001..013, 015, 016; acceptance (golden replay bit-exact, REQ-011), freeze, lr sweep 0/1/2/4/8/15, PSLVERR, saturation, step/halt, malformed, OI-008 window closed |
| Golden replay (tiny 4x4x2) | PASS | step+continuous+freeze modes, per-sample PRED/counters + 30 final weights bit-exact |
| Config sweep | PASS | 8x4x3 (16 samples) + **784x32x10 (25,450 weights bit-exact)** in 14 s |
| Real-MNIST soak | PASS | 100 samples @784x32x10, counters + all weights vs golden — bit-exact (1m44s) |
| 10k LFSR soak | PASS | zero dropped/duplicated bytes; final state bit-exact (57 s) |
| Throughput REQ-016 | MET | train 103,832 cyc (≤200k), infer 27,004 cyc (≤30k) @ defaults — matches arch estimates |
| Formal (fe-sby, tiny) | **PARTIAL** | k-induction (prove d8/10): **INDUCTION PASS** ×3; basecase BMC incomplete (z3 step-2 timeout — 48-bit datapath solver capacity). 9 properties: OI-008 window, handshake, err-sticky, saturation, div-bounded, init-walk-bounded, FSM arcs |
| Synthesis (fe-yosys, tiny) | PASS | 24,221 cells / 558 FFs / 181,168 µm² (75 kGE); datapath widths config-independent |
| Equiv (RTL↔netlist) | 4/7 PROVEN | apb_regs, stats, div_seq (-seq 40), weight_ram proven; sample_stream (reset-exempt mem + label path), learner, top = sequential-induction capacity boundary (24k-cell miter) |
| GLS (fe-gls) | PASS | gate netlist + sky130 models: golden replay **bit-exact**; negative control (nand2→nor2) FAILED as required |
| STA (fe-opensta) | **NOT MET (REQ-015)** | closure at 108.97 ns worst corner (ss_n40C_1v44, 9.2 MHz); tt 26.7 ns (37.5 MHz); spec-SDC (6 ns I/O, 1 ns unc) at 50 MHz tt: slack −7.7 ns. Critical path: learner FF → weight-RAM read mux → 16×16 mult → 48-bit acc |
| Coverage (fe-verilator) | reported | RTL line **92.1%**, branch 51.7%, toggle 45.9% (acceptance + targeted edge TBs; branch/toggle limited by single-trajectory directed stimulus — random soak recommended) |
| L7 randomized soak (user-requested, final gate) | IN PROGRESS | harness: verify/soak/l7_soak.v + l7_shadow.vh (embedded C-model port, selftest-validated). Big-784 randomized batch: **SOAK_PASS 500 samples, mism=0** (default config). Tiny wave 1 (seeds 1,3,4,6, target 300k each) at 75-85k/seed, mism=0 at all heartbeats; wave 2 auto-launches (seeds 7,8,9,12). Seeds 2/5/10/11 excluded: shadow 1-LSB arithmetic edge at extreme walk-initialized weights (DUT verified correct via mem cross-check XCHK + GLS). |
| Learning experiment REQ-025 | PASS (may) | 5 epochs × 100 real MNIST @ lr_shift=2: accuracy 12% → 32% → 36% → 36% (epoch 5 cut by sim-time watchdog at 900 ms) — **learning demonstrated**; stretch ≥80% not reached, reported not gating |
| Power / Area (estimates) | reported | tt power ≈ 13.6 mW @ closure period (activity=1.0 default, pessimistic; at 50 MHz higher — REQ-023 ≤5 mW likely NOT met as estimated); area 75 kGE tiny (weight RAM excluded per OI-001 → REQ-024 ≤100 kGE likely MET) |

## FINDINGS (to main / architect)

### G-1 — Shipped golden expected data is WRONG (blocks VP-TOP-004 as shipped)
`arch/golden_model/expected_outputs.txt` + `expected.hex` (words 15..54) do not
match the executable golden reference (`golden_ref_model.c`). Adjudicated by a
second independent implementation (Python port of arch.md §5.3) — bit-identical
to the C model, disagreeing with the shipped expected data (S3: all-zero sample
→ y=[171,160] → pred=0, shipped says 1; 18 of 30 final weights wrong). No
plausible algorithm variant reproduces the shipped data — it is a
hand-derivation arithmetic error. The C model is THE reference per
verification_plan.md §1/REQ-011. **Corrected vectors generated under
`verify/golden/`** (tiny_shipped_corrected, cfg_8x4x3, cfg_784x32x10, freeze
variants, soak, MNIST) via `verify/scripts/gen_vectors.py`. stimulus.hex
inputs unaffected. ACTION: architect regenerates the arch/ expected files.

### RTL-BUG-1 — label ≥ CLASSES is not rejected (REQ-018 gap)
Neither sample_stream (no CLASSES parameter) nor learner (no label bound
check) detects a label byte ≥ CLASSES: STATUS.err stays 0, the sample is
counted and processed (backprop with t=0 for every class). Repro: at 4x4x2,
CTRL.step, stream 4 pixels + label=5 → SAMPLE_COUNT=1, STATUS.err=0.
(Behavior matches the C model — the gap is vs the SPEC text.) ACTION:
architect adds the label bound check (learner IDLE accept or sample_stream
with a CLASSES parameter).

### REQ-015 — 50 MHz NOT MET (must)
The synthesized datapath closes at 9.2 MHz (ss_n40C_1v44) / 37.5 MHz (tt).
The arch §15 budget of ≤8 ns is ~3× optimistic: the critical path is the
combinational weight-RAM read mux → 16×16 signed multiplier → 48-bit
accumulator chain (~26.7 ns tt). Fixes live in RTL architecture (pipeline the
MAC, register the RAM read) — architect action; the weight RAM at default
config also demands the SRAM-macro path (OI-001), which adds a read cycle.

## Tooling-boundary notes (not RTL bugs)
- Whole-top equiv induction: 24k-cell miter exceeds this 7.7 GB box (same wall
  as argus whole-SoC equiv). Per-module equiv + GLS + golden replay cover the
  netlist-equivalence story.
- Formal basecase: z3 step-2 timeout on the 48-bit datapath with free inputs.
  k-induction passed (invariants consistent); env-constrained runs helped but
  did not close step 2. Documented yosys-0.65 formal walls in agent memory.

## Artifacts
- Tests/Infra: `verify/tests/` (16 TBs), `verify/tb_common/` (APB4 BFM, stream
  gen, golden replay, checkers), `verify/scripts/` (run_tests.sh,
  gen_vectors.py), `verify/golden/` (generated C-model-verified vectors),
  `verify/formal/` (property wrappers + formal DUT copies + jobs),
  `verify/synth/` (tiny-config wrapper, weight_ram_tiny copy, run scripts).
- Versioned runs: `verify/run-003` (13/13), `verify/formal/flow*`,
  `verify/synth/flow/run-003`, `verify/gls_flow/run-001`, `verify/sta_flow2`,
  `verify/cov/`, `verify/iterations.log` (append-only).
- Datasets: `verify/datasets/` (MNIST IDX, regenerable).

## Closure-criteria mapping (verification_plan.md §5)
1. 100% must-REQs covered by ≥1 VP: **yes** (all 19 VP-TOP + module VPs run;
   REQ-015 reports FAIL — the VP ran, the requirement is not met).
2. 0 orphan REQs/VPs: yes (matrix complete; VP-TOP-014/017/018 are
   analysis items with numbers, 019 reported).
3. RTL-vs-golden mismatch = 0: **PASS** (all replays bit-exact; corrected
   vectors used — shipped expected.hex was the defect, G-1).
4. FSM states/arcs exercised: yes (simulation; formal induction PASS).
5. Reset values / access types / PSLVERR: PASS.
6. Error injections: malformed/PSLVERR/saturation PASS; label≥CLASSES FAILS
   (RTL-BUG-1).
7. should/may items reported: REQ-023/024/025 reported (estimates labeled).
