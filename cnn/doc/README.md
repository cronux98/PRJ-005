# cnn (mnist_npu v2) — fe-rtl deliverable README

Stage: fe-rtl | Input: `arch/` (fe-arch output) | Technology: FPGA-generic (Xilinx Artix-7 100T /
Nexys A7 eventual target) — see `spec/spec.md` §2.1 and `arch/arch.md` §2.1 for the documented,
explicit deviation from the pipeline's Sky130 default. No tool was executed by this stage beyond
the mandatory `iverilog` compile-only sanity check (below) and re-running the frozen golden model
to confirm reproducibility; the user runs everything else.

## Directory layout

```
rtl/            one module per file (cnn_npu.v is the top; filename == module name + .v)
ip/             empty — reuse from v1 was verbatim file copies into rtl/, not vendored IP + wrapper
filelist.f      every synthesised file (rtl/*.v), no rtl/blackbox/ (none exists — no analog macros)
sdc/            sdc_spec.json — design-facts SDC spec for fe-opensta (this stage does not
                hand-author a .sdc)
doc/            this file
rtl_manifest.yaml
```

No `rtl/blackbox/` directory exists: this design instantiates zero Sky130 (or any) analog macros —
there is nothing to stub. No `tb/` directory: verification is a separate later stage (task
brief §6/§7); this stage's own exit gate is a **compile-only** sanity check, not a functional
simulation.

## Reused-from-v1 files (byte-for-byte, per task instruction)

`rtl/uart_tx.v`, `rtl/uart_line_fmt.v`, `rtl/led_ctrl.v`, `rtl/sigmoid_lut.v`,
`rtl/sigmoid_lut.hex`, `rtl/mnist_npu_defs.vh` were copied unchanged from `mnist_npu/rtl/` (diffed
byte-identical at copy time — see `WORKLOG.md`). `mnist_npu_defs.vh` is kept alongside the new
`cnn_defs.vh` specifically so `sigmoid_lut.v`'s own `` `include "rtl/mnist_npu_defs.vh" `` resolves
without any edit to the reused file. The **one** integration-level deviation: `cnn_npu`'s top-level
`BLINK_CYCLES` parameter defaults to 100,000 (REQ-026, fixing the v1 defect where a 5,000,000
default made the blink invisible in the ~7 ms busy window) and is passed to `led_ctrl` via an
explicit instance parameter override — `led_ctrl.v`'s own file-local default (5,000,000) is
untouched.

## Memory initialisation mechanism

Every `$readmemh`-initialised ROM/RAM defaults its hex-file-path parameter from `` `define ``s,
expressed relative to the `cnn` project root:

| Parameter | Default value | Source |
|---|---|---|
| `WEIGHTS_HEX_FILE` | `arch/golden_model/weights.hex` | `rtl/cnn_defs.vh` (frozen golden package) |
| `IMAGES_HEX_FILE`  | `arch/golden_model/images.hex`  | `rtl/cnn_defs.vh` (frozen golden package) |
| `LABELS_HEX_FILE`  | `arch/golden_model/labels.hex`  | `rtl/cnn_defs.vh` (frozen golden package) |
| `LUT_HEX_FILE`     | `rtl/sigmoid_lut.hex`           | `rtl/mnist_npu_defs.vh` (reused unchanged from v1) |

Every simulation/synthesis invocation that reads these files must run **from the `cnn` project
root**. Overriding any of the four is a normal Verilog parameter override at `cnn_npu`'s
instantiation — no RTL source edit is needed.

**FPGA bring-up note (out of scope this stage):** identical caveat to v1 — Vivado's own
`$readmemh` support in behavioural `initial` blocks generally works for BRAM inference; if it does
not in practice, a `.coe`/`.mem` conversion of the same hex content is the standard fallback,
deferred to the (explicitly out-of-scope) FPGA bring-up stage.

## Feature-map RAM (new vs v1)

A single `fm_ram` instance (7,840 x 16-bit signed) replaces v1's per-layer approach with a
two-region ping-pong layout — Region A `[0:6271]`, Region B `[6272:7839]` — documented exhaustively
in `arch/arch.md` §7.1, including the hazard-free reuse proof (no write ever precedes the last read
of the data it would overwrite). `win_addr_gen` (new, BLK-012) computes every layer's address
formula from `ctrl_fsm`'s loop counters, including the 3x3 zero-padding boundary check for
conv1/conv2 taps.

## Build / compile check (the fe-rtl exit gate)

Run from the `cnn` project root:

```
iverilog -g2005 -s cnn_npu -o /tmp/cnn_check.vvp -f filelist.f
```

This must compile clean (0 errors) for fe-rtl to be considered complete. No vectors are run (no
testbench exists yet); this is a **syntax/elaboration-only** sanity check.

## Golden model (frozen, reproduced not regenerated)

```
gcc -std=c99 -O2 -Wall -Wextra -o gm arch/golden_model/golden_ref_model.c
./gm .   # from the cnn project root
```

Reproduces `arch/golden_model/{expected.hex,images.hex,labels.hex,expected_outputs.txt}` in place,
byte-identical to the committed files (96.35% accuracy on the full 10,000-image set). This was
re-run during both the fe-arch and fe-rtl stages — see `WORKLOG.md`.

## Next steps (later stages, not run by fe-rtl)

1. Lint: `verilator --lint-only -Wall $(cat filelist.f)`
2. Simulate (once a TB exists): `iverilog -g2001 -o sim $(cat filelist.f) tb/tb_cnn_npu.v && vvp sim`
3. Compare: `./gm . && diff -u arch/golden_model/expected_outputs.txt got.txt`
4. SDC: `python3 <fe-opensta>/scripts/gen_sdc.py sdc/sdc_spec.json sdc/cnn_npu.sdc && bash <fe-opensta>/scripts/qa_sdc.sh cnn_npu <netlist> sdc/cnn_npu.sdc`
5. Synthesise: fe-yosys with `filelist.f`, then fe-opensta for STA

Open issues: none.
