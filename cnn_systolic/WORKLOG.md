# cnn_systolic WORKLOG

## 2026-08-28 18:24Z — project start (main)

Rinri (Telegram): create `cnn_systolic/` inside PRJ-005 — ASIC implementation,
systolic array + floating point, different from cnn_soc. "Tell me if you
understand before building, wait for my go." Confirmed; open questions
surfaced; Rinri answered all at 18:24Z. Go.

### Locked decisions (Rinri 2026-08-28 18:24Z)
1. FP format: **BF16** operands (weights/activations), FP32 accumulate.
2. Golden: **bit-exact, mirrored dataflow** — FP golden C model computes in the
   exact accumulate order of the 8x8 systolic array (conv) and the serial FC
   datapath.
3. Array: **8x8** (64 PEs), **conv layers only**. FC1/FC2 **serial** (not on
   the array).
4. Sigmoid: **piecewise** — exact breakpoints/coefficients pinned in arch,
   mirrored bit-exact in golden.
5. Scope: **front-end only** (spec -> arch -> rtl -> yosys -> openSTA ->
   firmware -> functional verify + coverage). **NO formal (sby), NO GLS, NO
   equivalence** (Rinri explicitly dropped all three).
6. PASS gates: (a) functional verification + measured functional coverage,
   (b) fe-opensta (timing/area/SDC QA), (c) fe-firmware (build + SoC verify,
   UART diff vs **regenerated FP expected outputs**).
7. Retry policy: **3 retries per gate**; if still failing after 3, write an
   honest review (what failed, why, residual risk) and pass with it as
   evidence. Never fake a pass.
8. Weights: **no retraining** — export BF16 from
   `../cnn/arch/golden_model/weights_float.npz` (float masters). Conversion
   float32->BF16 round-to-nearest-even, defined in the export script; golden
   uses the identical conversion.
9. `cnn/` and `cnn_soc/` are **READ-ONLY references**; all new artifacts live
   in `cnn_systolic/`. No git commits during the run (main commits at
   close-out).

### Dispatch plan
- P0/P1: architect agent (fe-spec + fe-arch incl. FP golden + BF16 export +
  systolic dataflow spec + tiling).
- P2..P6: frontend agent (fe-rtl -> fe-yosys -> fe-opensta -> fe-firmware ->
  functional verify + coverage + SoC UART diff).
- Main: skeleton, brief, monitoring, close-out (commit + memory + report).

### Pre-flight (18:24Z)
- Gateway healthy (openclaw status clean; agents 21, sessions 670).
- Skeleton created: spec/ arch/ rtl/ ip/ tb/ verify/ out/ sw/ sdc/ doc/.
- Frontend agent session had ended FAILED on 2026-08-26 (deepseek billing
  block, per cnn_soc pipeline_state.txt) — flagged; dispatch proceeds, first
  billing error pauses the run and reports.

## 2026-08-28 18:31Z — AUTONOMY OVERRIDE (main)

Rinri: "Continue till the end without halting/stopping, I'll be sleeping."
- Structured halts REPLACED for this run: agents resolve unconfirmed
  assumptions with documented best judgment and proceed (log + flag in final
  report). No waiting on Rinri.
- Billing/model failure: log, fall back to a funded model (sonnet) if needed,
  record the switch. (Spend authorization implied by the grant.)
- Main set a 30-min pipeline-watch cron (systemEvent to main) to monitor
  architect/frontend progress, nudge stalled stages, intervene on blockers.
- BRIEF.md updated with the override section; architect notified in-session.
- Close-out (main): commit, WORKLOG/memory fold, morning report to Rinri.

## 2026-08-28 ~19:40Z — P0/P1 COMPLETE (architect announce)

- P0 fe-spec PASS (41 REQs, 9 ASMs acknowledged J1..J8 under override, 0 blocking
  OIs, reg map/UART/conf/memory map identical to cnn_soc, Sky130 100 MHz sync
  rst_n, REQ-041 no formal/GLS/equiv).
- P1 fe-arch PASS (19 blocks — 11 custom + 8 shell verbatim; 6 FSMs; 8
  memories; 0 CDC; systolic_dataflow.md accumulate order; tiling_plan.md 2/18
  passes; piecewise_sigmoid.md exact dyadic table ≈ act_float(z)=0.5+0.5z/(1+|z|)
  — NOT logistic).
- Golden validated with ONE REAL BUG found+fixed: f32_add result-sign bug
  (opposite-sign adds took sign of raw difference instead of magnitude winner)
  — fixed + 2 sign-coverage vectors added (original 64 missed them). Also fixed:
  bf16_of_pixel clz bug (e7=31-clz32(p)), sigmoid target was act_float not
  logistic (table redesigned, 14 dyadic segments). Debug aids (Q8.8 numpy
  replication + twin reshape) had bugs too — all fixed.
- Validation: BF16 export 26,698/26,698; directed 66/66; 100-image twin 100/100;
  full-set accuracy 96.08% (9608/142/250) vs Q8.8 96.35% — parity, OI-002
  RESOLVED; FTZ counters all zero; G6 re-run byte-identical.
- Key numbers: compute ≈755,400 cyc/image → BUSY ≤ 760,000; 2-stage PE MAC;
  weight ROM 8×4096×16 BF16; FM RAM 8192×16; 9 shifted image banks; 8 pool1
  banks. OI-001 (SRAM macro PDK-verify) + OI-003 (shell sram mapping) → fe-rtl.
- Artifacts verified on disk by main (spec/ 5 files, arch/ 12 items incl.
  golden_model/, expected_outputs.txt 100 lines).
- 19:40Z: frontend dispatched for P2 fe-rtl → P6 functional verify + coverage.
  Night-watch cron active; next: monitor + close-out.

## 2026-08-28 19:10Z — P0/P1 start (architect agent)

Autonomy override (Rinri 18:31Z) in effect: no halts; best documented judgments logged here;
final report flags them. memory_search unavailable (embedding provider error) — disk-only
grounding this run.

### Judgment calls made so far (each logged, will be flagged in the final report)
- **J1 — golden/export execution.** The brief's P1 deliverable list (weights_bf16.hex, stimulus/
  expected.hex, regenerated FP expected outputs) requires running the BF16 export script and the
  new FP golden. fe-arch's "do not run" rule conflicts with the brief's deliverables; project
  precedent (mnist_npu 2026-08-25, cnn 2026-08-26: fe-arch ran the golden to populate expected
  outputs — their WORKLOGs document it) supports execution. Judgment: run export_bf16.py (numpy)
  + golden_ref_model.c (gcc) once, log exact commands/outputs here, cross-check with an
  independent numpy twin (check_fp.py). Alternative (stub files) would break P2 (needs
  weights_bf16.hex NOW). FLAGGED.
- **J2 — FP32 subnormal policy: flush-to-zero (FTZ)** on fp32_add/fp32_mul results AND on BF16
  conversion inputs. Deviation from IEEE-754 (which keeps subnormals) documented in arch;
  golden mirrors FTZ exactly; range analysis says FTZ never fires for this network's weights/
  activations (verified in the golden run via a flush counter).
- **J3 — piecewise sigmoid:** dyadic breakpoints {0,1/4,1/2,1,3/2,2,4,8}, dyadic sigma values,
  all constants exactly representable in FP32 (bit patterns pinned in arch). Max error vs
  true sigmoid ~0.25% (confidence granularity is 1%).
- **J4 — accumulate order pins** (the bit-exactness contract): conv1 per-oc: bias, then taps
  0..7, then tap 8; conv2 per-oc: bias, then (iy,ix) k=0..8 outer, ic c=0..7 inner (18
  sub-passes, oc-group 0 before 1); FC serial: bias, then input index ascending. See
  arch/systolic_dataflow.md.
- **J5 — memory banking:** weight ROM as 8 interleaved banks (8×~3,338×16, spec'd as 8×4,096×16
  SRAM macros = 524 Kbit vs the brief's ~427 Kbit naive size — banking overhead, documented);
  img buffer 9 pre-shifted banks (784×8 each, tap t = iy*3+ix) giving zero-padded parallel
  reads; pool1 output in 8 per-channel banks (256×16); FM RAM 8,192×16 SRAM macro (h1/h2/h3
  share region A, p2 in region B).
- **J6 — compute budget:** conv1 137,993 + pool1 9,408 + conv2 570,896 + pool2 4,704 + FC1
  25,152 + FC2 ~450 + present ~50 ≈ 748,653 cycles/image → BUSY ≤ 750,000; firmware poll
  guard stays 3,000,000 iterations (≈12M cycles, 16× margin) — re-derived from cnn_soc's
  667,208 (harness constant unchanged, comment updated in P4).
- **J7 — PE array:** 8×8 weight-stationary, 2-stage pipelined MAC (BF16 mult stage + FP32 add
  stage) for 100 MHz closure; wavefront = 8 cycles/sub-pass + 2-cycle drain; acc stays in PE
  across sub-passes (per-pixel sequential — cross-pixel pipelining would need 1.6 Mbit of
  external FP32 partials, rejected on area).
- **J8 — shell sram.v (128 KB behavioral RAM) reused verbatim; Sky130 macro mapping is an
  fe-yosys decision (documented area risk, non-blocking OI).**

### Pre-flight (19:10Z)
- Refs read this session: BRIEF/README/WORKLOG (cnn_systolic), fe-spec + fe-arch SKILL.md (full),
  cnn/arch/{arch.md,golden_model/{README.md,golden_ref_model.c}}, cnn/tools/{train_cnn.py,
  check_cnn.py}, cnn_soc/{spec/{spec.md,requirements.yaml,interfaces.yaml,verification_plan.md,
  spec_manifest.yaml}, arch/arch_manifest.yaml, rtl/{sram,vec_rom,bootrom,axi_lite_interconnect,
  axi2apb,apb_uart,apb_gpio}.v headers, ip/IP_PROVENANCE.md, sw/main.c, sdc/sdc_spec.json}.
- Toolchain: python3 3.10.12 + numpy 2.2.6 + gcc present.
- weights_float.npz structure confirmed from train_cnn.py: keys W1(8,1,3,3) b1(8) W2(16,8,3,3)
  b2(16) W3(784,32) b3(32) W4(32,10) b4(10), float64, pre-quantization masters; flat layout =
  conv1_w[oc*9+t] | b1 | conv2_w[oc*72+ic*9+k] | b2 | fc1_w[i*32+j] | b3 | fc2_w[i*10+j] | b4.

P0 fe-spec writing now.

## 2026-08-28 19:35Z — P0 fe-spec COMPLETE
- spec/ 5 files written + YAML-validated (41 REQs all must+traced, 9 ASMs acknowledged under
  override, 0 blocking OIs, 9 top + 22 module VP items).
- FE-SPEC handoff printed to the requester. Moving to P1 fe-arch.

## 2026-08-28 21:40Z — P1 fe-arch COMPLETE (golden validated; one real bug found & fixed)

### The debugging saga (why it took 2.5 h)
The first golden runs gave 2% accuracy — a systematic failure, not noise. Root causes found by
layer-by-layer diffing against the instrumented OLD Q8.8 golden (copied to /tmp, never touched
the read-only original):
1. **bf16_of_pixel used the 32-bit __builtin_clz with an 8-bit formula** → pixels became ~2^-27
   (garbage). Fixed: e7 = 31 - clz32(p).
2. **The activation function target was wrong in my spec**: the network family's "sigmoid" is
   the TRAINED rational act_float(z) = 0.5 + 0.5z/(1+|z|) (the old Q8.8 LUT's function), NOT the
   logistic 1/(1+e^-z). Redesigned the piecewise table around act_float (14 dyadic segments,
   exact FP32 constants; max error ~0.003). piecewise_sigmoid.md rewritten.
3. **f32_add result-sign bug (THE killer)**: for opposite-sign operands the code took
   neg = (s < 0), but after swapping the larger-exponent operand into aq the result sign must be
   THAT operand's sign (magnitude winner). Same-sign negative adds were also broken (s is always
   positive there). This flipped every mixed-sign accumulation whose larger operand was negative
   → conv/FC sums corrupted → constant wrong argmax. Fixed with saq tracking; added two
   sign-coverage vectors (which the original 64 missed — the existing set never tested
   small+large-negative or negative+negative).
4. Two bugs in MY OWN debugging aids, not the golden: my quick Q8.8 numpy replication missed the
   two's-complement sign of weights.hex; the numpy twin had a (B,px,oc)-vs-(B,oc,...) reshape
   transpose bug AND a pass-B activation bug (col 0 must be fed from bank 8 = tap 8's window).
   All fixed; the twin is now a clean independent implementation.

### Final validation (all measured this pass)
- BF16 export cross-check (independent conversion): 26,698/26,698.
- Directed vectors: 66/66 vs hand-derived expected_vectors.txt (G7).
- 100-image cross-check vs the numpy twin: 100/100 (G8).
- Full 10,000-image accuracy: **96.08 %** (9608 correct / 142 incorrect / 250 trash) vs the
  Q8.8 baseline's 96.35 % — BF16 + piecewise sigmoid at parity; OI-002 RESOLVED.
- FTZ flush counters: all zero (policy never fires, as predicted).
- G6: re-run byte-identical.
- Artifacts committed: expected_outputs.txt (100 UART lines), expected.hex (400 words),
  stimulus.hex (78,400), labels.hex (100), weights_bf16.hex (26,698).

### Judgment updates
- J3 amended: sigmoid = piecewise approx of act_float(z) (not logistic). Pinned in
  piecewise_sigmoid.md; mirrored in golden + twin + vectors.
- J1 executed as planned (export + golden run, commands logged in this file); flagged in the
  final report.
- arch_manifest.yaml: executed_by_skill: true, accuracy + cross-check results recorded.

P1 handoff printed to the requester. Next: P2 fe-rtl (frontend agent).

## 2026-08-28 22:1xZ — P2 fe-rtl COMPLETE (frontend agent)

- Shell reused byte-identical from cnn_soc (10 files; provenance in ip/IP_PROVENANCE.md).
  cnn_axi_slave (BLK-009) REUSED verbatim (its spec IS the cnn_soc slave — register map +
  park/start/present sequencer + wstrb-packed image write path; brief mandates harness
  identity; documented judgment).
- New custom RTL (17 files): fpu_fp32_add/mul/bf16_mul/bf16_round/bf16_expand/sigmoid/
  sigma256 (bit-exact golden mirror), systolic_array (8x8 weight-stationary + PARTIAL-SUM
  CHAIN — add order = bias, then left-to-right columns, per-oc bit-exact), conv_ctrl (layer
  FSM + sub-pass sequencer + drain pipeline + bias staging), pool_unit, fc_datapath (serial
  BF16 MAC + piecewise sigmoid + sigma256 + argmax), weight_rom/fm_ram/img_banks/p1_banks
  (behavioral bodies), bias_regfile, cnn_core, cnn_systolic.
- Memory strategy (OI-001/OI-003 RESOLVED for front-end): behavioral arrays in sim;
  same-name blackbox stubs (synth/*_bbox.v) for the gate flow — zero RTL edits; real
  OpenRAM sky130 macros deferred to PnR (documented).
- iverilog -g2005 elaboration: EXIT 0 (only benign picorv32 cpuregs warnings).
- **FP unit validation: 70/70 golden directed vectors bit-exact** (verify/tests/fp_unit_test.v).
  Bugs found & fixed this pass: (1) fp32_add used unaligned bq in sum/sub; (2) sigmoid sign
  fold XORed all 32 bits ({32{z[31]}}) then bit-0 ({31'd0,z[31]}) — fixed to {z[31],31'd0};
  (3) pass/n_out widths (17/32 need 5/6 bits); (4) img_banks pixel divmod (iw_addr[9:5] is
  /32 not /28); (5) iverilog -g2005 unpacked-array ports → flattened vectors.
- Design notes (documented judgment): wavefront = parallel act latch + partial-sum chain
  (arch prose "1 col/cycle wavefront" is internally inconsistent; the contract's substance —
  per-PE add order — is reproduced exactly); PWR-001 ICG clock gating deferred to PnR;
  ST_IDLE wait state added (busy=0 while parked).
