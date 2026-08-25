# qat — Quantization-Aware Training experiment (PRJ-005, mnist_npu v1.1)

**Status: COMPLETE — honest negative result.** QAT on the v1 MLP contract does
**not** recover the float→integer accuracy gap. Verified end-to-end anyway.

## Goal
Recover the v1 fixed-point loss (float 94.73% → integer 92.25%, ~2.5 points)
by training with the chip's quantization in the loop — zero RTL changes.

## Results (all integer-test accuracy, exact golden contract)

| Attempt | Method | Integer accuracy |
|---|---|---|
| v1 baseline | float SGD, quantize after (no QAT) | **92.25%** |
| QAT v1 | QAT from scratch (exact-int forward + STE), 60 ep | 92.32% |
| QAT v2 | float pretrain (v1-exact) + QAT fine-tune (STE, eta 0.1, 20 ep) | 92.18% |

**Verdict: QAT gains ~nothing on this contract.** Two fundamentally different
training objectives (plain float vs exact-integer STE) both land at
92.2–92.3% — strong evidence the MLP + Q8.8 truncation contract is at its
accuracy ceiling. The 2.5-point gap is dominated by per-layer activation
truncation (z = acc>>8 floor, sigmoid trunc, Q8.8 hidden RAM) that the STE
gradient is too noisy to adapt around, for a network this small.

## What WAS delivered (the machinery, validated)
- `tools/train_qat.py`: two-phase trainer (Phase A reproduces v1 float
  pretrain bit-for-bit incl. 92.25% integer baseline; Phase B = exact-integer
  forward + straight-through gradients). Deterministic (seed 0).
- `arch/golden_model/weights.hex`: QAT-tuned weights (25,450 Q8.8 words) —
  accuracy-equivalent to v1, bit-exact against the golden contract.
- **Full regression re-run against the QAT weights: PASS 9/9** (run-000),
  UART 200/200 byte-exact vs regenerated golden, cocotb stage2 PASS —
  proving the RTL matches the golden bit-for-bit with *any* valid weights.
- Cross-check: independent numpy integer emulation vs C golden 100/100
  bit-identical, full-set 92.18% identical.

## Lesson for the CNN (v2)
The real accuracy win is architectural: the CNN (more capacity, learned
features) absorbs quantization far better, and its trainer (`../cnn/tools/
train_cnn.py`) has QAT baked in from scratch. Do not expect QAT alone to
rescue a tiny MLP under a strict truncation contract.

## Files
- `tools/train_qat.log` — full training log (both attempts archived: v1 run
  overwritten by v2; see WORKLOG.md for v1 numbers)
- `arch/golden_model/` — weights.hex, weights_float.npz, expected.hex,
  expected_outputs.txt (regenerated from QAT weights)
- `verify/run-000/` — full regression evidence
