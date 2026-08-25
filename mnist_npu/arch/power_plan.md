# Low-Power Plan (No DFT) — mnist_npu

## 1. Strategy Summary
This is a tiny, always-on, single-clock-domain inference core with no host bus and no idle/sleep
requirement in the product brief. The strategy is deliberately simple: **no clock gating, no power
domains, single always-on supply.** Every register clocks every cycle; the FSM's own `case`
branches (not clock enables) determine which datapath elements' outputs matter on a given cycle.
No numeric power/area target was set in `spec/spec.md` §9 (not load-bearing for this design size:
one MAC, ~5 ROM/RAM instances, one UART shifter, one LED register bank).

## 2. Clock Gating

| PWR-ID | Block | Enable condition | Expected idle % | Implementation |
|---|---|---|---|---|
| — | none | — | — | **No clock gating anywhere in this design.** |

Rationale: the design has no meaningfully idle block — `mac_datapath` runs almost every cycle of
every image (25,408 of ~25,748 total per-image cycles, i.e. ~99%), and the remaining blocks
(`uart_tx`, `uart_line_fmt`, `led_ctrl`, ROMs) are each active for a small, non-power-critical
fraction of the cycle budget where the added verification burden of clock gating (generated-clock
SDC entries, ICG glitch analysis) is not justified for a design of this size and this product
brief's explicit non-goals (no FPGA timing closure yet, no power target set). If a future stage
adds power targets, `mac_datapath`'s idle cycles during `ST_PRESENT`/`ST_HOLD` (~360 of ~25,748
cycles, ~1.4%) are the only realistic clock-gating candidate, and even that is marginal.

## 3. Power Domains
Single always-on domain (default, and the correct answer here per `fe-arch`'s own guidance for
small open designs with no stated power budget). No domain partitioning.

## 4. Isolation and Retention
Not applicable — single power domain, nothing to isolate or retain across a power-down boundary
(there is no power-down state in this design at all; it free-runs forever per REQ-015).

## 5. Operand Isolation and Memory Enables
`mac_datapath`'s multiplier operands (`mac_a`, `mac_b`) are always driven by the currently
addressed ROM/RAM word — there is no "don't care" operand state that would benefit from operand
isolation, and no glitch-power concern rises to the level of justifying the added complexity for
this design size. All five memories (`weight_rom`, `image_rom`, `label_rom`, `hidden_ram`,
`sigmoid_lut`) are read/written only when `ctrl_fsm` addresses them (their address registers are
themselves gated by the FSM state, which is the natural/free memory-enable behaviour of a
synchronous design — no separate explicit enable signal is needed beyond the address-valid timing
already implied by the FSM's one-MAC-step-per-cycle sequencing).

## 6. Power Estimate by Block
Qualitative only (no numeric target set in spec.md §9, and no synthesis/STA is run at this stage
per fe-arch's "write files only" scope): `mac_datapath` (16x16 multiplier + 40-bit adder) is the
single largest dynamic-power contributor by a wide margin, since it toggles on ~99% of cycles;
`sigmoid_lut` (65536x8 ROM) is the largest static/leakage contributor by area once mapped to BRAM;
all other blocks (`uart_tx`, `uart_line_fmt`, `led_ctrl`, small ROMs/RAM) are minor by comparison.

## 7. Explicitly Excluded: all DFT structures
No scan chains, no scan-enable ports, no scan-variant clock gates (`*_sdlclkp*` or equivalent), no
BIST, no JTAG/TAP, no ATPG hooks. None of these are needed or present anywhere in this design.
