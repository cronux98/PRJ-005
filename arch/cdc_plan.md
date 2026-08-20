# Clock Domain Crossing Plan
Stage: fe-arch | No DFT structures

## 1. Clock Domains

| CLK-ID | Name | Freq | Source | Relationship to other domains |
|---|---|---|---|---|
| CLK-001 | clk_core | 50 MHz | external_pad | only domain (CD_CORE); no async peers |

**This design has exactly one clock domain.** Every input (APB4, sample stream) is
synchronous to clk_core; there are no asynchronous interfaces and no CDC paths
(`spec/interfaces.yaml → cdc_requirements: []`, `cdc_paths: 0`). This section exists to
state that explicitly and to pin the SDC intent.

## 2. Reset Domains and Sequencing

| RST-ID | Name | Type | Domain | Min assert (cycles) | De-assert order |
|---|---|---|---|---|---|
| RST-001 | rst_n | synchronous, active-low (ASM-002) | CD_CORE | 16 | single domain; no ordering required |

## 3. Crossings

| CDC-ID | Signal | From | To | Class | Mechanism | Module | Depth/Width | Data-stability rule | Traces |
|---|---|---|---|---|---|---|---|---|---|
| — | none | — | — | — | — | — | — | — | REQ-012 |

No crossings exist. A future integration that attaches an asynchronous bus bridge or
async FIFO source to IF-002 must add a CDC entry here before any RTL change.

## 4. Mechanism Specifications

Not applicable (no crossings). If a crossing is introduced later, the standard mechanisms
apply (2-flop sync for single-bit level, toggle-pulse for single-bit pulse, gray async
FIFO for multi-bit streaming, req-ack for multi-bit control) — none are instantiated now.

## 5. SDC Intent for fe-rtl (compiled into fe-opensta's sdc_spec.json)

fe-rtl does **not** hand-author a `.sdc`. It compiles the intent below into
`sdc/sdc_spec.json`, which fe-opensta (`gen_sdc.py` + `qa_sdc.sh`) turns into constraints:

- One clock: `clk_core`, period 20.000 ns, duty 50 %.
- Clock uncertainty: 5 % of period setup (1.0 ns), 0.1 ns hold (ASM-009).
- Input delay 6.0 ns, output delay 6.0 ns on all ports (30 % of period each).
- `set_clock_groups -asynchronous`: **none** (single clock).
- `set_false_path`: none.
- `set_max_delay -datapath_only`: none.
- Reset: synchronous `rst_n` — no reset-synchroniser recovery/removal constraints needed
  (synchronous reset is a normal data path; no async assert).

## 6. Verification Intent

No CDC stress is required (VP-TOP-004 CDC item does not apply — no CDC-### paths exist;
the spec verification plan records 0 CDC paths). Reset-during-traffic and malformed-frame
recovery are covered by VP-TOP-003/007/008.
