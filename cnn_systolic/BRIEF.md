# cnn_systolic — Overnight Dispatch Brief (2026-08-28 18:24Z)

**Project:** `PRJ-005/cnn_systolic` — Sky130 ASIC CNN accelerator: **8x8 BF16
systolic array (conv) + serial FP FC datapath + piecewise sigmoid**, wrapped in
the cnn_soc picorv32 AXI->APB SoC shell.

**Mode:** front-end ASIC pipeline ONLY. **NO fe-sby (formal), NO fe-gls, NO
RTL<->netlist equivalence** (Rinri explicitly dropped all three).

---

## Rinri decisions (locked 2026-08-28 18:24Z — not negotiable)

1. **FP format:** BF16 operands (weights/activations), FP32 accumulate.
2. **Golden:** bit-exact, mirrored dataflow — the FP golden C model must
   accumulate in the exact order of the 8x8 systolic array (conv) and the
   serial FC datapath. Tolerance compare is NOT acceptable.
3. **Array:** 8x8 (64 PEs), conv layers only. FC1/FC2 serial (single-MAC
   style, BF16 mult + FP32 acc), not on the array.
4. **Sigmoid:** piecewise — exact breakpoints/coefficients pinned in arch,
   mirrored bit-exact in golden.
5. **Front-end only:** fe-spec -> fe-arch -> fe-rtl -> fe-yosys (synth) ->
   fe-opensta (STA/SDC) -> fe-firmware -> functional verify + coverage. No PnR.
6. **PASS gates:** (a) functional verification + **measured functional
   coverage**, (b) fe-opensta timing/area + SDC QA, (c) fe-firmware build +
   SoC verification (UART diff vs **regenerated FP expected outputs**).
7. **Retry policy:** 3 retries per gate. If still failing after 3 retries:
   write an HONEST review (what failed, why, residual risk) and pass with the
   review as evidence. Never fake a pass, never silently skip a gate.
8. **Weights: no retraining.** Export BF16 from
   `../cnn/arch/golden_model/weights_float.npz` (float masters of the trained
   network; W1,b1..W4,b4). Conversion float32->BF16 round-to-nearest-even,
   defined in the export script; the golden uses the identical conversion.
9. **Expected outputs:** the 100-image UART diff compares against outputs
   REGENERATED from the new FP golden. The old Q8.8 `expected_outputs.txt`
   does NOT apply (FP confidences differ on borderline images).

---

## Architectural mandates

- **Reuse SoC shell verbatim from `../cnn_soc`** (READ-ONLY reference):
  `picorv32_axi`, `axi_lite_interconnect`, `axi2apb`, `sram`, `bootrom`,
  `apb_uart`, `apb_gpio`. Copy into ip/ with provenance recorded.
- **Replace** `cnn_axi_slave` + `cnn_infer` + `mac_datapath` + `sigmoid_lut`
  with: 8x8 systolic PE array (weight-stationary recommended), conv control
  FSM + tiling (conv1 = 72 MACs/output-pixel -> 2 array passes; conv2 =
  1152/output-pixel -> 18 passes; FC1 784x32, FC2 32x10 serial), FP serial FC
  datapath, piecewise sigmoid.
- **KEEP the register map + UART line format + 7-bit conf encoding identical
  to cnn_soc** so harnesses (`tb_cnn_soc`, `run_soc.sh`, UART diff) are reused
  unchanged: `CNN_CTRL 0x5000_0000` START[0]/PARK[1], `CNN_STATUS 0x5000_0004`
  BUSY[0]/DONE[1], `CNN_RESULT 0x5000_0008` pred[3:0] conf[14:8] verdict[17:16],
  `CNN_EXP 0x5000_000C`, `CNN_IMG 0x5000_0100` (784B, word-write packs 4 px LE),
  `VEC_IMG0 0x1000_0000`, `VEC_LABEL0 0x1001_3240`, UART `0x4000_0000`,
  GPIO `0x4000_1000`. UART line: "This is number N | confidence % | expected |
  CORRECT/INCORRECT". The poll bound (667,208 cycles in cnn_soc main.c) MUST
  be re-derived for this design and updated in firmware + comments.
- **Memories:** BF16 weight ROM (26,698 words x 16b ~= 427 Kbit — same size as
  the Q8.8 ROM), image buffer (784B), FM RAM. Banking/feed design for the
  array is the architect's call; document it.
- **Sky130 / STA:** fe-opensta with `sdc/sdc_spec.json` (reuse the
  `cnn_soc/sdc/sdc_spec.json` structure as the starting skeleton; nominal
  100 MHz core clock, Sky130B tt corner default per fe-opensta skill).
- **Confidence encoding:** define exact FP -> 7-bit conf mapping in arch
  (e.g., sigmoid out scaled x127, rounding mode pinned) so golden + RTL +
  firmware agree bit-exactly.

---

## Work split

### Architect (P0 + P1) — fe-spec + fe-arch skills
- `spec/`: spec.md, requirements.yaml, interfaces.yaml, verification_plan.md,
  spec_manifest.yaml. Structured halt SPEC-E on unconfirmed assumptions.
- `arch/`: arch.md, cdc_plan.md, power_plan.md, rtl_coding_guidelines.md,
  **golden_ref_model.c (FP, bit-exact mirrored dataflow)**, BF16 export script
  + `weights_bf16.hex`, `stimulus.hex` + `expected.hex` + regenerated
  expected outputs (FP), systolic dataflow spec (ACCUMULATE ORDER — the
  bit-exactness contract), tiling plan, piecewise sigmoid spec (exact
  breakpoints/coefficients/rounding), arch_manifest.yaml. Halt ARCH-E on
  unconfirmed assumptions.
- Read `../cnn/arch/golden_model/` (weights_float.npz, golden_ref_model.c,
  README) and `../cnn_soc/` (spec/, arch/, rtl/, sw/main.c, sdc/) as
  references. Never modify them.

### Frontend (P2..P6) — fe-rtl, fe-yosys, fe-opensta, fe-firmware, fe-cocotb/fe-regression
- `rtl/` + `ip/` + `filelist.f`, `sdc/sdc_spec.json`, `sw/` (firmware based on
  cnn_soc main.c/post_fw.c structure, updated poll bound), `verify/`
  (run-NNN/ + iterations.log + coverage report + UART diff vs FP expected),
  `out/` (yosys netlist, STA reports, pipeline_state.txt).
- Gates with 3 retries + honest-review fallback (decision 7).

---

## AUTONOMY OVERRIDE (Rinri, 2026-08-28 18:31Z) — in effect for this overnight run

Rinri: "Continue till the end without halting/stopping, I'll be sleeping."

- **Structured halts SPEC-E / ARCH-E are REPLACED for this run.** On
  unconfirmed assumptions: make the best documented judgment (log the
  assumption, the choice, and the impact in WORKLOG.md), proceed, and flag it
  in the final report. Do NOT wait for Rinri.
- **Gate retries:** unchanged — 3 retries per gate, then honest-review pass
  with evidence.
- **Billing/model failure:** do not spin. Log it, and switch the affected run
  to a funded fallback (sonnet) if needed to keep moving; record the switch
  in WORKLOG.md. (Spend authorization implied by the autonomy grant; main
  logs it in the morning report.)
- **No silent spinning:** log progress to WORKLOG.md as you go. Main watches
  via cron.

---

## Constraints
- `../cnn` and `../cnn_soc` are READ-ONLY. All new artifacts live in
  `cnn_systolic/`.
- No destructive ops. No git commits (main commits at close-out).
- Append-only history: new run dirs, never overwrite.
- If a model/billing failure interrupts work: STOP, log it, report — do not
  silently retry forever.
- Verify PASS gates before advancing (result files say PASS).
