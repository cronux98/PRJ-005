# qat — WORKLOG

## 2026-08-25 (overnight, ds4 flash in-session)

- Created qat/ per Rinri's plan (Phase 0: QAT on the v1 MLP, weights-only, no RTL change).
- QAT v1 (from scratch, exact-int forward + STE, 60 ep): FINAL 92.32% — tie with v1, not a win.
- QAT v2 (float pretrain reproducing v1 exactly, then QAT fine-tune eta 0.1/20 ep):
  FINAL 92.18% — flat/drifting down. Two different objectives, same ceiling →
  documented as honest negative result (README.md).
- Golden re-run with QAT weights: 92.18% (9218/268/514); numpy integer
  cross-check 100/100 + full-set identical.
- qat regression: run-000 PASS 9/9 (tb_reset, tb_rom_readback, tb_sigmoid_lut,
  tb_mac, tb_uart_line_fmt, tb_mnist_top, tb_uart_realdiv, check_lut 65536,
  uart_diff 200/200 byte-exact vs regenerated golden); cocotb stage2 PASS.
- Decision: skip QAT v3 (round-to-nearest fake-quant) — v1/v2 converging on the
  same ceiling makes a third objective unlikely to differ; the CNN is the real
  accuracy path and is already running with QAT baked in from scratch.
- mnist_npu/ RTL untouched (frozen); QAT weights are drop-in compatible.
