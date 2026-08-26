#!/usr/bin/env python3
"""check_cnn.py — independent numpy integer emulation of the CNN golden contract.

Cross-validates cnn/arch/golden_model/golden_ref_model.c (the C golden, the
bit-exact RTL contract): for all 65,536... no — for the first 100 images,
pred/conf/expected/verdict must match expected.hex exactly; full-set accuracy
must match the C SUMMARY. Written fresh (direct einsum + sliding windows),
independent of train_cnn.py's implementation.

Usage: python3 tools/check_cnn.py   (run from cnn/ root)
"""
import numpy as np
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GM = os.path.join(ROOT, "arch", "golden_model")

C1, C2, N_H, N_OUT = 8, 16, 32, 10
N_FC_IN = 7 * 7 * C2
N_WORDS = 9 * C1 + C1 + 9 * C1 * C2 + C2 + N_FC_IN * N_H + N_H + N_H * N_OUT + N_OUT


def load_hex_words(path):
    w = []
    for line in open(path):
        v = int(line.strip(), 16)
        w.append(v - 0x10000 if v & 0x8000 else v)
    return np.array(w, dtype=np.int64)


def sig_int(z):
    num = 128 * z
    den = 256 + np.abs(z)
    q = np.where(num >= 0, num // den, -((-num) // den))
    return 128 + q


def conv(x, w, b):
    """x (B,IC,H,W) int64, w (OC,IC,3,3) int64 Q8.8, b (OC,) int64 Q8.8.
    pad=1 stride=1 -> (B,OC,H,W) z = clip(acc>>8)."""
    B, IC, H, W = x.shape
    xp = np.pad(x.astype(np.int64), ((0, 0), (0, 0), (1, 1), (1, 1)))
    win = np.lib.stride_tricks.sliding_window_view(xp, (3, 3), axis=(2, 3))  # (B,IC,H,W,3,3)
    acc = np.einsum("bchwij,ocij->bhwo", win, w)              # (B,H,W,OC)
    acc = acc.transpose(0, 3, 1, 2) + (b << 8)[None, :, None, None]
    return np.clip(acc >> 8, -32768, 32767)


def pool_max(x):
    B, C, H, W = x.shape
    return x.reshape(B, C, H // 2, 2, W // 2, 2).max(axis=(3, 5))


def forward_int(W, X):
    """X (B,784) uint8 -> out (B,10) int64 0..256. W = flat word array."""
    n1, n2, n3, n4 = 9 * C1, 9 * C1 * C2, N_FC_IN * N_H, N_H * N_OUT
    W1 = W[0:n1].reshape(C1, 1, 3, 3)
    b1 = W[n1 : n1 + C1]
    W2 = W[n1 + C1 : n1 + C1 + n2].reshape(C2, C1, 3, 3)
    b2 = W[n1 + C1 + n2 : n1 + C1 + n2 + C2]
    W3 = W[n1 + C1 + n2 + C2 : n1 + C1 + n2 + C2 + n3].reshape(N_FC_IN, N_H)
    b3 = W[n1 + C1 + n2 + C2 + n3 : n1 + C1 + n2 + C2 + n3 + N_H]
    W4 = W[n1 + C1 + n2 + C2 + n3 + N_H : n1 + C1 + n2 + C2 + n3 + N_H + n4].reshape(N_H, N_OUT)
    b4 = W[n1 + C1 + n2 + C2 + n3 + N_H + n4 :]

    B = X.shape[0]
    x = X.reshape(B, 1, 28, 28)
    z1 = conv(x, W1, b1)
    h1 = np.maximum(z1, 0)
    p1 = pool_max(h1)
    z2 = conv(p1, W2, b2)
    h2 = np.maximum(z2, 0)
    p2 = pool_max(h2)                                   # (B,16,7,7)
    f = p2.reshape(B, N_FC_IN)                          # channel-major
    z3 = np.clip(((b3 << 8) + f @ W3) >> 8, -32768, 32767)
    h3 = sig_int(z3)
    z4 = np.clip(((b4 << 8) + h3 @ W4) >> 8, -32768, 32767)
    return sig_int(z4)


def main():
    W = load_hex_words(os.path.join(GM, "weights.hex"))
    assert W.shape[0] == N_WORDS, (W.shape[0], N_WORDS)
    imgs = np.fromfile(os.path.join(ROOT, "data", "t10k_images.bin"), dtype=np.uint8).reshape(-1, 784)
    labels = np.fromfile(os.path.join(ROOT, "data", "t10k_labels.bin"), dtype=np.uint8)

    exp = np.array([int(l.strip(), 16) for l in open(os.path.join(GM, "expected.hex"))]).reshape(100, 4)
    mm = 0
    for k in range(100):
        out = forward_int(W, imgs[k : k + 1])[0]
        best = int(np.argmax(out))
        conf = (int(out[best]) * 100) >> 8
        v = 2 if conf < 50 else (1 if best != int(labels[k]) else 0)
        if (best, conf, int(labels[k]), v) != tuple(exp[k]):
            mm += 1
            print(f"MISMATCH img {k}: np=({best},{conf},{labels[k]},{v}) exp=({exp[k][0]},{exp[k][1]},{exp[k][2]},{exp[k][3]})")
    print(f"cross-check: {100-mm}/100 match C golden")

    CH = 512
    preds, confs = [], []
    for s in range(0, imgs.shape[0], CH):
        out = forward_int(W, imgs[s : s + CH])
        bp = np.argmax(out, axis=1)
        preds.append(bp)
        confs.append((np.take_along_axis(out, bp[:, None], 1)[:, 0] * 100) >> 8)
    pred = np.concatenate(preds)
    conf = np.concatenate(confs)
    verdict = np.where(conf < 50, 2, np.where(pred != labels, 1, 0))
    print("numpy integer full-set:", dict(zip(*np.unique(verdict, return_counts=True))),
          "acc", round((verdict == 0).mean() * 100, 2), "%")


if __name__ == "__main__":
    main()
