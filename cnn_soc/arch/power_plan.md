# Low-Power Plan — cnn_soc (No DFT)
Stage: fe-arch | Technology: **FPGA-generic** (project precedent — NO Sky130 cells, no ICG cells,
no PDK power cells of any kind; see arch.md §2 deviation)

## 1. Strategy Summary

v1 targets **a single always-on domain, no clock gating, no power domains, no isolation, no
retention** — identical strategy to the verified cnn engine (`cnn/arch/arch.md §9` note: "no clock
gating, single always-on domain") and the smallest correct power architecture for a design whose
active engine (the CNN datapath) runs at ~100 % duty during every inference and whose CPU spends
most of its time in a poll loop that the firmware cannot cheaply power down (no IRQ in v1,
REQ-027). No numeric power targets exist in the spec (spec.md §9); estimates below are
qualitative and activity-based only. No Sky130 cells are named anywhere — power implementation on
the eventual FPGA target is the FPGA tool's clock-enable optimization, out of scope for
fe-rtl/fe-opensta.

## 2. Clock Gating

| PWR-ID | Block | Candidate enable | Expected idle % | Decision |
|---|---|---|---|---|
| PWR-001 | BLK-014..019 (CNN core, inside cnn_infer) | `seq_park` (parked) | ~0 % while a run is active (667,210 of ~670k cycles/image) | **No gating in v1.** The core is busy nearly the whole run window; gating buys nothing. FPGA tools may infer clock enables from `if (en)` RTL if present; none is specified. |
| PWR-002 | BLK-012 (CPU) | firmware poll loop | ~85 % (waiting on DONE/BUSY) | **Deferred.** Gating the CPU clock would require a CPU halt protocol (WFI/IRQ) that v1 deliberately excludes (REQ-027 polling-only). Revisit in v2 with IRQ. |
| PWR-003 | BLK-013 (uart_tx) | `!utx_busy` | ~99 % (one line per ~670k cycles) | **No gating.** Tiny block (< 30 flops); gating overhead exceeds benefit. |

Rules honoured: gate only on an enable, never on data; no ICG cells exist in an fpga_generic
design (and none may be invented — no Sky130 cell names anywhere); **no scan-enable OR-term
(DFT — forbidden)**; no raw AND/OR on a clock in RTL (if the FPGA flow infers enables, it does so
in the tool, not in RTL); no gated/generated clocks are declared (CD_CORE has exactly one clock,
CLK-001).

## 3. Power Domains

**Single always-on domain** (CD_CORE). No split is justified: one clock, one reset, ~20 small
blocks, no standby mode requirement in the spec. No domain-crossing isolation is needed (0 CDC
paths, cdc_plan.md).

## 4. Isolation and Retention

Not applicable — single domain. (The open PDK / fpga_generic context ships no dedicated isolation
or retention cells; nothing here needs RTL-level clamping beyond the specified reset values of
the register map, arch.md §7.3.)

## 5. Operand Isolation and Memory Enables

- Memories (MEM-001..007) are always enabled by construction (registered read ports with no
  clock-enable input in the cnn ROM/RAM pattern, `image_rom.v:25-29` et al.). This is inherited
  and acceptable: ROM/RAM power in v1 is dominated by the ~100 %-busy CNN window; the FPGA
  implementation maps them to BRAM with tool-managed enables.
- No operand-isolation muxes are specified: the interconnect drives only the selected slave
  (combinational mux), so unselected memories see stable, unchanging addresses — the natural
  operand isolation of a decoded bus. Explicit isolation logic is unnecessary.
- The image_buffer write port is active only while the CPU writes (bus-decoded `img_we`), i.e. a
  few hundred cycles per image.

## 6. Power Estimate by Block (qualitative, activity-based)

| Block | Dominant cost | Activity |
|---|---|---|
| BLK-012 CPU | ~1,100 flops | busy ~15 % (copy + poll), idle ~85 % |
| BLK-002 interconnect | small mux logic | 1 txn per ~3-8 cycles while CPU active |
| BLK-003 bootrom | 4 KB | instruction fetch stream during CPU activity |
| BLK-004 sram | 128 KB | stack pushes/pops only |
| BLK-005 vec_rom | 78.5 KB | 196 word reads per image |
| BLK-006/007/008 | < 100 flops | UART/GPIO writes per image |
| BLK-009 | < 150 flops | 2 edges per image (START, DONE) |
| BLK-014..019 CNN core | MAC + memories (dominant) | ~100 % busy per run window |
| Total dynamic | dominated by the CNN run window (667k cycles/image × 100) | ~127M cycles per demo @ CLK_DIV=868 (arch.md §6.5) |

## 7. Explicitly Excluded (all DFT structures)

No scan chains, no scan-enable port, no `sdlclkp`/`*_sdlclkp*`-style cells (none exist in this
design — no Sky130 cells at all), no BIST/MBIST, no JTAG/TAP, no ATPG hooks, no compression.
Debug/observability is register-mapped (CNN_STATUS etc.) + hierarchical TB probes only
(arch.md §12).
