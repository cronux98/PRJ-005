# Piecewise Sigmoid Specification — exact breakpoints, coefficients, rounding
Stage: fe-arch | Binding on: fc_datapath (BLK-013), golden model | ASM-005

## 1. Definition

**The activation function of this network family is the trained rational sigmoid**
`act_float(z) = 0.5 + 0.5·z/(1+|z|)` — the function the MNIST CNN was trained with
(`train_cnn.py act_float`) and that the old Q8.8 golden's LUT implemented bit-exactly
(`sigma = 128 + trunc(128·z_q8/(256+|z_q8|))` with `z_q8 = 256·z` — see
`../cnn/arch/golden_model/golden_ref_model.c`). **It is NOT the logistic 1/(1+e^-z).** The
piecewise approximation below targets act_float; the pinned piecewise function IS the contract
(the regenerated expected outputs are defined by it).

σ(z), z an FP32 value in the FC path (|z| provably ≤ ~2^28 for this network, arch.md §5.1):

```
x = |z|                 // sign bit cleared — exact, no rounding
if x >= 24:     s = 251/256        // saturation
else:
    select segment (x, m, c) from the table below     // FP32 compares, exact
    s = fp32_add(fp32_mul(m, x), c)                   // MUL FIRST, then ADD — pinned order,
                                                      // each RN-even with FTZ (arch.md §5.1)
sigma = (z < 0) ? fp32_sub(1.0, s) : s                // sign fold: one RN-even subtraction
```

- z = ±0 → x = 0 → segment 0 → s = fp32_add(fp32_mul(13/32, 0), 1/2) = 0.5 → sigma = 0.5.
- z < 0 with x ≥ 24 → s = 251/256 → sigma = 1 − 251/256 = 5/256 (exact FP32 subtraction).
- The piecewise function IS the definition — it is not an approximation of anything the RTL
  must match beyond it; there is no other sigmoid to be exact against.

## 2. Breakpoints, coefficients (exact dyadic rationals → exact FP32 bit patterns)

Breakpoints on |z|: {1/4, 1/2, 3/4, 1, 3/2, 2, 3, 4, 6, 8, 12, 16, 24}. σ values at the
breakpoints (dyadic, chosen within ~0.002 of act_float): 77/128, 85/128, 183/256, 3/4, 205/256,
107/128, 7/8, 115/128, 119/128, 121/128, 123/128, 249/256, 251/256 (σ(0) = 1/2; saturation
beyond 24 = 251/256).

| Segment (x range) | m (slope) | c (intercept) | m bits (0x) | c bits (0x) |
|---|---|---|---|---|
| [0, 1/4) | 13/32 | 1/2 | 3ED00000 | 3F000000 |
| [1/4, 1/2) | 1/4 | 69/128 | 3E800000 | 3F0A0000 |
| [1/2, 3/4) | 13/64 | 9/16 | 3E500000 | 3F100000 |
| [3/4, 1) | 9/64 | 39/64 | 3E100000 | 3F1C0000 |
| [1, 3/2) | 13/128 | 83/128 | 3DD00000 | 3F260000 |
| [3/2, 2) | 9/128 | 89/128 | 3D900000 | 3F320000 |
| [2, 3) | 5/128 | 97/128 | 3D200000 | 3F420000 |
| [3, 4) | 3/128 | 103/128 | 3CC00000 | 3F4E0000 |
| [4, 6) | 1/64 | 107/128 | 3C800000 | 3F560000 |
| [6, 8) | 1/128 | 113/128 | 3C000000 | 3F620000 |
| [8, 12) | 1/256 | 117/128 | 3B800000 | 3F6A0000 |
| [12, 16) | 3/1024 | 237/256 | 3B400000 | 3F6D0000 |
| [16, 24) | 1/1024 | 245/256 | 3A800000 | 3F750000 |
| [24, ∞) | 0 | 251/256 (saturate) | — | 3F7B0000 |

Breakpoint bit patterns (FP32 compares): 1/4 = 0x3E800000, 1/2 = 0x3F000000, 3/4 = 0x3F400000,
1 = 0x3F800000, 3/2 = 0x3FC00000, 2 = 0x40000000, 3 = 0x40400000, 4 = 0x40800000,
6 = 0x40C00000, 8 = 0x41000000, 12 = 0x41400000, 16 = 0x41800000, 24 = 0x41C00000.
Other pinned constants: 1.0 = 0x3F800000, 256.0 = 0x43800000, 0.5 = 0x3F000000.

Continuity check (every boundary is exact in both adjacent segments):
σ(1/4)=77/128, σ(1/2)=85/128, σ(3/4)=183/256, σ(1)=3/4, σ(3/2)=205/256, σ(2)=107/128,
σ(3)=7/8, σ(4)=115/128, σ(6)=119/128, σ(8)=121/128, σ(12)=123/128, σ(16)=249/256,
σ(24)=251/256 — each reproduced by both neighbours.

## 3. Rounding rules (pinned)

1. Segment selection: exact FP32 comparisons (both operands non-negative → unsigned bit
   compare). Segment i applies when breakpoint[i-1] ≤ x < breakpoint[i].
2. `fp32_mul(m, x)`: RN-even, FTZ. **RTL implementation note:** since m = k·2^-s with small
   integer k (numerators ∈ {1,3,5,9,13}), the RTL may implement the product as `mant_x × k`
   (≤ 30 bits) with exponent `exp_x − s`, normalised and rounded RN-even to 24 bits —
   **bit-identical** to fp32_mul(m, x) because the exact products are the same value; this is
   a size optimisation, not a semantic change.
3. `fp32_add(..., c)`: RN-even, FTZ.
4. Sign fold: `fp32_sub(1.0, s)` — one RN-even subtraction.
5. The golden model embeds the m/c/breakpoint values as the **exact uint32 bit patterns above**
   (never as C float literals) so no constant-rounding ambiguity exists.

## 4. Accuracy (vs the trained act_float(z) = 0.5 + 0.5·z/(1+|z|))

Breakpoint errors ≤ 0.0021 (worst at σ(3/4): 183/256 vs 5/7); interior chord errors ≤ ~0.003
(worst near z = 3/4). This is ≤ 0.3 confidence points — below the 1% confidence granularity;
predictions change only on images where two classes sit within ~0.3% (the regenerated expected
outputs are the contract regardless — BRIEF decision 9). Saturation at σ = 251/256 caps
confidence at 98% (the old Q8.8 LUT's max was 255/256 ≈ 99%).

## 5. sigma256 quantization (REQ-027, ASM-004)

```
sigma256 = trunc( fp32_add( fp32_mul(sigma, 256.0), 0.5 ) )
```
- `sigma × 256.0`: exact (power-of-two scaling, exponent +8; sigma ∈ [0,1] normal or zero).
- `+ 0.5`: exact in FP32 for all sigma·256 ∈ [0, 256] (values are ≤ 2^8 with 24-bit
  significands; the sum ≤ 256.5 is exactly representable).
- `trunc`: floor for the non-negative value → integer 0..256. (Round-half-up behaviour:
  σ·256 = 128.5 → 129.)
- argmax over the 10 sigma256 values, strict `>`, lowest index wins ties; conf =
  (sigma256_best × 100) >> 8 (integer truncation → 0..100); verdict = conf < 50 ? 2 :
  (best == exp_label ? 0 : 1). Note: TRASH iff sigma256_best ≤ 127 (since 127×100>>8 = 49,
  128×100>>8 = 50).
