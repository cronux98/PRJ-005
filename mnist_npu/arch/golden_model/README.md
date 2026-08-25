# Golden model — mnist_npu (inference-only MNIST NPU)

Reference: `golden_ref_model.c` (C99, integer-only Q8.8, transaction-level).
This is the BIT-EXACT CONTRACT for fe-rtl: the RTL must reproduce the
predictions, confidence, verdicts, and UART lines exactly.

## Build and run

```
gcc -std=c99 -O2 -Wall -Wextra -o gm golden_ref_model.c
./gm .. > expected_outputs.txt        # from arch/golden_model/, root = repo root
```

Run from the mnist_npu root: `./gm . > arch/golden_model/expected_outputs.txt`.
The model reads `arch/golden_model/weights.hex` + `data/t10k_images.bin` +
`data/t10k_labels.bin` (plain bytes, produced by `tools/train.py`).

## Fixed-point contract (RTL must match)

- Input: pixel byte p (0..255) is the Q8.8 value p (i.e. p/256).
- MAC: acc += x*w in signed 64-bit, NO intermediate truncation; bias added at
  Q16.16 alignment: `acc = bias << 8` (bias word is Q8.8, products are Q16.16).
- z = arithmetic shift `acc >> 8` (floor), then saturate to int16:
  z = clamp(z, -32768, 32767).
- Activation (LUT): sigma = 128 + trunc(128*z / (256+|z|)), C99 division
  truncates toward zero — identical to learn_accel `rtl/div_seq.v`. Range 0..256.
- argmax over the 10 output sigmas; LOWEST index wins ties.
- confidence = (best_sigma * 100) >> 8, range 0..100.
- verdict: TRASH if confidence < 50; else CORRECT if pred == expected label,
  else INCORRECT. (LED10 = verdict != 0; LED[9:0] off on TRASH.)
- UART line format (exact bytes RTL must emit):
  - `IMG %03zu: This is number %d | confidence %d%% | expected %u | CORRECT|INCORRECT`
  - `IMG %03zu: NOT A NUMBER | confidence %d%% | expected %u | TRASH`

## Vector set (RTL testbench inputs/outputs, first 100 test images)

| File | Contents | Consumer |
|------|----------|----------|
| `weights.hex` | 25,450 Q8.8 words: W1(784x32 row-major) \| b1(32) \| W2(32x10) \| b2(10) | weight ROM |
| `images.hex`  | 78,400 words, one pixel byte per word (100 x 784) | image ROM |
| `labels.hex`  | 100 words, expected label byte per image | label ROM |
| `expected.hex`| 400 words: per image pred, conf, expected, verdict (100 x 4) | TB compare |

## Results (2026-08-25, seed 0, 60 epochs, batch 64, eta 0.5)

- Float training eval (test, 10k): 94.73%
- Integer golden eval (test, 10k): **92.25%** — correct 9225, incorrect 270,
  trash 505
- Independent numpy integer emulation: 100/100 first images bit-identical to C;
  full-set 92.25% — contract cross-validated by two implementations.

## Reproduce

```
tools/fetch_mnist.sh && python3 tools/train.py && gcc ... && ./gm .
```
Deterministic: fixed seed 0, fixed schedule; weights.hex regenerates identically.
