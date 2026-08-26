# cnn — WORKLOG

## 2026-08-25/26 (overnight, ds4 flash in-session; spec/arch/rtl = Claude Sonnet 5)

- tools/train_cnn.py: numpy CNN trainer with QAT baked in (exact integer
  forward + STE gradients). Two bugs found & fixed during the run: conv
  gradient matmuls missing batch mean; float64-exact fast forward added after
  int64 matmul proved too slow (exactness proven: all values < 2^53).
- Training (seed 0, 40 ep, batch 64, eta 0.3): 88.06% (ep5) -> 96.35% (ep40,
  final verified on int64 path).
- golden_ref_model.c (CNN integer contract) compiles clean; run reproduces
  96.35% (9635/146/219); expected.hex/images.hex/labels.hex/expected_outputs.txt
  generated.
- tools/check_cnn.py (independent numpy emulation): 100/100 bit-identical to
  C, full-set identical. Contract cross-validated.
- Pipeline stall (completion event missed after training) -> resumed 01:45Z:
  golden + cross-check done, baseline committed, architect dispatched next.
