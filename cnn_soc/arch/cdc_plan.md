# Clock Domain Crossing Plan — cnn_soc
Stage: fe-arch | No DFT structures | Technology: FPGA-generic (no Sky130 cells)

## 1. Clock Domains

| CLK-ID | Name | Freq | Source | Relationship to other domains |
|---|---|---|---|---|
| CLK-001 | `clk` (CD_CORE) | 100 MHz nominal / 10.000 ns | external pad | — (only domain; fully synchronous reset `rst_n` in the same domain) |

**Exactly one domain exists.** There is no UART RX, no camera, no external asynchronous input in
v1 (spec.md §5; README.md:28). Therefore **zero clock-domain crossings exist** and no
synchroniser, FIFO, or async handshake module is required or permitted anywhere in the RTL.

## 2. Reset Domains and Sequencing

| RST-ID | Name | Type | Domain | Min assert (cycles) | De-assert order |
|---|---|---|---|---|---|
| RST-001 | `rst_n` | **fully synchronous**, active-low | CD_CORE | 2 (ASM-001; TB asserts ≥ 10) | n/a — single domain; no ordering needed |

Notes:
- No async reset term exists anywhere (REQ-029; deviation from the fe-arch skill default,
  documented in arch.md §2 / spec.md §2.1). All flops use `always @(posedge clk) if (!rst_n) …`.
- No reset synchroniser is needed or present (nothing is async).
- `core_rst_n` (the BLK-009 single-shot park signal into BLK-010) is a **functionally gated
  synchronous reset** derived from the sequencer registers in the same domain (`!(seq_park ||
  park_reg)`); it is a logic signal on the `clk` edge, never an asynchronous term. It re-asserts
  within 2 cycles of `lc_present` (REQ-021) and its release is synchronous with the START-accept
  edge. No CDC treatment applies.

## 3. Crossings

| CDC-ID | Signal | From | To | Class | Mechanism | Module | Depth/Width | Data-stability rule | Traces |
|---|---|---|---|---|---|---|---|---|---|
| — | (none) | — | — | — | — | — | — | — | REQ-028 |

The crossings table is **intentionally empty**: single clock domain, zero crossings
(spec interfaces.yaml `cdc_requirements: []`; spec_manifest `cdc_paths: 0`).

## 4. Mechanism Specifications

Not applicable — no crossings exist. The four mechanism templates of the fe-arch skill
(2-flop synchroniser, toggle-pulse synchroniser, gray-pointer async FIFO, req-ack handshake) are
**not instantiated anywhere** in cnn_soc v1. If a future milestone (M8 camera, v2) adds a second
domain, the CDC plan must be re-authored then; v1 forbids ad-hoc synchronisers.

## 5. SDC Intent for fe-rtl

> fe-rtl does not hand-author a `.sdc`. It compiles the intent below into `sdc/sdc_spec.json`
> for fe-opensta. For this design the intent is degenerate:

- `set_clock_groups`: **none required** — a single clock (`clk`, 10.000 ns) exists; no async
  clock pairs (arch_manifest `clock_domains[].async_with: []`).
- `set_false_path`: none (no static cross-domain config signals).
- `set_max_delay -datapath_only`: none (no handshake data buses across domains).
- Synchronised reset de-assertion: not applicable (reset is fully synchronous; recovery/removal
  are ordinary setup checks on `rst_n`).
- The `core_rst_n` park signal is a normal synchronous control path (no special constraints).

## 6. Verification Intent

No CDC stress is possible or required (0 crossings by construction, REQ-028). The SoC TB's
reset-hygiene checks (G4: `led==0`, `uart_tx==1` during reset; no X/Z after release) and the
single-shot timing probes (park ≤ 2 cycles after `lc_present`; `img_idx==0` at all times) cover
the only timing-adjacent behaviour that exists in this single-domain design (VP-TOP-005,
VP-TOP-007).
