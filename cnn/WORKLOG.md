# cnn — WORKLOG

## 2026-08-25/26 (overnight, ds4 flash in-session; spec/arch/rtl = Claude Sonnet 5)

- tools/train_cnn.py: numpy CNN trainer with QAT baked in (exact integer
  forward + STE gradients). Two bugs found & fixed during the run: conv
  gradient matmuls missing batch mean; float64-exact fast forward added after
  int64 matmul proved too slow (exactness proven: all values < 2^53).
- Training (seed 0, 40 ep, batch 64, eta 0.3): 88.06% (ep5) -> 96.35% (ep40,
  final verified on int64 path).
- golden_ref_model.c (CNN integer contract) compiles clean; run reproduces
  96.35% (9635/146/219); expected.hex/images.hex/labels.hex/expected_outputs.txt
  generated.
- tools/check_cnn.py (independent numpy emulation): 100/100 bit-identical to
  C, full-set identical. Contract cross-validated.
- Pipeline stall (completion event missed after training) -> resumed 01:45Z:
  golden + cross-check done, baseline committed, architect dispatched next.

## 2026-08-26 (architect pass: fe-spec -> fe-arch -> fe-rtl, Claude Sonnet 5)

- Golden baseline reproduced at the start of this pass: `gcc -std=c99 -O2 -Wall
  -Wextra -o gm arch/golden_model/golden_ref_model.c && ./gm .` from `cnn/`
  root -> stdout byte-identical to `expected_outputs.txt` (96.35% / 9635
  correct / 146 incorrect / 219 trash on the full 10,000-image set);
  `git status` clean after the run confirms no frozen file was touched.

- **fe-spec** -> `spec/`: spec.md, requirements.yaml (37 REQs, all `must`),
  interfaces.yaml, verification_plan.md (8 top + 17 module VP items, zero
  orphans), spec_manifest.yaml. Technology deviation (`fpga_generic`, not
  sky130) documented explicitly, mirroring v1 mnist_npu's precedent
  (`mnist_npu/spec/spec.md` §2.1). Reset kept synchronous active-low per the
  task's explicit port spec. `BLINK_CYCLES` default fixed at 100,000 (REQ-026,
  the v1 bug fix) as a direct brief requirement, not an assumption. 2
  assumptions (reset width, exact 100MHz), both acknowledged, neither affects
  bit-exactness.

- **fe-arch** -> `arch/`: arch.md (12 blocks, 6 FSMs — ctrl_fsm's outer
  8-state machine plus 3 shared sub-phase machines [mac_phase/pool_phase/
  present_phase] reused across CONV1/CONV2/FC1/FC2 and POOL1/POOL2/PRESENT
  respectively, plus the 2 reused v1 FSMs), cdc_plan.md (trivial, 0
  crossings), power_plan.md, rtl_coding_guidelines.md, interface_defs.yaml
  (10 internal interfaces), block_diagram.mmd, fsm_diagrams.mmd,
  arch_manifest.yaml. Golden model adopted as-is (frozen, not regenerated),
  identical precedent to v1. Key architecture decisions: single `fm_ram`
  (7,840 x 16-bit) with a two-region ping-pong layout (Region A 0..6271,
  Region B 6272..7839) proven hazard-free by construction (§7.1); 64-bit
  signed accumulator in `mac_datapath`, bit-exact to the golden's `int64_t`
  (margin analysis shows 41 bits would suffice — 64 chosen for direct
  bit-exactness, not just a bound); new `win_addr_gen` block (BLK-012,
  purely combinational) computing every layer's ROM/RAM address plus the
  3x3 zero-padding boundary check.

- **fe-rtl** -> `rtl/` + `ip/` (empty) + `filelist.f` + `sdc/sdc_spec.json` +
  `rtl_manifest.yaml` + `doc/README.md`. 4 files reused byte-for-byte from
  v1 (`uart_tx.v`, `uart_line_fmt.v`, `led_ctrl.v`, `sigmoid_lut.v` +
  `sigmoid_lut.hex` + `mnist_npu_defs.vh`, diffed identical at copy time).
  8 new modules: `weight_rom`, `image_rom`, `label_rom`, `fm_ram`,
  `mac_datapath`, `win_addr_gen`, `ctrl_fsm`, `cnn_npu` (top). `led_ctrl`'s
  `BLINK_CYCLES` file-local default (5,000,000) is deliberately overridden to
  100,000 at `cnn_npu`'s instantiation, not by editing the reused file.

  - **Compile gate (PASS):** `iverilog -g2005 -s cnn_npu -o /tmp/cnn_check.vvp
    -f filelist.f` from `cnn/` root -> exit 0, clean, also clean under
    `-Wall`.
  - **Beyond-gate smoke check (not a committed deliverable — TB is a later
    stage per the task brief; done for architect-level confidence only, then
    discarded):** a throwaway testbench in `/tmp` instantiated `cnn_npu` with
    `HOLD_CYCLES=4, CLK_DIV=4` and compared `lc_pred`/`ctrl_fsm.confidence`/
    `lc_verdict` at each `lc_present` pulse against `expected.hex`. **5/5
    result rows checked, first 4 images (0..3) bit-exact PASS** (pred/conf/
    verdict all matched: img0 pred=7 conf=94% CORRECT, img1 pred=2 conf=92%
    CORRECT, img2 pred=1 conf=94% CORRECT, img3 pred=0 conf=92% CORRECT); the
    5th image's check hit the test's own cycle cap (3,000,000) before
    completing — not a design failure, just an undersized loop bound in the
    throwaway harness. Measured ~669,877 cycles for one full image (compute +
    UART + hold at sim-override parameters), matching arch.md §6.8's
    ~669,976-cycle estimate to within 0.02%. This is materially stronger
    evidence of correctness than the fe-rtl stage requires, but it surfaced
    zero defects, so it is recorded here as evidence rather than gating
    anything.

- No halts of any kind (SPEC-E/ARCH-E/RTL-E) across all three stages — the
  golden contract and task brief were complete and unambiguous throughout.

- Deviations from the literal fe-spec/fe-arch/fe-rtl skill defaults (all
  pre-existing precedent from v1, restated per-project as the skills
  require): `technology: fpga_generic` (not sky130); fully synchronous reset
  (not async-assert/sync-deassert).

---

## Stage: frontend verification (2026-08-26, Suiseira agent) — FULL GREEN

Ran the complete frontend verification chain on the CNN as built:

- **fe-iverilog regression — PASS 9/9 (run-005, 05:41:05Z):** all 8 TBs +
  check_lut + uart_diff green. `tb_mnist_top` (200-image free-run, 2 full
  passes, ~54 min) bit-exact on every image vs the frozen golden:
  **200/200 lines byte-exact** (196 CORRECT + 4 TRASH = trash images 18 &
  73 in both passes), memory-init check C6 passed (img 0 pred=7 conf=94%),
  all LED/blink/verdict checks silent-pass, FSM state coverage passed
  (8/8 legal states 0..7 entered, no illegal states).
- **fe-cocotb stage 2 (run-004/cocotb_stage2, 05:17:14Z) — PASS:** 19
  sequential images 0..18 independently re-verified via cocotb — UART
  bit-level framing decode, golden line byte-compare, LED[10]/LED[9:0]/
  verdict exclusivity, LED[11] busy-blink ≥2 toggles, HOLD-window led[11]
  constancy — ending on the TRASH case at image 18 (NOT A NUMBER line
  byte-exact).
- **Evidence:** `verify/run-005/` (regression: summary.txt, per-TB logs,
  uart_captured.txt, uart_diff.log, golden_100.txt), `verify/run-004/
  cocotb_stage2/` (results.xml + cocotb_icarus.log), append-only
  `verify/iterations.log`. RTL md5 unchanged across all runs
  (0e91731bad2089b37af2b8ffa6f52629) — zero RTL edits during verification.
- **Two TB-side defects found and fixed during this stage (both MY
  adaptations, not RTL bugs):**
  1. `tb_mnist_top.v` VP-CTRL-001 FSM coverage still expected 10 legal
     states (v1 heritage); CNN FSM is 3-bit with 8 states (0..7) → states
     8/9 can never be entered → 2 false failures. Fixed to 8 legal +
     8..15 illegal; also shortened check names to ≤32 chars (checker.vh
     name field truncation was mangling log labels, e.g. "TRL-001").
  2. `test_mnist_top.py` IMG_LIST assumed the DUT could be pointed at
     image 18; the CNN free-runs images 0..99 sequentially (no
     image-select mechanism). Fixed to sequential 0..18 (19 images),
     ending on the trash case at 18.
- **Cost/perf data:** one full image ≈ 669.9k cycles at sim parameters;
  200-image iverilog free-run ≈ 54 min wall; cocotb ≈ 97 s/image.
- Commit: `git add -A` incl. `arch/`, `rtl/`, `spec/`, `sdc/`, `verify/`
  evidence; `.gitignore` extended so `cnn/verify/run-*/` + iterations.log
  are versioned (same policy as mnist_npu).
