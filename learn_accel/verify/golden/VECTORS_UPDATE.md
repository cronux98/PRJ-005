# VECTORS UPDATE — 2026-08-20 (architect fix for G-1 + RTL-BUG-1)

Frontend verification (run-000) found the shipped golden expected data wrong
(G-1) and a REQ-018 label-range gap (RTL-BUG-1). Both fixed by the architect;
this note records the impact on verify/golden.

## G-1 — shipped expected data regenerated (now C-model-exact)

`arch/golden_model/{expected_outputs.txt,expected.hex}` regenerated from the
executable reference `arch/golden_model/golden_ref_model.c`:

- The 5 SAMPLE rows and 30 WEIGHT rows are **value-identical** to
  `verify/golden/tiny_shipped_corrected/` (same generator output). Words 15..54
  of the old shipped expected.hex were wrong (S3 all-zero pred, S4 pred/count,
  18/30 final weights).
- `arch/golden_model/stimulus.hex` words 0..54 unchanged (inputs confirmed
  correct); only formatting (4-digit weight words) differs from the 2-digit
  words in the frontend copy — `$readmemh`-equivalent.

## RTL-BUG-1 — invalid labels now rejected (REQ-018)

- `rtl/sample_stream.v` gained a `CLASSES` parameter: a label byte >= CLASSES
  on the final beat raises `err_p` (sticky `STATUS.err`), never asserts
  `sample_valid` (sample not counted, learner never processes it), resync per
  FSM-002. Wired in `rtl/learn_accel.v`.
- `arch/golden_model/golden_ref_model.c` mirrors the rejection (REJECTED line,
  no count, no update) and the tiny vector set gained a 6th sample
  (pixels 0,1,2,3, label 0x05 >= CLASSES=2) as the proof.
- `arch/golden_model/stimulus.hex` is now 60 words (30 init + 6 samples);
  `expected.hex` stays 55 words (5 processed samples + 30 weights — the
  rejected sample contributes no row); `expected_outputs.txt` gains the
  `SAMPLE 005 ... REJECTED` line.
- `tb/tb_learn_accel.v` streams the 6th sample and checks STATUS.err=1 and
  unchanged counters/PRED/weights.

## Impact on verify/golden

- `tiny_shipped_corrected/` remains correct for the 5-sample set and is
  unchanged; the arch/golden_model files now supersede it (same values, plus
  the rejection proof).
- Other configs (`cfg_*`, `tiny_lr8`, `tiny_lr15`, `8x4x3_s16`, freeze sets)
  are unaffected (valid-label sets; the C model's rejection path only fires
  for label >= CLASSES, which those sets never contain).
- `verify/scripts/gen_vectors.py` parses the C stdout with a SAMPLE-row regex:
  REJECTED lines are skipped and the `5*len(per_sample)+W` assertion still
  holds (weights unchanged by rejection) — no generator change needed.
