# cnn_soc — fe-rtl deliverable README

Stage: fe-rtl | Input: `arch/` (fe-arch output, commit `6c41a61` decisions) | Technology:
FPGA-generic (Xilinx Artix-7 100T / Nexys A7 eventual target) — see `spec/spec.md` §2.1 and
`arch/arch.md` §2.1 for the documented, explicit deviation from the pipeline's Sky130 default.
No EDA tool was executed by this stage (AGENTS.md: the user runs tools); the **compile-only
gate below is the first thing to run**.

## Directory layout

```
rtl/            one module per file (cnn_soc.v is the top; filename == module name + .v)
rtl/cnn_defs.vh, rtl/mnist_npu_defs.vh
                byte-identical copies of the cnn project's define files, placed here so the
                reused files' own `include "rtl/..." resolves when iverilog runs from the
                cnn_soc root (same mechanism the cnn project uses — cnn/doc/README.md)
ip/             byte-for-byte reused IP (8 .v files + IP_PROVENANCE.md) — NOT rewritten
filelist.f      every synthesised file (rtl/*.v + ip/*.v), dependency order; no rtl/blackbox/
                (none exists — this design instantiates zero analog macros)
sdc/            sdc_spec.json — design-facts SDC spec for fe-opensta (this stage does not
                hand-author a .sdc)
doc/            this file
rtl_manifest.yaml
```

No `rtl/blackbox/` directory exists. No `tb/` directory: verification is a later stage; this
stage's own exit gate is a **compile-only** sanity check, not a functional simulation.

## Module inventory (19 blocks = 11 custom + 8 reused)

| BLK | Module | File | Source |
|---|---|---|---|
| BLK-001 | `cnn_soc` | `rtl/cnn_soc.v` | custom (top, structural) |
| BLK-002 | `axi_lite_interconnect` | `rtl/axi_lite_interconnect.v` | custom |
| BLK-003 | `bootrom` | `rtl/bootrom.v` | custom |
| BLK-004 | `sram` | `rtl/sram.v` | custom |
| BLK-005 | `vec_rom` | `rtl/vec_rom.v` | custom |
| BLK-006 | `axi2apb` | `rtl/axi2apb.v` | custom |
| BLK-007 | `apb_uart` | `rtl/apb_uart.v` | custom (wraps BLK-013) |
| BLK-008 | `apb_gpio` | `rtl/apb_gpio.v` | custom |
| BLK-009 | `cnn_axi_slave` | `rtl/cnn_axi_slave.v` | custom |
| BLK-010 | `cnn_infer` | `rtl/cnn_infer.v` | custom (wires BLK-011..019) |
| BLK-011 | `image_buffer` | `rtl/image_buffer.v` | custom |
| BLK-012 | `picorv32_axi` | `ip/picorv32.v` | reuse, verbatim (ISC) |
| BLK-013 | `uart_tx` | `ip/uart_tx.v` | reuse, verbatim |
| BLK-014 | `ctrl_fsm` | `ip/ctrl_fsm.v` | reuse, verbatim |
| BLK-015 | `mac_datapath` | `ip/mac_datapath.v` | reuse, verbatim |
| BLK-016 | `win_addr_gen` | `ip/win_addr_gen.v` | reuse, verbatim |
| BLK-017 | `fm_ram` | `ip/fm_ram.v` | reuse, verbatim |
| BLK-018 | `weight_rom` | `ip/weight_rom.v` | reuse, verbatim |
| BLK-019 | `sigmoid_lut` | `ip/sigmoid_lut.v` | reuse, verbatim |

Reused files are byte-identical to their sources (diffed at copy time — `ip/IP_PROVENANCE.md`):
`cnn/rtl/{ctrl_fsm,mac_datapath,win_addr_gen,fm_ram,weight_rom,sigmoid_lut,uart_tx}.v` and
`skill-tests/ex6/rtl/picorv32.v`. **Zero edits** to any reused file: the SoC's integration
deltas (lf_done tie, label substitution, structural LUT addressing, CLK_DIV parameter) are
wiring/parameter decisions at `cnn_infer`/`apb_uart`/`cnn_soc` (arch.md §4 BLK-010).

## Reused-file include mechanism

`ip/weight_rom.v` `` `include "rtl/cnn_defs.vh" `` and `ip/sigmoid_lut.v`
`` `include "rtl/mnist_npu_defs.vh" `` resolve via the byte-identical copies in `rtl/` when
iverilog runs from the cnn_soc root (their `define values are cnn-root-relative DEFAULTS only —
every SoC ROM overrides the hex path via instance parameters; see below).

## Memory initialisation mechanism (arch.md §7.2; PLAN.md R5)

Every `$readmemh`-initialised ROM defaults its hex-file path from a **module parameter**,
expressed relative to the **cnn_soc project root**:

| Parameter | Default value | Carrier |
|---|---|---|
| `BOOT_HEX_FILE` | `sw/firmware.hex` (later stage's artifact; $readmemh runs at vvp runtime, so the compile gate passes without it) | `cnn_soc` → `bootrom` |
| `IMAGES_HEX_FILE` | `../cnn/arch/golden_model/images.hex` | `cnn_soc` → `vec_rom` |
| `LABELS_HEX_FILE` | `../cnn/arch/golden_model/labels.hex` | `cnn_soc` → `vec_rom` |
| `WEIGHTS_HEX_FILE` | `../cnn/arch/golden_model/weights.hex` | `cnn_soc` → `cnn_infer` → `weight_rom` |
| `LUT_HEX_FILE` | `../cnn/rtl/sigmoid_lut.hex` | `cnn_soc` → `cnn_infer` → `sigmoid_lut` |

Overriding any of the five is a normal Verilog parameter override at `cnn_soc`'s instantiation —
no RTL source edit is needed. All simulation/synthesis invocations must run **from the cnn_soc
project root**.

**FPGA bring-up note (out of scope this stage):** Vivado's own `$readmemh` support in
behavioural `initial` blocks generally works for BRAM inference; if it does not in practice, a
`.coe`/`.mem` conversion of the same hex content is the standard fallback, deferred to the
(out-of-scope) FPGA bring-up stage.

## Pinned fe-rtl decisions honoured (arch.md §2/§6, PLAN.md)

- **Response timing**: memory/register slaves write accept at N → `bvalid` N+1; read accept at N
  → `rvalid`/`rdata` N+2 (registered read). AXI2APB accepts only during its APB ACCESS phase →
  `bvalid`/`rvalid` = accept+1, no buffering (adapter holds address/data; picorv32.v:2786-2787).
  All response pulses are exactly 1 cycle — never wait for bready/rready.
- **Single-shot sequencer** (FSM-003, `cnn_axi_slave`): START write-1 strobe launches when
  PARK=0 && !BUSY; PARK write aborts; DONE cleared on next START; result latched on `lc_present`;
  core re-parked ≤ 2 cycles after the present cycle; `core_rst_n = !(seq_park || park_reg)`.
- **Image-buffer writes** (CNN_IMG): word writes serialised into 4 byte-writes on the single
  8-bit buffer port (drain counter); the next CNN_IMG write is backpressured until the drain
  completes. wstrb policy per arch.md §7.3: register targets update on any write; CNN_IMG/SRAM
  honour lanes; RO memories ignore writes.
- **Fully synchronous active-low `rst_n`** everywhere (rtl_coding_guidelines.md §3; REQ-029) —
  the documented deviation from the pipeline's async-reset default. Every flop is
  `always @(posedge clk) if (!rst_n) ... else ...`; `negedge rst_n` appears nowhere.

## Build / compile check (the fe-rtl exit gate)

Run from the `cnn_soc` project root:

```
iverilog -g2005 -s cnn_soc -o /tmp/cnn_soc_check.vvp -f filelist.f
```

This must compile clean (0 errors) for fe-rtl to be considered complete. No vectors are run (no
testbench exists yet); this is a **syntax/elaboration-only** sanity check. Note the gate is also
satisfied with `iverilog -g2005 -f filelist.f` (no `-s`): compile-only does not require a top.

## Golden model (frozen, reference-only — NOT reproduced this stage)

The executable golden contract is the pre-existing CNN package
(`cnn/arch/golden_model/`, commit `e7569dbd`): `golden_ref_model.c`, `weights.hex`,
`images.hex`, `labels.hex`, `expected.hex` (400 words), `expected_outputs.txt` (first 100 lines
= the SoC demo set, PLAN.md §9 G1). The SoC adds no arithmetic — no new C model is authored and
nothing is regenerated (binding instruction; arch.md §11).

## Next steps (later stages, not run by fe-rtl)

1. Compile gate (above).
2. Lint: `verilator --lint-only -Wall -Wno-fatal $(cat filelist.f)` (note: picorv32.v is
   lint-noisy by nature; treat its warnings separately).
3. fe-firmware: pure-ROM firmware (0 .data/.bss, ≤ 4 KB, `ld -m elf32lriscv`, hex →
   `sw/firmware.hex`), then the compile gate still passes and vvp runs become meaningful.
4. Verification stage (G1–G5): SoC TB + UART bit-level decoder, diff vs `expected_outputs.txt`
   lines 1..100, result registers vs `expected.hex`.
5. SDC: `python3 <fe-opensta>/scripts/gen_sdc.py sdc/sdc_spec.json sdc/cnn_soc.sdc` then
   fe-opensta QA.
6. Synthesise: fe-yosys with `filelist.f`, then fe-opensta for STA.

Open issues: none (arch.md §14: 0 OIs; this stage raised none — OI-011 is the next free ID).
