# cnn_systolic — Sky130 ASIC CNN Accelerator (BF16 systolic + FP serial FC)

Third accelerator in PRJ-005 (sibling of `cnn_soc` / `mnist_npu` / `learn_accel`),
but an **ASIC-targeted** implementation from day one: **8x8 BF16 systolic array**
for the conv layers + **serial floating-point FC** datapath + **piecewise
sigmoid**, wrapped in the same picorv32 AXI->APB SoC shell as `cnn_soc`.

- **Golden source (READ-ONLY):** `../cnn/arch/golden_model/` — trained MNIST CNN
  (conv1 3x3 1->8 ReLU, pool 2x2, conv2 3x3 8->16 ReLU, pool 2x2, FC1 784->32,
  FC2 32->10, input 28x28 uint8). Float masters `weights_float.npz` are the
  trained weights — **no retraining**; BF16 export is a deterministic
  conversion, bit-exact to the new FP golden.
- **FP semantics (Rinri, 2026-08-28):** BF16 operands, FP32 accumulate,
  bit-exact golden that **mirrors the systolic accumulate order**, piecewise
  sigmoid pinned in arch, conv-only systolic + serial FC.
- **SoC shell:** picorv32_axi + AXI-Lite interconnect + axi2apb + sram +
  bootrom + apb_uart + apb_gpio, reused verbatim from `../cnn_soc` (provenance
  recorded). Register map + UART line format + 7-bit conf encoding kept
  identical to `cnn_soc` so the SoC verify harness is reused unchanged.
- **Verification scope (Rinri):** functional verification + functional
  coverage, fe-opensta (STA/SDC), fe-firmware (build + SoC UART diff vs
  regenerated FP expected outputs). **NO fe-sby formal, NO fe-gls, NO
  RTL<->netlist equivalence.** 3 retries per gate; honest-review fallback.

Pipeline: fe-spec -> fe-arch -> fe-rtl -> fe-yosys -> fe-opensta -> fe-firmware
-> functional verify + coverage. Front-end only (no PnR).

Status: dispatched 2026-08-28 18:24Z (see WORKLOG.md + BRIEF.md).
