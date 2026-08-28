# Low-Power Plan (No DFT) — cnn_systolic
Stage: fe-arch | Sky130 130 nm, 1.8 V core (sky130_fd_sc_hd)

## 1. Strategy Summary

Single always-on power domain. Power reduction via: (a) **core clock gating** at the
accelerator boundary (the dominant logic consumer — 64-PE array + FP datapath), (b) RTL-level
operand isolation + memory enable gating inside the core, (c) the shell's inherent low activity
(poll-loop CPU, 115200 UART). No power-domain split (no retention/isolation cells in the open
PDK; RTL clamping is the fallback). Target: no numeric power budget was set by the brief —
qualitative reductions recorded.

## 2. Clock Gating

| PWR-ID | Block | Enable condition | Expected idle % | Implementation |
|---|---|---|---|---|
| PWR-001 | accelerator core (BLK-009..017) | `core_clk_en = busy` (1 from START-accept until result latch) | ~46 % (755K busy of ~1.4M-cycle image period at CLK_DIV=868; more at slower UART) | Explicit `sky130_fd_sc_hd__dlclkp_1` (non-scan latch ICG) at the core clock root; gated clock declared as a generated clock in SDC (cdc_plan.md §5) |
| PWR-002 | weight banks (BLK-014) | read enables only when the array/FC/bias path is reading | ~50 % | RTL read-enable gating on the bank ports (operand isolation), no clock gating |
| PWR-003 | fm_ram / p1 banks / img banks | access strobes per owning FSM | layer-dependent (idle during UART/poll windows) | RTL write-enable + read-address isolation |
| PWR-004 | uart_tx (BLK-019) | inherent (idle-high, no toggle while idle) | ~99.9 % | none needed (state machine idles) |

Rules: gate only on the enable, never on data; latch-based ICG only (never a raw AND on a
clock); **no scan-enable OR-term** (that is DFT — forbidden); gated clocks declared as
generated clocks in SDC.

## 3. Power Domains

One domain: `PD_CORE` (always-on). No split: the open PDK ships no dedicated isolation/retention
cells, the design is small, and the accelerator is already clock-gated at its boundary. Any
future split would require RTL-level clamping (below).

## 4. Isolation and Retention

None required (single domain, always-on). If a split were ever added: RTL-level clamping to
defined values (no dedicated cells in the open PDK). Not applicable in v1.

## 5. Operand Isolation and Memory Enables

- Array PEs: `advance`-qualified input latching; product/acc stages only toggle during
  wavefronts (PWR-001's gated clock already stops them between images; within a run, sub-pass
  idle cycles are minimal).
- Weight banks: address/data muxes isolated to the active access mode (parallel reload vs
  serial FC vs bias staging).
- fm_ram/p1/img: single-port SRAM macros with enable-pin gating when idle.

## 6. Power Estimate by Block

Qualitative (no tool at this stage): the PE grid (64 × fp32_add + registers) dominates dynamic
power while busy; SRAM macros dominate leakage (≈ 762 Kbit, arch.md §15); the shell is small.
The gated clock (PWR-001) removes ≈ all core dynamic power between inferences — the single
most effective measure, implemented with the standard non-scan ICG cell.

## 7. Explicitly Excluded

All DFT structures: no scan chains, no `sky130_fd_sc_hd__sdlclkp*` (scan clock gates), no
BIST/MBIST, no JTAG/TAP, no ATPG hooks, no compression.
