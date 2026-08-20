#!/usr/bin/env python3
"""
gen_vectors.py — rinriAI golden-vector generator (frontend verification)

Generates {stimulus,expected}.hex + expected_outputs.txt + the C model
header for ANY configuration (FEATURES x HIDDEN x CLASSES, lr_shift) by
building and running a derived copy of arch/golden_model/golden_ref_model.c
(the executable golden reference). Also emits a self-contained Python
reference-model trace for cross-checking (bit-identical, verified 2026-08-20).

The shipped tiny-config expected data (arch/golden_model/expected.hex,
expected_outputs.txt) has hand-derivation errors (S3/S4 pred+counters,
18 of 30 final weights) — see verify/run-000/FINDINGS.md. This generator
produces C-MODEL-CORRECT expected data; the shipped stimulus.hex input
section is unaffected (raw inputs).

Usage:
  python3 verify/scripts/gen_vectors.py --features 8 --hidden 4 --classes 3 \
      --lr-shift 0 --samples 16 --seed 1 --outdir verify/golden
  python3 verify/scripts/gen_vectors.py --features 784 --hidden 32 --classes 10 \
      --lr-shift 2 --samples 5 --seed 7 --outdir verify/golden
  # IDX dataset source (MNIST-class):
  python3 verify/scripts/gen_vectors.py --features 784 --hidden 32 --classes 10 \
      --idx train-images-idx3-ubyte --idx-labels train-labels-idx1-ubyte \
      --samples 1000 --outdir verify/golden --name mnist1000

Outputs (per config, name = <tag>_<F>x<H>x<C>_s<S>):
  <outdir>/<name>/stimulus.hex        $readmemh input (init weights + sample bytes)
  <outdir>/<name>/expected.hex        $readmemh expected (per-sample + final weights)
  <outdir>/<name>/expected_outputs.txt  C-model stdout (diff-comparable)
  <outdir>/<name>/build/golden_ref_model.c  derived C model (defines set)
  <outdir>/<name>/build/vectors.h     generated header
"""
import argparse
import os
import random
import re
import shutil
import subprocess
import sys

def trunc_pow2(x, n):
    if n <= 0:
        return x
    return x >> n if x >= 0 else -((-x) >> n)

def sat16(x):
    return max(-32768, min(32767, x))

def c99_div(num, den):
    q = abs(num) // abs(den)
    return q if (num >= 0) == (den >= 0) else -q

def sigmoid_q8(z):
    az = -z if z < 0 else z
    return 128 + c99_div(128 * z, 256 + az)

class RefModel:
    """Python port of golden_ref_model.c (bit-identical; verified)."""
    def __init__(self, F, H, C, LS, freeze=False):
        self.F, self.H, self.C, self.LS = F, H, C, LS
        self.freeze = freeze
        self.W = F * H + H + H * C + C
        self.w = [0] * self.W
        self.sample_cnt = 0
        self.correct_cnt = 0
        self.error_cnt = 0

    def load_init(self, words):
        self.w = list(words)

    def process(self, pix, label):
        F, H, C = self.F, self.H, self.C
        a_h = []
        for h in range(H):
            acc = self.w[F * H + h] << 8
            for f in range(F):
                acc += self.w[h * F + f] * pix[f]
            a_h.append(sigmoid_q8(sat16(trunc_pow2(acc, 8))))
        y, pred = [], 0
        for c in range(C):
            acc = self.w[F * H + H + H * C + c] << 8
            for h in range(H):
                acc += self.w[F * H + H + c * H + h] * a_h[h]
            yc = sigmoid_q8(sat16(trunc_pow2(acc, 8)))
            y.append(yc)
            if yc > y[pred]:
                pred = c
        correct = 1 if pred == label else 0
        self.sample_cnt = min(self.sample_cnt + 1, 0xFFFFFFFF)
        if correct:
            self.correct_cnt = min(self.correct_cnt + 1, 0xFFFFFFFF)
        else:
            self.error_cnt = min(self.error_cnt + 1, 0xFFFFFFFF)
        delta_o = []
        for c in range(C):
            t = 256 if c == label else 0
            tmp = (y[c] - t) * y[c] * (256 - y[c])
            delta_o.append(sat16(trunc_pow2(tmp, 16)))
        delta_h = []
        for h in range(H):
            e16 = 0
            for c in range(C):
                e16 += self.w[F * H + H + c * H + h] * delta_o[c]
            delta_h.append(sat16(trunc_pow2(e16 * a_h[h] * (256 - a_h[h]), 24)))
        if self.freeze:
            return (pred, correct, self.sample_cnt, self.correct_cnt, self.error_cnt)
        for c in range(C):
            for h in range(H):
                a = F * H + H + c * H + h
                self.w[a] = sat16(self.w[a] - trunc_pow2(delta_o[c] * a_h[h], self.LS + 8))
            a = F * H + H + H * C + c
            self.w[a] = sat16(self.w[a] - trunc_pow2(delta_o[c], self.LS))
        for h in range(H):
            for f in range(F):
                a = h * F + f
                self.w[a] = sat16(self.w[a] - trunc_pow2(delta_h[h] * pix[f], self.LS + 8))
            a = F * H + h
            self.w[a] = sat16(self.w[a] - trunc_pow2(delta_h[h], self.LS))
        return (pred, correct, self.sample_cnt, self.correct_cnt, self.error_cnt)

def make_init_weights(W):
    """Shipped deterministic pattern: w[i] = ((i*7+3) mod 256) - 128."""
    return [((i * 7 + 3) % 256) - 128 for i in range(W)]

def make_lfsr_samples(F, H, C, n, seed):
    """Deterministic pseudo-random samples: pixels 0..255, labels 0..C-1."""
    rng = random.Random(seed)
    out = []
    for _ in range(n):
        pix = [rng.randrange(256) for _ in range(F)]
        label = rng.randrange(C)
        out.append((pix, label))
    return out

def read_idx_images(path, count=None):
    with open(path, 'rb') as f:
        magic = int.from_bytes(f.read(4), 'big')
        assert magic == 2051, f"bad IDX images magic {magic}"
        n = int.from_bytes(f.read(4), 'big')
        rows = int.from_bytes(f.read(4), 'big')
        cols = int.from_bytes(f.read(4), 'big')
        n = count or n
        data = f.read(n * rows * cols)
    return rows * cols, [list(data[i * rows * cols:(i + 1) * rows * cols]) for i in range(n)]

def read_idx_labels(path, count=None):
    with open(path, 'rb') as f:
        magic = int.from_bytes(f.read(4), 'big')
        assert magic == 2049, f"bad IDX labels magic {magic}"
        n = int.from_bytes(f.read(4), 'big')
        n = count or n
        return list(f.read(n))

def emit_header(path, F, H, C, W, init, samples):
    with open(path, 'w') as f:
        f.write(f"/* generated by gen_vectors.py — {F}x{H}x{C}, {len(samples)} samples */\n")
        f.write("#ifndef GOLDEN_MODEL_TEST_VECTORS_H\n#define GOLDEN_MODEL_TEST_VECTORS_H\n")
        f.write("#include <stdint.h>\n\n")
        f.write(f"#define GM_VECTOR_COUNT {len(samples)}\n")
        f.write(f"#define GM_FEATURES     {F}\n")
        f.write(f"#define GM_INIT_WORDS   {W}\n\n")
        f.write("static const int16_t gm_init_weights[GM_INIT_WORDS] = {\n")
        for i in range(0, W, 4):
            f.write("    " + ", ".join(f"{v}" for v in init[i:i+4]) + ",\n")
        f.write("};\n\n")
        f.write("typedef struct {\n    uint16_t pixels[GM_FEATURES];\n    uint8_t  label;\n} gm_sample_t;\n\n")
        f.write(f"static const gm_sample_t gm_samples[GM_VECTOR_COUNT] = {{\n")
        for pix, label in samples:
            f.write("    { { " + ", ".join(str(p) for p in pix) + " }, " + str(label) + " },\n")
        f.write("};\n\n#endif\n")

def build_and_run(F, H, C, LS, build_dir, workdir):
    """Derive golden_ref_model.c with the target defines, build, run."""
    src = os.path.join(workdir, 'arch', 'golden_model', 'golden_ref_model.c')
    with open(src) as f:
        code = f.read()
    code = re.sub(r'#define FEATURES \d+', f'#define FEATURES {F}', code)
    code = re.sub(r'#define HIDDEN   \d+', f'#define HIDDEN   {H}', code)
    code = re.sub(r'#define CLASSES  \d+', f'#define CLASSES  {C}', code)
    code = re.sub(r'#define LR_SHIFT \d+', f'#define LR_SHIFT {LS}', code)
    code = re.sub(r'#include "golden_model_test_vectors.h"',
                  '#include "vectors.h"', code)
    os.makedirs(build_dir, exist_ok=True)
    cpath = os.path.join(build_dir, 'golden_ref_model.c')
    with open(cpath, 'w') as f:
        f.write(code)
    exe = os.path.join(build_dir, 'gm')
    subprocess.run(['gcc', '-std=c99', '-O2', '-Wall', '-Wextra', '-o', exe, cpath],
                   check=True, cwd=build_dir)
    res = subprocess.run([exe], capture_output=True, text=True, check=True, cwd=build_dir)
    return res.stdout

def parse_c_output(text, W):
    per_sample, weights = [], []
    for ln in text.splitlines():
        m = re.match(r'SAMPLE (\d+) label=0x(\w+) pred=0x(\w+) correct=0x(\w+) sample=0x(\w+) correct_cnt=0x(\w+) error_cnt=0x(\w+)', ln)
        if m:
            # groups: 1=idx 2=label 3=pred 4=correct 5=sample 6=correct_cnt 7=error_cnt
            per_sample.append(tuple(int(m.group(k), 16) for k in (3, 4, 5, 6, 7)))
        m = re.match(r'WEIGHT 0x(\w+)=0x(\w+)', ln)
        if m:
            weights.append(int(m.group(2), 16))
    assert len(per_sample) * 5 + len(weights) == 5 * len(per_sample) + W
    return per_sample, weights

def write_hex(path, words, width, comment_lines):
    with open(path, 'w') as f:
        for c in comment_lines:
            f.write(f"// {c}\n")
        for w in words:
            f.write(f"{w:0{width}X}\n")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--features', type=int, required=True)
    ap.add_argument('--hidden', type=int, required=True)
    ap.add_argument('--classes', type=int, required=True)
    ap.add_argument('--lr-shift', type=int, default=0)
    ap.add_argument('--samples', type=int, default=5)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--name', default=None, help='output tag (default <F>x<H>x<C>_s<S>)')
    ap.add_argument('--idx', default=None, help='IDX images file (MNIST-class)')
    ap.add_argument('--idx-labels', default=None, help='IDX labels file')
    ap.add_argument('--idx-offset', type=int, default=0, help='start at sample N of the dataset')
    ap.add_argument('--shipped', action='store_true',
                    help='use the shipped 5-sample tiny-vector set (4x4x2 only)')
    ap.add_argument('--freeze', action='store_true',
                    help='generate FREEZE-mode expected (inference only, no updates; '
                         'RefModel-based — the C model has no freeze flag)')
    ap.add_argument('--outdir', default='verify/golden')
    ap.add_argument('--repo', default=os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))  # PRJ-005 root
    args = ap.parse_args()

    F, H, C, LS = args.features, args.hidden, args.classes, args.lr_shift
    W = F * H + H + H * C + C
    assert W <= 65535, f"W_TOT={W} exceeds REQ-022 limit"
    args.outdir = os.path.abspath(args.outdir)
    args.repo = os.path.abspath(args.repo)
    tag = args.name or f"{F}x{H}x{C}_s{args.samples}"
    outdir = os.path.join(args.outdir, tag)
    build = os.path.join(outdir, 'build')
    os.makedirs(build, exist_ok=True)

    init = make_init_weights(W)
    if args.shipped:
        # exact shipped vector set (golden_model_test_vectors.h) — used to
        # regenerate CORRECT expected data for the same inputs
        assert (F, H, C) == (4, 4, 2), "--shipped is the tiny 4x4x2 set only"
        samples = [
            ([0, 100, 100, 0], 0),
            ([200, 0, 0, 200], 1),
            ([50, 50, 50, 50], 0),
            ([0, 0, 0, 0], 0),
            ([255, 255, 255, 255], 1),
        ]
    elif args.idx:
        feats, imgs = read_idx_images(args.idx, args.idx_offset + args.samples)
        lbls = read_idx_labels(args.idx_labels, args.idx_offset + args.samples)
        assert feats == F, f"dataset features {feats} != {F}"
        samples = [(imgs[i], lbls[i]) for i in range(args.idx_offset, args.idx_offset + args.samples)]
    else:
        samples = make_lfsr_samples(F, H, C, args.samples, args.seed)

    # 1) header + derived C model -> run
    emit_header(os.path.join(build, 'vectors.h'), F, H, C, W, init, samples)
    c_out = build_and_run(F, H, C, LS, build, args.repo)
    per_sample, final_w = parse_c_output(c_out, W)

    # 2) independent Python reference (cross-check the C run)
    rm = RefModel(F, H, C, LS, freeze=args.freeze)
    rm.load_init(init)
    py_rows = []
    for pix, label in samples:
        py_rows.append(rm.process(pix, label))
    if args.freeze:
        per_sample = py_rows                      # freeze: RefModel is the reference
        final_w = [w & 0xFFFF for w in rm.w]      # = init weights (unchanged)
    else:
        c_rows = [(p[0], p[1], p[2], p[3], p[4]) for p in per_sample]
        if py_rows != c_rows:
            for i, (a, b) in enumerate(zip(py_rows, c_rows)):
                if a != b:
                    print(f"WARN python vs C differ at sample {i}: {a} vs {b}", file=sys.stderr)
        # C model is the contract; continue (report only)
    if [w & 0xFFFF for w in rm.w] != final_w:
        print("WARN python final weights differ from C model", file=sys.stderr)

    # 3) stimulus.hex: init words (16-bit) + sample bytes (8-bit, 2 hex)
    stim_words = []
    for w in init:
        stim_words.append(w & 0xFFFF)
    for pix, label in samples:
        stim_words += pix + [label]
    write_hex(os.path.join(outdir, 'stimulus.hex'), stim_words, 2,
              [f"stimulus.hex — {tag}, generated by verify/scripts/gen_vectors.py",
               f"layout: {W} init weight words, then {len(samples)} samples x {F}+1 bytes"])

    # 4) expected.hex: per-sample 5 words + final weights
    exp_words = []
    for (pred, correct, sc, cc, ec) in per_sample:
        exp_words += [pred, correct, sc, cc, ec]
    exp_words += [w & 0xFFFF for w in final_w]
    write_hex(os.path.join(outdir, 'expected.hex'), exp_words, 8,
              [f"expected.hex — {tag}, generated by verify/scripts/gen_vectors.py",
               f"layout: {len(samples)} samples x 5 words, then {W} final weight words"])

    with open(os.path.join(outdir, 'expected_outputs.txt'), 'w') as f:
        f.write(c_out)

    print(f"OK {tag}: W_TOT={W} samples={len(samples)} lr_shift={LS}")
    print(f"  stimulus.hex  -> {os.path.join(outdir, 'stimulus.hex')}")
    print(f"  expected.hex  -> {os.path.join(outdir, 'expected.hex')}")
    print(f"  C model: {len(per_sample)} sample rows, {len(final_w)} weights")

if __name__ == '__main__':
    main()
