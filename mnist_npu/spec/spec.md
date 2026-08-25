# mnist_npu — Front-End Specification
Document ID: SPEC-MNIST_NPU-v1.0 | Stage: fe-spec | Technology: see §2 (FPGA, not Sky130 — deviation documented)

## 1. Scope and Overview

`mnist_npu` is a tiny, inference-only MNIST digit classifier accelerator. It implements a
784-32-10 multilayer perceptron (MLP) forward pass in 16-bit signed Q8.8 fixed-point arithmetic,
using a 65536-entry lookup table (LUT) for the sigmoid activation (no divider circuit). All
network weights, the 100-image demo dataset, and the expected labels are loaded into on-chip
memory at elaboration/synthesis time via `$readmemh`, from a frozen, pre-existing golden reference
package (`arch/golden_model/`). There is no training, no backpropagation, no weight update, no
host bus, and no firmware. After reset the design free-runs forever: it classifies image 0, holds
the result on LEDs and over a UART line, then classifies image 1, and so on, wrapping from image 99
back to image 0 indefinitely.

The **golden reference model** (`arch/golden_model/golden_ref_model.c`, C99, integer-only) is the
bit-exact behavioural contract this design must reproduce: predictions, confidences, verdicts and
the UART byte stream must match it exactly. The golden model was validated at 92.25% accuracy on
the full 10,000-image MNIST test set (9225 correct / 270 incorrect / 505 trash) and independently
cross-checked bit-identical against a numpy integer emulation on the first 100 images (see
`arch/golden_model/README.md`). This spec traces every functional behaviour back to that model.

## 2. Global Constraints

| Constraint | Rule |
|---|---|
| Technology | **FPGA-synthesizable generic RTL.** Eventual target: Xilinx Artix-7 100T (Nexys A7 board). FPGA implementation (bitstream/timing closure/pin planning) is explicitly OUT OF SCOPE for fe-spec/fe-arch/fe-rtl; the design need only be *cleanly synthesizable*. |
| RTL language | **Pure Verilog-2001 or earlier / Verilog-2005.** No SystemVerilog, no VHDL. |
| Coding discipline | "Sky130-style" discipline is retained as a **style/rigor** reference only (no latches, no module-scope shared `integer`, disciplined always-block structure) — see §2.1 below for why the literal Sky130/130nm technology binding is NOT used. |
| Analog | None. No Sky130 or any other analog macro is instantiated. No black-box stubs are needed. |
| DFT | **None.** No scan, BIST, JTAG/TAP, MBIST, compression. |
| Host interface | **None.** No CSR/APB/AXI register block, no bootrom, no firmware. All program data enters via `$readmemh` memory initialisation only (REQ-012/013/014). |
| Tool execution | This stage **writes files only**. No simulator, synthesizer, or linter is invoked here. |
| Guessing | Missing mandatory input -> halt. Documented assumptions only where explicitly permitted (§11). |

### 2.1 Technology deviation from the fe-spec default (documented, not guessed)

The `fe-spec` skill's default hard scope targets SkyWater Sky130 130 nm ASIC tapeout and would
normally halt (`SPEC-E004`) on a brief naming a non-Sky130 technology. This project's commissioning
brief **explicitly and deliberately** specifies an FPGA deployment context (Nexys A7 / Artix-7
100T, FPGA work explicitly deferred/out-of-scope) rather than an ASIC tapeout flow — this is not an
ambiguity or a silent default, it is a direct, unambiguous instruction. No part of the brief asks
for any Sky130-specific artifact (no PDK cell names, no analog black boxes, no liberty/SDC corner
names, no tapeout-oriented DFT policy) — every place the upstream skills reference Sky130
specifically is either not exercised by this design (analog macros, DFT) or is kept
technology-neutral in this project's artifacts (clock/reset architecture, coding discipline,
SDC-intent JSON schema). Accordingly: **this spec proceeds using the fe-spec/fe-arch/fe-rtl
artifact schemas, ID conventions, and coding rigor unchanged, but with `technology: fpga_generic`
instead of `sky130`,** and calls this out explicitly here, in `requirements.yaml`
(`project.technology`), and in `spec_manifest.yaml` rather than silently overriding the skill's
default. This is recorded as a deviation, not a silent guess, and downstream `fe-arch`/`fe-rtl`
stages must carry it forward unchanged (see `arch_manifest.yaml`/`rtl_manifest.yaml` `technology:`
fields in their respective stages).

## 3. Functional Description

1. **Network:** 784-32-10 fully-connected MLP. Layer 1: 784 inputs -> 32 hidden units (sigmoid).
   Layer 2: 32 hidden -> 10 outputs (sigmoid). Forward pass (inference) only — REQ-001.
2. **Arithmetic:** 16-bit signed Q8.8 fixed point throughout, bit-exact to the golden C model —
   REQ-002. See §5 for the full data-flow and REQ-003..REQ-011/028/029 for the exact algorithm.
3. **Memory-resident program data:** weights (25,450 x 16-bit), 100 demo images (78,400 x 8-bit),
   and 100 expected labels (100 x 8-bit) are `$readmemh`-initialised from
   `arch/golden_model/{weights,images,labels}.hex` — REQ-012/013/014.
4. **Free-running control:** after reset, the design infers image 0, 1, ..., 99, then wraps to 0
   and repeats forever, with no external control signal — REQ-015.
5. **Pacing:** a parameterized hold (`HOLD_CYCLES`) keeps each result visible before the next
   image starts; a parameterized blink (`BLINK_CYCLES`) flashes LED[11] while a result is being
   computed — REQ-016/019/020.
6. **Outputs:** `led[9:0]` one-hot predicted digit (all off on TRASH), `led[10]` fail/trash flag,
   `led[11]` busy-blink, and a UART TX line per image in one of three exact ASCII formats —
   REQ-017/018/021/022.

## 4. External Interfaces

See `interfaces.yaml` for the full signal-level definition. Summary:

- **`sys_if` (IF-003):** `clk` (100 MHz nominal, CLK-001), `rst_n` (active-low, **synchronous**,
  RST-001 — see §5 for why this deviates from the fe-spec reset default).
- **`uart_tx_if` (IF-001):** `uart_tx` (output only). 115200 8N1, parameterized `CLK_DIV`. No RX.
  Idles high (mark) outside of frame transmission — REQ-021/031.
- **`led_status_if` (IF-002):** `led[11:0]` (output only). Bit layout: `led[9:0]` one-hot
  predicted-digit, `led[10]` fail/trash, `led[11]` busy-blink — REQ-017/018/019.

No other external interface exists: no host bus, no register-mapped CSR block, no bootrom port, no
UART RX, no GPIO input, no interrupt line. This is intentional (REQ-015) — see §8 for the resulting
(empty) error/interrupt/exception behaviour.

### UART line framing (byte-exact, REQ-022)

```
verdict 0 (CORRECT)  : "IMG %03u: This is number %u | confidence %u%% | expected %u | CORRECT\n"
verdict 1 (INCORRECT): "IMG %03u: This is number %u | confidence %u%% | expected %u | INCORRECT\n"
verdict 2 (TRASH)    : "IMG %03u: NOT A NUMBER | confidence %u%% | expected %u | TRASH\n"
```

`%03u` = image index 0..99, zero-padded to 3 ASCII decimal digits. All other `%u` fields are plain
ASCII decimal, no padding. `%%` is a literal `%`. Line terminator is a single `0x0A` (LF); no `0x0D`
(CR) is ever transmitted. These are the exact bytes `golden_ref_model.c`'s `printf` calls produce
(see `arch/golden_model/golden_ref_model.c` lines 171-177) — the RTL UART stream must match them
byte-for-byte (VP-TOP-004/VP-UART-001).

## 5. Clock and Reset Architecture

- **One clock domain, `CD_CORE`**, `clk_core` (`clk` port), 100 MHz nominal / 10.000 ns period
  (CLK-001, ASM-002). No second domain exists — there is no UART RX, no external async input, and
  program data is loaded at elaboration time, not over a live bus. Consequently `cdc_plan.md`
  (produced in `fe-arch`) has zero crossings to plan; it exists to satisfy the pipeline's own
  process requirement, not because this design needs one.
- **One reset, `rst_n`**, active-low, **fully SYNCHRONOUS** (RST-001): every flop's reset term is
  evaluated only at `posedge clk`, i.e. `always @(posedge clk) if (!rst_n) ... else ...` — **not**
  `always @(posedge clk or negedge rst_n)`. This is an explicit, deliberate deviation from the
  `fe-spec`/`fe-arch`/`fe-rtl` skills' default reset template (async-assert / sync-de-assert),
  driven directly by the project brief ("Single clock domain, synchronous active-low reset (no
  async reset)"). `fe-arch`'s reset-synchroniser guidance and `fe-rtl`'s `rst_sync`/async-reset
  flop template do **not** apply to this design; `rtl_coding_guidelines.md` (fe-arch stage) must
  restate the synchronous-only template explicitly so a fresh `fe-rtl` agent does not default back
  to the skill's own async-reset example.
- Minimum reset assert width: 2 `clk_core` cycles (ASM-001) — sufficient for a purely synchronous
  single-domain design; no cross-domain de-assert ordering is needed (single domain).

## 6. Register Map

**None.** There is no host-visible register file, no CSR block, no APB/AXI slave of any kind
(REQ-015). This section is intentionally empty; it is not an omission.

## 7. Requirements

The full requirement set (30 items, all `priority: must`) is in `requirements.yaml`. Categories:

| Category | REQ-IDs |
|---|---|
| Functional — network/arithmetic contract | REQ-001..REQ-011, REQ-028, REQ-029 |
| Interface — memory-mapped ROM init | REQ-012, REQ-013, REQ-014 |
| Functional — free-running control | REQ-015 |
| Performance — pacing parameters | REQ-016, REQ-020, REQ-026 |
| Functional — outputs (LED) | REQ-017, REQ-018, REQ-019, REQ-030 |
| Interface — UART | REQ-021, REQ-022, REQ-031 |
| Clocking / Reset | REQ-023 |
| Compliance — language & synthesis | REQ-024, REQ-025 |

## 8. Error, Interrupt and Exception Behaviour

There are no interrupts (no host to interrupt) and no error-reporting interface. The only
"exception-like" condition in the product requirements is the **TRASH** classification
(confidence < 50%), which is not an error but a defined, always-legal third output state
(REQ-011/REQ-017): `led[9:0]` goes to all-zero and `led[10]` asserts, and the UART line uses the
"NOT A NUMBER ... TRASH" format (REQ-022). No image index, weight value, or LUT address can put the
design into an undefined state: the LUT is defined for all 65536 possible addresses (REQ-006), the
accumulator is sized to never overflow for the full weight/pixel value range (REQ-028), and the
image-index counter wraps modulo 100 by construction (REQ-015). FSM illegal-state recovery
(`default:` -> safe/reset state) is a coding-discipline requirement (REQ-024) rather than a
functionally reachable case, since the FSM's own transition table is fully enumerated.

## 9. Power and Area Targets

Not specified by the brief and not load-bearing for this small design (single MAC, one LUT ROM,
three small ROMs, one 32-word RAM). No power or area numeric targets are set in this stage;
`fe-arch`'s `power_plan.md` documents a "no clock gating, single always-on domain" strategy
consistent with the brief's simplicity requirement, and estimates area only qualitatively (§15 of
`arch.md`).

## 10. IP Reuse Plan

| IPR-ID | Block | Decision | Source | Licence | Status |
|---|---|---|---|---|---|
| IPR-001 | `uart_tx` | custom | n/a (no network search executed in this sandboxed environment) | n/a | rejected — see `requirements.yaml: ip_reuse` for rationale and the fallback search command recorded per the anti-hallucination rule |

No other block is a reuse candidate: the MAC datapath, sigmoid LUT, control FSM, ROMs and LED
controller are all fully custom, project-specific, and trivial enough that IP search would not be
cost-effective even with network access (this is recorded, not silently assumed).

## 11. Assumptions (ASM-###)

| ASM-ID | Statement | Requires confirmation |
|---|---|---|
| ASM-001 | Minimum reset assert width = 2 `clk_core` cycles | true |
| ASM-002 | Core clock = exactly 100 MHz (10.000 ns), consistent with the brief's "~0.5 s at 100 MHz" and "100 MHz nominal" language | true |
| ASM-003 | Default `BLINK_CYCLES` = 5,000,000 (~10 Hz visible blink at 100 MHz) | true |

All three are cosmetic/timing defaults with **zero effect on the bit-exact datapath contract**
(REQ-002/006) — worst case if reconsidered, they only change simulation pacing or visible LED
blink rate, never a pred/confidence/verdict/UART-byte outcome. Per `spec_manifest.yaml`, these are
listed in `unconfirmed_assumptions` for `fe-arch`'s `ARCH-E012` gate; this project explicitly
acknowledges them (`assumptions_acknowledged: true`) so `fe-arch` may proceed without a human
round-trip, since none of them can invalidate golden-model bit-exactness.

## 12. Open Issues (OI-###)

None. All three items the project README listed as "open" (weight source, trash confidence
threshold, directory naming) are resolved by this spec: weights are frozen in the committed golden
package (§3), the trash threshold is fixed at confidence < 50 (REQ-011, matching the golden model
exactly), and directory naming follows the pipeline's own `spec/`/`arch/`/`rtl/` convention under
`mnist_npu/`.

## 13. Verification Closure Criteria

See `verification_plan.md` §5 for the full countable list. Headline criteria: 0/65536 LUT
mismatches, 0/100 pred/confidence/verdict mismatches, 0 UART byte mismatches, 0 LED-pattern
mismatches, 100% FSM state/arc coverage over one 100-image pass, and a documented bounded
simulation-cycle count under `iverilog`.

## 14. Glossary

- **Q8.8** — 16-bit signed fixed point, 8 integer bits + 8 fractional bits (value = raw/256).
- **sigma / sigmoid LUT** — the golden model's rational approximation `128 + trunc(128z/(256+|z|))`
  implemented as a 65536x8 ROM (REQ-006).
- **verdict** — 0=CORRECT, 1=INCORRECT, 2=TRASH (REQ-011).
- **HOLD_CYCLES / BLINK_CYCLES / CLK_DIV** — the three pacing parameters (REQ-016/020/021).
- **Golden model** — `arch/golden_model/golden_ref_model.c` and its `.hex` companions; the frozen,
  pre-existing bit-exact behavioural contract this design must reproduce (project brief §3).
