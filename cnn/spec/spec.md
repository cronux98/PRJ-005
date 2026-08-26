# cnn (mnist_npu v2) — Front-End Specification
Document ID: SPEC-CNN-v1.0 | Stage: fe-spec | Technology: see §2 (FPGA, not Sky130 — deviation documented)

## 1. Scope and Overview

`cnn` (product name `mnist_npu` v2, top module `cnn_npu`) is a tiny, inference-only MNIST digit
classifier accelerator. It implements a small convolutional neural network forward pass —
Conv1(3x3,1->8,pad1)-ReLU -> Pool1(2x2 max) -> Conv2(3x3,8->16,pad1)-ReLU -> Pool2(2x2 max) ->
FC1(784->32,sigmoid) -> FC2(32->10,sigmoid) — in 16-bit signed Q8.8 fixed-point arithmetic with
64-bit signed accumulation, using the same 65536-entry sigmoid lookup table (LUT) as v1 (no divider
circuit). All network weights, the 100-image demo dataset, and the expected labels are loaded into
on-chip memory at elaboration/synthesis time via `$readmemh`, from a frozen, pre-existing golden
reference package (`arch/golden_model/`). There is no training, no backpropagation, no weight
update, no host bus, and no firmware. After reset the design free-runs forever: it classifies image
0, holds the result on LEDs and over a UART line, then classifies image 1, and so on, wrapping from
image 99 back to image 0 indefinitely. This is externally the same product as v1 `mnist_npu`
(identical ports, UART line format, LED scheme, 100-image loop, `$readmemh` mechanism) — only the
internal datapath changes from MLP to CNN.

The **golden reference model** (`arch/golden_model/golden_ref_model.c`, C99, integer-only) is the
bit-exact behavioural contract this design must reproduce: predictions, confidences, verdicts and
the UART byte stream must match it exactly. The golden model was trained to 96.35% integer accuracy
on the full 10,000-image MNIST test set (9635 correct / 146 incorrect / 219 trash) and independently
cross-checked bit-identical against a numpy integer emulation (`tools/check_cnn.py`, 100/100 on the
first 100 images — see `WORKLOG.md`). This spec traces every functional behaviour back to that
model, which is FROZEN and MUST NOT be regenerated or edited by this stage or any downstream stage.

## 2. Global Constraints

| Constraint | Rule |
|---|---|
| Technology | **FPGA-synthesizable generic RTL.** Eventual target: Xilinx Artix-7 100T (Nexys A7 board). FPGA implementation (bitstream/timing closure/pin planning) is explicitly OUT OF SCOPE for fe-spec/fe-arch/fe-rtl; the design need only be *cleanly synthesizable*. |
| RTL language | **Pure Verilog-2001 or earlier / Verilog-2005.** No SystemVerilog, no VHDL. |
| Coding discipline | "Sky130-style" discipline is retained as a **style/rigor** reference only (no latches, no module-scope shared `integer`, disciplined always-block structure) — see §2.1 below for why the literal Sky130/130nm technology binding is NOT used. |
| Analog | None. No Sky130 or any other analog macro is instantiated. No black-box stubs are needed. |
| DFT | **None.** No scan, BIST, JTAG/TAP, MBIST, compression. |
| Host interface | **None.** No CSR/APB/AXI register block, no bootrom, no firmware. All program data enters via `$readmemh` memory initialisation only (REQ-019/020/021/022). |
| Tool execution | This stage **writes files only**. No simulator, synthesizer, or linter is invoked here. |
| Guessing | Missing mandatory input -> halt. Documented assumptions only where explicitly permitted (§11). |

### 2.1 Technology deviation from the fe-spec default (documented, not guessed)

Identical deviation to v1 `mnist_npu` (`mnist_npu/spec/spec.md` §2.1), restated here rather than
silently inherited: the `fe-spec` skill's default hard scope targets SkyWater Sky130 130 nm ASIC
tapeout and would normally halt (`SPEC-E004`) on a brief naming a non-Sky130 technology. This
project's commissioning brief **explicitly and deliberately** specifies an FPGA deployment context
(Nexys A7 / Artix-7 100T, FPGA work explicitly deferred/out-of-scope) — this is not an ambiguity or
a silent default, it is a direct, unambiguous instruction, consistent with the sibling v1 project.
No part of the brief asks for any Sky130-specific artifact. Accordingly: **this spec proceeds using
the fe-spec/fe-arch/fe-rtl artifact schemas, ID conventions, and coding rigor unchanged, but with
`technology: fpga_generic` instead of `sky130`,** recorded here, in `requirements.yaml`
(`project.technology`), and in `spec_manifest.yaml`. Downstream `fe-arch`/`fe-rtl` stages must carry
it forward unchanged.

## 3. Functional Description

1. **Network:** Conv1(3x3,1->8ch,pad=1,stride=1,ReLU) -> Pool1(2x2 max,stride=2) ->
   Conv2(3x3,8->16ch,pad=1,stride=1,ReLU) -> Pool2(2x2 max,stride=2) -> FC1(784->32,sigmoid) ->
   FC2(32->10,sigmoid). Forward pass (inference) only — REQ-001.
2. **Arithmetic:** 16-bit signed Q8.8 fixed point, 64-bit signed accumulation, bit-exact to the
   golden C model — REQ-002. See §5 and REQ-003..REQ-018 for the exact algorithm.
3. **Memory-resident program data:** weights (26,698 x 16-bit, layout below), 100 demo images
   (78,400 x 8-bit), and 100 expected labels (100 x 8-bit) are `$readmemh`-initialised from
   `arch/golden_model/{weights,images,labels}.hex` — REQ-019/020/021. The sigmoid LUT
   (65536 x 8-bit) is reused unchanged from v1 — REQ-022.
4. **Free-running control:** after reset, the design infers image 0, 1, ..., 99, then wraps to 0
   and repeats forever, with no external control signal — REQ-024.
5. **Pacing:** a parameterized hold (`HOLD_CYCLES`) keeps each result visible before the next
   image starts; a parameterized blink (`BLINK_CYCLES`) flashes LED[11] while a result is being
   computed — REQ-025/026/027.
6. **Outputs:** `led[9:0]` one-hot predicted digit (all off on TRASH), `led[10]` fail/trash flag,
   `led[11]` busy-blink, and a UART TX line per image in one of three exact ASCII formats —
   REQ-028/029/030/032.

### Weight layout (`weights.hex`, 26,698 Q8.8 words, one 4-hex-digit word per line)

| Region | Word count | Word-address range | Index formula |
|---|---|---|---|
| `conv1_w` | 72 (8 oc x 9 taps, 1 ic) | 0 .. 71 | `oc*9 + iy*3 + ix` |
| `conv1_b` | 8 | 72 .. 79 | `oc` |
| `conv2_w` | 1152 (16 oc x 8 ic x 9 taps) | 80 .. 1231 | `(oc*8+ic)*9 + iy*3 + ix` |
| `conv2_b` | 16 | 1232 .. 1247 | `oc` |
| `fc1_w` | 25088 (784 x 32) | 1248 .. 26335 | `i*32 + j` (input i -> hidden j) |
| `fc1_b` | 32 | 26336 .. 26367 | `j` |
| `fc2_w` | 320 (32 x 10) | 26368 .. 26687 | `j*10 + c` (hidden j -> output c) |
| `fc2_b` | 10 | 26688 .. 26697 | `c` |

Total 26,698 words, offsets as tabulated (REQ-013, REQ-019). `iy`/`ix` range 0..2 (3x3 tap
position). General conv-tap formula (both layers): `oc*IC*9 + ic*9 + iy*3 + ix`, `IC`=1 for conv1,
`IC`=8 for conv2.

## 4. External Interfaces

See `interfaces.yaml` for the full signal-level definition. Identical port set and semantics to v1
`mnist_npu`:

- **`sys_if` (IF-003):** `clk` (100 MHz nominal, CLK-001), `rst_n` (active-low, **synchronous**,
  RST-001).
- **`uart_tx_if` (IF-001):** `uart_tx` (output only). 115200 8N1, `CLK_DIV` = 868. No RX. Idles high
  (mark) outside of frame transmission — REQ-031/033.
- **`led_status_if` (IF-002):** `led[11:0]` (output only). Bit layout: `led[9:0]` one-hot
  predicted-digit, `led[10]` fail/trash, `led[11]` busy-blink — REQ-028/029/027.

No other external interface exists: no host bus, no register-mapped CSR block, no bootrom port, no
UART RX, no GPIO input, no interrupt line — REQ-024. See §8 for the resulting (empty)
error/interrupt/exception behaviour.

### UART line framing (byte-exact, REQ-032) — identical strings to v1

```
verdict 0 (CORRECT)  : "IMG %03u: This is number %u | confidence %u%% | expected %u | CORRECT\n"
verdict 1 (INCORRECT): "IMG %03u: This is number %u | confidence %u%% | expected %u | INCORRECT\n"
verdict 2 (TRASH)    : "IMG %03u: NOT A NUMBER | confidence %u%% | expected %u | TRASH\n"
```

`%03u` = image index 0..99, zero-padded to 3 ASCII decimal digits. All other `%u` fields are plain
ASCII decimal, no padding. `%%` is a literal `%`. Line terminator is a single `0x0A` (LF); no `0x0D`
(CR) is ever transmitted. These are the exact bytes `golden_ref_model.c`'s `printf` calls produce
(lines 239-245) — the RTL UART stream must match them byte-for-byte (VP-TOP-004/VP-UART-001).

## 5. Clock and Reset Architecture

- **One clock domain, `CD_CORE`**, `clk_core` (`clk` port), 100 MHz nominal / 10.000 ns period
  (CLK-001, ASM-002). No second domain exists — there is no UART RX, no external async input, and
  program data is loaded at elaboration time, not over a live bus. `cdc_plan.md` (produced in
  `fe-arch`) has zero crossings to plan.
- **One reset, `rst_n`**, active-low, **fully SYNCHRONOUS** (RST-001): every flop's reset term is
  evaluated only at `posedge clk`, i.e. `always @(posedge clk) if (!rst_n) ... else ...` — **not**
  `always @(posedge clk or negedge rst_n)`. This inherits v1's explicit, deliberate deviation from
  the `fe-spec`/`fe-arch`/`fe-rtl` skills' default reset template (async-assert / sync-de-assert):
  the project brief pins the port list as "clk, rst_n (sync active-low), led[11:0], uart_tx" and
  requires the design to be externally the same product as v1. `fe-arch`'s reset-synchroniser
  guidance and `fe-rtl`'s `rst_sync`/async-reset flop template do **not** apply to this design;
  `rtl_coding_guidelines.md` (fe-arch stage) must restate the synchronous-only template explicitly.
- Minimum reset assert width: 2 `clk_core` cycles (ASM-001) — sufficient for a purely synchronous
  single-domain design; no cross-domain de-assert ordering is needed (single domain).

## 6. Register Map

**None.** There is no host-visible register file, no CSR block, no APB/AXI slave of any kind
(REQ-024). This section is intentionally empty; it is not an omission.

## 7. Requirements

The full requirement set (37 items, all `priority: must`) is in `requirements.yaml`. Categories:

| Category | REQ-IDs |
|---|---|
| Functional — network/arithmetic contract | REQ-001..REQ-018 |
| Interface — memory-mapped ROM/RAM init | REQ-019, REQ-020, REQ-021, REQ-022, REQ-023 |
| Functional — free-running control | REQ-024 |
| Performance — pacing parameters | REQ-025, REQ-026, REQ-037 |
| Functional — outputs (LED) | REQ-027, REQ-028, REQ-029, REQ-030 |
| Interface — UART | REQ-031, REQ-032, REQ-033 |
| Clocking / Reset | REQ-034 |
| Compliance — language & synthesis | REQ-035, REQ-036 |

## 8. Error, Interrupt and Exception Behaviour

There are no interrupts (no host to interrupt) and no error-reporting interface. The only
"exception-like" condition in the product requirements is the **TRASH** classification
(confidence < 50%), which is not an error but a defined, always-legal third output state
(REQ-016/REQ-028): `led[9:0]` goes to all-zero and `led[10]` asserts, and the UART line uses the
"NOT A NUMBER ... TRASH" format (REQ-032). No image index, weight value, or LUT address can put the
design into an undefined state: the sigmoid LUT is defined for all 65536 possible addresses
(REQ-022), the accumulator is sized to never overflow for the full weight/activation value range
(REQ-017), and the image-index counter wraps modulo 100 by construction (REQ-024). FSM
illegal-state recovery (`default:` -> safe/reset state) is a coding-discipline requirement
(REQ-035) rather than a functionally reachable case.

## 9. Power and Area Targets

Not specified by the brief and not load-bearing for this small design (single MAC, one sigmoid LUT
ROM, weight/image/label ROMs, one feature-map RAM). No power or area numeric targets are set in
this stage; `fe-arch`'s `power_plan.md` documents a "no clock gating, single always-on domain"
strategy consistent with v1's approach, and estimates area only qualitatively.

## 10. IP Reuse Plan

| IPR-ID | Block | Decision | Source | Licence | Status |
|---|---|---|---|---|---|
| IPR-001 | `uart_tx` | reuse (verbatim copy from v1) | `mnist_npu/rtl/uart_tx.v` (this repo, sibling project, same author) | project-internal, no external licence | verified |
| IPR-002 | `uart_line_fmt` | reuse (verbatim copy from v1) | `mnist_npu/rtl/uart_line_fmt.v` | project-internal | verified |
| IPR-003 | `led_ctrl` | reuse (verbatim copy from v1) | `mnist_npu/rtl/led_ctrl.v` | project-internal | verified |
| IPR-004 | `sigmoid_lut` | reuse (verbatim copy from v1, contents unchanged) | `mnist_npu/rtl/sigmoid_lut.v` + generated `sigmoid_lut.hex` | project-internal | verified |

No external (GitHub) IP search was executed: the brief explicitly directs verbatim reuse of
same-repo sibling modules (`mnist_npu/rtl/*.v`), which is a stronger, already-verified source than
any external search could produce. The MAC datapath, conv/pool window-address generator, control
FSM, weight/image/label ROMs and feature-map RAM are all fully custom, CNN-specific, and have no
external reuse candidate.

## 11. Assumptions (ASM-###)

| ASM-ID | Statement | Requires confirmation |
|---|---|---|
| ASM-001 | Minimum reset assert width = 2 `clk_core` cycles | true |
| ASM-002 | Core clock = exactly 100 MHz (10.000 ns) | true |

Both are cosmetic/timing defaults with **zero effect on the bit-exact datapath contract**
(REQ-002). `HOLD_CYCLES`=50,000,000, `BLINK_CYCLES`=100,000, and `CLK_DIV`=868 are NOT recorded as
assumptions: they are explicit numeric values given directly by the project brief (task §5), not
defaults this stage invented — see REQ-025/026/031. Per `spec_manifest.yaml`, ASM-001/002 are
listed in `unconfirmed_assumptions` for `fe-arch`'s `ARCH-E012` gate; this project explicitly
acknowledges them (`assumptions_acknowledged: true`) so `fe-arch` may proceed without a human
round-trip, since neither can invalidate golden-model bit-exactness.

## 12. Open Issues (OI-###)

None. Top module name is fixed as `cnn_npu` (distinct from v1's `mnist_npu`, since both share this
repository) — this is a naming decision, not an open issue.

## 13. Verification Closure Criteria

See `verification_plan.md` §5 for the full countable list. Headline criteria: 0/100
pred/confidence/verdict mismatches against `expected.hex`, 0 UART byte mismatches, 0 LED-pattern
mismatches, 100% FSM state/arc coverage over one 100-image pass, and a documented bounded
simulation-cycle count under `iverilog`.

## 14. Glossary

- **Q8.8** — 16-bit signed fixed point, 8 integer bits + 8 fractional bits (value = raw/256).
- **acc64** — the 64-bit signed accumulator used for every conv/FC MAC reduction (REQ-002/017).
- **ReLU** — `h = max(z, 0)`, the conv/pool-path activation (REQ-006), no LUT.
- **sigma / sigmoid LUT** — `128 + trunc(128z/(256+|z|))`, the FC-path activation, unchanged from
  v1, implemented as a 65536x8 ROM (REQ-022).
- **verdict** — 0=CORRECT, 1=INCORRECT, 2=TRASH (REQ-016).
- **HOLD_CYCLES / BLINK_CYCLES / CLK_DIV** — the three pacing parameters (REQ-025/026/031).
- **Golden model** — `arch/golden_model/golden_ref_model.c` and its `.hex` companions; the frozen,
  pre-existing bit-exact behavioural contract this design must reproduce.
