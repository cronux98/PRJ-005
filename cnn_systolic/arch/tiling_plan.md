# Tiling Plan — conv1 2 passes, conv2 18 passes
Stage: fe-arch | Binding on: conv_ctrl (BLK-011), systolic_array (BLK-010), golden model

Per the brief: conv1 = 72 MACs/output-position → **2 passes of 64**; conv2 = 1,152
MACs/output-position → **18 passes of 64**. The array is 8 rows × 8 columns; a pass (sub-pass)
= one 8-cycle wavefront = 64 PEs × 1 MAC each = 64 MACs.

## 1. conv1 (1→8 ch, 3×3, pad 1, stride 1; 28×28 out)

- Per output position (oy,ox): 72 MACs = 8 oc × 9 taps (t = iy*3+ix).
- **Pass A:** columns = taps 0..7 (8 taps); rows = oc 0..7. 64 weights loaded: PE(r,c) =
  w1[r][c], i.e. conv1_w[r*9+c]. 64 MACs.
- **Pass B:** columns = tap 8 in column 0 only; rows = oc 0..7; columns 1..7 hold weight 0.
  8 real MACs + 56 zero-weight no-ops (exact identities). PE(r,0) = conv1_w[r*9+8].
- Loop order: pixels (oy,ox) outer (6272), passes inner (2). Per pixel: bias-init (1) + 2×10
  sub-pass cycles + drain (1) = 22 cycles.
- Activation source: 9 shifted image banks, shared read address oy*28+ox.
- Weight loads: pass A 64 words (8 reads/bank, 8 cycles, shadowed), pass B 8 words (1
  read/bank, 1 cycle, shadowed); both overlap compute from pixel 1 on (initial 9 cycles at
  layer start).

## 2. conv2 (8→16 ch, 3×3, pad 1, stride 1; 14×14 out)

- Per output position (oy,ox): 1,152 MACs = 16 oc × 8 ic × 9 taps (k = iy*3+ix).
- **Pass index p ∈ 0..17:** `g = p / 9` (oc-group: 0 → oc 0..7, 1 → oc 8..15), `k = p % 9`
  (tap position (iy,ix), k = iy*3+ix). Rows = the group's 8 oc; columns = 8 input channels
  ic 0..7. PE(r,c) = conv2_w[(g*8+r)*72 + c*9 + k]. 64 MACs/pass → 18 × 64 = 1,152 ✓.
- Loop order: pixels (oy,ox) outer (3136), passes inner (18). Per pixel: bias-init g0 (1) +
  9×10 (passes p=0..8) + drain g0 (1, h2 writes for oc 0..7) + bias-init g1 (1) + 9×10
  (p=9..17) + drain g1 (1) = 184 cycles.
- Activation source: 8 per-channel p1 banks, shared read address (oy+iy-1)*14+(ox+ix-1),
  combinational zero mux when out of 0..13.
- Weight loads: 64 words per pass (8 reads/bank, 8 cycles, shadowed, overlapping the wavefront
  of the current pass). Initial load 8 cycles at layer start.

## 3. Serial FC (not on the array)

- FC1: 32 outputs × 785 MAC-steps (784 + bias), pipelined 1 MAC/cycle, ascending i.
- FC2: 10 outputs × 33 MAC-steps, ascending i, then sigmoid/sigma256/argmax.
- Reads: p2/h3 from FM RAM (1/cycle), weights from the banks via the serial port (1/cycle).

## 4. Cycle budget (recap, arch.md §6.5)

| Stage | Cycles |
|---|---|
| conv1 | 137,993 (incl. 9 initial weight-load cycles) |
| pool1 | 9,408 |
| conv2 | 577,168 (incl. 144 initial weight-load cycles) |
| pool2 | 4,704 |
| FC1 | 25,440 |
| FC2 | 440 |
| bias staging + transitions + present | ≈ 256 |
| **Total** | **≈ 755,400 → BUSY ≤ 760,000** |

## 5. Why 18 passes and not fewer (design note, J4/J7)

A pixel's 1,152 MACs could in principle be spread over 8 pixels pipelined through the array
with 9 sub-passes each, but the per-pixel FP32 partial sums would then need external storage
(1,536 FP32 words ≈ 1.6 Mbit) because the in-PE accumulator is per-pixel. In-PE accumulation
with per-pixel pass serialisation costs 184 cycles/pixel (≈ 8 MACs/cycle effective) but needs
zero extra storage — the chosen point. The wavefront structure (1 column/cycle) is preserved
verbatim; the array is a true systolic engine, its throughput is simply bound by the
accumulation dependency for this tiny network. Documented honestly; not a defect.
