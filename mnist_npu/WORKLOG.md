# mnist_npu — WORKLOG

Architect pipeline run: fe-spec -> fe-arch -> fe-rtl. All three stages completed; no structured
halts. This log records stages, key decisions, and verification evidence.

## Stage 1 — fe-spec (spec/)

Artifacts: `spec.md`, `requirements.yaml` (30 REQ, all `must`, 3 ASM), `interfaces.yaml` (3
interfaces, 1 clock domain, 0 CDC), `verification_plan.md` (8 top-level VP + 13 module VP items,
full traceability matrix, 0 orphans), `spec_manifest.yaml`.

Key decision — **technology deviation (documented, not guessed):** the fe-spec skill's default
hard scope targets Sky130 130 nm ASIC tapeout (halt `SPEC-E004` on a non-Sky130 brief). This
project's brief explicitly and unambiguously specifies an FPGA deployment (Xilinx Artix-7 100T /
Nexys A7, FPGA bring-up explicitly deferred). This is not a silent default or an unresolved
ambiguity — the brief is completely clear — so the technology was recorded as `fpga_generic`
throughout, with the deviation and its rationale written into `spec.md` §2.1,
`spec_manifest.yaml : deviation_note`, and carried forward unchanged into every later manifest.

Other explicit deviations from fe-spec's own defaults, all directly mandated by the brief and
recorded as such (not guesses): fully **synchronous** reset (not async-assert/sync-deassert); no
host bus / no APB register block at all (REQ-015).

3 assumptions (ASM-001 min reset assert width, ASM-002 exact 100 MHz, ASM-003 default
`BLINK_CYCLES`) recorded and explicitly acknowledged in `spec_manifest.yaml`
(`assumptions_acknowledged: true`) — all three are cosmetic/pacing only, proven to have zero effect
on bit-exactness.

## Stage 2 — fe-arch (arch/)

Artifacts: `arch.md`, `block_diagram.mmd`, `fsm_diagrams.mmd`, `interface_defs.yaml`, `cdc_plan.md`
(trivial — 0 crossings, as expected for 1 clock domain), `power_plan.md` (no clock gating, single
always-on domain), `rtl_coding_guidelines.md`, `arch_manifest.yaml`.

11 blocks (BLK-001..011): top + ctrl_fsm + mac_datapath + sigmoid_lut + weight_rom + image_rom +
label_rom + hidden_ram + uart_tx + led_ctrl + **uart_line_fmt** (added beyond the brief's suggested
module list — the brief explicitly invited "refine as you see fit" — because ASCII line
composition with variable-width, no-leading-zero confidence formatting is a distinct
responsibility from both `ctrl_fsm`'s sequencing and `uart_tx`'s bit-level shifter). 3 FSMs
(`ctrl_fsm` 10 states, `uart_line_fmt` 3 states, `uart_tx` 4 states), all binary-encoded with full
transition tables. 5 memories (weight/image/label ROM, hidden RAM, sigmoid LUT).

**Golden model handling:** `arch/golden_model/` is pre-existing and FROZEN per the task. This stage
did **not** regenerate it. It was re-run (`gcc -std=c99 -O2 -Wall -Wextra -o gm
golden_ref_model.c && ./gm .` from the `mnist_npu` root) purely to confirm reproducibility — output
was byte-identical to the committed files (`git status` clean afterward: 9225 correct / 270
incorrect / 505 trash / 92.25%, matching the committed baseline exactly).

Key architecture decision made and documented mid-design (arch.md §6.1): the MAC-loop and bias-load
timing were worked out explicitly to respect the 1-cycle read latency of the registered
`weight_rom`/`image_rom`/`hidden_ram` (needed for clean BRAM inference, REQ-025) — each MAC step is
an ADDR/ACC micro-step pair, and each hidden/output unit's bias is fetched as its own dedicated
ADDR/ACC pair (a single-port ROM cannot return the bias word and the first weight word in the same
cycle). `mac_z` was made purely combinational (not registered) specifically to avoid stacking a
third pipeline-latency stage that could not be verified without a working simulator in this
environment — this simplification was applied retroactively and the cycle-budget arithmetic in
arch.md §8 was corrected to match (documented inline, not hidden).

## Stage 3 — fe-rtl (rtl/, ip/, filelist.f, sdc/, doc/, rtl_manifest.yaml)

11 Verilog-2001/2005 modules, one per file, `mnist_npu.v` as top (module name matches the task's
mandated `-s mnist_npu` exit-check exactly — corrected from an initial `mnist_npu_top` draft name
before finalising). `ip/` is empty of vendored sources (`IP_PROVENANCE.md` documents the one
considered-and-rejected reuse candidate, `uart_tx`, custom per REQ-021/022's exact-byte contract).
No `rtl/blackbox/` — zero analog macros in an FPGA-generic design.

**Bug caught and fixed during self-review (documented, not silent):** the first `uart_line_fmt`
draft used a registered `utx_valid` gated by a registered `utx_ready` read one cycle earlier — this
double-fires on a valid/ready handshake (the classic registered-vs-registered race). Fixed by
making `utx_valid`/`utx_data` pure combinational functions of `(state, byte_idx)` only (never of
`utx_ready`, satisfying the documented `valid_may_depend_on_ready:false` semantics) and only
advancing `byte_idx`/state on a cycle where `utx_ready` is independently observed high — the
standard, race-free valid/ready pattern. Caught by hand-tracing the handshake because no
simulator was available to catch it dynamically in this environment (verification is explicitly a
later stage).

**Documentation correction caught during LUT verification:** `verification_plan.md`'s VP-LUT-002
originally claimed `sigma(-1) == 127`; the real value (confirmed by both the generated LUT and a
hand check) is `128` (truncation-toward-zero flattens both z=-1 and z=0 to the same sigma). Fixed
in `spec/verification_plan.md` before this stage completed.

**Confidence range sanity check:** confirmed `confidence = (best_val*100)>>8` can only ever reach
99, never 100, given the LUT's proven `sigma` range of 1..255 (not 0..256 as the golden C
comment's loose phrasing suggests) — cross-checked against the actual 10,000-image golden run
(observed max confidence: 96). The RTL's `uart_line_fmt` still defensively formats a hypothetical
3-digit "100" case (dead code, matches REQ-010's literal "0..100" wording) — documented, not a bug.

### Verification evidence gathered this stage

```
$ gcc -std=c99 -O2 -Wall -Wextra -o gm arch/golden_model/golden_ref_model.c && ./gm .
SUMMARY on 10000 test images: correct 9225, incorrect 270, trash 505, accuracy 92.25%
$ git status --porcelain   # after the run above: clean — byte-identical to committed golden files

$ python3 tools/gen_sigmoid_lut.py rtl/sigmoid_lut.hex
wrote 65536 entries to rtl/sigmoid_lut.hex
$ python3 tools/check_lut.py rtl/sigmoid_lut.hex
PASS: rtl/sigmoid_lut.hex matches golden sigmoid(z) bit-exactly for all 65536/65536 addresses

$ iverilog -g2005 -s mnist_npu -o /tmp/mnist_check.vvp -f filelist.f
(no output, exit code 0)
$ iverilog -g2005 -Wall -s mnist_npu -o /tmp/mnist_check2.vvp -f filelist.f
(no output, exit code 0 — clean even under -Wall)

$ grep -n "always_ff\|always_comb\|always_latch\|\blogic\b\|typedef\|\benum\b\|casex\|\.\*\|posedge clk or negedge" rtl/*.v
NONE FOUND (only false-positive comment-word matches on "asserted")
```

All named-port instantiations were cross-checked against each module's declared port list
(name-for-name, all 29 `ctrl_fsm` ports verified as one representative example) — consistent with
`iverilog` raising no "no such port" errors on the full 11-module elaboration.

## Deviations summary (all explicit, all documented at point of origin)

1. Technology: FPGA-generic (Artix-7 100T / Nexys A7), not Sky130 130 nm — brief-mandated,
   documented in `spec.md` §2.1 / `arch.md` §2.1 / both manifests' `deviation_note`.
2. Reset: fully synchronous, not async-assert/sync-deassert — brief-mandated, documented in
   `spec.md` §5, `rtl_coding_guidelines.md` §3, every module's own header comment.
3. No host bus/CSR/APB anywhere — brief-mandated (REQ-015).
4. `uart_line_fmt` (BLK-011) added beyond the brief's suggested module list — brief explicitly
   invited refinement; documented in `arch.md` §3.

## No halts

No `SPEC-E`, `ARCH-E`, or `RTL-E` structured halt occurred at any stage. The one skill-level check
knowingly and explicitly overridden (fe-arch's `technology.pdk==sky130` gate, `ARCH-E007`) was
overridden with full written justification rather than silently skipped, per the same reasoning
already applied at the fe-spec stage.

## Stage 4 — frontend verification (verify/) — fe-iverilog -> fe-cocotb -> fe-regression

Verification agent pass, RTL frozen at `ae9b07d` throughout (confirmed via a constant RTL md5,
`f9bb51a6e18820abfc894f06f23a534a`, across every run recorded in `verify/iterations.log`). Full
detail in `verify/report.txt` and `verify/FINDINGS.md`; summary here.

**Baseline reproduction (isolated, zero risk to frozen files):** `golden_ref_model.c` rebuilt and
re-run from a `/tmp` scratch directory (symlinked inputs, never the real `arch/golden_model/`
outputs) — byte-identical to the committed `expected.hex`/`images.hex`/`labels.hex`/
`expected_outputs.txt` (correct 9225 / incorrect 270 / trash 505 / 92.25%, matching the fe-arch
stage's own reproduction exactly).

**Stage 1 (fe-iverilog, PRIMARY GATE):** 8 pure-Verilog-2001/2005 testbenches (mirroring
`learn_accel/verify`'s conventions: `tb_common/*.vh` + `tests/tb_*.v` + versioned `run-NNN/` +
append-only `iterations.log`), covering VP-TOP-001..008, VP-LED-001..003, VP-MAC-001..003,
VP-LUT-001/002, VP-ROM-001, VP-UART-001/002, VP-CTRL-001/002 and the verify-task's own C1-C7 checks.
200-image (2 full free-running passes, proving the 0..99 wraparound) bit-exact regression: 0
mismatches on pred/confidence/verdict, 0 byte mismatches across the full UART stream (md5-identical
to the golden `expected_outputs.txt`), 0 LED-encoding mismatches, 100% FSM state coverage. Result:
8 PASS / 1 FAIL / 0 ERROR — the 1 FAIL is FINDING-001 (below), not a data-path issue. Elaboration
lint (`ivl_lint.sh`) and the X-hygiene structural scan (`x_check.sh`) both PASS clean (0
warnings/errors, 0 X/Z events).

**Stage 2 (fe-cocotb, independent harness):** a separate Python/cocotb 2.0.1 implementation
(`test_mnist_top.py`, async/await + RisingEdge polling — deliberately not sharing any code or
control-flow shape with Stage 1's Verilog tasks) re-verifies UART framing/line-strings, LED[11]
blink-window timing, and verdict/LED[10]/LED[9:0] exclusivity over 9 images (8 CORRECT + 1 TRASH
from the golden set). Result: 1/1 PASS, 0 mismatches. (A same-session TB bug — a flawed assumption
about `lf_done` timing relative to full UART transmission — was caught and fixed before this
verdict; documented in `verify/report.txt`, not an RTL issue.)

**Stage 3 (fe-regression):** consolidated into `verify/run-001/` + `verify/iterations.log`
(append-only, RTL md5 per entry) + `verify/report.txt`. Constrained-random multi-seed REGRESS
doesn't apply to this design (fully directed stimulus per `spec/verification_plan.md`'s own stated
methodology — no randomness to vary); the 200-image/2-pass run already is this design's soak, since
the free-running loop only ever cycles the same 100 golden vectors and further passes are provably
identical (no persistent state beyond the deterministically-wrapping `img_idx`).

**1 finding, RTL, Low severity (FINDING-001, not fixed — RTL frozen for this pass):** `led[0]` reads
1, not 0, throughout reset (violates REQ-030/VP-TOP-001's literal `led[11:0]==0` criterion, and
contradicts `arch.md`'s own documented BLK-010 reset-behaviour claim). Root cause: `led_ctrl.v`
resets `verdict_r<=2'd0` (CORRECT) rather than `2'd2` (TRASH) — combined with `pred_r<=4'd0`, the
combinational `led_digit=(verdict_r==2'd2)?0:(10'd1<<pred_r)` evaluates to 1, not 0. Cosmetic/
display-only: does not affect inference correctness (fully bit-exact across 209 total images
verified between both stages) — only the LED digit display's transient value between reset-release
and the first result being presented. Full reproduction command, expected-vs-actual table, and a
suggested one-line fix direction are in `verify/FINDINGS.md`.

**TB bugs found and fixed this session (TB-side only, documented for transparency, not RTL):** an
early UART monitor mixed `@(negedge uart_tx)` with `@(posedge clk)` cycle-counting, producing a
spurious extra sampled cycle per frame boundary (confirmed via a from-scratch `@(posedge
clk)`-only cross-check probe reading `uart_tx.state`/`baud_cnt` directly — a TB artifact, not an
RTL timing bug: the real pin holds each symbol for exactly `CLK_DIV` cycles); two testbenches
cleared a DUT-facing control signal with a blocking assignment immediately after the
`@(posedge clk)` it needed to be seen high on, racing the DUT's own NBA-driven always block (fixed
by switching to non-blocking, matching the `tb_reset` task's existing correct pattern); one
testbench read DUT-internal registers immediately after `@(posedge clk)` with no settle delay,
intermittently racing the DUT's own always blocks (fixed with a `#1` delay, confirmed via
`$strobe`). All fully detailed with reproduction evidence in `verify/report.txt`.

**Verdict:** NOT ALL GREEN — 1 Low-severity RTL finding (FINDING-001), otherwise fully green across
both independent verification stages. See `verify/report.txt` for the complete evidence index.

## FINDING-001 fix + regression rerun (2026-08-25, deepseek-v4-flash in-session)

- Fixed rtl/led_ctrl.v: led output forced to 12'h0 while rst_n asserted.
  Rejected the FINDINGS.md-suggested verdict_r<=2'd2 (would flip led[10] high
  during reset — violation would just move). Fix matches arch.md BLK-010.
- tb_reset: PASS (was FAIL). Full regression run-002: PASS=9 FAIL=0 ERROR=0,
  200/200 UART lines byte-exact, check_lut 65536/65536. cocotb stage2 PASS.
- REQ-030 fully closed; all REQ-001..031 now green.
