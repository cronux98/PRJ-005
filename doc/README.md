# rinriAI — RTL (fe-rtl stage)

Online-learning MLP accelerator IP: 2-layer MLP (FEATURES × HIDDEN × CLASSES),
online SGD training per sample, firmware-driven via APB4, byte-stream sample feed,
accuracy counters readable from firmware and simulation. Sky130 130 nm,
`sky130_fd_sc_hd`, 1.8 V, single clock domain `clk_core` (50 MHz), synchronous
active-low reset `rst_n`. Pure Verilog-2001/2005, no DFT, no external IP.

## Pipeline position

```
fe-spec (spec/) → fe-arch (arch/) → fe-rtl (this) → fe-yosys → fe-gls →
fe-opensta (SDC from sdc/sdc_spec.json) → fe-sby → fe-cocotb/fe-regression
```

## File layout

| Path | Content |
|---|---|
| `rtl/*.v` | One synthesizable module per file. Authoritative inventory: `rtl_manifest.yaml`. |
| `rtl/blackbox/` | Simulation-only stubs. **Excluded** from `filelist.f` and synthesis. Currently empty — this design uses no analog/macro black boxes. |
| `filelist.f` | Synthesis file list for fe-yosys (excludes `rtl/blackbox/`). |
| `sdc/sdc_spec.json` | Design-facts SDC spec (fe-opensta schema). fe-opensta's `gen_sdc.py` authors the `.sdc`; fe-rtl never hand-writes SDC. |
| `tb/tb_learn_accel.v` | Source-only pure-Verilog testbench (never executed by this stage). |
| `ip/IP_PROVENANCE.md` | IP reuse record — all blocks are custom. |
| `doc/README.md` | This file. |

## Module inventory

BLK-001 `learn_accel` (top) · BLK-002 `apb_regs` · BLK-003 `sample_stream` ·
BLK-004 `learner` · BLK-005 `weight_ram` · BLK-006 `stats` · BLK-007 `div_seq`.
All custom (no external IP). Defaults: FEATURES=784, HIDDEN=32, CLASSES=10,
W_TOT=25450. The design is parameterized; the golden model and testbench exercise
the tiny configuration FEATURES=4, HIDDEN=4, CLASSES=2, lr_shift=0 (see
`arch/golden_model/README.md`).

## Commands (the USER runs these; this stage never executes tools)

```bash
# Lint (from project root)
verilator --lint-only -Wall $(cat filelist.f)

# Simulate the golden-model testbench (reads arch/golden_model/{stimulus,expected}.hex)
iverilog -g2001 -Wall -o sim $(cat filelist.f) tb/tb_learn_accel.v && vvp sim

# Golden reference model cross-check (C, integer-only)
gcc -std=c99 -O2 -Wall -Wextra -o gm arch/golden_model/golden_ref_model.c \
    && ./gm > got.txt && diff -u arch/golden_model/expected_outputs.txt got.txt

# SDC generation + QA (fe-opensta owns SDC authoring)
python3 <fe-opensta>/scripts/gen_sdc.py sdc/sdc_spec.json sdc/rinriAI.sdc
bash    <fe-opensta>/scripts/qa_sdc.sh  learn_accel <netlist> sdc/rinriAI.sdc

# Synthesis
#   fe-yosys reads filelist.f (rtl/*.v only; rtl/blackbox/ excluded)
```

## SDC intent (sdc/sdc_spec.json)

- One clock: `clk_core`, 20.000 ns (ASM-001/009). Uncertainty 1.000 ns (5 % of
  period, ASM-009). `latency: 1.500` is the template default — review against the
  actual clock topology at integration.
- No generated clocks: power_plan.md PWR-001..004 are enable-based RTL gating with
  tool-inferred ICG; no explicit ICG cells are instantiated (if one is ever added,
  it must be `sky130_fd_sc_hd__dlclkp_1` non-scan, verified against the installed
  PDK, and added to `generated_clocks`).
- I/O delay 6.000 ns on all APB4 and stream inputs/outputs (ASM-009), 0.050 pF load
  on `prdata`.
- Zero CDC paths → no `clock_groups_async`, no false paths, no multicycle paths.
- STA corners (fe-opensta convention): typical `sky130_fd_sc_hd__tt_025C_1v80`,
  setup-critical `ss_100C_1v60`, hold-critical `ff_n40C_1v95`.

## Design notes

- Bit-exactness contract: `arch/arch.md` §5 + `arch/golden_model/golden_ref_model.c`.
  Rounding is truncation toward zero (`trunc_pow2`), saturation `sat16`; the sigmoid
  is the integer rational approximation σ = 128 + trunc(128·z/(256+|z|)) via BLK-007.
- Two accepted deviations from arch text, both documented as open issues in
  `rtl_manifest.yaml` and `arch/arch.md` §14: OI-005 (IFI-002 `pred` signal added in
  RTL), OI-008 (`accept_en` includes `!sample_valid` to close a stream-overwrite
  window). Also OI-006 (single-owner memory write block) and OI-007 (W_F=12 pinned).
- Reset: synchronous active-low (ASM-002); all flops reset; MEM-002 (pixel RAM) is
  reset-exempt under the write-before-read protocol (documented in its module).
