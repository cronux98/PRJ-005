# cnn_systolic FP golden model — README (fe-arch P1)

Bit-exact mirrored-dataflow reference for the BF16 systolic CNN accelerator. Integer-only C99;
every FP32 op is emulated bit-for-bit (RN-even, flush-to-zero) — no floating point in the
datapath, byte-identical on every run/machine.

## Files

| File | Role |
|---|---|
| `golden_ref_model.c` | The golden. Reads `weights_bf16.hex` + `../cnn/data/t10k_images.bin` + `t10k_labels.bin`; writes `expected_outputs.txt` (100 UART lines — G1 diff target), `expected.hex` (400 words — G2 target), `stimulus.hex` (78,400 pixel words), `labels.hex` (100 words); prints the full 10,000-image UART stream + summary (accuracy, FTZ flush counters). `--vectors` mode runs the directed vector self-test. |
| `golden_model_test_vectors.h` | 70 directed vectors (kinds: BF16 conversion, fp32 add/mul incl. sign-coverage, piecewise sigmoid segments, sigma256, conf/verdict, argmax). Expected values in `expected_vectors.txt` — hand-derived from the pinned FP semantics, NOT generated. |
| `expected_vectors.txt` | Hand-derived expected output of the vector self-test (G7). |
| `export_bf16.py` | float64→float32 (RN-even)→BF16 (RN-even, FTZ) export of `../cnn/arch/golden_model/weights_float.npz` → `weights_bf16.hex` (26,698 words, layout per systolic_dataflow.md §6). |
| `weights_bf16.hex` | The exported BF16 weights — consumed by the golden AND the RTL weight banks (the identical converted values; ASM-009). |
| `check_fp.py` | Independent numpy twin (G8): re-derives the BF16 export from the npz (26,698/26,698 match), re-computes the 100-image results (100/100 match expected.hex) and the full-set accuracy. |
| `stimulus.hex` / `labels.hex` | The 100-image input set (same images as `../cnn`'s images.hex — relocated into this project; used by vec_rom + the SoC TB). |
| `expected.hex` | 400 words: per image pred, conf, expected label, verdict (4 words/image — same format as the old golden). |
| `expected_outputs.txt` | The 100 UART lines (regenerated FP contract — the old Q8.8 file does NOT apply; BRIEF decision 9). |

## Build / run (user action — fe-arch does not execute these)

```
cd cnn_systolic
gcc -std=c99 -O2 -Wall -Wextra -o arch/golden_model/gm arch/golden_model/golden_ref_model.c
./arch/golden_model/gm .                    # full 10,000-image run (writes the artifacts)
./arch/golden_model/gm . 100                # 100-image run (same artifacts)
./arch/golden_model/gm --vectors > got.txt && diff -u arch/golden_model/expected_vectors.txt got.txt
python3 arch/golden_model/export_bf16.py     # re-export weights (deterministic)
python3 arch/golden_model/check_fp.py        # G8 twin cross-check
```

## P1 results (measured 2026-08-28, logged in WORKLOG.md)

- Export cross-check: **26,698/26,698** words match an independent conversion.
- Directed vectors: **70/70** match the hand-derived expectations (G7). The sign-coverage
  vectors (added after a debugging session) caught a real `f32_add` result-sign bug — fixed.
- 100-image cross-check vs the numpy twin: **100/100** (G8).
- Full-set accuracy: **96.08 %** (9608/142/250) vs the Q8.8 baseline's 96.35 %.
- FTZ flush counters: **all zero** — the subnormal flush-to-zero policy never fires for this
  network (as predicted by the arch.md §5.1 range analysis); OI-002 resolved.
- G6 reproducibility: re-runs are byte-identical.

## Determinism contract

Fixed-width integer arithmetic only; no float, no malloc in the datapath, no time/address-
dependent output. The accumulate orders (systolic_dataflow.md §3-5), the piecewise sigmoid
(piecewise_sigmoid.md) and the confidence path (sigma256 = trunc(σ·256+0.5), conf =
(best·100)>>8, TRASH < 50) are the bit-exactness contract for fe-rtl.
