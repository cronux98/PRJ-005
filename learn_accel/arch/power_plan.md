# Low-Power Plan (No DFT)

## 1. Strategy Summary

Target: ≤ 5 mW dynamic at 25 MHz nominal, 1.8 V, typical corner, excluding weight memory
(REQ-023; original 50 MHz target superseded by REQ-015 erratum 2026-08-20 — the 5 mW budget
is retained as a conservative bound; dynamic power scales ~linearly with frequency). Dominant power is the learner datapath (multiplier, 48-bit accumulator,
divider) and the memory arrays. Strategy: enable-based RTL clock gating (tool-inferred
ICG), operand isolation on the MAC inputs when idle, and memory clock-enables. Single
always-on power domain (the correct default for a Sky130 open-PDK IP block).

## 2. Clock Gating

| PWR-ID | Block | Enable condition | Expected idle % | Implementation |
|---|---|---|---|---|
| PWR-001 | BLK-004 learner datapath | `busy_processing \|\| fsm_active` (any state ≠ IDLE) | ~90 % (firmware-paced experiments) | RTL `if (en)` around datapath registers; tool-inferred ICG |
| PWR-002 | BLK-005 weight_ram | `a_we \|\| b_we \|\| a_rd \|\| b_rd` | ~85 % | RTL enable; inferred |
| PWR-003 | BLK-007 div_seq | `div_busy` | ~98 % | RTL enable; inferred |
| PWR-004 | BLK-003 sample_ram | `beat \|\| x_rd` | ~90 % | RTL enable; inferred |

Rules: gate only on the enable, never on data; if an explicit ICG cell is ever
instantiated it must be `sky130_fd_sc_hd__dlclkp_1` (latch-based, **non-scan**; name to be verified against the installed PDK before any instantiation — it is NOT instantiated in this RTL); the
`sky130_fd_sc_hd__sdlclkp*` scan variant is DFT and is **forbidden**; a raw AND gate on
the clock is forbidden. Gated clocks must be declared as generated clocks in SDC if
explicit ICG cells are used — with tool-inferred gating this is handled by the tool.

## 3. Power Domains

Single always-on domain (CD_CORE). No split: the IP is a small single-clock macro;
retention/isolation cells would cost more than they save at this scale.

## 4. Isolation and Retention

None required (single domain). If the IP is ever partitioned, note that the open PDK
ships no dedicated isolation/retention cells — plan RTL-level clamping (e.g., force
memory enables off) instead.

## 5. Operand Isolation and Memory Enables

- MAC multiplier inputs (a_sel, w_sel) held at 0 when the learner FSM is in IDLE
  (PWR-001).
- Accumulator clock-enable only during FWD_H/FWD_O/BP_H MAC loops.
- Weight RAM port A/B read enables qualified by the owning FSM's active cycles.
- Counters (BLK-006) enable only on `sample_done_p`/`clr_stats_p`.

## 6. Power Estimate by Block

| Block | Dynamic power estimate @25 MHz 1.8 V typ (orig. @50 MHz superseded) |
|---|---|
| BLK-002 apb_regs | ~0.15 mW |
| BLK-003 sample_stream (+6.3 kbit) | ~0.25 mW |
| BLK-004 learner | ~0.9 mW active, ~0.05 mW idle (gated) |
| BLK-005 weight_ram logic | ~0.1 mW (array power excluded) |
| BLK-006 stats | ~0.05 mW |
| BLK-007 div_seq | ~0.15 mW active, ~0.01 mW idle |
| **Total (excl. weight RAM)** | **≤ ~1.6 mW — meets REQ-023** (analysis item VP-TOP-017) |

## 7. Explicitly Excluded

All DFT structures: no scan-enable OR-terms in any gating logic, no `sdlclkp`, no
isolation/retention scan cells, no BIST.
