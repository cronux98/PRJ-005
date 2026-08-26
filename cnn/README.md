# cnn — mnist_npu v2: tiny CNN inference NPU (PRJ-005)

**Status: TRAINING (2026-08-25 night) — golden-first pipeline in progress.**

Inference-only MNIST CNN accelerator, the v2 of mnist_npu:
- Tiny CNN: Conv1 3×3 (1→8) + ReLU + MaxPool → Conv2 3×3 (8→16) + ReLU +
  MaxPool → FC 784→32 (sigmoid) → FC 32→10 (sigmoid), all Q8.8 fixed point
- Same chip personality as v1: free-running 100-image loop, LED[9:0] digit,
  LED[10] fail/trash, LED[11] busy blink, UART TX 115200 with the same line
  format; memories $readmemh-initialized; no host interface
- Target: ~97-99% integer accuracy (vs 92.25% for v1 MLP), FPGA (Nexys A7)
  later — simulation-first per Rinri
- BLINK_CYCLES default fixed to 100_000 (v1's 5M made the blink invisible in
  the ~7ms busy window — carried into the v2 spec)

## Golden-first flow (in progress)
1. ✅ `tools/train_cnn.py` — numpy CNN trainer with QAT baked in (exact
   integer forward, STE gradients, deterministic seed 0)
2. ⏳ `arch/golden_model/golden_ref_model.c` — the integer C contract
   (compiles clean); pending trained weights + cross-check
3. ⏳ `arch/golden_model/` — weights.hex (26,698 words), expected.hex,
   expected_outputs.txt (pending training)
4. ⏳ fe-spec → fe-arch → fe-rtl (architect agent, Claude Sonnet 5)
5. ⏳ verification (fe-iverilog + cocotb, ds4 flash)

## Files
- `tools/train_cnn.log` — training log (per-epoch integer accuracy)
- `tools/check_cnn.py` — independent numpy integer emulation (cross-check vs C)
- `arch/golden_model/golden_ref_model.c` — the bit-exact contract (see its
  header for the full fixed-point rules + weight layout)
- `verify/` — scripts + tb_common carried from v1 (TB files adapt once RTL lands)
