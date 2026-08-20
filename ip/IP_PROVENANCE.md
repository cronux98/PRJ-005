# IP Provenance — rinriAI

**Every block in this design is custom (`source: custom`). No third-party IP was
used.** This is a deliberate project decision (Rinri directive: "author everything
fresh; no external IP"), recorded here for auditability.

## Blocks and provenance

| BLK | Module | Source | Provenance |
|---|---|---|---|
| BLK-001 | learn_accel | custom | authored by fe-rtl |
| BLK-002 | apb_regs | custom | authored by fe-rtl |
| BLK-003 | sample_stream | custom | authored by fe-rtl |
| BLK-004 | learner | custom | authored by fe-rtl |
| BLK-005 | weight_ram | custom | authored by fe-rtl |
| BLK-006 | stats | custom | authored by fe-rtl |
| BLK-007 | div_seq | custom | authored by fe-rtl |

`ip/` is intentionally empty. No `git clone` was performed at any stage.

## Due-diligence search record (fe-spec stage, 2026-08-20)

Candidates were surveyed and **rejected** per the no-external-IP directive. Exact
search commands used (recorded for reproducibility):

```
web_search: github verilog APB4 slave verilog-2001
web_search: github sky130 APB4 slave verilog
web_search: github verilog sigmoid LUT fixed point
```

Notable hits (all rejected): `vyges/uart-controller` (SystemVerilog, APB3 —
language out of scope), ForrestBlue ARM CMSDK APB4 slave (ARM example, licence
unsuitable for fresh-authoring directive), assorted sigmoid-LUT repositories
(approach superseded by the integer rational approximation in arch.md §5.3 —
no transcendental table needed, bit-exact by construction).

## IP-reuse fallback rule

Per fe-rtl SKILL.md §5: if IP retrieval were unavailable the fallback is a custom
implementation with the search commands recorded — which is exactly the state of
this project by directive rather than by unavailability. No repository URL,
commit SHA, or licence is claimed anywhere in this project that was not actually
verified on 2026-08-20.
