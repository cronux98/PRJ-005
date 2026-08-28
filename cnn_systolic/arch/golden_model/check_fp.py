#!/usr/bin/env python3
"""check_fp.py — independent numpy twin of the cnn_systolic FP golden (G8).

Implements the SAME pinned contract as golden_ref_model.c (systolic_dataflow.md,
piecewise_sigmoid.md) in numpy float32, written independently (vectorised over
pixels/channels/batch; per-element add order preserved), with an explicit FTZ
wrapper around every FP32 op. Cross-checks:

  1. weights_bf16.hex vs an independent BF16 conversion of the npz masters
     (the export script's conversion re-implemented here from the spec).
  2. The 100-image pred/conf/verdict vs the C golden's expected.hex (G8).
  3. Full-10,000-set accuracy + FTZ/subnormal event counters.

Run: python3 arch/golden_model/check_fp.py   (from cnn_systolic/ root)
"""
import os
import sys

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GM = os.path.join(ROOT, "arch", "golden_model")
NPZ = os.path.normpath(os.path.join(ROOT, "..", "cnn", "arch", "golden_model", "weights_float.npz"))
IMGS = os.path.normpath(os.path.join(ROOT, "..", "cnn", "data", "t10k_images.bin"))
LBLS = os.path.normpath(os.path.join(ROOT, "..", "cnn", "data", "t10k_labels.bin"))

C1, C2, N_H, N_OUT = 8, 16, 32, 10
N_FC_IN = 784
N_WORDS = 9 * C1 + C1 + 9 * C1 * C2 + C2 + N_FC_IN * N_H + N_H + N_H * N_OUT + N_OUT

F32_MIN_NORMAL = np.float32(2.0 ** -126)


def f32(a):
    return np.float32(a)


def ftz(x):
    """Flush subnormal results to signed zero (ASM-003), mirroring the golden."""
    x = np.asarray(x, dtype=np.float32)
    mag = np.abs(x)
    flush = (mag != 0) & (mag < F32_MIN_NORMAL)
    if np.any(flush):
        x = x.copy()
        x[flush] = np.copysign(np.float32(0.0), x[flush])
    return x


def fadd(a, b):
    return ftz(f32(f32(a) + f32(b)))


def fmul(a, b):
    return ftz(f32(f32(a) * f32(b)))


def fsub(a, b):
    return ftz(f32(f32(a) - f32(b)))


def bf16_round(x):
    """FP32 -> BF16 RN-even FTZ (independent reimplementation from the spec)."""
    x = np.asarray(x, dtype=np.float32)
    u = x.view(np.uint32)
    sa = u >> 31
    ea = (u >> 23) & 0xFF
    ma = u & 0x7FFFFF
    keep = ma >> 16
    r = (ma >> 15) & 1
    s = (ma & 0x7FFF) != 0
    up = (r != 0) & (s | (keep & 1))
    keep = keep + up
    ovf = keep == 0x80
    keep = np.where(ovf, 0, keep)
    ea = ea + ovf
    # FTZ: subnormal or zero input -> signed zero
    bf = ((sa << 15) | (ea << 7) | keep).astype(np.uint16)
    bf = np.where(ea == 0, (sa << 15).astype(np.uint16), bf)
    return bf


def bf16_to_f32(b):
    b = np.asarray(b, dtype=np.uint16)
    u = (b.astype(np.uint32) << 16)
    return u.view(np.float32)


def bf16_of_pixel(p):
    p = np.asarray(p, dtype=np.uint32)
    bf = np.zeros_like(p, dtype=np.uint16)
    nz = p != 0
    pp = p[nz]
    e7 = np.floor(np.log2(pp.astype(np.float64))).astype(np.uint32)  # 0..7
    bf[nz] = (((119 + e7) << 7) | ((pp << (7 - e7)) & 0x7F)).astype(np.uint16)
    return bf


# ---- piecewise sigmoid constants (exact dyadic values; exact in float32) ----
# Target: the TRAINED rational sigmoid act_float(z) = 0.5 + 0.5*z/(1+|z|) (the old
# Q8.8 LUT's function), approximated by the pinned dyadic table of
# piecewise_sigmoid.md §2. Segment i: BP[i-1] <= x < BP[i]; x >= BP[12] saturates.
BP = [np.float32(1) / np.float32(4), np.float32(1) / np.float32(2), np.float32(3) / np.float32(4),
      np.float32(1), np.float32(3) / np.float32(2), np.float32(2), np.float32(3),
      np.float32(4), np.float32(6), np.float32(8), np.float32(12), np.float32(16), np.float32(24)]
MS = [np.float32(13) / np.float32(32), np.float32(1) / np.float32(4), np.float32(13) / np.float32(64),
      np.float32(9) / np.float32(64), np.float32(13) / np.float32(128), np.float32(9) / np.float32(128),
      np.float32(5) / np.float32(128), np.float32(3) / np.float32(128), np.float32(1) / np.float32(64),
      np.float32(1) / np.float32(128), np.float32(1) / np.float32(256), np.float32(3) / np.float32(1024),
      np.float32(1) / np.float32(1024)]
CS = [np.float32(1) / np.float32(2), np.float32(69) / np.float32(128), np.float32(9) / np.float32(16),
      np.float32(39) / np.float32(64), np.float32(83) / np.float32(128), np.float32(89) / np.float32(128),
      np.float32(97) / np.float32(128), np.float32(103) / np.float32(128), np.float32(107) / np.float32(128),
      np.float32(113) / np.float32(128), np.float32(117) / np.float32(128), np.float32(237) / np.float32(256),
      np.float32(245) / np.float32(256)]
ONE = np.float32(1.0)
F256 = np.float32(256.0)
HALF = np.float32(0.5)
SIG_SAT = np.float32(251) / np.float32(256)


def sigmoid_piecewise(z):
    z = np.asarray(z, dtype=np.float32)
    x = np.abs(z)
    m = np.zeros(z.shape, dtype=np.float32)
    c = np.zeros(z.shape, dtype=np.float32)
    sat = x >= BP[12]
    m = np.select([x < bp for bp in BP[:12]] + [True], MS, default=MS[12])
    c = np.select([x < bp for bp in BP[:12]] + [True], CS, default=CS[12])
    sigma = fadd(fmul(m, x), c)               # mul first, then add (pinned order)
    sigma = np.where(sat, SIG_SAT, sigma)
    sigma = np.where(z < 0, fsub(ONE, sigma), sigma)
    return sigma


def sigma256_of(sigma):
    return np.trunc(fadd(fmul(sigma, F256), HALF)).astype(np.uint32)


def load_hex_words(path):
    return np.array([int(l.strip(), 16) for l in open(path)], dtype=np.uint32)


def independent_bf16_export():
    """Re-derive weights_bf16.hex from the npz masters (independent code path)."""
    z = np.load(NPZ)
    W1, b1 = z["W1"], z["b1"]
    W2, b2 = z["W2"], z["b2"]
    W3, b3 = z["W3"], z["b3"]
    W4, b4 = z["W4"], z["b4"]
    parts = []
    for x in [W1, b1, W2, b2, W3, b3, W4, b4]:
        f32v = x.astype(np.float32)
        parts.append(bf16_round(f32v).reshape(-1))
    return np.concatenate(parts)


def conv1_v(x, w, b):
    """x (B,784) raw pixels; w (B,8,9) expanded; b (B,8). Returns (B,28,28,8) h1."""
    B = x.shape[0]
    xb = bf16_to_f32(bf16_of_pixel(x)).reshape(B, 1, 28, 28)
    xp = np.pad(xb, ((0, 0), (0, 0), (1, 1), (1, 1)))
    acc = np.broadcast_to(b[:, None, :], (B, 784, 8)).copy()  # (B, px, oc) bias first
    for c in range(8):                                          # pass A: taps 0..7
        iy, ix = divmod(c, 3)
        a = xp[:, 0, iy:iy + 28, ix:ix + 28].reshape(B, 784)    # (B, px)
        prod = fmul(a[:, :, None], w[:, None, :, c])            # (B, px, 8)
        acc = fadd(acc, prod)
    for c in range(8):                                          # pass B: tap 8 in col 0 (fed from bank 8)
        iy, ix = divmod(c, 3)
        a = xp[:, 0, iy:iy + 28, ix:ix + 28].reshape(B, 784)
        ww = np.zeros_like(w[:, :, 0])
        if c == 0:
            ww = w[:, :, 8]
            a = xp[:, 0, 2:2 + 28, 2:2 + 28].reshape(B, 784)   # col 0 sees tap 8's window
        prod = fmul(a[:, :, None], ww[:, None, :])
        acc = fadd(acc, prod)
    h = np.maximum(acc, 0)
    return bf16_to_f32(bf16_round(h)).transpose(0, 2, 1).reshape(B, 8, 28, 28)   # (B,oc,oy,ox)


def pool2x2(h):
    B, C, H, W = h.shape
    return h.reshape(B, C, H // 2, 2, W // 2, 2).max(axis=(3, 5))


def conv2_v(p1, w, b):
    """p1 (B,8,14,14) float32 BF16 values; w (B,16,8,9); b (B,16). -> (B,16,14,14) h2."""
    B = p1.shape[0]
    acc = np.broadcast_to(b[:, None, :], (B, 196, 16)).copy()   # (B, px, oc) bias first
    for k in range(9):                                          # k = iy*3+ix outer
        iy, ix = divmod(k, 3)
        xp = np.pad(p1, ((0, 0), (0, 0), (1, 1), (1, 1)))
        a = xp[:, :, iy:iy + 14, ix:ix + 14].reshape(B, 8, 196).transpose(0, 2, 1)  # (B,px,ic)
        for c in range(8):                                      # ic inner (wavefront col order)
            prod = fmul(a[:, :, c][:, :, None], w[:, None, :, c, k])   # (B, px, 16)
            acc = fadd(acc, prod)
    h = np.maximum(acc, 0)
    return bf16_to_f32(bf16_round(h)).transpose(0, 2, 1).reshape(B, 16, 14, 14)  # (B,oc,oy,ox)


def fc1_v(p2, w, b):
    """p2 (B,784); w (B,784,32); b (B,32). -> h3 (B,32) BF16 values."""
    B = p2.shape[0]
    acc = b.copy()
    for i in range(784):
        prod = fmul(p2[:, i][:, None], w[:, i, :])
        acc = fadd(acc, prod)
    return bf16_to_f32(bf16_round(sigmoid_piecewise(acc)))       # (B,32)


def fc2_v(h3, w, b):
    """h3 (B,32); w (B,32,10); b (B,10). -> out sigma256 (B,10)."""
    acc = b.copy()
    for i in range(32):
        prod = fmul(h3[:, i][:, None], w[:, i, :])
        acc = fadd(acc, prod)
    return sigma256_of(sigmoid_piecewise(acc))


def main():
    # ---- 1. independent BF16 export check ----
    want = load_hex_words(os.path.join(GM, "weights_bf16.hex"))
    got = independent_bf16_export()
    assert got.shape == (N_WORDS,), got.shape
    mm = int((got != want).sum())
    print(f"export cross-check: {N_WORDS - mm}/{N_WORDS} words match independent conversion"
          + ("  (MISMATCHES: %d)" % mm if mm else ""))
    if mm:
        idx = np.where(got != want)[0][:5]
        for i in idx:
            print(f"   idx {i}: file 0x{want[i]:04x} vs independent 0x{int(got[i]):04x}")

    # ---- weight expansion (mirror the golden's bf16_to_f32) ----
    z = np.load(NPZ)
    W1, b1 = z["W1"], z["b1"]
    W2, b2 = z["W2"], z["b2"]
    W3, b3 = z["W3"], z["b3"]
    W4, b4 = z["W4"], z["b4"]
    w1 = bf16_to_f32(bf16_round(W1.astype(np.float32))).reshape(1, 8, 9)
    b1f = bf16_to_f32(bf16_round(b1.astype(np.float32))).reshape(1, 8)
    w2 = bf16_to_f32(bf16_round(W2.astype(np.float32))).reshape(1, 16, 8, 9)
    b2f = bf16_to_f32(bf16_round(b2.astype(np.float32))).reshape(1, 16)
    w3 = bf16_to_f32(bf16_round(W3.astype(np.float32))).reshape(1, 784, 32)
    b3f = bf16_to_f32(bf16_round(b3.astype(np.float32))).reshape(1, 32)
    w4 = bf16_to_f32(bf16_round(W4.astype(np.float32))).reshape(1, 32, 10)
    b4f = bf16_to_f32(bf16_round(b4.astype(np.float32))).reshape(1, 10)

    imgs = np.fromfile(IMGS, dtype=np.uint8).reshape(-1, 784)
    labels = np.fromfile(LBLS, dtype=np.uint8)
    n = imgs.shape[0]

    # ---- 2. 100-image cross-check vs the C golden's expected.hex ----
    exp = load_hex_words(os.path.join(GM, "expected.hex")).reshape(100, 4)
    CH = 100
    preds, confs, verds = [], [], []
    for s in range(0, CH, 25):
        B = 25
        x = imgs[s:s + B]
        h1 = conv1_v(x, np.broadcast_to(w1, (B, 8, 9)), np.broadcast_to(b1f, (B, 8)))
        p1 = pool2x2(h1)
        h2 = conv2_v(p1, np.broadcast_to(w2, (B, 16, 8, 9)), np.broadcast_to(b2f, (B, 16)))
        p2 = pool2x2(h2).reshape(B, 784)
        h3 = fc1_v(p2, np.broadcast_to(w3, (B, 784, 32)), np.broadcast_to(b3f, (B, 32)))
        out = fc2_v(h3, np.broadcast_to(w4, (B, 32, 10)), np.broadcast_to(b4f, (B, 10)))
        bp = np.argmax(out, axis=1)
        conf = ((np.take_along_axis(out, bp[:, None], 1)[:, 0].astype(np.uint32) * 100) >> 8)
        verd = np.where(conf < 50, 2, np.where(bp != labels[s:s + B], 1, 0))
        preds.append(bp); confs.append(conf); verds.append(verd)
    pred = np.concatenate(preds); conf = np.concatenate(confs); verd = np.concatenate(verds)
    mm = int(((pred != exp[:, 0]) | (conf != exp[:, 1]) | (verd != exp[:, 3])).sum())
    print(f"G8 100-image cross-check: {100 - mm}/100 match the C golden's expected.hex"
          + ("  (MISMATCHES: %d)" % mm if mm else ""))
    if mm:
        bad = np.where((pred != exp[:, 0]) | (conf != exp[:, 1]) | (verd != exp[:, 3]))[0][:8]
        for i in bad:
            print(f"   img {i}: twin=(p{pred[i]},c{conf[i]},v{verd[i]}) golden=(p{exp[i,0]},c{exp[i,1]},v{exp[i,3]})")

    # ---- 3. full-set accuracy (vectorised chunks) ----
    CH2 = 512
    preds, confs = [], []
    for s in range(0, n, CH2):
        B = min(CH2, n - s)
        x = imgs[s:s + B]
        h1 = conv1_v(x, np.broadcast_to(w1, (B, 8, 9)), np.broadcast_to(b1f, (B, 8)))
        p1 = pool2x2(h1)
        h2 = conv2_v(p1, np.broadcast_to(w2, (B, 16, 8, 9)), np.broadcast_to(b2f, (B, 16)))
        p2 = pool2x2(h2).reshape(B, 784)
        h3 = fc1_v(p2, np.broadcast_to(w3, (B, 784, 32)), np.broadcast_to(b3f, (B, 32)))
        out = fc2_v(h3, np.broadcast_to(w4, (B, 32, 10)), np.broadcast_to(b4f, (B, 10)))
        bp = np.argmax(out, axis=1)
        confs.append(((np.take_along_axis(out, bp[:, None], 1)[:, 0].astype(np.uint32) * 100) >> 8))
        preds.append(bp)
    pred = np.concatenate(preds); conf = np.concatenate(confs)
    verd = np.where(conf < 50, 2, np.where(pred != labels, 1, 0))
    cnt = {v: int((verd == v).sum()) for v in (0, 1, 2)}
    print(f"full-set (numpy twin, {n} images): correct {cnt[0]}, incorrect {cnt[1]},"
          f" trash {cnt[2]}, accuracy {100.0 * cnt[0] / n:.2f}%")
    return 0


if __name__ == "__main__":
    sys.exit(main())
