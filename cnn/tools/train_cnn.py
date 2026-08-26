#!/usr/bin/env python3
"""train_cnn.py — Quantization-Aware Training for the mnist_npu v2 CNN.

Network (tiny CNN, integer Q8.8 contract for golden_ref_model.c):
  Input 28x28 (784 pixels, uint8 = Q8.8 value p)
  Conv1: 3x3, 1->8 ch, pad=1, stride=1, ReLU        -> 28x28x8   (80 weights)
  Pool1: 2x2 max, stride=2                           -> 14x14x8
  Conv2: 3x3, 8->16 ch, pad=1, stride=1, ReLU        -> 14x14x16  (1,168)
  Pool2: 2x2 max, stride=2                           -> 7x7x16 = 784
  FC1: 784->32, sigmoid (rational, LUT contract)     -> 32        (25,120)
  FC2: 32->10, sigmoid (rational, LUT contract)      -> 10        (330)
  Total weights: 26,698 words (conv1_w|conv1_b|conv2_w|conv2_b|fc1_w|fc1_b|fc2_w|fc2_b)

Integer contract (bit-exact target, identical to golden_ref_model.c):
  acc64 = (bias<<8) + SUM x*w           (int64, Q16.16 bias alignment)
  z     = clamp(acc64>>8, -32768, 32767)  (arithmetic floor shift)
  conv/pool hidden: h = max(z, 0)          (ReLU; no saturation clamp needed
                                            because accumulation is 64-bit)
  FC hidden/output: sigma = 128 + trunc(128*z/(256+|z|))   (C99 trunc)
  argmax lowest-index; confidence = (best*100)>>8; trash < 50

QAT method: every batch quantizes weights to Q8.8 and runs the EXACT integer
forward (loss from integer outputs, MSE vs one-hot); gradients flow through
the float analogue (STE: quantizers = identity; error from integer outputs).

Deterministic: seed 0, fixed schedule. Outputs (all inside cnn/):
  arch/golden_model/weights.hex         26,698 Q8.8 words
  arch/golden_model/weights_float.npz   float masters
  tools/train_cnn.log                   training log
Reads MNIST from ../mnist_npu/data.
"""
import gzip
import os
import struct
import time

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # cnn/
DATA = os.path.normpath(os.path.join(ROOT, "..", "mnist_npu", "data"))
OUT = os.path.join(ROOT, "arch", "golden_model")

# Network
C1, C2 = 8, 16
N_FC_IN = 7 * 7 * C2        # 784
N_H, N_OUT = 32, 10
N_WORDS = (9 * C1 + C1) + (9 * C1 * C2 + C2) + (N_FC_IN * N_H + N_H) + (N_H * N_OUT + N_OUT)  # 26,698

EPOCHS = 40
BATCH = 64
ETA = 0.3
SEED = 0
EVAL_CHUNK = 512


def load_idx_images(path):
    with gzip.open(path, "rb") as f:
        magic, n, rows, cols = struct.unpack(">IIII", f.read(16))
        assert magic == 2051, f"bad image magic {magic:#x}"
        return np.frombuffer(f.read(), dtype=np.uint8).reshape(n, rows * cols)


def load_idx_labels(path):
    with gzip.open(path, "rb") as f:
        magic, n = struct.unpack(">II", f.read(8))
        assert magic == 2049, f"bad label magic {magic:#x}"
        return np.frombuffer(f.read(), dtype=np.uint8)


# ---------------------------------------------------------------------------
# Integer contract helpers (bit-exact with the C golden)
# ---------------------------------------------------------------------------
def sig_int(z):
    num = 128 * z
    den = 256 + np.abs(z)
    q = np.where(num >= 0, num // den, -((-num) // den))
    return 128 + q


def quantize_q8(w):
    return np.clip(np.rint(w.astype(np.float64) * 256.0), -32768.0, 32767.0).astype(np.int64)


def im2col_pad(x, pad):
    """x: (B,C,H,W) -> patches (B, H*W, C*9) with zero padding, tap order ic*9+iy*3+ix.
    Returns the padded array too (needed by col2im)."""
    B, C, H, W = x.shape
    xp = np.pad(x, ((0, 0), (0, 0), (pad, pad), (pad, pad)))
    Hp, Wp = H + 2 * pad, W + 2 * pad
    windows = np.lib.stride_tricks.sliding_window_view(xp, (C, 3, 3), axis=(1, 2, 3))
    # windows: (B, Hp-2, Wp-2, C, 3, 3)
    patches = windows.reshape(B, H * W, C * 9)
    return patches, xp


def col2im(d_patches, B, C, H, W, pad):
    """d_patches: (B, H*W, C*9) -> (B, C, H, W) via shifted adds (tap order ic*9+iy*3+ix)."""
    acc = np.zeros((B, C, H + 2 * pad, W + 2 * pad), dtype=np.float64)
    dp = d_patches.reshape(B, H, W, C, 3, 3)
    for iy in range(3):
        for ix in range(3):
            acc[:, :, iy : iy + H, ix : ix + W] += dp[:, :, :, :, iy, ix].transpose(0, 3, 1, 2)
    return acc[:, :, pad : pad + H, pad : pad + W]


def conv_int(x, w, b):
    """x: (B,IC,H,W) uint8/int64; w: (OC,IC,3,3) int64 Q8.8; b: (OC,) int64 Q8.8.
    Returns z (B,OC,H,W) int64: clamp(acc>>8)."""
    B, IC, H, W = x.shape
    patches, _ = im2col_pad(x, 1)
    wf = w.transpose(1, 2, 3, 0).reshape(IC * 9, w.shape[0])     # (IC*9, OC)
    acc = patches @ wf + (b.astype(np.int64) << 8)[None, None, :]
    z = acc.reshape(B, H, W, w.shape[0]).transpose(0, 3, 1, 2)
    return np.clip(z >> 8, -32768, 32767)


# ---------------------------------------------------------------------------
# float64 EXACT simulation of the integer forward (fast path for training).
# Bit-exactness: every product <= 32767*32768 = 2^30 and every partial
# accumulation <= 784*2^30 = 8.4e11 < 2^53, so float64 matmuls (any BLAS
# summation order) are exact; acc/256 is a power-of-two division (exact);
# floor(acc/256) == arithmetic shift acc>>8 for all ints. The sigmoid stays
# on the int64 path (trunc division), so results are bit-identical to
# forward_int — verified by the final int64 eval + check_cnn.py.
# ---------------------------------------------------------------------------
def conv_f64(x, w, b):
    """x/w/b float64 (exact ints). Returns z int64 = clip(floor(acc/256))."""
    B, IC, H, W = x.shape
    patches, _ = im2col_pad(x, 1)
    wf = w.transpose(1, 2, 3, 0).reshape(IC * 9, w.shape[0])
    acc = patches @ wf + (b * 256.0)[None, None, :]
    acc = acc.reshape(B, H, W, w.shape[0]).transpose(0, 3, 1, 2)
    return np.clip(np.floor(acc / 256.0).astype(np.int64), -32768, 32767)


def forward_int_f64(W1, b1, W2, b2, W3, b3, W4, b4, X):
    """Bit-exact fast twin of forward_int (float64 matmuls, see module note)."""
    B = X.shape[0]
    x = X.reshape(B, 1, 28, 28).astype(np.float64)
    fW1, fb1 = W1.astype(np.float64), b1.astype(np.float64)
    fW2, fb2 = W2.astype(np.float64), b2.astype(np.float64)
    fW3, fb3 = W3.astype(np.float64), b3.astype(np.float64)
    fW4, fb4 = W4.astype(np.float64), b4.astype(np.float64)
    z1 = conv_f64(x, fW1, fb1)
    h1 = np.maximum(z1, 0)
    p1 = pool_max(h1)
    z2 = conv_f64(p1.astype(np.float64), fW2, fb2)
    h2 = np.maximum(z2, 0)
    p2 = pool_max(h2)
    f = p2.reshape(B, N_FC_IN).astype(np.float64)
    acc3 = (fb3 * 256.0)[None, :] + f @ fW3
    z3 = np.clip(np.floor(acc3 / 256.0).astype(np.int64), -32768, 32767)
    h3 = sig_int(z3)
    acc4 = (fb4 * 256.0)[None, :] + h3.astype(np.float64) @ fW4
    z4 = np.clip(np.floor(acc4 / 256.0).astype(np.int64), -32768, 32767)
    return sig_int(z4)


def pool_max(x):
    """x: (B,C,H,W) -> (B,C,H/2,W/2) max over 2x2."""
    B, C, H, W = x.shape
    return x.reshape(B, C, H // 2, 2, W // 2, 2).max(axis=(3, 5))


def forward_int(W1, b1, W2, b2, W3, b3, W4, b4, X):
    """Full integer forward; X (B,784) uint8. Returns out (B,10) int64 0..256."""
    x = X.reshape(X.shape[0], 1, 28, 28)
    z1 = conv_int(x, W1, b1)
    h1 = np.maximum(z1, 0)
    p1 = pool_max(h1)                                   # (B,8,14,14)
    z2 = conv_int(p1, W2, b2)
    h2 = np.maximum(z2, 0)
    p2 = pool_max(h2)                                   # (B,16,7,7)
    f = p2.reshape(X.shape[0], N_FC_IN)
    acc3 = (b3 << 8) + f @ W3
    z3 = np.clip(acc3 >> 8, -32768, 32767)
    h3 = sig_int(z3)                                    # (B,32) 0..256
    acc4 = (b4 << 8) + h3 @ W4
    z4 = np.clip(acc4 >> 8, -32768, 32767)
    return sig_int(z4)


def integer_eval(W1, b1, W2, b2, W3, b3, W4, b4, Xte, yte, fast=True):
    fwd = forward_int_f64 if fast else forward_int
    preds, confs = [], []
    for s in range(0, Xte.shape[0], EVAL_CHUNK):
        out = fwd(W1, b1, W2, b2, W3, b3, W4, b4, Xte[s : s + EVAL_CHUNK])
        bp = np.argmax(out, axis=1)
        preds.append(bp)
        confs.append((np.take_along_axis(out, bp[:, None], 1)[:, 0] * 100) >> 8)
    pred = np.concatenate(preds)
    conf = np.concatenate(confs)
    verdict = np.where(conf < 50, 2, np.where(pred != yte, 1, 0))
    return (verdict == 0).mean() * 100.0, verdict


def act_float(z):
    return 0.5 + 0.5 * z / (1.0 + np.abs(z))


def dact_float(z):
    return 0.5 / ((1.0 + np.abs(z)) ** 2)


def export_hex(path, words):
    with open(path, "w") as f:
        for w in words:
            f.write(f"{int(w) & 0xFFFF:04x}\n")


def main():
    os.makedirs(OUT, exist_ok=True)
    log = open(os.path.join(ROOT, "tools", "train_cnn.log"), "w")
    def say(*a):
        line = " ".join(str(x) for x in a)
        print(line, flush=True)
        log.write(line + "\n")
        log.flush()

    say("loading MNIST from", DATA)
    Xtr = load_idx_images(os.path.join(DATA, "train-images-idx3-ubyte.gz"))
    ytr = load_idx_labels(os.path.join(DATA, "train-labels-idx1-ubyte.gz"))
    Xte = load_idx_images(os.path.join(DATA, "t10k-images-idx3-ubyte.gz"))
    yte = load_idx_labels(os.path.join(DATA, "t10k-labels-idx1-ubyte.gz"))
    Ytr = np.eye(N_OUT, dtype=np.float64)[ytr]
    say(f"train {Xtr.shape} test {Xte.shape}")

    rng = np.random.default_rng(SEED)
    W1 = rng.normal(0.0, 1.0 / np.sqrt(9.0), (C1, 1, 3, 3)).astype(np.float64)
    b1 = np.zeros(C1)
    W2 = rng.normal(0.0, 1.0 / np.sqrt(9.0 * C1), (C2, C1, 3, 3)).astype(np.float64)
    b2 = np.zeros(C2)
    W3 = rng.normal(0.0, 1.0 / np.sqrt(N_FC_IN), (N_FC_IN, N_H)).astype(np.float64)
    b3 = np.zeros(N_H)
    W4 = rng.normal(0.0, 1.0 / np.sqrt(N_H), (N_H, N_OUT)).astype(np.float64)
    b4 = np.zeros(N_OUT)

    n = Xtr.shape[0]
    say("CNN QAT training: epochs=%d batch=%d eta=%g seed=%d" % (EPOCHS, BATCH, ETA, SEED))
    for ep in range(1, EPOCHS + 1):
        t0 = time.time()
        perm = rng.permutation(n)
        for s in range(0, n, BATCH):
            idx = perm[s : s + BATCH]
            Xb, yb = Xtr[idx], Ytr[idx]
            B = Xb.shape[0]

            qW1, qb1 = quantize_q8(W1), quantize_q8(b1)
            qW2, qb2 = quantize_q8(W2), quantize_q8(b2)
            qW3, qb3 = quantize_q8(W3), quantize_q8(b3)
            qW4, qb4 = quantize_q8(W4), quantize_q8(b4)

            # ---- exact integer forward (loss source; float64-exact fast path) ----
            out_int = forward_int_f64(qW1, qb1, qW2, qb2, qW3, qb3, qW4, qb4, Xb)
            y_hat = out_int / 256.0

            # ---- float analogue (derivatives; weights dequantized) ----
            fW1, fb1 = qW1 / 256.0, qb1 / 256.0
            fW2, fb2 = qW2 / 256.0, qb2 / 256.0
            fW3, fb3 = qW3 / 256.0, qb3 / 256.0
            fW4, fb4 = qW4 / 256.0, qb4 / 256.0

            xf = Xb.astype(np.float64).reshape(B, 1, 28, 28) / 256.0
            # conv1
            p1f, _ = im2col_pad(xf, 1)                       # (B,784,9)
            w1f = fW1.transpose(1, 2, 3, 0).reshape(9, C1)    # (9, C1)
            z1f = (p1f @ w1f + fb1[None, None, :]).reshape(B, 28, 28, C1).transpose(0, 3, 1, 2)
            a1f = np.maximum(z1f, 0)                          # ReLU
            # pool1
            pp1 = a1f.reshape(B, C1, 14, 2, 14, 2)
            p1v = pp1.max(axis=(3, 5))                        # (B,8,14,14)
            p1idx = np.argmax(pp1.reshape(B, C1, 14, 14, 4), axis=4)  # 0..3
            # conv2
            p2f, _ = im2col_pad(p1v, 1)                       # (B,196,72)
            w2f = fW2.transpose(1, 2, 3, 0).reshape(C1 * 9, C2)
            z2f = (p2f @ w2f + fb2[None, None, :]).reshape(B, 14, 14, C2).transpose(0, 3, 1, 2)
            a2f = np.maximum(z2f, 0)
            # pool2
            pp2 = a2f.reshape(B, C2, 7, 2, 7, 2)
            p2v = pp2.max(axis=(3, 5))                        # (B,16,7,7)
            p2idx = np.argmax(pp2.reshape(B, C2, 7, 7, 4), axis=4)
            # fc
            fflat = p2v.reshape(B, N_FC_IN)
            z3f = fflat @ fW3 + fb3
            a3f = act_float(z3f)
            z4f = a3f @ fW4 + fb4
            a4f = act_float(z4f)

            # ---- backward (STE: error from integer outputs, derivatives float) ----
            d4 = (y_hat - yb) * dact_float(z4f)
            gW4 = a3f.T @ d4 / B
            gb4 = d4.mean(axis=0)
            d3 = (d4 @ fW4.T) * dact_float(z3f)
            gW3 = fflat.T @ d3 / B
            gb3 = d3.mean(axis=0)
            # pool2 back
            dp2 = d3 @ fW3.T                                        # (B,784)
            dp2 = dp2.reshape(B, C2, 7, 7)
            da2 = np.zeros((B, C2, 14, 14))
            for k in range(4):
                oy, ox = k // 2, k % 2
                da2[:, :, oy::2, ox::2] += np.where(p2idx == k, dp2, 0.0)
            da2 *= (z2f > 0)                                        # ReLU grad
            # conv2 back
            dp2f, _ = im2col_pad(p1v, 1)                            # reuse float pool1 (B,196,72)
            d2col = da2.transpose(0, 2, 3, 1).reshape(B, 196, C2)   # (B,196,C2)
            gW2 = (dp2f.transpose(0, 2, 1) @ d2col).mean(axis=0).reshape(C1, 3, 3, C2).transpose(3, 0, 1, 2)
            gb2 = d2col.mean(axis=(0, 1))
            dp1 = (d2col @ w2f.T)                                   # (B,196,72)
            dp1 = col2im(dp1, B, C1, 14, 14, 1)                      # grad wrt pool1 OUTPUT
            # pool1 back
            dp1 = dp1.reshape(B, C1, 14, 14)
            da1 = np.zeros((B, C1, 28, 28))
            for k in range(4):
                oy, ox = k // 2, k % 2
                da1[:, :, oy::2, ox::2] += np.where(p1idx == k, dp1, 0.0)
            da1 *= (z1f > 0)                                        # conv1 ReLU grad
            # conv1 back
            xcol, _ = im2col_pad(xf, 1)                             # (B,784,9)
            d1col = da1.transpose(0, 2, 3, 1).reshape(B, 784, C1)
            gW1 = (xcol.transpose(0, 2, 1) @ d1col).mean(axis=0).reshape(1, 3, 3, C1).transpose(3, 0, 1, 2)
            gb1 = d1col.mean(axis=(0, 1))

            W1 -= ETA * gW1
            b1 -= ETA * gb1
            W2 -= ETA * gW2
            b2 -= ETA * gb2
            W3 -= ETA * gW3
            b3 -= ETA * gb3
            W4 -= ETA * gW4
            b4 -= ETA * gb4

        if ep % 5 == 0 or ep == EPOCHS:
            qW1, qb1 = quantize_q8(W1), quantize_q8(b1)
            qW2, qb2 = quantize_q8(W2), quantize_q8(b2)
            qW3, qb3 = quantize_q8(W3), quantize_q8(b3)
            qW4, qb4 = quantize_q8(W4), quantize_q8(b4)
            acc, verdict = integer_eval(qW1, qb1, qW2, qb2, qW3, qb3, qW4, qb4, Xte, yte)
            say(f"epoch {ep:02d}/{EPOCHS}  INTEGER test_acc {acc:5.2f}%  "
                f"(correct {int((verdict==0).sum())}, wrong {int((verdict==1).sum())}, trash {int((verdict==2).sum())})  ({time.time()-t0:4.1f}s)")

    # export (the exact quantized weights training used)
    qW1, qb1 = quantize_q8(W1), quantize_q8(b1)
    qW2, qb2 = quantize_q8(W2), quantize_q8(b2)
    qW3, qb3 = quantize_q8(W3), quantize_q8(b3)
    qW4, qb4 = quantize_q8(W4), quantize_q8(b4)
    words = np.concatenate([
        qW1.reshape(-1), qb1,
        qW2.reshape(-1), qb2,
        qW3.reshape(-1), qb3,
        qW4.reshape(-1), qb4,
    ])
    assert words.shape[0] == N_WORDS, (words.shape[0], N_WORDS)
    export_hex(os.path.join(OUT, "weights.hex"), words)
    np.savez(os.path.join(OUT, "weights_float.npz"), W1=W1, b1=b1, W2=W2, b2=b2, W3=W3, b3=b3, W4=W4, b4=b4)
    acc, verdict = integer_eval(qW1, qb1, qW2, qb2, qW3, qb3, qW4, qb4, Xte, yte, fast=False)
    say(f"FINAL (int64 forward): INTEGER test_acc {acc:.2f}% (correct {int((verdict==0).sum())}, "
        f"wrong {int((verdict==1).sum())}, trash {int((verdict==2).sum())})")
    say(f"exported {N_WORDS} Q8.8 words -> {os.path.join(OUT, 'weights.hex')}")
    say("CNN TRAIN DONE")
    log.close()


if __name__ == "__main__":
    main()
