# cnn_soc — FPGA Port Plan (Nexys A7 / Artix-7)

**Status:** PLAN ONLY — for Rinri's review. No RTL touched.
**Date:** 2026-08-27
**Author:** Suiseira (main agent), grounded in a direct read of `cnn_soc/rtl` + `cnn_soc/ip` + `out/pipeline_state.txt`.
**Target:** Digilent **Nexys A7** (Artix-7), per standing board preference.

---

## 1. Purpose & scope

Bring `cnn_soc` up on a **physical FPGA** so it can be demonstrated live to a thesis panel:
board boots → runs MNIST CNN inference → prints predictions over UART → shows the result on the LEDs.

This is **functional prototyping + demo**, and a genuine first pass through real synthesis. It is **not**
ASIC signoff and does **not** replace the Sky130 path — see §9.

### In scope
- A thin FPGA top **wrapper** around the existing `cnn_soc` top (no changes to the core design).
- Vivado constraints (clock + pins) for the Nexys A7.
- BRAM memory-init handling for the `$readmemh` ROMs.
- A reproducible Vivado build script producing utilisation + timing reports + a bitstream.
- On-board bring-up + evidence capture (UART log, LED behaviour, photo/screenshot).

### Out of scope (this plan)
- Any edit to `cnn_soc/rtl/` or `cnn_soc/ip/` (frozen — see §3).
- Interactive "draw-a-digit" input (needs a new `uart_rx` + firmware change → **Phase 6**, separate approval).
- ASIC synth/STA/PnR/GDS (a *separate* future workstream — also still to be done).
- Timing GLS.

---

## 2. Current state of cnn_soc (ground truth)

From `out/pipeline_state.txt` and the RTL:

| Item | State |
|---|---|
| P0 spec / P1 arch / P2 rtl / P3 firmware / P4 verify / P5 evidence | **DONE, all green** |
| Functional SoC verification | co-sim **100/100** images byte-exact vs golden (run-002) |
| Synthesis (yosys) | **not run** |
| STA / PnR / GDS (ASIC) | **not run** (only `sdc/` constraints authored) |
| FPGA implementation | **not started** (this plan) |

**Implication:** the FPGA build is the design's **first real synthesis on any target**. Expect the first
Vivado run to surface synth/timing issues that pure simulation never exercised — that is normal and useful.

---

## 3. Guiding principle — the ASIC RTL stays frozen

The verified `cnn_soc/rtl` + `cnn_soc/ip` are immutable evidence. The FPGA port lives in a **separate tree**
and *references* the core RTL read-only through a filelist. Nothing under `cnn_soc/rtl` or `cnn_soc/ip` is edited.
If a portability change ever proves unavoidable, it is done **only** in the FPGA wrapper or a clearly-marked
FPGA-only shim — never in the frozen core.

---

## 4. Portability audit (already done — grounded in the RTL)

`cnn_soc` was authored **FPGA-generic** (the RTL headers literally say `Technology: FPGA-generic (NOT Sky130)`),
which makes this port unusually low-risk:

| Check | Finding | FPGA impact |
|---|---|---|
| Internal tri-state / `inout` | **None** | ✅ none (the #1 FPGA blocker is absent) |
| Sky130 SRAM macros / blackboxes | **None** | ✅ every memory is an inferable `reg [..] mem [..]` array → maps to BRAM |
| Instantiated clock-gate cells | **None** | ✅ only `picorv32` `MUL_CLKGATE` param (default 0, behavioural) |
| PLL / DLL / analog | **None** | ✅ external clock straight in |
| Memory init | `$readmemh` (bootrom, weights, sigmoid LUT, vectors) | ⚠️ path handling needed (§7.2) — otherwise fine |
| Reset | fully **synchronous, active-low** (`rst_n`) | ⚠️ needs button debounce + reset synchroniser (§7.1) |

### On-chip memory budget (tally from the array declarations)

| Memory | Size |
|---|---|
| `sram.v` (32768 × 32) | 128 KB |
| `ip/sigmoid_lut.v` (65536 × 8) | 64 KB |
| `vec_rom.v` (78500 × 8) | ~77 KB |
| `bootrom.v` (4096 × 8) | 4 KB |
| `image_buffer.v` (784 × 8) | ~0.8 KB |
| **Total** | **~273 KB** |

- **XC7A100T** (A7-100T): ~4.86 Mbit ≈ **607 KB** BRAM → ~45% used. **Comfortable.**
- **XC7A50T** (A7-50T): ~2.70 Mbit ≈ **337 KB** BRAM → ~81% used. **Tight but likely fits.**

*(Paper estimate from the RTL, not a Vivado run — Phase 4 confirms it. Board variant is an open decision, §10.)*

---

## 5. Top-level interface (from `rtl/cnn_soc.v`)

```verilog
module cnn_soc #(
    parameter UART_CLK_DIV = 868,   // = round(100e6 / 115200)
    parameter BOOT_HEX_FILE, IMAGES_HEX_FILE, LABELS_HEX_FILE,
              WEIGHTS_HEX_FILE, LUT_HEX_FILE
)(
    input  wire        clk,      // CD_CORE, 100 MHz
    input  wire        rst_n,    // fully synchronous, active-low
    output wire        uart_tx,  // 115200 8N1
    output wire [11:0] led       // GPIO_OUT pattern
);
```

Only **four** ports, all output-or-clock/reset. Two happy accidents:
- Core clock is **100 MHz** — the Nexys A7 onboard oscillator is also **100 MHz** (direct match).
- `UART_CLK_DIV = 868` already yields **115200 baud** at 100 MHz — no change for a 100 MHz build.

**Consequence:** there is **no `uart_rx`**. Images are baked into `vec_rom`; firmware loops through them
automatically. The base demo therefore **auto-runs** — it is not interactive (see §8, Phase 6).

---

## 6. Demo model

**Base (Phases 1–5, no design change):**
Power on → bitstream boots picorv32 from bootrom → firmware walks the 100 baked images in `vec_rom` →
each prediction is printed over UART (`IMG NNN: This is number X | confidence Y% | expected Z | CORRECT`)
and reflected on `led[11:0]`. Panel sees a serial terminal filling with correct predictions + LED activity.

**Optional interactive (Phase 6, design change — separate approval):**
Add a `uart_rx` path + firmware to accept a streamed 28×28 image from a PC (or a webcam/host GUI), so a
panelist can hand-draw a digit and watch it classify. This edits the design, so it is deliberately **out**
of the frozen-RTL base scope.

---

## 7. Work breakdown

### 7.1 FPGA wrapper — `cnn_soc_fpga/rtl/cnn_soc_fpga_top.v`
- Instantiate `cnn_soc` (params overridden as in §7.2 / §7.3).
- **Clock:** drive `clk` from `CLK100MHZ`. If we down-clock (§7.3), add a `BUFG` + clock divider or an MMCM.
- **Reset:** board button (active-low `CPU_RESETN`, or a slide switch) → **debounce** → **2-FF synchroniser**
  → `rst_n`. Add a power-on reset (hold asserted ≥ a few cycles; spec ASM-001 wants ≥ 2).
- **Outputs:** `uart_tx` → USB-UART bridge pin; `led[11:0]` → LD0–LD11.
- **Heartbeat (nice-to-have):** blink LD15 off a free-running counter to prove the bitstream is live even
  before any UART traffic.

### 7.2 Memory init (the `$readmemh` ROMs)
- ROM paths are parameters/defines that are **cnn_soc-root-relative** (`sw/firmware.hex`,
  `../cnn/arch/golden_model/{images,labels,weights}.hex`, `../cnn/rtl/sigmoid_lut.hex`).
- For Vivado: **override the path parameters at the wrapper** to absolute paths, *or* `add_files` the `.hex`
  and reference by basename, *or* copy the hex set into `cnn_soc_fpga/mem/`. (Decide in Phase 2; absolute-path
  override is simplest and keeps the frozen tree read-only.)
- Confirm every array infers as **block RAM** (check the synth log for `RAMB36/RAMB18` and no "cannot infer
  RAM" warnings). Force `(* ram_style = "block" *)` in the *wrapper-visible* config only if an array mis-infers
  as distributed RAM (LUT blowup). The `image_buffer` READ-FIRST 1-cycle pattern already maps to simple-dual-port BRAM.

### 7.3 Clocking & timing target
- **Recommended: run the core at 50 MHz.** picorv32 + AXI + the CNN datapath may not close at 100 MHz on
  Artix-7 (-1 speed grade) on a first synth; 50 MHz is ample for a live demo.
- **Critical detail:** if the core runs at 50 MHz, `UART_CLK_DIV` must be **overridden to 434**
  (= round(50e6/115200)) or the terminal baud will be wrong. Keep `UART_CLK_DIV` and the real core clock in lockstep.
- Option to attempt 100 MHz later once 50 MHz is proven.

### 7.4 Constraints — `cnn_soc_fpga/constraints/nexys_a7.xdc`
- **Pins are copied verbatim from the official Digilent *Nexys-A7 Master XDC*** — not hand-typed from memory.
  Signals to map: `CLK100MHZ`, `CPU_RESETN` (or a switch), `UART_RXD_OUT` (= our `uart_tx`), `LD0..LD11`,
  optional `LD15` heartbeat + a start button.
- Indicative anchors (verify against the master XDC): `CLK100MHZ = E3`, `CPU_RESETN = C12`,
  `UART_RXD_OUT = D4`. LED/button banks taken from the same file.
- `create_clock -period 10.000 [get_ports CLK100MHZ]` (or 20.000 for a 50 MHz derived clock); mark the
  debounced reset button as a false path / async input.

### 7.5 Vivado build — `cnn_soc_fpga/scripts/build_fpga.tcl` (non-project batch flow)
- `read_verilog` the filelist (`filelist_fpga.f` = `../cnn_soc/ip/*` + `../cnn_soc/rtl/*` + wrapper),
  `read_xdc`, `synth_design -top cnn_soc_fpga_top -part xc7a100tcsg324-1`.
- `opt_design → place_design → route_design`.
- `report_utilization`, `report_timing_summary`, `write_bitstream`.
- Emit into a **versioned** `cnn_soc_fpga/fpga/run-NNN/` with an append-only `iterations.log` (mirrors the
  house evidence pattern). Bitstream + reports are the evidence; large intermediates gitignored.

### 7.6 Bring-up — `cnn_soc_fpga/docs/bringup.md`
1. Program the board (`open_hw_manager` / `program_hw_devices`).
2. Serial terminal @ **115200 8N1** on the USB-UART COM port.
3. Confirm: heartbeat LED blinks → boot → 100 prediction lines stream → LEDs track predictions.
4. Capture evidence: UART transcript + a photo/screenshot of the board.

---

## 8. Phasing & effort

| Phase | Work | Depends on | Est. |
|---|---|---|---|
| 0 | Install free Vivado (ML Standard / ex-WebPACK) + Nexys A7 board files + master XDC | — | ~½ day (mostly download) |
| 1 | FPGA wrapper (`cnn_soc_fpga_top`) | 0 | ½ day |
| 2 | Memory-init / BRAM inference | 1 | ½ day |
| 3 | Constraints (clock + XDC) | 1 | ¼ day |
| 4 | Vivado synth→impl→bitstream + reports | 1–3 | ½–1 day (build + timing iteration) |
| 5 | On-board bring-up + evidence | 4 + board | ½ day |
| 6 | *(optional)* interactive `uart_rx` demo — **design change, separate approval** | 5 | +1–2 days |

**Base demo (Phases 1–5): ~2–4 focused days** after Vivado is installed. Low risk given the §4 audit.

---

## 9. Honest framing for the thesis (why do this at all)

- **FPGA proves a different thing than ASIC.** FPGA = "it functionally works in real hardware at speed";
  Sky130 synth/STA/PnR = "it's manufacturable, meets timing/area/power". A strong thesis shows **both**.
- The ASIC half's value is **not** software — it's tapeout-grade signoff. Don't undersell it to the panel.
- **FPGA-working ≠ ASIC-signed-off.** A design can pass on FPGA and still fail ASIC timing/DRC. Present the
  Sky130 results alongside; FPGA **complements**, it does not substitute.
- Precedent: `aukhalid/evpix_rv32` (a B.Sc. thesis) did exactly this dual FPGA + Sky130 story — good template.

---

## 10. Open decisions for Rinri

1. **Board variant** — Nexys A7-**100T** (comfortable, recommended) or A7-**50T** (tight at ~81% BRAM)?
2. **Core clock** — **50 MHz** (safe, recommended; remember `UART_CLK_DIV=434`) or attempt 100 MHz?
3. **Demo mode** — base **auto-run** (no design change, recommended first) or go straight for **Phase 6**
   interactive draw-a-digit (design change)?
4. **vec_rom size** — keep all 100 baked images, or trim to a handful for a lighter/faster loop?

---

## 11. Proposed directory layout (nothing created yet)

```
PRJ-005/
├── cnn_soc/                 # FROZEN — untouched, referenced read-only
└── cnn_soc_fpga/            # NEW — all FPGA-only work lives here
    ├── rtl/
    │   └── cnn_soc_fpga_top.v      # wrapper: clk, reset sync/debounce, heartbeat
    ├── constraints/
    │   └── nexys_a7.xdc            # from Digilent master XDC
    ├── scripts/
    │   ├── build_fpga.tcl          # non-project Vivado flow
    │   └── filelist_fpga.f         # ../cnn_soc/ip + ../cnn_soc/rtl + wrapper
    ├── mem/                        # hex init handling (or absolute-path override)
    ├── fpga/run-NNN/               # versioned util+timing reports + bitstream (evidence)
    ├── docs/bringup.md
    └── README.md
```

---

## 12. Non-goals (explicit)

- No edits to frozen `cnn_soc/rtl` or `cnn_soc/ip`.
- Not a replacement for the Sky130 flow (synth/STA/PnR still to be done separately).
- No timing GLS; no SDF.

**Next step:** Rinri picks the §10 options → I execute Phase 1 onward (Vivado install is the gate), writing up
each run as versioned evidence and reporting honestly on the first-synth surprises.
