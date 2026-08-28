# cnn_systolic — Sky130 BF16 Systolic CNN Accelerator SoC: Front-End Specification
Document ID: SPEC-CNN-SYSTOLIC-v1.0 | Stage: fe-spec | Technology: SkyWater Sky130, 130 nm
Input: PRJ-005/cnn_systolic BRIEF.md (Rinri, 2026-08-28 18:24Z, locked decisions 1-9) + WORKLOG.md

## 1. Scope and Overview

`cnn_systolic` (top module `cnn_systolic`) is a **Sky130 ASIC** SoC wrapping a new BF16/FP32 CNN
accelerator in the verified `cnn_soc` picorv32 AXI→APB shell. The accelerator replaces the Q8.8
single-MAC core of `cnn_soc` with:

- an **8×8 BF16 systolic array** (64 PEs, weight-stationary, **conv layers only**),
- a **serial floating-point FC datapath** (FC1 784→32, FC2 32→10; BF16 multiply + FP32
  accumulate, single-MAC style),
- a **piecewise-linear sigmoid** (exact dyadic breakpoints/coefficients pinned in fe-arch,
  mirrored bit-exactly in the FP golden model),

so that C firmware boots from the bootrom, feeds one image at a time, reads back the result
registers, and prints the identical golden UART line format + drives the LEDs — **with the
cnn_soc register map, UART line format, 7-bit confidence encoding, memory map and harness
(`tb_cnn_soc`, `run_soc.sh`, UART diff) reused unchanged** (BRIEF.md "Architectural mandates").

**Bit-exactness contract (BRIEF.md decision 2, 8):** the FP golden reference model (C, integer
arithmetic) accumulates in the **exact order of the 8×8 systolic array** (conv) and the **serial
FC datapath**, using BF16 operands (weights + activations), FP32 accumulation, round-to-nearest-
even at every FP32 operation, subnormal flush-to-zero (pinned, fe-arch), and the pinned piecewise
sigmoid. Weights are exported from `../cnn/arch/golden_model/weights_float.npz` (float masters of
the trained network — **no retraining**) via float32→BF16 round-to-nearest-even; the golden uses
the identical converted values. The 100-image expected outputs are **regenerated** from the new FP
golden (the old Q8.8 `expected_outputs.txt` does NOT apply — BRIEF.md decision 9).

**Scope pin (BRIEF.md decision 5):** front-end pipeline only — fe-spec → fe-arch → fe-rtl →
fe-yosys → fe-opensta → fe-firmware → functional verify + coverage. **NO fe-sby (formal), NO
fe-gls, NO RTL↔netlist equivalence** — explicitly dropped by Rinri. No PnR.

**References (READ-ONLY, never modified):** `../cnn/` (trained network, float weight masters,
golden vectors, MNIST data) and `../cnn_soc/` (SoC shell, register map, firmware, harness, SDC
skeleton). All new artifacts live in `cnn_systolic/`.

## 2. Global Constraints

| Constraint | Rule |
|---|---|
| Technology | **SkyWater SKY130 open PDK, 130 nm** only. Std-cell target `sky130_fd_sc_hd` (1.8 V core). STA corner: Sky130B tt (nominal), per fe-opensta skill, at the P3 stage. |
| RTL language | **Pure Verilog-2001 (IEEE 1364-2001) or earlier.** No SystemVerilog, no VHDL. |
| Analog | Existing Sky130 macros (SRAM macros) may be **instantiated as black boxes** with a Verilog stub + SDC constraint. **No custom analog design.** |
| DFT | **None.** No scan, BIST, JTAG/TAP, MBIST, compression. Debug is register-mapped test mode + GPIO observability only. |
| Tool execution | This stage **writes files only**. No simulator, synthesizer, linter, formal tool, or waveform viewer is invoked. |
| Guessing | Missing mandatory input → halt (`FE-SPEC HALTED`). Documented assumptions (ASM-###) per §11; under the 2026-08-28 18:31Z autonomy override, unconfirmed assumptions are logged + best-judgment decisions applied and flagged (WORKLOG.md J1-J8). |
| Memory-init | `$readmemh` remains the mechanism for bootrom, vec_rom, weight banks (BF16), and any ROM content. SRAM macros (FM RAM, banks, shell SRAM) are initialized by writes (stack/RAM) or `$readmemh` (ROM role) per macro type. |
| Formal/GLS/equiv | **Explicitly out of scope** (Rinri dropped fe-sby, fe-gls, RTL↔netlist equivalence). |

### 2.1 Deviations from the fe-spec defaults (documented, binding)

1. **Reset: fully SYNCHRONOUS active-low `rst_n`** — not the skill default async-assert /
   sync-de-assert. Same project precedent as `cnn`/`cnn_soc` (every flop
   `always @(posedge clk) if (!rst_n) ... else ...`). Binding because the SoC shell (reused
   verbatim from `cnn_soc`, including `picorv32_axi`) is synchronous-reset; changing reset style
   would force edits to verbatim files. Restated in RST-001 / REQ-035.
2. **Core clock exactly 100.000 MHz nominal** (10.000 ns) — precedent (cnn/cnn_soc CLK-001,
   ASM-002); also the brief's STA target ("nominal 100 MHz core clock").
3. **FP32 subnormal flush-to-zero (FTZ)** in the FP datapath (fp32 add/mul results and BF16
   conversion inputs): documented deviation from full IEEE-754 subnormal support; golden mirrors
   FTZ exactly (J2). Range analysis (fe-arch §5) shows FTZ never fires for this network.
4. **Per-image BUSY bound re-derived:** compute ≈ 748,653 cycles/image → `BUSY ≤ 750,000`
   (cnn_soc's 667,208 bound no longer applies; REQ-021/REQ-037, J6). Firmware poll guard constant
   (3,000,000 iterations) is unchanged but its comment is updated in P4.

## 3. Functional Description

1. **SoC shell (reused verbatim from `../cnn_soc`, provenance recorded in fe-arch §10):**
   `picorv32_axi` (RV32I, ENABLE_MUL=0, ENABLE_DIV=0, simplified AXI4-Lite master),
   `axi_lite_interconnect`, `bootrom` (4 KB, `$readmemh`), `sram` (128 KB behavioral RAM),
   `vec_rom` (78,500 B image/label source), `axi2apb`, `apb_uart` (115200 8N1 via reused
   `uart_tx`), `apb_gpio` (LEDs). **Replaced** (not reused): `cnn_axi_slave` + `cnn_infer` +
   `mac_datapath` + `sigmoid_lut` are superseded by the new accelerator (new `cnn_axi_slave`,
   systolic engine, pool unit, serial FC datapath, piecewise sigmoid).
2. **New accelerator datapath (all BF16 operands / FP32 accumulate):**
   - Conv1: 3×3, 1→8 ch, pad=1, stride=1, ReLU → 28×28×8. 72 MACs per output position (8 oc ×
     9 taps) → **2 array passes of 64** (pass A: taps 0..7; pass B: tap 8) (REQ-024).
   - Pool1: 2×2 max, stride=2 → 14×14×8.
   - Conv2: 3×3, 8→16 ch, pad=1, stride=1, ReLU → 14×14×16. 1,152 MACs per output position →
     **18 passes of 64** (2 oc-groups × 9 (iy,ix) tap positions; 8 input channels per pass)
     (REQ-024).
   - Pool2: 2×2 max, stride=2 → 7×7×16 = 784.
   - FC1: 784→32, serial MAC (BF16 mult + FP32 acc), piecewise sigmoid → 32 BF16.
   - FC2: 32→10, serial MAC, piecewise sigmoid → 10 FP32 → sigma256 quantization → argmax
     (lowest-index ties) → confidence 0..100, verdict 0/1/2.
3. **Boot flow (§8):** identical to cnn_soc: reset → CPU fetches at `0x0000_0000` (bootrom,
   firmware baked, executes in place) → boot stub (`sp=0x0003_0000; jal main`) → 100-image demo
   loop → spin forever.
4. **Per-image flow (firmware):** read image i (784 B, vec_rom) + label i → write `CNN_EXP` →
   copy 784 B to `CNN_IMG` (word writes, little-endian pixel packing) → write `CNN_CTRL.START` →
   poll `CNN_STATUS.DONE` (guard: 3,000,000 iterations; compute ≤ 750,000 cycles) → read
   `CNN_RESULT` → print the exact golden UART line → write LED pattern → next image.
5. **Single-shot (REQ-021):** the new `cnn_axi_slave` sequencer holds the accelerator core in
   synchronous reset (parked) at SoC reset and after each result; `START` (write-1 strobe)
   launches exactly one inference; on completion the sequencer latches pred/conf/verdict into
   `CNN_RESULT`, sets `DONE`, clears `BUSY`, and re-parks. `PARK` (soft-reset/abort) semantics
   identical to cnn_soc.
6. **Outputs:** top-level `uart_tx` (115200 8N1, idle-high mark) and `led[11:0]`; firmware
   formats the UART line (three variants) and LED pattern exactly as cnn_soc firmware does.

### 3.1 Memory map (32-bit, byte-addressed, little-endian; identical to cnn_soc — binding)

| Base | Size | Region | Access | Notes |
|---|---|---|---|---|
| `0x0000_0000` | 4 KB | **bootrom** | RO/exec | Firmware `.text`+`.rodata` baked (`$readmemh`, `BOOT_HEX_FILE`); executes in place. |
| `0x0001_0000` | 128 KB | **SRAM** | RW | Stack only (pure-ROM firmware); stack top `0x0003_0000` = `STACKADDR`. |
| `0x1000_0000` | 78,500 B | **vec_rom** | RO | Images `+0x0000..+0x1323F` (78,400 B), labels `+0x13240..+0x132A3` (100 B); `$readmemh` from the frozen golden image/label files (relocated copies in `arch/golden_model/`: `stimulus.hex`, `labels.hex`). |
| `0x4000_0000` | window | **AXI2APB** | — | `+0x0000` UART_TX (W) / UART_STAT (R); `+0x1000` GPIO_OUT (RW) → `led[11:0]`. |
| `0x5000_0000` | window | **cnn_axi_slave** | RW | Register map §6.3; image buffer at `+0x100..+0x40F` (784 B). |

Decode rule (combinational, `addr[31:28]`): `0x0` = bootrom/SRAM sub-window, `0x1` = vec_rom,
`0x4` = AXI2APB, `0x5` = cnn; all other addresses **unmapped**: read returns 0, write ignored,
handshake completes — the CPU never hangs.

## 4. External Interfaces

See `interfaces.yaml` for signal-level definitions. Top-level ports of `cnn_systolic` (four,
identical to cnn_soc):

- **`sys_if`:** `clk` (100 MHz nominal, CLK-001), `rst_n` (active-low, **fully synchronous**,
  RST-001).
- **`uart_tx_if` (IF-001):** `uart_tx` (output). 115200 8N1, `CLK_DIV`=868 default (top
  parameter `UART_CLK_DIV`). No RX. Idles high (mark) between frames and during reset.
- **`led_status_if` (IF-002):** `led[11:0]` (output) = `GPIO_OUT[11:0]`; encoding per REQ-032.
- **Internal IF-003:** simplified AXI4-Lite master (picorv32_axi port list; contract: AW+W
  together, completion = `bvalid||rvalid`, no BRESP/RRESP/ID; slaves respond 1 cycle after
  accept, AXI2APB ≤ 3 cycles; never wait for bready/rready).
- **Internal IF-004:** APB bus (bridge → peripherals): `PSEL/PENABLE/PWRITE/PADDR[11:0]/
  PWDATA[31:0]/PRDATA[31:0]/PREADY`; no PSTRB.
- **Internal IF-005:** `cnn_core_if` (cnn_axi_slave ↔ accelerator core): `core_rst_n` (park),
  `start`, `exp_label[3:0]`, image-buffer write port (`img_waddr[9:0]`, `img_wdata[7:0]`,
  `img_we`; the slave broadcasts the word write to the 9 pre-shifted image banks),
  `pred[3:0]`, `conf[6:0]`, `verdict[1:0]`, `busy`, `done`.

### 4.1 UART line framing (byte-exact, REQ-030) — identical strings to the cnn_soc harness

```
verdict 0 (CORRECT)  : "IMG %03u: This is number %u | confidence %u%% | expected %u | CORRECT\n"
verdict 1 (INCORRECT): "IMG %03u: This is number %u | confidence %u%% | expected %u | INCORRECT\n"
verdict 2 (TRASH)    : "IMG %03u: NOT A NUMBER | confidence %u%% | expected %u | TRASH\n"
```

`%03u` = image index 0..99 zero-padded; other `%u` plain decimal; terminator = single `0x0A`,
never `0x0D`. The diff target is the **regenerated FP** `arch/golden_model/expected_outputs.txt`
(first 100 lines).

## 5. Clock and Reset Architecture

- **One clock domain, `CD_CORE`**, `clk`, 100 MHz nominal / 10.000 ns (CLK-001, ASM-002). No
  second domain: no UART RX, no camera, no external async input. **Zero CDC paths**.
- **One reset, `rst_n`**, active-low, **fully synchronous** (RST-001, deviation §2.1): every flop
  `always @(posedge clk) if (!rst_n) ... else ...`. Fans out to `picorv32.resetn` and every
  slave. Minimum assert width 2 cycles (ASM-001); the SoC TB asserts ≥ 10 cycles. During reset:
  `led[11:0]==12'h000`, `uart_tx==1'b1`. No reset synchroniser (single domain).

## 6. Register Map

All registers 32-bit, word-aligned, little-endian (RV32). Reset value of every register = 0
unless stated. **Identical to cnn_soc §6 (binding, harness reuse).**

### 6.1 APB UART (`0x4000_0000`, via AXI2APB)

| Offset | Name | Width | Access | Reset | Fields |
|---|---|---|---|---|---|
| `+0x00` | `UART_TX` | 8 | W | 0 | `[7:0]` byte; write pulses `utx_valid` 1 cycle. Write-while-busy: byte dropped (REQ-014). |
| `+0x04` | `UART_STAT` | 1 | R | 0 | `[0]` BUSY = `!utx_ready`; `[31:1]` read 0. |

### 6.2 APB GPIO/LED (`0x4000_1000`)

| Offset | Name | Width | Access | Reset | Fields |
|---|---|---|---|---|---|
| `+0x00` | `GPIO_OUT` | 12 | RW | 0 | `[11:0]` → `led[11:0]`; any write updates the full 12-bit value. |

### 6.3 CNN AXI slave (`0x5000_0000`)

| Offset | Name | Width | Access | Reset | Fields |
|---|---|---|---|---|---|
| `+0x00` | `CNN_CTRL` | 2 | RW | 0 | `[0]` START — write-1 strobe (reads 0); ignored while PARK=1 or BUSY=1. `[1]` PARK — RW: 1 = hold core in reset + clear BUSY/DONE (abort). |
| `+0x04` | `CNN_STATUS` | 2 | RO | 0 | `[0]` BUSY: 1 from START-accept until result latch. `[1]` DONE: set on result latch; cleared by next START or PARK write. `[31:2]` read 0. |
| `+0x08` | `CNN_RESULT` | 18 | RO | 0 | `[3:0]` pred; `[14:8]` confidence 0..100 (**7-bit encoding**: `(sigma256_best * 100) >> 8`, sigma256 = `trunc(σ·256 + 0.5)`); `[17:16]` verdict 0/1/2. Latched on done. |
| `+0x0C` | `CNN_EXP` | 4 | WO | 0 | `[3:0]` expected label; drives the hardware verdict comparison. Reads return 0. |
| `+0x100..+0x40F` | `CNN_IMG` | 8×784 | WO | — | 784-byte image buffer (row-major, byte p = pixel value p). Word write to `+0x100+4k` packs pixels `4k..4k+3` into bytes `[7:0],[15:8],[23:16],[31:24]` (LE, wstrb lanes). Internally broadcast to the 9 pre-shifted image banks (fe-arch). Reads return 0. CPU writes only while parked (REQ-020). |

## 7. Requirements

The full set (41 items, `priority: must` except where noted) is in `requirements.yaml`.
Categories:

| Category | REQ-IDs |
|---|---|
| Functional — SoC scope, CPU, boot | REQ-001..REQ-004 |
| Interface — AXI contract, decode, memory map | REQ-005..REQ-012 |
| Interface — peripherals | REQ-013..REQ-015 |
| Interface — CNN slave | REQ-016..REQ-020 |
| Functional — single-shot | REQ-021 |
| Functional — FP arithmetic contract | REQ-022, REQ-023, REQ-027 |
| Functional — systolic array + tiling | REQ-024, REQ-025 |
| Functional — serial FC + sigmoid | REQ-026 |
| Functional — weights + golden | REQ-028, REQ-029 |
| Functional — firmware behaviour | REQ-030..REQ-033 |
| Clocking / Reset | REQ-034, REQ-035 |
| Interface — widths | REQ-036 |
| Performance | REQ-037 |
| Memories | REQ-039, REQ-040 |
| Compliance | REQ-038, REQ-041 |

## 8. Error, Interrupt and Exception Behaviour

- **Interrupts: none.** `ENABLE_IRQ=0`, `irq=32'd0` (REQ-033). Polling only.
- **Unmapped bus addresses:** read returns 0, write ignored, handshake completes (REQ-006).
- **UART_TX write while BUSY:** byte dropped; firmware polls `UART_STAT[0]` first (REQ-014).
- **START while BUSY or PARK:** ignored (REQ-016).
- **PARK written mid-inference (abort):** core held in reset immediately; partial results
  discarded; BUSY/DONE cleared; re-start requires PARK=0 then START (REQ-016).
- **TRASH classification** (confidence < 50) is a defined third output state, not an error.
- **FP datapath errors:** FP32 overflow to ±Inf and subnormal results are **unreachable by
  range analysis** (fe-arch §5); subnormal flush-to-zero is pinned behaviour, not an error
  (REQ-022, J2).
- **FSM illegal states:** every FSM recovers via `default:` to its reset state (REQ-038).

## 9. Power and Area Targets

No numeric power/area targets set by the brief. Qualitative drivers (fe-arch `power_plan.md`
documents the single always-on domain + clock-gating candidates):

- **Memories dominate:** weight banks 8×4,096×16 ≈ 524 Kbit (banking overhead over the naive
  26,698×16 ≈ 427 Kbit — J5), FM RAM 8,192×16 ≈ 131 Kbit, image banks 9×1,024×8 ≈ 74 Kbit,
  pool1 banks 8×256×16 ≈ 33 Kbit, plus shell: SRAM 128 KB, vec_rom 78,500 B, bootrom 4 KB.
- **Logic:** 64 PEs × (2×16-bit weight regs + 32-bit acc + BF16 mult + FP32 add) is the dominant
  logic block; the shell CPU/bus is small. No gate budget exists to contradict; §3 arithmetic
  sanity checks pass (single 100 MHz domain, one outstanding transaction, no throughput
  ceiling beyond the compute bound of REQ-037).

## 10. IP Reuse Plan

| IPR-ID | Block | Decision | Source | Licence | Status |
|---|---|---|---|---|---|
| IPR-001 | `picorv32_axi` (+ core + adapter) | reuse (verbatim) | `cnn_soc/ip/picorv32.v` (vendored from skill-tests/ex6, ISC header) | ISC (© 2015 Claire Xenia Wolf) | verified (IP_PROVENANCE.md read this session) |
| IPR-002 | Shell: `axi_lite_interconnect`, `bootrom`, `sram`, `vec_rom`, `axi2apb`, `apb_uart`, `apb_gpio` | reuse (verbatim, zero edits) | `cnn_soc/rtl/*.v` (project-internal, read this session) | project-internal | verified |
| IPR-003 | `uart_tx` (APB UART shell) | reuse (verbatim, `CLK_DIV` param) | `cnn_soc/ip/uart_tx.v` (from `cnn/rtl/uart_tx.v`) | project-internal | verified |
| IPR-004 | Frozen golden data: MNIST test images/labels, `weights_float.npz` (float masters) | reuse (frozen, read-only) | `../cnn/arch/golden_model/` + `../cnn/data/` | project-internal | verified |
| IPR-005 | Sky130 SRAM macros (OpenRAM `sky130_sram_*`) for FM RAM / banks / shell SRAM mapping | blackbox (PDK-verify at fe-rtl) | Sky130 open PDK, OpenRAM-generated | Apache-2.0 (OpenRAM)/PDK | unverified_candidate — cell names + sizes must be verified against the installed PDK at fe-rtl (OI-001); fallback: flop arrays |

No external (GitHub) search was executed: the brief directs verbatim reuse of local verified
project sources (stronger than any external candidate, same precedent as cnn_soc). No external
repo URL is claimed anywhere. All new accelerator blocks (`cnn_axi_slave`, systolic engine,
pool unit, serial FC datapath, piecewise sigmoid, weight banks, FM RAM, image banks, pool1
banks) are **custom** — no block is `undecided`.

## 11. Assumptions (ASM-###)

| ASM-ID | Statement | Requires confirmation |
|---|---|---|
| ASM-001 | Minimum reset assert width = 2 `clk` cycles (SoC TB asserts ≥ 10 cycles — cnn_soc precedent). | true |
| ASM-002 | Core clock exactly 100.000 MHz (10.000 ns) — cnn/cnn_soc precedent, brief STA target. | true |
| ASM-003 | FP32 subnormal flush-to-zero (FTZ) policy in the FP datapath (J2). | true |
| ASM-004 | Confidence quantization: `sigma256 = trunc(σ·256 + 0.5)` (round-half-up), `conf = (sigma256_best·100)>>8`, TRASH iff `conf < 50` (J3/REQ-027). | true |
| ASM-005 | Piecewise sigmoid: dyadic breakpoints {0,1/4,1/2,3/4,1,3/2,2,3,4,6,8,12,16,24} approximating the TRAINED rational sigmoid act_float(z)=0.5+0.5z/(1+|z|) (NOT logistic), dyadic coefficients, exact FP32 bit patterns pinned in fe-arch (piecewise_sigmoid.md) (J3). | true |
| ASM-006 | Accumulate-order pins for the systolic array and serial FC (the bit-exactness contract) (J4). | true |
| ASM-007 | Memory banking plan + SRAM macro sizes (J5); exact OpenRAM cell availability PDK-verified at fe-rtl (OI-001). | true |
| ASM-008 | Per-image compute ≈ 748,653 cycles; BUSY ≤ 750,000; firmware poll guard 3,000,000 iterations unchanged (J6). | true |
| ASM-009 | BF16 export = float64→float32 (RN-even) → BF16 (RN-even, FTZ); defined in `export_bf16.py`; golden consumes `weights_bf16.hex` (REQ-028, J1). | true |

All ASM entries are acknowledged with `assumptions_acknowledged: true` in `spec_manifest.yaml`
under the 2026-08-28 18:31Z autonomy override (documented judgment, flagged in the final
report; cnn_soc precedent for the acknowledgement mechanism).

## 12. Open Issues (OI-###)

| OI-ID | Description | Blocks | Owner |
|---|---|---|---|
| OI-001 | Sky130 SRAM macro availability/sizes (OpenRAM `sky130_sram_*`: 8,192×16 FM, 8×256×16 p1 banks, 9×1,024×8 img banks, 8×4,096×16 weight banks) — cell names/sizes must be verified against the installed PDK at fe-rtl; fallback = flop arrays (area cost documented in fe-arch). | REQ-039, REQ-040 | fe-rtl |
| OI-002 | BF16 network accuracy vs the Q8.8 baseline (96.35% full-set): measured when the FP golden first runs (P1); regenerated expected outputs are the contract regardless of the number (BRIEF decision 9). | REQ-028, REQ-029 | fe-arch (P1) |
| OI-003 | 128 KB shell `sram.v` is a behavioral RAM (verbatim reuse); its Sky130 physical mapping (OpenRAM macro vs flops) is an fe-yosys decision; area risk documented (J8). | REQ-009 | fe-yosys |

None of OI-001..003 is blocking for fe-arch; `blocking_open_issues` is empty.

## 13. Verification Closure Criteria

See `verification_plan.md` §5 for the countable list. Headline gates (harness-reused G1-G5 +
FP-specific G6-G8): G1 UART diff vs the regenerated FP `expected_outputs.txt` (100 lines) = 0
mismatches; G2 `CNN_RESULT`/`CNN_EXP` vs regenerated `expected.hex` (400 words) = 0 mismatches;
G3 LED encoding = 0 mismatches at all 100 presented instants; G4 reset hygiene = 0 violations;
G5 boot liveness within the bounded budgets; G6 golden reproducibility (re-run produces
byte-identical expected files); G7 FP datapath unit checks (BF16 conversion, fp32 add/mul,
piecewise sigmoid segments, sigma256 mapping, argmax/conf/verdict — hand-derived directed
vectors, 0 mismatches); G8 accumulate-order cross-check (independent numpy twin vs golden over
the 100-image set = 0 mismatches). Plus 0 orphan REQs/VP items and an `iverilog -g2001`
compile-only clean gate.

## 14. Glossary

- **BF16** — bfloat16: 1 sign + 8 exponent + 7 mantissa bits; expanded to FP32 exactly.
- **FP32** — IEEE-754 single precision; the accumulate format; RN-even rounding; FTZ subnormals.
- **Systolic array** — 8×8 PE grid, weight-stationary; activations stream left→right (wavefront,
  1 column/cycle); partial sums accumulate in each PE over its column; acc persists across
  sub-passes; results drain at the right edge.
- **Pass / sub-pass** — one 8-cycle wavefront through the array (64 PEs × 1 MAC each).
  conv1 = 2 passes/pixel (taps 0..7, then tap 8); conv2 = 18 passes/pixel (2 oc-groups × 9
  (iy,ix) positions; columns = 8 input channels).
- **sigma256** — `trunc(σ·256+0.5)`, integer 0..256; the quantization of the FC2 sigmoid output
  feeding argmax/confidence (REQ-027).
- **Piecewise sigmoid** — the pinned piecewise-linear σ(z) (dyadic breakpoints/coefficients,
  exact in FP32) replacing the old rational-sigmoid LUT; no divider, no LUT (REQ-026).
- **Park / parked** — holding the accelerator core in synchronous reset so it stays idle until
  START (single-shot, REQ-021).
- **FP golden** — `arch/golden_model/golden_ref_model.c`: integer-only C model mirroring the
  systolic/FC accumulate order bit-exactly (REQ-029).
- **FTZ** — flush-to-zero: any FP32 result (or BF16 conversion input) with magnitude < 2^-126 is
  replaced by ±0 (ASM-003).
- **Simplified AXI4-Lite** — the picorv32_axi adapter's reduced AXI master (AW+W together,
  completion = bvalid||rvalid, no BRESP/RRESP/ID) (IF-003).
