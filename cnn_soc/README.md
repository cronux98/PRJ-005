# cnn_soc — MNIST CNN Accelerator SoC (PRJ-005)

**Status: DESIGN DISCUSSION (draft — awaiting Rinri approval before fe-spec)**

SoC integrating the verified `cnn/` MNIST CNN accelerator (96.35%, bit-exact)
with a RISC-V CPU, AXI interconnect, SRAM, bootrom, and UART/LED peripherals.
Firmware-driven: CPU boots → feeds image → reads result → UART + LED output.
Replaces the `$readmemh` + testbench-only flow with a real boot flow.

## Proposed architecture (v0 draft)

- **CPU:** picorv32 **with its built-in `picorv32_axi` wrapper** (AXI4-Lite
  master interface included in picorv32.v itself — no custom adapter needed;
  source: skill-tests/ex6/rtl/picorv32.v L2517, `picorv32_axi_adapter` L2731)
- **Interconnect:** AXI4-Lite (single master: CPU). Full AXI4 deferred until DMA (v2).
- **AXI slaves:**
  - bootrom (4 KB, reset vector + boot stub / firmware)
  - SRAM (128 KB: firmware, stack, data)
  - AI accelerator (CNN, AXI4-Lite slave wrapper — NEW RTL)
  - AXI→APB bridge
- **APB slaves:**
  - UART (TX, reuse verified uart_tx; 115200 @ CLK_DIV=868 / 100 MHz)
  - GPIO (LEDs, 16-bit out; firmware drives LED pattern from CNN result)
- **AI accelerator wrapper (new):** control regs (start/status), 784-byte
  writable image buffer (replaces image_rom $readmemh), result regs
  (pred/confidence/verdict). Weights: v1 = internal ROM (model is fixed);
  v2 = load via CPU into SRAM (26,698 words ≈ 53 KB) for zero-ROM.
- **Clock:** single sysclk domain, synchronous reset. No CDC (no camera yet).
- **Boot flow:** reset vector → bootrom stub → (copy firmware to SRAM) →
  jump to firmware → init UART/GPIO/CNN → write image → start inference →
  poll done → print UART line + set LEDs.

## Proposed memory map (v0)

- `0x0000_0000` bootrom (4 KB)
- `0x0000_1000` SRAM (128 KB)
- `0x4000_0000` AXI→APB: UART @ +0x0000, GPIO @ +0x1000
- `0x5000_0000` AI accelerator: CTRL/STATUS/RESULT @ +0x00..0x0C,
  image buffer @ +0x100 (784 B)

## Verification

fe-firmware flow: C → riscv-gcc → elf → objcopy → hex → iverilog preload
into bootrom/SRAM → full-SoC sim → UART lines vs golden + LED checks.
CNN unit TB (tb_mnist_top/cocotb) stays as the IP-level gate.

## Reuse

- ex6 already proved: picorv32 + SRAM + UART + GPIO + firmware boot (PASS all targets)
- picorv32_axi / picorv32_axi_adapter: built-in AXI4-Lite master (picorv32.v L2517/L2731)
- cnn RTL + golden: verified bit-exact
- fe-firmware skill: hex build/preload/POST patterns
- **NEW RTL:** AXI4-Lite decoder/mux + AXI2APB bridge + CNN AXI slave wrapper
  + APB UART/GPIO wrappers (CPU side comes free via picorv32_axi)
