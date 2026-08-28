# IP Provenance — cnn_systolic (fe-rtl P2)

All reused blocks are **local, project-internal sources** (cnn_soc sibling project on
this machine) — no external fetch performed. Every copy was diffed byte-identical at
copy time (2026-08-28, P2). `cnn_soc` itself vendored picorv32 from
`skill-tests/ex6/rtl/picorv32.v` (ISC licence, © 2015 Claire Xenia Wolf) with its own
IP_PROVENANCE.md — carried forward.

## Reused verbatim (byte-identical copies, zero edits)

| File (this project) | Source (cnn_soc) | Licence | BLK |
|---|---|---|---|
| `ip/picorv32.v` | `cnn_soc/ip/picorv32.v` | ISC | BLK-018 (picorv32_axi) |
| `ip/uart_tx.v` | `cnn_soc/ip/uart_tx.v` | project-internal | BLK-019 |
| `rtl/axi_lite_interconnect.v` | `cnn_soc/rtl/axi_lite_interconnect.v` | project-internal | BLK-002 |
| `rtl/bootrom.v` | `cnn_soc/rtl/bootrom.v` | project-internal | BLK-003 |
| `rtl/sram.v` | `cnn_soc/rtl/sram.v` | project-internal | BLK-004 |
| `rtl/vec_rom.v` | `cnn_soc/rtl/vec_rom.v` | project-internal | BLK-005 |
| `rtl/axi2apb.v` | `cnn_soc/rtl/axi2apb.v` | project-internal | BLK-006 |
| `rtl/apb_uart.v` | `cnn_soc/rtl/apb_uart.v` | project-internal | BLK-007 |
| `rtl/apb_gpio.v` | `cnn_soc/rtl/apb_gpio.v` | project-internal | BLK-008 |
| `rtl/cnn_axi_slave.v` | `cnn_soc/rtl/cnn_axi_slave.v` | project-internal | BLK-009 |

## Reuse judgment notes (documented deviations, fe-rtl)

- **BLK-009 cnn_axi_slave — REUSED verbatim, not re-authored.** arch.md §4 lists
  BLK-009 as "custom (NEW)" but its spec (register map §7.2, FSM-001 sequencer,
  image write path with per-lane wstrb packing) is EXACTLY what the verified
  cnn_soc slave implements, and the brief mandates the register map + harness
  identical. The slave's IFI-003 core interface (core_rst_n/exp_label/img_*/
  pred/conf/verdict/busy/present) matches the arch's IFI-005 signal-for-signal.
  Reusing the proven file removes re-authoring risk. The arch's `start`/`done`
  strobes of IFI-005 are not separate ports in the reused slave (start is the
  START-register strobe, done is the `present` pulse) — no contract change.
- **img_waddr width 10 (0..783 pixel index)** maps directly to BLK-016's broadcast
  write (IFI-004); the shifted per-bank addresses are computed inside img_banks.
- **Memory implementation:** all accelerator memories (weight_rom, fm_ram,
  img_banks, p1_banks) and the shell memories (sram, bootrom, vec_rom) are
  behavioral Verilog arrays in RTL (sim) and are BLACKBOXED for the gate flow
  (synth bbox stubs in `synth/` — same module names, empty bodies; see
  `../synth/README.md`). This resolves OI-001/OI-003 for the front-end scope:
  real OpenRAM sky130 SRAM macros are a PnR/backend decision (macro selection,
  characterization, and the timing model land at PnR, not in the front-end
  netlist). The RTL interface (registered reads, single-cycle) matches the arch's
  macro abstraction.

## Not reused (replaced by new custom RTL, per the brief)

cnn_soc's `cnn_infer`, `image_buffer`, and the ip/ accelerator leaves
(`ctrl_fsm`, `mac_datapath`, `win_addr_gen`, `fm_ram`, `weight_rom`,
`sigmoid_lut`) are NOT carried over — the brief replaces the CNN datapath with
the BF16 systolic array + serial FP FC + piecewise sigmoid. New custom files:
`rtl/{fpu_fp32_add,fpu_fp32_mul,fpu_bf16_mul,fpu_bf16_round,fpu_bf16_expand,
systolic_array,conv_ctrl,pool_unit,fc_datapath,weight_rom,fm_ram,img_banks,
p1_banks,cnn_core,cnn_systolic}.v`.
