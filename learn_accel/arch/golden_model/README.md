# Golden model — rinriAI (fe-arch)

Reference: `golden_ref_model.c` (C99, integer-only, transaction-level).

## Build and run (the user runs these; fe-arch never executes tools)

```
gcc -std=c99 -O2 -Wall -Wextra -o gm golden_ref_model.c
./gm > got.txt && diff -u expected_outputs.txt got.txt
```

A clean diff means the model reproduces the expected outputs.

## REQ-018 invalid-label rejection (fix 2026-08-20, RTL-BUG-1)

A sample whose label is out of range (label >= CLASSES) is REJECTED: the C
model prints a `SAMPLE ... REJECTED (label out of range)` line and does NOT
count the sample, run a forward pass, or update weights. This mirrors the
RTL fix in `rtl/sample_stream.v` (label-range check on the final beat ->
`err_p` to stats, `sample_valid` never asserted, resync per FSM-002) so
RTL and golden stay bit-exact. The tiny vector set includes one such sample
(S6: pixels 0,1,2,3, label 0x05 >= CLASSES=2) as the rejection proof; it
contributes no row to `expected.hex` (it is not counted) and the rejection
line appears only in `expected_outputs.txt`.

## What it models

2-layer MLP (FEATURES × HIDDEN × CLASSES), online SGD, 16-bit Q8.8 fixed point, sigmoid
via the integer rational approximation (arch.md §5.3), quadratic cost, backprop per
Nielsen ch.1–2, saturating counters, lowest-index argmax ties. Rounding rules in
arch.md §5.2 are the bit-exactness contract for fe-rtl.

## Default build configuration (tiny config)

FEATURES=4, HIDDEN=4, CLASSES=2, LR_SHIFT=0 (eta=1). Vectors: 5 valid samples
(S6 is the invalid-label rejection proof) with a deterministic pseudo-random
initial weight set. The three golden data files are value-identical:

| File | Purpose | Consumer |
|---|---|---|
| golden_model_test_vectors.h | embedded vectors (init weights + samples) | C model |
| expected_outputs.txt | expected lines, diff-comparable | `diff -u` flow |
| stimulus.hex | $readmemh input (30 init weights + 30 sample bytes) | fe-rtl Verilog TB |
| expected.hex | $readmemh expected (25 per-sample words + 30 final weights) | fe-rtl Verilog TB |

Note (2026-08-20): the expected files were regenerated from the C model —
value-identical to the frontend-verified `verify/golden/tiny_shipped_corrected/`
for the 5 processed samples (the shipped hand-derived data had S3/S4
pred/counter errors and 18 wrong final weights, see verify/run-000/FINDINGS.md).
`stimulus.hex` inputs were confirmed correct by the frontend; only the 6th
sample (invalid label) was appended.

## Generating vectors for another configuration

1. Edit `FEATURES`, `HIDDEN`, `CLASSES`, `LR_SHIFT` in `golden_ref_model.c`.
2. Replace the vectors in `golden_model_test_vectors.h` (init weights and samples) with
   the desired data — e.g., MNIST-class samples converted from IDX byte streams
   (research/datasets.md) by the user's own script (run by the user, not by this stage).
3. Rebuild and run; then regenerate `stimulus.hex`/`expected.hex` in the documented
   layout (headers in those files) so the TB and C model stay value-identical.

The default 784×32×10 configuration is exercised in simulation by fe-cocotb porting the
C model as a Python refmodel (per the front-end pipeline) or by the user generating the
full vector set with this tool.
