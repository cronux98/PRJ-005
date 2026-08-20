# learning-accelerator-ip

**Simple, learning AI accelerator** — an IP block that *learns* (not just infers), testable with simulation **and** firmware, fed by online datasets as experiments.

## Goal

A small, understandable learning-accelerator IP that:
- implements an **online learning** algorithm in RTL (weights update continuously from a stream of samples — no cloud training),
- is testable via simulation (iverilog/Verilator/cocotb) and via **firmware** (bare-metal program driving the IP through a register interface and streaming samples),
- runs **experiments** fed by real, downloadable datasets (MNIST-class byte streams, adaptive-filter signal traces, etc.),
- targets the existing front-end ASIC pipeline (fe-spec → fe-arch → fe-rtl → fe-yosys → fe-gls → fe-opensta → fe-sby → … → fe-regression), pure Verilog-2001/2005, Sky130-ready.

## Repository layout

| Path | Contents |
|------|----------|
| `research/` | Curated papers, online books, datasets, and design directions (you are here) |
| `spec/` | (planned) fe-spec stage output |
| `arch/` | (planned) fe-arch stage output |
| `rtl/` | (planned) fe-rtl stage output |
| `fw/` | (planned) firmware + dataset→hex tooling |
| `sim/` | (planned) testbenches |

## Status

- 2026-08-20: repo + research compiled. Spec/arch/rtl authoring dispatched to architect agent (deepseek-v4-flash).
