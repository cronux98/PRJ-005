# Low-Power Plan (No DFT) — cnn (mnist_npu v2)

## 1. Strategy Summary
This is a tiny, always-on, single-clock-domain inference core with no host bus and no idle/sleep
requirement in the task brief. The strategy is deliberately simple, identical to v1's precedent:
**no clock gating, no power domains, single always-on supply.** Every register clocks every cycle;
the FSM's own `case` branches (not clock enables) determine which datapath elements' outputs
matter on a given cycle. No numeric power/area target was set in `spec/spec.md` §9.

## 2. Clock Gating

| PWR-ID | Block | Enable condition | Expected idle % | Implementation |
|---|---|---|---|---|
| — | none | — | — | **No clock gating anywhere in this design.** |

Rationale: `mac_datapath` runs on the overwhelming majority of every image's ~667,208 compute
cycles (arch.md §6.8) — it is the least-idle block in the design by a wide margin. `fm_ram`,
`weight_rom`, `image_rom` are read on almost every MAC-phase cycle too. The remaining blocks
(`uart_tx`, `uart_line_fmt`, `led_ctrl`, `label_rom`, `sigmoid_lut`) are each active for a small,
non-power-critical fraction of the cycle budget where the added verification burden of clock gating
(generated-clock SDC entries, ICG glitch analysis) is not justified for a design of this size and
this task's explicit non-goals (no FPGA timing closure yet, no power target set). The only
realistic clock-gating candidate — `mac_datapath` idle during `ST_PRESENT`/`ST_HOLD` — is an even
smaller fraction of the per-image cycle budget than in v1 (since CNN compute dominates the total
far more than v1's MLP compute did), making it more marginal here, not less.

## 3. Power Domains
Single always-on domain (default, and the correct answer here per `fe-arch`'s own guidance for
small open designs with no stated power budget). No domain partitioning.

## 4. Isolation and Retention
Not applicable — single power domain, nothing to isolate or retain across a power-down boundary
(there is no power-down state in this design at all; it free-runs forever per REQ-024).

## 5. Operand Isolation and Memory Enables
`mac_datapath`'s multiplier operands (`mac_a`, `mac_b`) are always driven by the currently
addressed ROM/RAM word (or forced to zero by `tap_valid_r` for zero-padded taps, arch.md §6.2) —
there is no "don't care" operand state that would benefit from operand isolation. All six memories
(`weight_rom`, `image_rom`, `label_rom`, `fm_ram`, `sigmoid_lut`, and the reused v1
`sigmoid_lut.hex` table) are read/written only when `ctrl_fsm`/`win_addr_gen` addresses them (their
address inputs are driven only during the FSM phases that need them) — the natural, free
memory-enable behaviour of a synchronous design; no separate explicit enable signal is needed.

## 6. Power Estimate by Block
Qualitative only (no numeric target set in spec.md §9, no synthesis/STA run at this stage):
`mac_datapath` (16x16 multiplier + 64-bit adder) is the single largest dynamic-power contributor by
a wide margin — larger than v1's equivalent block, since both the accumulator width (64 vs 40 bits)
and the toggle rate (near-100% of ~667K cycles/image vs v1's ~51K) are higher. `fm_ram` (7,840x16 =
125,440 bits) and `sigmoid_lut` (65536x8 ROM) are the largest static/leakage contributors by area
once mapped to BRAM. All other blocks (`uart_tx`, `uart_line_fmt`, `led_ctrl`, small ROMs) are minor
by comparison.

## 7. Explicitly Excluded: all DFT structures
No scan chains, no scan-enable ports, no scan-variant clock gates (`*_sdlclkp*` or equivalent), no
BIST, no JTAG/TAP, no ATPG hooks. None of these are needed or present anywhere in this design.
