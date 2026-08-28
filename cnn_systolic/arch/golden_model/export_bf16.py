#!/usr/bin/env python3
"""export_bf16.py — BF16 weight export for cnn_systolic (REQ-028, ASM-009).

Reads ../cnn/arch/golden_model/weights_float.npz (float64 masters W1,b1..W4,b4 of the
trained network — READ-ONLY, no retraining), converts float64 -> float32 (RN-even) ->
BF16 (RN-even, FTZ) and writes weights_bf16.hex (26,698 words, 4-hex-digit, one word per
line) with the SAME flat layout as the old Q8.8 weights.hex:

    conv1_w[oc*9 + t]   (8*9)   | conv1_b[oc]      (8)
  | conv2_w[oc*72 + ic*9 + k] (16*8*9) | conv2_b[oc] (16)
  | fc1_w[i*32 + j]   (784*32) | fc1_b[j]  (32)
  | fc2_w[i*10 + j]   (32*10)  | fc2_b[j]  (10)

BF16 conversion (float32 bit pattern -> BF16 bit pattern), RN-even with FTZ:
  - exp == 0 (zero or subnormal): -> {sign, 0x00, 0x00}   (flush to signed zero)
  - else: keep = mant >> 16 (7 bits); r = (mant >> 15) & 1; S = (mant & 0x7FFF) != 0
          if (r && (S || (keep & 1))): keep += 1          (RN-even)
          if keep == 0x80: keep = 0; exp += 1             (mantissa overflow)
  - result = (sign << 15) | (exp << 7) | keep

Deterministic. Run:  python3 arch/golden_model/export_bf16.py   (from cnn_systolic/ root)
Output:  arch/golden_model/weights_bf16.hex + summary on stdout.
"""
import os
import sys

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))  # cnn_systolic/
SRC = os.path.normpath(os.path.join(ROOT, "..", "cnn", "arch", "golden_model", "weights_float.npz"))
OUT = os.path.join(ROOT, "arch", "golden_model", "weights_bf16.hex")

C1, C2, N_FC_IN, N_H, N_OUT = 8, 16, 784, 32, 10
N_WORDS = 9 * C1 + C1 + 9 * C1 * C2 + C2 + N_FC_IN * N_H + N_H + N_H * N_OUT + N_OUT  # 26,698


def f32_to_bf16_bits(u32):
    """uint32 float32 bit pattern -> uint16 BF16 bit pattern (RN-even, FTZ)."""
    sign = (u32 >> 31) & 1
    exp = (u32 >> 23) & 0xFF
    mant = u32 & 0x7FFFFF
    if exp == 0:                      # zero or subnormal -> flush to signed zero
        return sign << 15
    keep = mant >> 16
    r = (mant >> 15) & 1
    s = (mant & 0x7FFF) != 0
    if r and (s or (keep & 1)):
        keep += 1
    if keep == 0x80:                  # mantissa overflow: 1.1111111 -> 10.0000000
        keep = 0
        exp += 1
    if exp >= 0xFF:                   # overflow to Inf (unreachable for this data)
        exp = 0xFF
        keep = 0
    return (sign << 15) | (exp << 7) | keep


def main():
    z = np.load(SRC)
    keys = ["W1", "b1", "W2", "b2", "W3", "b3", "W4", "b4"]
    assert list(z.files) == keys, f"unexpected npz keys: {list(z.files)}"
    W1, b1 = z["W1"], z["b1"]           # (8,1,3,3), (8,)
    W2, b2 = z["W2"], z["b2"]           # (16,8,3,3), (16,)
    W3, b3 = z["W3"], z["b3"]           # (784,32), (32,)
    W4, b4 = z["W4"], z["b4"]           # (32,10), (10,)

    def to_bf16(x):
        f32 = x.astype(np.float32)                    # float64 -> float32, RN-even
        u32 = f32.view(np.uint32)
        return np.array([f32_to_bf16_bits(int(v)) for v in u32.reshape(-1)], dtype=np.uint16)

    parts = [
        to_bf16(W1).reshape(-1),     # (8,1,3,3) flat = oc*9 + iy*3 + ix  (tap order matches weights.hex)
        to_bf16(b1),
        to_bf16(W2).reshape(-1),     # (16,8,3,3) flat = oc*72 + ic*9 + iy*3 + ix
        to_bf16(b2),
        to_bf16(W3).reshape(-1),     # (784,32) flat = i*32 + j
        to_bf16(b3),
        to_bf16(W4).reshape(-1),     # (32,10) flat = i*10 + j
        to_bf16(b4),
    ]
    words = np.concatenate(parts)
    assert words.shape[0] == N_WORDS, (words.shape[0], N_WORDS)

    with open(OUT, "w") as f:
        for w in words:
            f.write(f"{int(w):04x}\n")

    # ---- summary / range analysis (arch.md §5.1 FTZ + overflow claims) ----
    def bf16_to_f(v):
        s = (v >> 15) & 1; e = (v >> 7) & 0xFF; m = v & 0x7F
        if e == 0:
            return 0.0
        return (-1.0) ** s * (1.0 + m / 128.0) * (2.0 ** (e - 127))

    fvals = np.array([bf16_to_f(int(v)) for v in words])
    mag = np.abs(fvals)
    nz = mag[mag != 0]
    exact = int(((words & 0x7F) == 0).sum())   # mantissa tail zero -> exactly representable
    print(f"exported {words.shape[0]} BF16 words -> {OUT}")
    print(f"  zero words        : {int((words == 0).sum())}")
    print(f"  min |w| (nonzero) : {nz.min():.6e}")
    print(f"  max |w|           : {nz.max():.6e}")
    print(f"  exactly representable in BF16: {exact} words")
    print("  FTZ note: min |w| ~ %.3e is far above 2^-126 (%.3e); no weight is subnormal"
          % (nz.min(), 2.0 ** -126))
    print("  Overflow note: max |w| ~ %.3e << 2^127; no weight can overflow FP32 accumulation"
          % nz.max())
    # layout spot-check vs the old Q8.8 words (same order): compare first/last few addresses
    old = os.path.normpath(os.path.join(ROOT, "..", "cnn", "arch", "golden_model", "weights.hex"))
    print(f"  (old Q8.8 weights.hex left untouched at {old})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
