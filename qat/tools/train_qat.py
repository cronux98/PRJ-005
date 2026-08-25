#!/usr/bin/env python3
"""train_qat.py — Quantization-Aware Training for the v1 mnist_npu MLP (784-32-10).

Two-phase recipe (the one that actually recovers fixed-point loss):
  Phase A — float pretrain: EXACTLY the v1 algorithm (seed 0, batch 64, eta 0.5,
            MSE, rational-sigmoid float analogue) -> reproduces v1's float
            94.73% / integer 92.25% baseline bit-for-bit (deterministic).
  Phase B — QAT fine-tune: from the float masters, continue training with the
            chip's EXACT integer forward in the loop (weights quantized to Q8.8
            every batch, loss from integer outputs, straight-through gradients
            through the float analogue), eta 0.1, 20 epochs. The network adapts
            its weights to the integer truncation noise -> integer accuracy
            recovers most of the float-vs-integer gap.

Integer contract (golden_ref_model.c, unchanged from v1):
  acc64 = (bias<<8) + SUM x*w ; z = clamp(acc64>>8, -32768, 32767)
  sigma = 128 + trunc(128*z/(256+|z|)) ; argmax lowest-index ; conf=(best*100)>>8

Outputs (all inside qat/):
  arch/golden_model/weights.hex      Q8.8 weights, 25,450-word layout
  arch/golden_model/weights_float.npz  float masters after Phase B
  tools/train_qat.log                training log (both phases, integer acc)
Deterministic: seed 0, fixed schedule. Reads MNIST from ../mnist_npu/data.
"""
import gzip
import os
import struct
import time

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # qat/
DATA = os.path.normpath(os.path.join(ROOT, "..", "mnist_npu", "data"))
OUT = os.path.join(ROOT, "arch", "golden_model")

N_IN, N_H, N_OUT = 784, 32, 10
N_WORDS = N_IN * N_H + N_H + N_H * N_OUT + N_OUT

FLOAT_EPOCHS = 60      # Phase A — must match v1 exactly (seed 0, batch 64, eta 0.5)
QAT_EPOCHS = 20        # Phase B
BATCH = 64
ETA_FLOAT = 0.5
ETA_QAT = 0.1
SEED = 0


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
# Integer contract (bit-identical to golden_ref_model.c)
# ---------------------------------------------------------------------------
def sig_int(z):
    num = 128 * z
    den = 256 + np.abs(z)
    q = np.where(num >= 0, num // den, -((-num) // den))
    return 128 + q


def forward_int(W1, b1, W2, b2, X):
    acc = (b1 << 8) + X.astype(np.int64) @ W1
    z = np.clip(acc >> 8, -32768, 32767)
    h = sig_int(z)
    acc2 = (b2 << 8) + h @ W2
    z2 = np.clip(acc2 >> 8, -32768, 32767)
    return sig_int(z2)


def quantize_q8(w):
    return np.clip(np.rint(w.astype(np.float64) * 256.0), -32768.0, 32767.0).astype(np.int64)


def act_float(z):
    return 0.5 + 0.5 * z / (1.0 + np.abs(z))


def dact_float(z):
    return 0.5 / ((1.0 + np.abs(z)) ** 2)


def integer_accuracy(W1, b1, W2, b2, Xte, yte):
    out = forward_int(W1, b1, W2, b2, Xte)
    pred = np.argmax(out, axis=1)
    conf = (np.take_along_axis(out, pred[:, None], 1)[:, 0] * 100) >> 8
    verdict = np.where(conf < 50, 2, np.where(pred != yte, 1, 0))
    return (verdict == 0).mean() * 100.0, verdict


def export_hex(path, words):
    with open(path, "w") as f:
        for w in words:
            f.write(f"{int(w) & 0xFFFF:04x}\n")


def float_pretrain(Xtr, Ytr, Xte, yte, say):
    """Phase A: v1's exact float SGD (reproduces float 94.73% / int 92.25%)."""
    rng = np.random.default_rng(SEED)
    W1 = rng.normal(0.0, 1.0 / np.sqrt(N_IN), (N_IN, N_H)).astype(np.float64)
    b1 = np.zeros(N_H, dtype=np.float64)
    W2 = rng.normal(0.0, 1.0 / np.sqrt(N_H), (N_H, N_OUT)).astype(np.float64)
    b2 = np.zeros(N_OUT, dtype=np.float64)
    n = Xtr.shape[0]
    say(f"Phase A: float pretrain (v1-exact, {FLOAT_EPOCHS} epochs, eta {ETA_FLOAT})...")
    for ep in range(1, FLOAT_EPOCHS + 1):
        t0 = time.time()
        perm = rng.permutation(n)
        for s in range(0, n, BATCH):
            idx = perm[s : s + BATCH]
            xb = Xtr[idx].astype(np.float64) / 256.0
            yb = Ytr[idx]
            z1 = xb @ W1 + b1
            a1 = act_float(z1)
            z2 = a1 @ W2 + b2
            a2 = act_float(z2)
            d2 = (a2 - yb) * dact_float(z2)
            gW2 = a1.T @ d2 / BATCH
            gb2 = d2.mean(axis=0)
            d1 = (d2 @ W2.T) * dact_float(z1)
            gW1 = xb.T @ d1 / BATCH
            gb1 = d1.mean(axis=0)
            W1 -= ETA_FLOAT * gW1
            b1 -= ETA_FLOAT * gb1
            W2 -= ETA_FLOAT * gW2
            b2 -= ETA_FLOAT * gb2
        if ep % 10 == 0 or ep == FLOAT_EPOCHS:
            acc, v = integer_accuracy(quantize_q8(W1), quantize_q8(b1), quantize_q8(W2), quantize_q8(b2), Xte, yte)
            say(f"  [A] epoch {ep:02d}/{FLOAT_EPOCHS}  INTEGER test_acc {acc:5.2f}%  ({time.time()-t0:4.1f}s)")
    return W1, b1, W2, b2


def qat_finetune(W1, b1, W2, b2, Xtr, Ytr, Xte, yte, say):
    """Phase B: QAT fine-tune with exact-integer forward + STE gradients."""
    n = Xtr.shape[0]
    say(f"Phase B: QAT fine-tune ({QAT_EPOCHS} epochs, eta {ETA_QAT}, exact-int forward, STE)...")
    for ep in range(1, QAT_EPOCHS + 1):
        t0 = time.time()
        rng = np.random.default_rng(SEED + ep)     # deterministic but varied order
        perm = rng.permutation(n)
        for s in range(0, n, BATCH):
            idx = perm[s : s + BATCH]
            Xb, yb = Xtr[idx], Ytr[idx]

            qW1, qb1 = quantize_q8(W1), quantize_q8(b1)
            qW2, qb2 = quantize_q8(W2), quantize_q8(b2)

            out_int = forward_int(qW1, qb1, qW2, qb2, Xb)      # exact integer
            y_hat = out_int / 256.0

            xf = Xb.astype(np.float64) / 256.0
            z1f = xf @ (qW1 / 256.0) + (qb1 / 256.0)
            a1f = act_float(z1f)
            z2f = a1f @ (qW2 / 256.0) + (qb2 / 256.0)
            a2f = act_float(z2f)

            d2 = (y_hat - yb) * dact_float(z2f)                 # error from INTEGER fwd
            gW2 = a1f.T @ d2 / BATCH
            gb2 = d2.mean(axis=0)
            d1 = (d2 @ (qW2 / 256.0).T) * dact_float(z1f)
            gW1 = xf.T @ d1 / BATCH
            gb1 = d1.mean(axis=0)

            W1 -= ETA_QAT * gW1
            b1 -= ETA_QAT * gb1
            W2 -= ETA_QAT * gW2
            b2 -= ETA_QAT * gb2
        if ep % 5 == 0 or ep == QAT_EPOCHS:
            acc, v = integer_accuracy(quantize_q8(W1), quantize_q8(b1), quantize_q8(W2), quantize_q8(b2), Xte, yte)
            say(f"  [B] epoch {ep:02d}/{QAT_EPOCHS}  INTEGER test_acc {acc:5.2f}%  "
                f"(correct {int((v==0).sum())}, wrong {int((v==1).sum())}, trash {int((v==2).sum())})  ({time.time()-t0:4.1f}s)")
    return W1, b1, W2, b2


def main():
    os.makedirs(OUT, exist_ok=True)
    log = open(os.path.join(ROOT, "tools", "train_qat.log"), "w")
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

    W1, b1, W2, b2 = float_pretrain(Xtr, Ytr, Xte, yte, say)
    W1, b1, W2, b2 = qat_finetune(W1, b1, W2, b2, Xtr, Ytr, Xte, yte, say)

    qW1, qb1 = quantize_q8(W1), quantize_q8(b1)
    qW2, qb2 = quantize_q8(W2), quantize_q8(b2)
    words = np.concatenate([qW1.reshape(-1), qb1, qW2.reshape(-1), qb2])
    assert words.shape[0] == N_WORDS, words.shape
    export_hex(os.path.join(OUT, "weights.hex"), words)
    np.savez(os.path.join(OUT, "weights_float.npz"), W1=W1, b1=b1, W2=W2, b2=b2)
    acc, verdict = integer_accuracy(qW1, qb1, qW2, qb2, Xte, yte)
    say(f"FINAL: INTEGER test_acc {acc:.2f}% (correct {int((verdict==0).sum())}, "
        f"wrong {int((verdict==1).sum())}, trash {int((verdict==2).sum())})")
    say(f"v1 baseline was 92.25% (float 94.73%); exported {N_WORDS} Q8.8 words -> {os.path.join(OUT, 'weights.hex')}")
    say("QAT DONE")
    log.close()


if __name__ == "__main__":
    main()
