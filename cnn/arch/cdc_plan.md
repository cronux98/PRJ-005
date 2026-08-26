# Clock Domain Crossing Plan — cnn (mnist_npu v2)
Stage: fe-arch | No DFT structures | **This design has exactly one clock domain and zero CDC
crossings.** This document exists to satisfy the pipeline's process requirement (identical to v1
mnist_npu's precedent); every section below is filled in truthfully as empty/trivial rather than
omitted.

## 1. Clock Domains

| CLK-ID | Name | Freq | Source | Relationship to other domains |
|---|---|---|---|---|
| CLK-001 | clk_core | 100 MHz nominal (10.000 ns) | external_pad (board oscillator; FPGA clock management is out of scope this stage) | N/A — the only domain (CD_CORE) |

No second clock exists anywhere in the design. The UART baud rate (115200) is generated **inside**
CD_CORE by a free-running cycle counter (`CLK_DIV`, BLK-009, reused verbatim from v1) that produces
a single-cycle `baud_tick` pulse — a *rate divider*, not a second clock domain: `baud_tick` is a
synchronous enable sampled every `clk_core` edge, never used to clock a flop. No generated clock is
instantiated (no ICG, per `power_plan.md` — no clock gating in this design at all).

## 2. Reset Domains and Sequencing

| RST-ID | Name | Type | Domain | Min assert (cycles) | De-assert order |
|---|---|---|---|---|---|
| RST-001 | rst_n | **synchronous** (not async-assert/sync-deassert — see arch.md §9 and spec.md §5 for why this deviates from the fe-spec/fe-arch/fe-rtl skill defaults) | CD_CORE | 2 (ASM-001) | N/A — single domain, nothing to sequence against |

## 3. Crossings

*(none — table intentionally has zero rows)*

| CDC-ID | Signal | From | To | Class | Mechanism | Module | Depth/Width | Data-stability rule | Traces |
|---|---|---|---|---|---|---|---|---|---|
| — | — | — | — | — | — | — | — | — | — |

## 4. Mechanism Specifications

Not applicable — no synchroniser primitives (`cdc_sync_2ff`, `cdc_pulse_sync`, `cdc_async_fifo`,
`cdc_handshake`) are instantiated anywhere in this design, because there is nothing to synchronise
between. `fe-rtl` must NOT introduce any of these primitives; their presence in the RTL would
itself be a defect (an ad-hoc synchroniser with no `CDC-###` justification, forbidden by
`rtl_coding_guidelines.md` §9).

## 5. SDC Intent for fe-rtl (compiled into fe-opensta's sdc_spec.json)

- `set_clock_groups -asynchronous`: none — only one clock exists.
- `set_false_path`: none required for CDC reasons. (`sdc/sdc_spec.json` may still carry a narrowly
  scoped, commented false path on the synchronous reset network if fe-rtl's reset chain needs one —
  see `rtl_coding_guidelines.md` §3; this is a reset-recovery consideration, not a CDC one, and per
  fe-rtl's own rule it must never be a blanket `to: "*"`.)
- `set_max_delay -datapath_only`: none.
- `clock_groups_async` in `sdc/sdc_spec.json` (§8 template) shall be an empty list `[]`.

## 6. Verification Intent

Not applicable at the CDC level (no crossings to stress with skew/jitter sweeps). The single-clock
design is instead verified end-to-end against the golden model per `spec/verification_plan.md`
(VP-TOP-001..008): reset-and-defaults, full-throughput soak over all 100 images, and the
free-running back-to-back image loop (no idle gaps beyond the specified `HOLD_CYCLES`) already
cover everything a CDC stress test would normally add for a multi-domain design.
