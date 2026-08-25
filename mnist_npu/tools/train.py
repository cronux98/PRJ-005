#!/usr/bin/env python3
"""mnist_npu trainer — numpy SGD for a 784-32-10 MLP with the hardware-matching
activation (PRJ-005 rational sigmoid), Q8.8 export.

The chip implements the integer sigmoid (div_seq.v semantics):
    sigma = 128 + trunc(128*z / (256+|z|))        z = Q8.8
which is the fixed-point form of the float activation trained here:
    f(z) = 0.5 + 0.5*z/(1+|z|)                   f'(z) = 0.5/(1+|z|)^2

Training uses MSE (quadratic) cost, plain SGD (Nielsen ch.1-2), inputs x=p/256
(pixel byte p as Q8.8), targets one-hot 0/1. Weights are quantized to Q8.8
(16-bit signed, clip at +-128) and exported as one 4-hex-digit word per line,
layout W1 row-major (784*32) | b1 (32) | W2 (32*10) | b2 (10) = 25,450 words.

Outputs:
  arch/golden_model/weights.hex        Q8.8 weights for RTL/golden
  data/t10k_images.bin, t10k_labels.bin   plain-byte test set for golden C
Deterministic: fixed seed, fixed schedule. Python >= 3.8, numpy.
"""
import gzip
import os
import struct
import sys
import time

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "data")
OUT = os.path.join(ROOT, "arch", "golden_model")

N_IN, N_H, N_OUT = 784, 32, 10
N_WORDS = N_IN * N_H + N_H + N_H * N_OUT + N_OUT  # 25,450


def load_idx_images(path):
    with gzip.open(path, "rb") as f:
        magic, n, rows, cols = struct.unpack(">IIII", f.read(16))
        assert magic == 2051, f"bad image magic {magic:#x}"
        data = np.frombuffer(f.read(), dtype=np.uint8).reshape(n, rows * cols)
    return data


def load_idx_labels(path):
    with gzip.open(path, "rb") as f:
        magic, n = struct.unpack(">II", f.read(8))
        assert magic == 2049, f"bad label magic {magic:#x}"
        data = np.frombuffer(f.read(), dtype=np.uint8)
    return data


def act(z):
    """Float analogue of the hardware rational sigmoid (Q8.8 domain)."""
    return 0.5 + 0.5 * z / (1.0 + np.abs(z))


def dact(z):
    return 0.5 / ((1.0 + np.abs(z)) ** 2)


def forward(W1, b1, W2, b2, X):
    a1 = act(X @ W1 + b1)
    a2 = act(a1 @ W2 + b2)
    return a2


def train(X, Y, Xte, Yte, epochs=60, batch=64, eta=0.5, seed=0):
    n = X.shape[0]
    rng = np.random.default_rng(seed)
    W1 = rng.normal(0.0, 1.0 / np.sqrt(N_IN), (N_IN, N_H)).astype(np.float32)
    b1 = np.zeros(N_H, dtype=np.float32)
    W2 = rng.normal(0.0, 1.0 / np.sqrt(N_H), (N_H, N_OUT)).astype(np.float32)
    b2 = np.zeros(N_OUT, dtype=np.float32)
    for ep in range(1, epochs + 1):
        t0 = time.time()
        perm = rng.permutation(n)
        for s in range(0, n, batch):
            idx = perm[s : s + batch]
            xb, yb = X[idx], Y[idx]
            z1 = xb @ W1 + b1
            a1 = act(z1)
            z2 = a1 @ W2 + b2
            a2 = act(z2)
            d2 = (a2 - yb) * dact(z2)
            gW2 = a1.T @ d2 / batch
            gb2 = d2.mean(axis=0)
            d1 = (d2 @ W2.T) * dact(z1)
            gW1 = xb.T @ d1 / batch
            gb1 = d1.mean(axis=0)
            W1 -= eta * gW1
            b1 -= eta * gb1
            W2 -= eta * gW2
            b2 -= eta * gb2
        acc = (forward(W1, b1, W2, b2, Xte).argmax(1) == Yte).mean()
        print(f"epoch {ep:02d}/{epochs}  test_acc {acc*100:5.2f}%  ({time.time()-t0:4.1f}s)", flush=True)
    return W1, b1, W2, b2


def quantize_q8(w):
    """Float tensor -> Q8.8 int16 (round-to-nearest, clip at +-128 = Q8.8 range)."""
    q = np.clip(np.rint(w.astype(np.float64) * 256.0), -32768.0, 32767.0).astype(np.int32)
    return q


def export_hex(path, words):
    with open(path, "w") as f:
        for w in words:
            f.write(f"{w & 0xFFFF:04x}\n")


def main():
    os.makedirs(OUT, exist_ok=True)
    print("loading MNIST...", flush=True)
    Xtr_raw = load_idx_images(os.path.join(DATA, "train-images-idx3-ubyte.gz"))
    Xtr = Xtr_raw.astype(np.float32) / 256.0
    ytr = load_idx_labels(os.path.join(DATA, "train-labels-idx1-ubyte.gz"))
    Xte_raw = load_idx_images(os.path.join(DATA, "t10k-images-idx3-ubyte.gz"))
    Xte = Xte_raw.astype(np.float32) / 256.0
    yte = load_idx_labels(os.path.join(DATA, "t10k-labels-idx1-ubyte.gz"))
    Ytr = np.eye(N_OUT, dtype=np.float32)[ytr]
    print(f"train {Xtr.shape}  test {Xte.shape}", flush=True)

    print("training (seed 0, epochs 60, batch 64, eta 0.5)...", flush=True)
    W1, b1, W2, b2 = train(Xtr, Ytr, Xte, yte)

    # quantize to Q8.8
    qW1, qb1, qW2, qb2 = quantize_q8(W1), quantize_q8(b1), quantize_q8(W2), quantize_q8(b2)
    words = np.concatenate([qW1.reshape(-1), qb1, qW2.reshape(-1), qb2])
    assert words.shape[0] == N_WORDS, words.shape
    export_hex(os.path.join(OUT, "weights.hex"), words)
    print(f"exported {N_WORDS} Q8.8 words -> {os.path.join(OUT, 'weights.hex')}", flush=True)

    # rough float-accuracy check with the QUANTIZED weights (dequantized)
    dW1, db1, dW2, db2 = qW1 / 256.0, qb1 / 256.0, qW2 / 256.0, qb2 / 256.0
    acc_q = (forward(dW1, db1, dW2, db2, Xte).argmax(1) == yte).mean()
    print(f"quantized-weights float eval: test_acc {acc_q*100:.2f}%", flush=True)

    # plain-byte test set for the C golden model (RAW pixels, pre-scaling)
    with open(os.path.join(DATA, "t10k_images.bin"), "wb") as f:
        f.write(Xte_raw.tobytes())
    with open(os.path.join(DATA, "t10k_labels.bin"), "wb") as f:
        f.write(yte.tobytes())
    print("wrote data/t10k_images.bin + data/t10k_labels.bin for golden C", flush=True)
    print("TRAIN DONE", flush=True)


if __name__ == "__main__":
    main()
