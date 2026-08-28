# Systolic Dataflow Specification — ACCUMULATE ORDER (the bit-exactness contract)
Stage: fe-arch | Binding on: golden_ref_model.c, fe-rtl (systolic_array + conv_ctrl), fe-cocotb

This document pins the **exact FP32 add order** the golden C model and the RTL must both
reproduce. Any deviation on either side breaks the bit-exact contract (REQ-022/023/029, ASM-006).

## 1. Array structure (recap)

- 8×8 weight-stationary PE grid. PE(r,c): BF16 weight (active `w_a`, shadow `w_s`), FP32
  accumulator `acc`. Row r = output channel oc (8 per group), column c = the c-th operand of
  the sub-pass.
- Per sub-pass (pinned duration 10 cycles: 8 wavefront feeds + 2 pipeline drain):
  - cycle 0..7: activation for column c enters at cycle c (act propagates 1 column/cycle);
    PE(r,c) computes `prod = fp32_mul(w_a, act_c)` (stage 1, registered) and
    `acc <= fp32_add(acc, prod)` (stage 2, registered — the add for column c commits at cycle
    c+2);
  - cycles 8..9: pipeline drain (no adds).
- The per-PE add order is therefore **column order 0..7 within each sub-pass**, sub-passes in
  the pinned order below. All 8 rows of a column add at the same cycle — the golden computes
  rows sequentially but with the identical per-row order (bit-identical, since rows share no
  state).
- `acc` persists across sub-passes of the same pixel (in-PE accumulation); at a group boundary
  (conv2) or at pixel end, the 8 accs drain (parallel, 1 cycle), pass through ReLU (sign test)
  and the BF16 conversion, and are written to FM RAM (1 word/cycle, overlapped with the next
  pixel's compute).
- Weights: shadow-loaded during the previous sub-pass (8 reads per bank per load); `swap` at
  sub-pass boundaries. Zero-weight columns contribute ±0 products — `fp32_add(acc, ±0) = acc`
  (IEEE), so unused columns are exact no-ops; the golden still evaluates them (same bits).

## 2. Activation sources and zero-padding

- **conv1:** activation for tap t (t = iy*3+ix, iy,ix ∈ 0..2) of pixel (oy,ox):
  `act_t = img[(oy+iy-1)*28 + (ox+ix-1)]` if both coordinates in 0..27 else 0. Implemented as 9
  pre-shifted image banks: `act_t = img_bank_t[oy*28 + ox]`, where bank t was written
  write-side-shifted so out-of-range taps read back 0 (zero-padding by construction).
  Pass A feeds column c from bank c (tap c). Pass B feeds column 0 from **bank 8** (tap 8) and
  columns 1..7 from banks 1..7 (zero-weighted — exact no-ops).
  Pixel value: `img[p] / 256` as an exact BF16 (p ∈ 0..255, §5.4 of arch.md).
- **conv2:** activation for sub-pass k = iy*3+ix, column c = input channel ic:
  `act(k,c) = p1[ic][(oy+iy-1)*14 + (ox+ix-1)]` if in 0..13 else 0. Implemented as 8
  per-channel banks with a combinational in-range zero mux on the shared read address
  `(oy+iy-1)*14 + (ox+ix-1)`.
- **FC1:** `p2[i]` = FM[6272 + i], i = 0..783 (channel-major flatten: p2[oc*49 + oy*7 + ox]).
- **FC2:** `h3[i]` = FM[i], i = 0..31 (BF16 FC1 outputs).

## 3. Conv1 accumulate order (per output pixel (oy,ox) ∈ 28×28, per oc ∈ 0..7)

```
acc = fadd_bias: acc := expand_bf16(bias1[oc])              // bias FIRST, exactly once
// sub-pass A — columns c = taps t = 0..7 (t = iy*3+ix):
for c in 0..7:
    acc := fp32_add(acc, fp32_mul(w1[oc][c], act_c))        // w1[oc][t] = conv1_w[oc*9 + t]
// sub-pass B — tap 8 in column 0 (fed from bank 8), columns 1..7 weight 0:
for c in 0..7:
    wB   = (c == 0) ? w1[oc][8] : 0
    actB = (c == 0) ? act(tap 8) : act(tap c)   // col 0 fed from bank 8; cols 1..7 from
                                                // banks 1..7 (zero-weighted -> exact no-ops)
    acc := fp32_add(acc, fp32_mul(wB, actB))
h1[oc*784 + oy*28 + ox] := bf16_from_fp32(relu(acc))
```

## 4. Conv2 accumulate order (per output pixel (oy,ox) ∈ 14×14, per oc ∈ 0..15)

```
g = oc / 8   (oc-group; group 0 = oc 0..7 runs first in the array, group 1 = oc 8..15 second)
acc := expand_bf16(bias2[oc])
for k in 0..8:                       // k = iy*3+ix (k outer — pinned)
    for c in 0..7:                   // c = ic (c inner — wavefront column order)
        acc := fp32_add(acc, fp32_mul(w2[oc][c*9 + k], act(k,c)))
        // w2[oc][ic*9 + k] = conv2_w[oc*72 + ic*9 + k]
h2[oc*196 + oy*14 + ox] := bf16_from_fp32(relu(acc))
```

In hardware the array processes group 0's 9 sub-passes for the pixel, drains (h2 writes for
oc 0..7), re-initialises acc to bias2[8..15], processes group 1's 9 sub-passes, drains
(oc 8..15). The golden's per-oc order (bias, then (k,c) lexicographic) is identical for every
oc regardless of group.

## 5. FC accumulate order (serial datapath)

```
FC1, per j ∈ 0..31:
    acc := expand_bf16(bias3[j])
    for i in 0..783:
        acc := fp32_add(acc, fp32_mul(w3[i*32 + j], p2[i]))
    sigma := piecewise_sigmoid(acc)               // arch/piecewise_sigmoid.md
    h3[j] := bf16_from_fp32(sigma)                // FM[j]

FC2, per j ∈ 0..9:
    acc := expand_bf16(bias4[j])
    for i in 0..31:
        acc := fp32_add(acc, fp32_mul(w4[i*10 + j], h3[i]))
    sigma := piecewise_sigmoid(acc)               // FP32, NO intermediate rounding
    sigma256[j] := trunc(fp32_add(fp32_mul(sigma, 256.0), 0.5))   // exact FP32 steps
argmax: best = 0; for j in 1..9: if sigma256[j] > sigma256[best] then best := j   // strict >, lowest-index ties
conf   := (sigma256[best] * 100) >> 8             // integer truncation, 0..100
verdict:= (conf < 50) ? 2 : ((best == exp_label) ? 0 : 1)
```

## 6. Weight ROM layout (identical to the old weights.hex, now BF16)

26,698 words, flat order: `conv1_w[0..71]` (index oc*9 + t) | `conv1_b[0..7]` |
`conv2_w[0..1151]` (index oc*72 + ic*9 + k) | `conv2_b[0..15]` | `fc1_w[0..25087]`
(index i*32 + j) | `fc1_b[0..31]` | `fc2_w[0..319]` (index i*10 + j) | `fc2_b[0..9]`.
Bank interleave (hardware only): word n → bank n%8, offset n/8. The golden reads the flat file
directly (no banking) — the banking is a physical arrangement that does not change values.

## 7. What the golden MUST NOT do

- No reordering of adds (no tree reduction, no reassociation, no vectorised pairwise sums).
- No extended-precision intermediates (no double, no wider-than-FP32 accumulators; the C
  integer emulation must round exactly at each fp32 op).
- No skipping of the zero-weight columns (they are exact no-ops; include them for structural
  mirroring — the result is identical either way, but the mirror must be provable).
- No fused multiply-add (product must round to FP32 exactly — for BF16 operands it is exact —
  then the add rounds; FMA fusion would change nothing here since the product is exact, but the
  RTL is explicitly 2-stage to keep the order visible).
