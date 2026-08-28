# Clock Domain Crossing Plan
Stage: fe-arch | No DFT structures | Project: cnn_systolic

## 1. Clock Domains

| CLK-ID | Name | Freq | Source | Relationship to other domains |
|---|---|---|---|---|
| CLK-001 | clk | 100.000 MHz | external_pad | single domain — no relationships |

## 2. Reset Domains and Sequencing

| RST-ID | Name | Type | Domain | Min assert (cycles) | De-assert order |
|---|---|---|---|---|---|
| RST-001 | rst_n | fully synchronous, active-low | CD_CORE | 2 (TB: ≥ 10) | n/a (single domain) |

## 3. Crossings

None. **Zero CDC paths** — the design has exactly one clock domain and no asynchronous external
input (no UART RX, no camera, no async reset). The `cdc_requirements` enumeration in
`spec/interfaces.yaml` is intentionally empty (REQ-034). The core's gated clock
(`core_clk_en = busy`, PWR-001) is a **generated clock derived from clk** — it is not a second
domain; SDC must declare it as a generated clock with the same source period (see §5).

## 4. Mechanism Specifications

Not applicable (no crossings). The four sanctioned CDC modules of the skill are not instantiated
anywhere.

## 5. SDC Intent for fe-rtl (compiled into fe-opensta's sdc_spec.json)

- Single clock `clk` 10.000 ns; `set_clock_groups` — none (no async pairs).
- Generated clock for the gated core clock (ICG output, `core_clk_en`): period 10.000 ns,
  master = clk. No false paths.
- `set_false_path` — none required (no static/config CDC inputs).
- SRAM macro blackbox pins: input setup/output load constraints per macro datasheet
  (fe-opensta, P3); memory stubs carry the macro timing intent.
- Do NOT blanket-false-path the reset: `rst_n` is synchronous and must be timed normally.
- `clock_groups_async: []` in sdc_spec.json (matches cnn_soc skeleton).

## 6. Verification Intent

No CDC stress exists by construction (single domain). Reset hygiene (G4) and the gated-clock
enable/disable equivalence (core idle vs busy, no X/Z at the ICG boundary) are the only
clock-related checks (VP-TOP-005, VP-TOP-001).
