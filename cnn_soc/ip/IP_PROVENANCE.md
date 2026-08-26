# IP Provenance — cnn_soc (fe-rtl)

All reused blocks are **local, project-internal or locally-vendored sources** — no external fetch
was needed or performed (no network access required; arch_manifest entries carry `repo` as local
paths with `commit: null` because they are files already on disk, verified by inspection and by
byte-identical diff at copy time). No URL or licence is claimed for anything not read from disk.

## picorv32_axi (+ picorv32, picorv32_axi_adapter, picorv32_regs, picorv32_pcpi_*)  (BLK-012)
- Repository : local: `skill-tests/ex6/rtl/picorv32.v` (vendored copy; no remote fetch)
- Commit     : n/a (local copy; pin by path, diffed byte-identical at copy time)
- Licence    : ISC (in-file header, © 2015 Claire Xenia Wolf <claire@yosyshq.com>)
- Files used : `ip/picorv32.v` (contains all picorv32_* modules; only `picorv32_axi` is instantiated)
- Language   : Verilog-2001, verified by inspection (no SV constructs)
- Adaptation : none — instantiated verbatim from `cnn_soc` top with named parameters/ports
- DFT check  : no scan/JTAG constructs found

## ctrl_fsm  (BLK-014)
- Repository : local: `cnn/rtl/ctrl_fsm.v` (project-internal, verified bit-exact per cnn/rtl_manifest.yaml)
- Licence    : project-internal
- Adaptation : none — byte-for-byte copy to `ip/ctrl_fsm.v`; instantiated by `cnn_infer` with
  `lf_done` tied to 1 and `lrom_data` driven from the CNN_EXP register (wiring change only, zero
  file edits)

## mac_datapath  (BLK-015)
- Repository : local: `cnn/rtl/mac_datapath.v` · Licence: project-internal · Adaptation: none
- Files used : `ip/mac_datapath.v`

## win_addr_gen  (BLK-016)
- Repository : local: `cnn/rtl/win_addr_gen.v` · Licence: project-internal · Adaptation: none
- Files used : `ip/win_addr_gen.v`

## fm_ram  (BLK-017)
- Repository : local: `cnn/rtl/fm_ram.v` · Licence: project-internal · Adaptation: none
- Files used : `ip/fm_ram.v`

## weight_rom  (BLK-018)
- Repository : local: `cnn/rtl/weight_rom.v` · Licence: project-internal · Adaptation: none
- Files used : `ip/weight_rom.v` (its `include "rtl/cnn_defs.vh" resolves via the byte-identical
  copy at `rtl/cnn_defs.vh`; its `WEIGHTS_HEX_FILE` default is overridden by `cnn_infer`'s
  parameter, which defaults to `../cnn/arch/golden_model/weights.hex` — cnn_soc-root-relative)

## sigmoid_lut  (BLK-019)
- Repository : local: `cnn/rtl/sigmoid_lut.v` · Licence: project-internal · Adaptation: none
- Files used : `ip/sigmoid_lut.v` (its `include "rtl/mnist_npu_defs.vh" resolves via the
  byte-identical copy at `rtl/mnist_npu_defs.vh`; `LUT_HEX_FILE` default overridden by
  `cnn_infer`, default `../cnn/rtl/sigmoid_lut.hex`)

## uart_tx  (BLK-013)
- Repository : local: `cnn/rtl/uart_tx.v` · Licence: project-internal · Adaptation: none
- Files used : `ip/uart_tx.v` (parameter `CLK_DIV` driven from `apb_uart`'s `UART_CLK_DIV`,
  default 868)

## Include-path copies (NOT IP, no licence claim)
- `rtl/cnn_defs.vh`, `rtl/mnist_npu_defs.vh` — byte-identical copies from `cnn/rtl/`, placed in
  `rtl/` so the reused files' `` `include "rtl/..." `` resolves when iverilog runs from the
  cnn_soc root (same mechanism the cnn project uses). Their `define values are cnn-root-relative
  DEFAULTS only — every SoC ROM overrides the hex path via instance parameters (arch.md §7.2).

## Fallback note
No external search was required: every entry above was verified from disk this stage
(byte-identical diff). Per the arch decision, no block is `unverified_candidate`.
