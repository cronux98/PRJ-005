# Golden model — cnn (mnist_npu v2 CNN, inference-only)

Reference: `golden_ref_model.c` (C99, integer-only Q8.8, transaction-level).
THE BIT-EXACT CONTRACT for fe-rtl: the RTL must reproduce predictions,
confidence, verdicts, and UART lines exactly.

## Build and run (from the cnn/ root)

```
gcc -std=c99 -O2 -Wall -Wextra -o gm golden_ref_model.c
./gm .
```
Reads `arch/golden_model/weights.hex` + `data/t10k_images.bin` +
`data/t10k_labels.bin`; writes `expected.hex`, `images.hex`, `labels.hex`
(first 100 test images) and prints the UART-format report + summary.

## Network (all Q8.8 16-bit signed)

```
Input 28x28 (784 px; byte p = Q8.8 value p)
Conv1  3x3, 1->8 ch, pad=1, stride=1, ReLU      -> 28x28x8   (80 w)
Pool1  2x2 max, stride=2                        -> 14x14x8
Conv2  3x3, 8->16 ch, pad=1, stride=1, ReLU     -> 14x14x16  (1,168 w)
Pool2  2x2 max, stride=2                        -> 7x7x16 = 784
FC1    784->32, sigmoid (LUT)                   -> 32        (25,120 w)
FC2    32->10, sigmoid (LUT)                    -> 10        (330 w)
```
Total 26,698 words. Layout: conv1_w[8x9] | conv1_b[8] | conv2_w[16x72] |
conv2_b[16] | fc1_w[784x32] | fc1_b[32] | fc2_w[32x10] | fc2_b[10].

## Fixed-point contract (RTL must match)

- acc64 = (bias<<8) + SUM x*w — signed 64-bit accumulation; bias Q8.8 at
  Q16.16 alignment (same rule as v1)
- z = clamp(acc64 >> 8, -32768, 32767) — arithmetic floor shift
- conv/pool hidden: h = max(z, 0) — ReLU (no saturation clamp; the 64-bit
  accumulator absorbs the full range)
- FC activations: sigma = 128 + trunc(128*z/(256+|z|)) — C99 trunc toward
  zero (identical to v1's sigmoid LUT contents; LUT reused unchanged)
- argmax over 10 sigmas, LOWEST index wins ties
- confidence = (best_sigma * 100) >> 8 ; TRASH if < 50
- verdict: 0 CORRECT / 1 INCORRECT / 2 TRASH (vs label ROM)
- Feature-map flatten into FC1: channel-major f[oc*49 + oy*7 + ox]
- UART lines (exact bytes):
  `IMG %03u: This is number %u | confidence %u%% | expected %u | CORRECT|INCORRECT\n`
  `IMG %03u: NOT A NUMBER | confidence %u%% | expected %u | TRASH\n`

## Vector set (RTL testbench inputs/outputs, first 100 test images)

| File | Contents | Consumer |
|------|----------|----------|
| `weights.hex` | 26,698 Q8.8 words (layout above) | weight ROM |
| `images.hex`  | 78,400 words, one pixel byte per word (100 x 784) | image ROM |
| `labels.hex`  | 100 words, expected label byte per image | label ROM |
| `expected.hex`| 400 words: per image pred, conf, expected, verdict | TB compare |

## Results (2026-08-25, seed 0, 40 epochs, batch 64, eta 0.3, QAT baked in)

- PENDING TRAINING — fill from tools/train_cnn.log + golden run summary.
- Baseline: v1 MLP integer 92.25%; CNN target >= 97%.

## Reproduce

```
python3 tools/train_cnn.py && gcc ... && ./gm .
python3 tools/check_cnn.py   # independent numpy emulation, must be 100/100
```
Deterministic: seed 0, fixed schedule.
