# mnist_npu — MNIST Inference-Only NPU (PRJ-005)

**Status: GOLDEN MODEL DONE (2026-08-25)** — 92.25% integer accuracy on 10k
MNIST test images (9225 correct / 270 wrong / 505 trash), bit-exact contract
cross-validated (C golden vs independent numpy integer emulation, 100/100).
Next: fe-spec → fe-arch → fe-rtl, then iverilog/cocotb sim (UART bytes + LED
patterns vs expected.hex). FPGA deferred until simulation is fully green.

Tiny inference-only MNIST accelerator:
- MLP 784-32-10, Q8.8 fixed point, LUT sigmoid (no restoring divider)
- Weights + dataset (images + expected labels) loaded from memory ($readmemh)
- LED 0-9: one-hot predicted digit; LED 10: trash/failure (LED 0-9 off);
  LED 11: blinks during inference
- UART TX @115200 8N1: `IMG 042: This is number 7 | confidence 93% | expected 7 | CORRECT`

Decisions (Rinri 2026-08-25): LUT activation, golden model first, simulate
everything (UART + LEDs) before any FPGA step.

Open items: weight source (self-trained numpy vs open weights), trash
confidence threshold, directory naming.
