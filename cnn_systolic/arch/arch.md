# cnn_systolic — Microarchitecture Specification
Document ID: ARCH-CNN-SYSTOLIC-v1.0 | Stage: fe-arch | Input: SPEC-CNN-SYSTOLIC-v1.0
Technology: Sky130 130 nm | RTL: pure Verilog-2001 | DFT: none

## 1. Architecture Overview

`cnn_systolic` is a Sky130 ASIC SoC: the verified `cnn_soc` picorv32 AXI→APB shell (reused
verbatim) wrapped around a **new BF16/FP32 CNN accelerator**:

- **8×8 systolic array** (64 PEs, weight-stationary, 2-stage pipelined MAC: BF16 multiply
  (exact→FP32) + FP32 add RN-even/FTZ) computing **conv1 and conv2 only**;
- **serial FP FC datapath** (single pipelined MAC, 1 MAC/cycle steady state) computing FC1
  (784→32) and FC2 (32→10) with the **piecewise sigmoid** (dyadic coefficients, exact FP32);
- **confidence path**: sigma256 = trunc(σ·256+0.5) → argmax (lowest-index ties) → conf =
  (best·100)>>8 → verdict 0/1/2 (TRASH iff conf<50).

The register map, UART line format, 7-bit confidence encoding and memory map are **identical to
cnn_soc** (harness reuse). The bit-exactness contract is the **accumulate order**: the FP golden
C model mirrors the array's per-output-channel FP32 add order (bias first, then sub-pass/column
order) and the FC datapath's per-output ascending input order, with identical FP32 RN-even/FTZ
arithmetic and the identical piecewise sigmoid (see `systolic_dataflow.md`, `piecewise_sigmoid.md`,
`tiling_plan.md` — these three files are binding sub-specifications).

## 2. Design Constraints Inherited from Specification

Restated from `spec/spec.md` §2 (binding): SkyWater SKY130, 130 nm; pure Verilog-2001; no
SystemVerilog; no DFT; no custom analog (SRAM macros as black boxes, PDK-verified at fe-rtl —
OI-001); single clock domain CD_CORE at 100.000 MHz nominal; **fully synchronous** active-low
`rst_n` (shell-verbatim deviation); `$readmemh` ROM initialisation; **no formal/GLS/equivalence**
(REQ-041); per-image BUSY ≤ 760,000 cycles (REQ-021/037, ASM-008); memory map and register map
identical to cnn_soc (§7); harness (`tb_cnn_soc`, `run_soc.sh`, UART diff) reused unchanged.

## 3. Hierarchy and Partitioning

| BLK-ID | Module | Parent | Clock | Reset | Source |
|---|---|---|---|---|---|
| BLK-001 | `cnn_systolic` | (top) | clk | rst_n | custom |
| BLK-002 | `axi_lite_interconnect` | BLK-001 | clk | rst_n | reuse (cnn_soc/rtl, verbatim) |
| BLK-003 | `bootrom` | BLK-001 | clk | rst_n | reuse (verbatim) |
| BLK-004 | `sram` | BLK-001 | clk | rst_n | reuse (verbatim, behavioral 128 KB; macro mapping = fe-yosys, OI-003) |
| BLK-005 | `vec_rom` | BLK-001 | clk | rst_n | reuse (verbatim; loads `stimulus.hex`+`labels.hex` params) |
| BLK-006 | `axi2apb` | BLK-001 | clk | rst_n | reuse (verbatim) |
| BLK-007 | `apb_uart` | BLK-001 | clk | rst_n | reuse (verbatim) |
| BLK-008 | `apb_gpio` | BLK-001 | clk | rst_n | reuse (verbatim) |
| BLK-009 | `cnn_axi_slave` | BLK-001 | clk | rst_n | custom (NEW — regs + image write path + single-shot sequencer) |
| BLK-010 | `systolic_array` | BLK-001 | clk | rst_n | custom (NEW — 8×8 PE grid) |
| BLK-011 | `conv_ctrl` | BLK-001 | clk | rst_n | custom (NEW — layer/pixel/sub-pass FSM + drain + bias staging) |
| BLK-012 | `pool_unit` | BLK-001 | clk | rst_n | custom (NEW — 2×2 max, pool1→p1 banks, pool2→FM) |
| BLK-013 | `fc_datapath` | BLK-001 | clk | rst_n | custom (NEW — serial FP MAC + piecewise sigmoid + sigma256 + argmax/conf/verdict) |
| BLK-014 | `weight_rom` | BLK-001 | clk | rst_n | custom (NEW — 8 interleaved BF16 banks, `$readmemh` weights_bf16.hex) |
| BLK-015 | `fm_ram` | BLK-001 | clk | rst_n | custom (NEW — 8,192×16 BF16 SRAM-macro wrapper) |
| BLK-016 | `img_banks` | BLK-001 | clk | rst_n | custom (NEW — 9 shifted 784×8 banks) |
| BLK-017 | `p1_banks` | BLK-001 | clk | rst_n | custom (NEW — 8 per-channel 256×16 banks) |
| BLK-018 | `picorv32_axi` | BLK-001 | clk | rst_n | ip (cnn_soc/ip/picorv32.v, ISC, verbatim) |
| BLK-019 | `uart_tx` | BLK-007 | clk | rst_n | ip (cnn_soc/ip/uart_tx.v, verbatim) |

Memory-macro black boxes (instantiated inside BLK-014..017 and BLK-004's synthesis mapping):
OpenRAM `sky130_sram_*` (exact cells PDK-verified at fe-rtl; OI-001): 8×4,096×16 (weights),
9×1,024×8 (image banks), 8×256×16 (p1 banks), 1×8,192×16 (FM RAM). Stubs + SDC per REQ-040.

## 4. Block Specifications

#### BLK-001 : cnn_systolic
- Purpose: top-level integration; wiring only.
- Parent: (none) / Clock: clk / Reset: rst_n / Source: custom
- Traces: all REQs (top-level integration)
- Ports: `clk`, `rst_n`, `uart_tx` (output), `led[11:0]` (output) — IF-001/IF-002.
- Parameters: re-exports `UART_CLK_DIV` (default 868), `BOOT_HEX_FILE`, `IMAGES_HEX_FILE`
  (= `arch/golden_model/stimulus.hex`), `LABELS_HEX_FILE` (= `arch/golden_model/labels.hex`),
  `WEIGHTS_HEX_FILE` (= `arch/golden_model/weights_bf16.hex`).
- Internal structure: instantiates BLK-002..BLK-019 per `block_diagram.mmd`; the accelerator
  core (BLK-009..017) sits behind the park/start/done protocol (IFI-003) and a gated clock
  (PWR-001, `core_clk_en = busy`).
- Latency/Throughput: N/A (structural).
- Reset behaviour: passes rst_n through.
- Timing budget: N/A.

#### BLK-009 : cnn_axi_slave (NEW)
- Purpose: cnn_soc-compatible register map + image-buffer write path + single-shot sequencer.
- Parent: BLK-001 / Clock: clk / Reset: rst_n / Source: custom
- Traces: REQ-012, REQ-016..REQ-021, REQ-036
- Ports: IFI-001 (AXI slave side, `sram_`-style naming per shell convention), IFI-003
  (`core_rst_n`, `start`, `exp_label`, `img_waddr/wdata/we`, `pred`, `conf`, `verdict`, `busy`,
  `done`).
- Parameters: none.
- Internal structure: registers per spec §6.3; FSM-001 (sequencer); the CNN_IMG word-write
  unpacker (4 pixels/word, wstrb lanes) + 784×8 staging buffer feeding `img_waddr/wdata/we`
  1 pixel/cycle to BLK-016's broadcast write port.
- Latency: 1-cycle AXI responses; sequencer re-park ≤ 2 cycles after `done`.
- Reset behaviour: all registers 0; sequencer state = parked (`core_rst_n=0`, BUSY=0, DONE=0).
- Error handling: START while BUSY/PARK ignored (REQ-016); PARK abort = core reset + clear
  (REQ-016); WO reads return 0.
- Timing budget: simple register/decode logic.

#### BLK-010 : systolic_array (NEW)
- Purpose: 8×8 weight-stationary PE grid; conv MAC engine.
- Parent: BLK-001 / Clock: clk / Reset: rst_n / Source: custom
- Traces: REQ-022, REQ-023, REQ-024
- Ports: IFI-006 (feed: `act_in[7:0][15:0]`-equivalent wavefront inputs, `w_load[7:0][15:0]` +
  `w_load_en` (shadow), `bias_init[7:0][31:0]` + `bias_en`, `advance`, `drain_en`), IFI-007
  (`dout[7:0][31:0]` — 8 FP32 accumulator values at drain).
- Parameters: none.
- Internal structure: 64 PEs. PE(r,c): two 16-bit BF16 weight registers (active `w_a`,
  shadow `w_s`), 32-bit FP32 accumulator `acc`; stage-1: `prod <= fp32_mul(w_a, act_in)` (BF16×
  BF16 → FP32 exact, registered); stage-2: `acc <= fp32_add(acc, prod)` (RN-even, FTZ,
  registered). Activation registers chain left→right (col c latches col c-1's activation each
  `advance`). `drain_en`: `dout[r] <= acc[r][7]` (parallel, 1 cycle). Weight load: `w_s <=
  w_load[col]` per row/col enable; `swap`: `w_a <= w_s` at sub-pass boundaries.
- Latency: wavefront = 8 feed cycles + 2 pipeline cycles per sub-pass (10 cycles/sub-pass);
  per-PE add order = column order within each sub-pass, sub-passes in pinned order (the
  accumulate-order contract, §5/`systolic_dataflow.md`).
- Throughput: 64 MACs per sub-pass (8 per cycle).
- Reset behaviour: `acc <= 0`, `w_a/w_s <= 0`.
- Error handling: none (deterministic datapath; zero-weight columns add ±0 — identity).
- Timing budget: PE critical path = stage-2 fp32_add (~5-6 ns) within the 10.000 ns period;
  stage-1 BF16 mult is small (~2 ns). Two-stage pipelining gives > 3 ns margin (J7).

#### BLK-011 : conv_ctrl (NEW)
- Purpose: sequences conv1/pool1/conv2/pool2 and the array sub-passes; owns the bias staging
  register file (66×16 flops) and the drain→FM write path with ReLU + BF16 conversion.
- Parent: BLK-001 / Clock: clk / Reset: rst_n / Source: custom
- Traces: REQ-023, REQ-024, REQ-025, REQ-039
- Ports: IFI-005 (pixel/feature reads: img bank + p1 bank + FM read addresses), IFI-006 (array
  feed/control), IFI-007 (drain), IFI-008 (weight bank read addresses + bias reads), IFI-009
  (FM write port), IFI-003 (start/busy/done into the result path).
- Parameters: none.
- Internal structure: FSM-002 (layer/pixel loop), FSM-003 (sub-pass sequencer), loop counters
  (oy[4:0], ox[4:0], oc/group, k[3:0], c[2:0]), address generators (combinational per
  `tiling_plan.md`), drain pipeline (ReLU mux → bf16 convert → 8-word staging → FM writes
  1/cycle, overlapped with the next pixel).
- Latency: conv1 = 137,993 cycles, pool1 = 9,408, conv2 = 577,168, pool2 = 4,704 (cycle
  derivation §6.5).
- Reset behaviour: FSM states + counters 0.
- Error handling: illegal states → default to layer reset (REQ-038).
- Timing budget: address arithmetic ~2 ns; drain BF16 convert ~2 ns.

#### BLK-012 : pool_unit (NEW)
- Purpose: 2×2 max pooling; pool1 reads h1 (FM region A) → writes 8 p1 banks in parallel;
  pool2 reads h2 (FM region A) → writes p2 (FM region B).
- Parent: BLK-001 / Clock: clk / Reset: rst_n / Source: custom
- Traces: REQ-023, REQ-025, REQ-039
- Ports: IFI-005 (FM read/write), IFI-010 (p1 bank write port), IFI-003 (busy).
- Parameters: none.
- Internal structure: FSM-004 (4 reads + compare + write, 6 cycles/unit), `pool_max` 16-bit
  comparator chain (BF16 values, exact compare).
- Latency: 6 cycles per pooled output (9,408 for pool1, 4,704 for pool2).
- Timing budget: comparator tree ~1.5 ns.

#### BLK-013 : fc_datapath (NEW)
- Purpose: serial FP MAC for FC1/FC2; piecewise sigmoid; sigma256; argmax/conf/verdict.
- Parent: BLK-001 / Clock: clk / Reset: rst_n / Source: custom
- Traces: REQ-022, REQ-025, REQ-026, REQ-027
- Ports: IFI-011 (FM read port: p2/h3), IFI-012 (weight bank serial read), IFI-013 (result:
  pred/conf/verdict/busy/done into BLK-009), IFI-003.
- Parameters: none.
- Internal structure: pipelined MAC (read i at t, BF16 mult at t+1, FP32 add at t+2 — 1
  MAC/cycle steady state); bias register file (fc1_b 32, fc2_b 10 staged at layer start);
  piecewise sigmoid unit (segment compare tree + scale-mul (|z|×k, exact dyadic — bit-identical
  to fp32_mul(m,|z|), see §5) + fp32_add + sign fold `1-σ`); sigma256 unit (exp+8 exact scale,
  fp32_add +0.5, truncate); FSM-005 (per-output MAC sequence), FSM-006 (result: argmax strict >
  lowest-index ties, conf = (best·100)>>8, verdict = conf<50 ? 2 : (best==exp ? 0 : 1),
  present strobe).
- Latency: FC1 = 25,440 cycles; FC2 = 440; result ≈ 50 (cycle derivation §6.5).
- Reset behaviour: acc/best/conf/verdict = 0; FSMs reset.
- Timing budget: fp32_add ~5-6 ns; scale-mul ~2 ns; both within 10 ns with the 2-stage MAC.

#### BLK-014 : weight_rom (NEW)
- Purpose: 26,698×16 BF16 weight storage, 8 interleaved banks (bank = addr%8, offset =
  addr/8), `$readmemh` from `weights_bf16.hex` (layout = spec REQ-028: conv1_w[oc*9+t] | b1 |
  conv2_w[oc*72+ic*9+k] | b2 | fc1_w[i*32+j] | b3 | fc2_w[i*10+j] | b4).
- Parent: BLK-001 / Clock: clk / Reset: rst_n / Source: custom
- Traces: REQ-028, REQ-039
- Ports: IFI-008 (8 parallel read addresses + 8 read data — array reload), IFI-012 (serial
  read port + data — FC), IFI-014 (bias reads).
- Parameters: `WEIGHTS_HEX_FILE`.
- Internal structure: 8 × 4,096×16 SRAM-macro instances (blackbox, OI-001) + registered read
  ports; the parallel port presents 8 addresses (one per bank) every cycle.
- Latency: 1-cycle registered reads (bank read latency absorbed by the shadow-load pipeline).
- Reset behaviour: output registers 0 (contents via $readmemh).
- Timing budget: SRAM access ~2 ns.

#### BLK-015 : fm_ram (NEW)
- Purpose: 8,192×16 BF16 feature-map SRAM; region map (§7): h1 0..6271, h2 0..3135 (reuses
  h1's region), p2 6,272..7,055, h3 0..31. Single read/write port, 1 access/cycle.
- Parent: BLK-001 / Clock: clk / Reset: rst_n / Source: custom
- Traces: REQ-039, REQ-040
- Ports: IFI-005 (conv drain writes), IFI-009 (pool/FC read + pool2/FC1 writes).
- Parameters: none.
- Internal structure: 8,192×16 SRAM-macro instance (blackbox) + registered port.
- Latency: 1-cycle read. Hazard-free by construction (§7 proof — identical ping-pong argument
  to cnn's fm_ram).
- Timing budget: SRAM access ~2 ns.

#### BLK-016 : img_banks (NEW)
- Purpose: 9 pre-shifted 784×8 image banks; bank t (t = iy*3+ix) at address (oy,ox) holds
  img[(oy+iy-1)*28 + (ox+ix-1)] or 0 if that tap is out of range. CPU write port broadcasts
  pixel img[py*28+px] to bank t at address ((py-iy+1)*28 + (px-ix+1)) when in range (write-side
  shift ⇒ read-side zero-padding by construction).
- Parent: BLK-001 / Clock: clk / Reset: rst_n / Source: custom
- Traces: REQ-020, REQ-039
- Ports: IFI-004 (broadcast write: addr, data, we × 9), IFI-005 (9 parallel read ports, shared
  address oy*28+ox).
- Parameters: none.
- Internal structure: 9 × 1,024×8 SRAM-macro instances (or 784×8 flop arrays if macros
  unavailable — OI-001) + write address arithmetic (9 combinational shifted addresses + 9
  in-range enables) + read port.
- Latency: 1-cycle reads (absorbed by the wavefront pipeline).
- Timing budget: SRAM access + shift mux ~2.5 ns.

#### BLK-017 : p1_banks (NEW)
- Purpose: 8 per-channel pool1 banks (bank ic = p1[ic], 196×16); shared read address (oy+iy-1)*
  14+(ox+ix-1) with combinational in-range zeroing (conv2 feed); pool1 writes all 8 banks in
  parallel at address oy*14+ox.
- Parent: BLK-001 / Clock: clk / Reset: rst_n / Source: custom
- Traces: REQ-023, REQ-024, REQ-039
- Ports: IFI-010 (write: addr, 8× data, 8× we), IFI-005 (read: shared addr + 8× data + zero
  mux).
- Parameters: none.
- Internal structure: 8 × 256×16 SRAM-macro instances + ports.
- Latency: 1-cycle reads.
- Timing budget: SRAM access ~2 ns.

#### BLK-002..008, BLK-018, BLK-019 : reused shell (verbatim)
- Purpose/behaviour: identical to cnn_soc (REQ-005..015; see cnn_soc arch.md §4 for the
  internal FSM tables of the interconnect/bridge/uart_tx — carried forward unchanged). The
  interconnect decodes `addr[31:28]`; the unmapped responder never hangs (REQ-006). `vec_rom`
  parameters point at the new golden files. `sram.v` stays behavioral (OI-003).

## 5. Datapath Definition

### 5.1 FP32 arithmetic primitives (the bit-exact FP contract — REQ-022)

| Node | Width | Signed | Notes |
|---|---|---|---|
| BF16 operand | 16 | sign+8exp+7man | weights, activations, biases |
| BF16→FP32 expand | 32 | IEEE | exact: `mant << 16`, same exponent |
| FP32 add (`fp32_add`) | 32 | IEEE | RN-even; FTZ (subnormal result → ±0); x+±0 = x; +0+-0 = +0; full IEEE alignment+GRS+normalize+round (26-bit intermediate, 64-bit safe) |
| FP32 mul (`fp32_mul`) | 32 | IEEE | RN-even; FTZ; BF16×BF16 products are EXACT (≤16-bit significand) — rounding is a no-op for MAC operands; full 24×24 for the sigmoid path |
| FP32→BF16 (`bf16_from_fp32`) | 16 | RN-even | keep top 7 mantissa bits; round bit = bit 15, sticky = bits 14..0; mantissa overflow → exp+1; FTZ: subnormal/zero input → ±0 (sign kept) |
| pixel → BF16 | 16 | exact | value = p/256: exp = 119 + (7-clz8(p)), mant = (p << (7-e)) & 0x7F; p=0 → 0. All p ∈ 0..255 exact |
| ReLU | 32 | — | sign bit → +0 else value (exact) |

FTZ justification (range analysis): all BF16 weights have |w| ≥ 2^-60 (measured in the export
run: min |w| ≈ 1e-6 ≫ 2^-126; verified again by the golden's flush counter — see
`golden_model/README.md`); activations are ReLU'd sums of ≤ 1,152 products of bounded operands;
no computed value approaches 2^-126; the FTZ pins exist for total determinism and are never
exercised in the 10,000-image run (flush counter == 0). FP32 overflow to ±Inf is unreachable
(|acc| ≤ 784 × 2^11 × 2^8 ≪ 2^127); if it ever occurred the unit saturates per IEEE (documented,
unreachable).

### 5.2 Systolic accumulate order (THE contract — see `systolic_dataflow.md` for the full spec)

Per output channel, the FP32 add sequence is exactly:

- **conv1** (per pixel (oy,ox), per oc): `acc = bias1[oc]`; sub-pass A: for c = 0..7
  (t = c): `acc = fadd(acc, fmul(w1[oc][t], act_t))`; sub-pass B: for c = 0..7
  (w = w1[oc][8] at c=0, 0 at c>0): `acc = fadd(acc, fmul(w, act_c))`; `h1 = bf16(relu(acc))`.
  act_t = img_bank_t[oy*28+ox] (0 when the tap is OOB — bank pre-shift).
- **conv2** (per pixel (oy,ox), per oc, g = oc/8): `acc = bias2[oc]`; for k = 0..8
  (k = iy*3+ix): for c = 0..7 (ic): `acc = fadd(acc, fmul(w2[oc][c*9+k], act(k,c)))` where
  act(k,c) = p1_bank_c[(oy+iy-1)*14 + (ox+ix-1)] or 0 if OOB; `h2 = bf16(relu(acc))`.
  (Per-oc order: (k,c) lexicographic — identical for all oc; oc rows run in parallel in the
  array, sequentially in the golden.)
- **FC1** (per j): `acc = bias3[j]`; for i = 0..783: `acc = fadd(acc, fmul(w3[i*32+j],
  p2[i]))`; `h3[j] = bf16(piecewise_sigmoid(acc))`.
- **FC2** (per j): `acc = bias4[j]`; for i = 0..31: `acc = fadd(acc, fmul(w4[i*10+j], h3[i]))`;
  `sigma = piecewise_sigmoid(acc)`; `sigma256 = trunc(fadd(fmul(sigma, 256.0), 0.5))` (all
  exact FP32 steps); argmax strict `>`, lowest-index ties; `conf = (sigma256_best*100)>>8`;
  `verdict = conf<50 ? 2 : (best==exp_label ? 0 : 1)`.

### 5.3 Piecewise sigmoid (see `piecewise_sigmoid.md` for the full spec)

The activation target is the **trained rational sigmoid** `act_float(z) = 0.5 + 0.5·z/(1+|z|)`
— the function this network family was trained with (`train_cnn.py act_float`) and that the old
Q8.8 LUT implemented bit-exactly — **not** the logistic 1/(1+e^-z). σ(z): x = |z| (sign cleared,
exact); segment select by FP32 compare against dyadic breakpoints {1/4, 1/2, 3/4, 1, 3/2, 2, 3,
4, 6, 8, 12, 16, 24}; σ = fp32_add(m·x, c) with dyadic m/c (exact FP32 bit patterns, table in
`piecewise_sigmoid.md`); x ≥ 24 → σ = 251/256 (saturation); z < 0 → σ = fp32_sub(1.0, σ). The
RTL's scale-mul (mantissa × k + exponent − s, RN-even) is bit-identical to fp32_mul(m, x)
because m = k·2^-s exactly. Max |σ − act_float| ≈ 0.003 (≤ 1 confidence point). Measured
full-set accuracy with this sigmoid: 96.08 % (vs the Q8.8 network's 96.35 %).

### 5.4 Widths and overflow policy

All FP32 nodes: IEEE bit patterns (32 bits), RN-even, FTZ, no saturating clamps anywhere except
the pinned sigma256 truncation and the integer conf shift. No node can overflow (range analysis
above). The only integer nodes: loop counters, addresses, sigma256 (9 bits), conf (7 bits),
verdict (2 bits), pred (4 bits) — all bounded by construction.

## 6. Control FSMs

### 6.0 Shared registers (conv_ctrl)
`state[2:0]` (FSM-002), `sub[1:0]` (FSM-003), `oy[4:0]`, `ox[4:0]`, `oc[3:0]`/`grp[0:0]`,
`k[3:0]` (0..8), `c[2:0]` (0..7), `px_cnt[12:0]` (pixel counter), `bias[65:0][15:0]` staging
regfile, drain staging `dstage[7:0][15:0]` (BF16), plus fc_datapath's `j[4:0]`/`i[9:0]` and
result registers `best_val[8:0]`, `best_idx[3:0]`, `conf[6:0]`, `verdict[1:0]`.

### 6.1 FSM-001 : cnn_axi_slave sequencer (binary, 3 states, reset = ST_PARK)

| State | Condition | Next | Action |
|---|---|---|---|
| ST_PARK | `start_i && !busy` (START write while parked) | ST_RUN | `core_rst_n<=1` (release park); `busy<=1`; `start<=1` (1-cycle strobe) |
| ST_PARK | else | ST_PARK | parked; BUSY/DONE = 0 |
| ST_RUN | `done_i` | ST_PARK | latch pred/conf/verdict into CNN_RESULT; `DONE<=1`; `busy<=0`; `core_rst_n<=0` (re-park ≤ 2 cycles) |
| ST_RUN | `parker` (PARK=1 written) | ST_PARK | abort: `core_rst_n<=0`; `busy<=0`; `DONE<=0` |
| ST_RUN | else | ST_RUN | running |
| (any other) | default | ST_PARK | illegal-state recovery |

START-while-BUSY and START-while-PARK are ignored by the decode (REQ-016). DONE clears on the
next START or a PARK write (REQ-017).

### 6.2 FSM-002 : conv_ctrl layer FSM (binary, 7 states, reset = ST_CONV1)

| State | Condition | Next | Action |
|---|---|---|---|
| ST_CONV1 | layer not done (px < 6272) | ST_CONV1 | run FSM-003 in conv1 mode (2 sub-passes/px); drain writes h1[oc*784+oy*28+ox] |
| ST_CONV1 | done | ST_POOL1 | stage bias1 (8 reads); px=0 |
| ST_POOL1 | not done (px < 1568) | ST_POOL1 | run FSM-004; pool1 writes 8 p1 banks |
| ST_POOL1 | done | ST_CONV2 | stage bias2 (16 reads); px=0 |
| ST_CONV2 | not done (px < 3136) | ST_CONV2 | run FSM-003 in conv2 mode (18 sub-passes/px); drain writes h2[oc*196+oy*14+ox] |
| ST_CONV2 | done | ST_POOL2 | px=0 |
| ST_POOL2 | not done (px < 784) | ST_POOL2 | run FSM-004; pool2 writes p2[oc*49+oy*7+ox] at FM 6272+ |
| ST_POOL2 | done | ST_FC1 | stage bias3 (32 reads); j=0 |
| ST_FC1 | not done (j < 32) | ST_FC1 | run FSM-005 (fc1 mode); h3[j] written to FM[j] |
| ST_FC1 | done | ST_FC2 | stage bias4 (10 reads); j=0 |
| ST_FC2 | not done (j < 10) | ST_FC2 | run FSM-005 (fc2 mode) + FSM-006 argmax update |
| ST_FC2 | done | ST_PRESENT | — |
| ST_PRESENT | (always) | ST_DONE | `conf<=(best_val*100)>>8`; `verdict<=...`; `pred<=best_idx`; present strobe → BLK-009 latches + re-parks |
| ST_DONE | (always) | ST_CONV1 | `done_i<=1` (1 cycle); all counters reset |
| (any other) | default | ST_CONV1 | illegal-state recovery |

### 6.3 FSM-003 : sub-pass sequencer (binary, 4 states, reset = ST_LOAD)

Per pixel: sequence = [bias-init g0] then (per sub-pass: shadow-load + wavefront + drain-2) …
[group switch: drain g0 + bias-init g1] … final drain. Timing per sub-pass = 10 cycles
(8 wavefront feeds + 2 pipeline drain); weight shadow loads overlap the wavefront (8 reads per
bank per load; conv2's 9 loads/pixel-group, conv1's 2 loads/pixel).

| State | Condition | Next | Action |
|---|---|---|---|
| ST_BIAS | (always) | ST_WAVE | `acc[r] <= bias[grp*8+r]` (8 rows parallel, 1 cycle) |
| ST_WAVE | `c < 7` | ST_WAVE | present bank address (pixel, k) 1 cycle ahead; `advance`; col c latches act; stage-1/stage-2 pipeline |
| ST_WAVE | `c == 7` | ST_DRAIN | last feed; pipeline drains (2 cycles) |
| ST_DRAIN | `k < last_of_group` | ST_WAVE | `swap` (w_a <= w_s); shadow-load next sub-pass; k++ |
| ST_DRAIN | group 0 last (conv2) | ST_BIAS | drain 8 accs → ReLU → bf16 → dstage; `grp=1`; k=0 |
| ST_DRAIN | group 1 last (conv2) / pass B last (conv1) | ST_DONE_PX | drain 8 accs → dstage; FM writes drain 1/cycle during the next pixel (overlapped) |
| ST_DONE_PX | (always) | ST_BIAS (next pixel) | px++; FM write drain ongoing |
| (any other) | default | ST_BIAS | illegal-state recovery |

conv1: 2 sub-passes (pass A: taps 0..7, load 64 w; pass B: tap 8 + zeros, load 8 w) — no group
switch. conv2: 18 sub-passes (g = p/9, k = p%9), group switch after k=8.

### 6.4 FSM-004 : pool FSM (binary, 4 states, reset = PH_R0)

| State | Condition | Next | Action |
|---|---|---|---|
| PH_R0 | always | PH_R1 | FM read (2y,2x); latch a |
| PH_R1 | always | PH_R2 | FM read (2y,2x+1); max(a,b) |
| PH_R2 | always | PH_R3 | FM read (2y+1,2x); max |
| PH_R3 | always | PH_WB | FM read (2y+1,2x+1); max |
| PH_WB | always | PH_R0 | write: pool1 → 8 p1 banks (parallel, addr oy*14+ox); pool2 → FM 6272+oc*49+oy*7+ox |
| (any other) | default | PH_R0 | illegal-state recovery |

### 6.5 FSM-005 : fc MAC sequencer (binary, 4 states, reset = PH_BIAS)

| State | Condition | Next | Action |
|---|---|---|---|
| PH_BIAS | always | PH_MAC | `acc <= bias[j]`; i=0 |
| PH_MAC | `i < N-1` | PH_MAC | read p2/h3[i] (FM) + w[i][j] (banks) in parallel; pipelined mult/add; i++ |
| PH_MAC | `i == N-1` | PH_ACT | last MAC in flight |
| PH_ACT | always | PH_WB | FC1: `sigma = piecewise(acc)` → `h3[j] = bf16(sigma)` → FM write FM[j]; FC2: `sigma = piecewise(acc)` → `sigma256 = trunc(...)` → FSM-006 |
| PH_WB | always | PH_BIAS | j++ (or done → FSM-002) |
| (any other) | default | PH_BIAS | illegal-state recovery |

### 6.6 FSM-006 : result FSM (argmax/conf/verdict/present, combinational + registered)

argmax update on each FC2 output (in ST_FC2): `if (j==0 || sigma256 > best_val) begin
best_val<=sigma256; best_idx<=j; end` — strict `>` ⇒ lowest-index ties (matches the golden's
`out[i] > out[best]`). At ST_PRESENT: `conf = (best_val*100)>>8` (integer, exact);
`verdict = (conf < 50) ? 2 : ((best_idx == exp_label) ? 0 : 1)`; present strobe.

### 6.7 Compute cycle-budget derivation (REQ-021/037, ASM-008)

| Layer | Units | Cycles/unit | Total |
|---|---|---|---|
| CONV1 | 6,272 px | 1 bias + 2×10 sub-pass + 1 drain = 22 | 137,984 |
| CONV1 weight loads (first pixel) | — | 9 | 9 |
| POOL1 | 1,568 | 6 | 9,408 |
| CONV2 | 3,136 px | 1 + 9×10 + 1 (drain g0) + 1 + 9×10 + 1 = 184 | 577,024 |
| CONV2 weight loads (first pixel) | — | 144 | 144 |
| POOL2 | 784 | 6 | 4,704 |
| FC1 | 32 | ~795 (bias 1 + 784 MACs pipelined + drain 2 + sigmoid ~7 + write 1) | 25,440 |
| FC2 | 10 | ~44 | 440 |
| Bias staging + transitions + present | — | — | ~256 |

**Compute total ≈ 755,400 cycles/image → BUSY ≤ 760,000 cycles per START (REQ-021/037).**
Firmware poll guard: 3,000,000 iterations × ~4 cycles ≈ 12M cycles ≈ 15.8× margin (constant
unchanged from cnn_soc; the comment in firmware is updated at P4). G5 budgets hold: 100 × 760K
= 76.0M + UART 100×69×10×868 ≈ 59.9M + firmware ≈ 5M = 140.9M < 150M; first line at
CLK_DIV=868: boot ~50K + image copy ~5K + 760K + line 599K ≈ 1.41M < 1.5M.

## 7. Memory Map and Register Definition

### 7.1 SoC memory map — identical to cnn_soc (spec §3.1): bootrom 0x0000_0000 (4 KB),
SRAM 0x0001_0000 (128 KB), vec_rom 0x1000_0000 (78,500 B), AXI2APB 0x4000_0000
(UART +0x0000, GPIO +0x1000), cnn_axi_slave 0x5000_0000. Decode on addr[31:28]; unmapped →
read 0 / write ignored / complete (REQ-006/007).

### 7.2 Register map — identical to cnn_soc spec §6 (binding): CNN_CTRL 0x5000_0000 (START[0]
write-1 strobe, PARK[1] RW), CNN_STATUS 0x5000_0004 (BUSY[0] RO, DONE[1] RO, [31:2] read 0),
CNN_RESULT 0x5000_0008 (pred[3:0], conf[14:8] 0..100, verdict[17:16]; [31:18],[7:4] read 0),
CNN_EXP 0x5000_000C (WO, [3:0], reads 0), CNN_IMG 0x5000_0100..0x40F (WO, 784 B, LE word
packing). UART_TX 0x4000_0000 (W), UART_STAT 0x4000_0004 (R, [0] BUSY), GPIO_OUT 0x4000_1000
(RW, [11:0]). Every register resets to 0; reserved bits read 0 / writes ignored.

### 7.3 Accelerator memories (REQ-039/040)

| MEM-ID | Instance (BLK) | Depth×Width | Contents / address map | Implementation |
|---|---|---|---|---|
| MEM-001 | weight banks (BLK-014) | 8 × 4,096 × 16 BF16 | 26,698 words, bank = addr%8, offset = addr/8; layout per REQ-028 | SRAM macro (OI-001) or flops |
| MEM-002 | img banks (BLK-016) | 9 × 1,024 × 8 | bank t (t=iy*3+ix) at (oy,ox) = img[(oy+iy-1),(ox+ix-1)] or 0 (write-side shift) | SRAM macro or flops |
| MEM-003 | p1 banks (BLK-017) | 8 × 256 × 16 BF16 | bank ic = p1[ic][oy*14+ox], 196 used | SRAM macro or flops |
| MEM-004 | fm_ram (BLK-015) | 8,192 × 16 BF16 | h1 0..6271 (oc*784+oy*28+ox); h2 0..3135 (oc*196+oy*14+ox, reuses h1 region); p2 6,272..7,055 (oc*49+oy*7+ox); h3 0..31 (reuses h2 region) | SRAM macro |
| MEM-005 | bias regfile | 66 × 16 BF16 | conv1_b 8 + conv2_b 16 + fc1_b 32 + fc2_b 10, staged at layer start | flops |
| MEM-006 | bootrom | 4,096 × 8 | firmware hex ($readmemh) | reused shell |
| MEM-007 | sram | 32,768 × 32 | stack (behavioral) | reused shell (OI-003) |
| MEM-008 | vec_rom | 78,500 × 8 | stimulus.hex + labels.hex ($readmemh) | reused shell |

**Hazard-free proof (fm_ram):** conv1 writes h1 fully before pool1 reads it; pool1 writes the
p1 banks (not FM); conv2 writes h2 (region A) only after pool1 consumed h1 (region A); pool2
reads h2 (region A) and writes p2 (region B, disjoint); FC1 reads p2 (region B) and writes h3
(region A, 0..31); FC2 reads h3 (region A) after FC1's last write. No write precedes the last
read of the data it overwrites — by construction (layer FSM serialises layers).

## 8. Internal Interfaces (IFI-###)

See `interface_defs.yaml` for full signal lists. Key handshake semantics:

- **IFI-003 cnn_core_if** (BLK-009 ↔ core): `core_rst_n` park (level), `start` (1-cycle pulse),
  `done` (1-cycle pulse), data/status level signals. No backpressure (single-shot).
- **IFI-006 array feed**: `advance` (1 per wavefront cycle), shadow-load strobes, `swap`,
  bias-init strobe, drain strobe. `valid`/`ready` none — the FSM owns all timing; data must be
  stable while the relevant strobe is asserted.
- **IFI-005/009/010/011/012 memory ports**: registered single-cycle reads; write-enable strobes;
  no read/write contention by construction (accesses serialised by the owning FSM).
- **IFI-012 FC serial weight read**: 1 word/cycle from bank (addr%8) — a mux over the 8 bank
  read buses.

## 9. Clock and Reset Architecture

One domain `CD_CORE` (clk, 100.000 MHz, CLK-001). One reset `rst_n`, active-low, fully
synchronous (RST-001, REQ-035) — no reset synchroniser (single domain). The accelerator core's
clock is gated by `core_clk_en = busy` (PWR-001, §power_plan.md): while parked, the core is in
its reset-stable state, so gating is state-lossless. Zero CDC paths (cdc_plan.md empty
enumeration). Clock relationships: none (single domain).

## 10. IP Reuse Plan

| BLK-ID | Decision | Repo | Licence | Status | Adapter needed |
|---|---|---|---|---|---|
| BLK-002..008 | reuse (verbatim) | `cnn_soc/rtl/*.v` (local, read this session) | project-internal | verified | none |
| BLK-018 | reuse (verbatim) | `cnn_soc/ip/picorv32.v` (local; vendored from skill-tests/ex6) | ISC | verified | none (parameter list per REQ-002) |
| BLK-019 | reuse (verbatim) | `cnn_soc/ip/uart_tx.v` (local) | project-internal | verified | none (`CLK_DIV` param) |
| memory macros | blackbox | Sky130 PDK / OpenRAM (local) | Apache-2.0/PDK | unverified_candidate (OI-001) | Verilog stub + SDC; flop fallback |

No external search performed (brief directs verbatim local reuse — cnn_soc precedent). Carried
forward: picorv32 ISC provenance (IP_PROVENANCE.md read this session). All NEW blocks are
custom; nothing is undecided.

## 11. Golden Model Description

`arch/golden_model/golden_ref_model.c` — NEW FP golden (integer-only C99; **no float** in the
datapath): implements §5's FP32 primitives (fp32_add/fp32_mul RN-even/FTZ in integer bit
manipulation), BF16 conversion/expansion, the pixel mapping, the piecewise sigmoid (bit-pattern
constants), and the pinned accumulate orders of §5.2. Reads `weights_bf16.hex` +
`../cnn/data/t10k_images.bin` + `../cnn/data/t10k_labels.bin`; writes
`expected_outputs.txt` (100 UART lines — the G1 diff target), `expected.hex` (400 words — the
G2 target), `stimulus.hex` (78,400 pixel words), `labels.hex` (100 words); prints the full
10,000-image UART stream + summary to stdout (accuracy report) and a flush counter (FTZ
evidence). `--vectors` mode runs the directed vector set (`golden_model_test_vectors.h`) against
the hand-derived `expected_vectors.txt` (G7). `check_fp.py` is the independent numpy twin (G8).
Build/run (NOT executed by fe-arch — see note): see `golden_model/README.md`.

> **Execution note (J1, flagged):** per the 2026-08-28 18:31Z autonomy override and the brief's
> deliverable list (weights_bf16.hex, regenerated expected outputs are P1 deliverables), the
> export script and the golden model ARE executed once during this fe-arch pass, with commands
> and outputs logged in WORKLOG.md — precedent: mnist_npu/cnn fe-arch runs. The fe-arch skill's
> "do not compile/run" clause is knowingly overridden here; `executed_by_skill: true` in
> arch_manifest.yaml documents it.
>
> **P1 results (measured this pass):** export cross-check 26,698/26,698 (independent numpy
> conversion); directed FP vectors 66/66 vs hand-derived values (the sign-coverage vectors 64/65
> caught a real f32_add sign bug — fixed, see WORKLOG); 100-image cross-check 100/100 vs the
> independent numpy twin (G8); full 10,000-image accuracy **96.08 %** (9608 correct / 142
> incorrect / 250 trash; Q8.8 baseline 96.35 %); FTZ flush counters all zero (the FTZ policy
> never fires, as predicted by the §5.1 range analysis); G6 reproducibility byte-identical on
> re-run. OI-002 resolved: BF16 + piecewise-sigmoid accuracy ≈ parity with the Q8.8 baseline.

## 12. Verification Hooks

Pure-Verilog observation points for the later verification stage: `conv_ctrl` FSM states +
counters (FSM coverage), `systolic_array` PE acc registers + wavefront position (VP-ARR-002/003),
`fc_datapath.acc`/sigma/sigma256 (VP-FC-001, VP-SIG-001/002), `weight_rom` bank addresses
(VP-WROM-001), `fm_ram`/`p1_banks`/`img_banks` read/write address+data every cycle
(VP-MEM-001/VP-POOL-001), `cnn_axi_slave` sequencer state + BUSY/DONE (VP-CNN-001/002), top-level
`uart_tx` pin + `led[11:0]` (VP-TOP-002..004). All plain hierarchical references — no DFT mux.

## 13. Traceability: REQ -> BLK

| REQ-ID | BLK-ID(s) |
|---|---|
| REQ-001 | BLK-001 (all) |
| REQ-002 | BLK-018 |
| REQ-003 | BLK-018, BLK-003 |
| REQ-004 | BLK-003 (firmware, P4) |
| REQ-005 | BLK-002, BLK-006 |
| REQ-006 | BLK-002 |
| REQ-007 | BLK-002 |
| REQ-008 | BLK-003 |
| REQ-009 | BLK-004 |
| REQ-010 | BLK-005 |
| REQ-011 | BLK-006 |
| REQ-012 | BLK-009 |
| REQ-013 | BLK-007, BLK-019 |
| REQ-014 | BLK-007 |
| REQ-015 | BLK-008 |
| REQ-016 | BLK-009 |
| REQ-017 | BLK-009 |
| REQ-018 | BLK-009, BLK-013 |
| REQ-019 | BLK-009, BLK-013 |
| REQ-020 | BLK-009, BLK-016 |
| REQ-021 | BLK-009 |
| REQ-022 | BLK-010, BLK-013 |
| REQ-023 | BLK-010, BLK-011 |
| REQ-024 | BLK-011, BLK-016, BLK-017 |
| REQ-025 | BLK-013, BLK-012, BLK-011 |
| REQ-026 | BLK-013 |
| REQ-027 | BLK-013 |
| REQ-028 | BLK-014 |
| REQ-029 | golden model (P1 deliverable) |
| REQ-030 | BLK-001 (firmware, P4) |
| REQ-031 | BLK-001 (firmware, P4) |
| REQ-032 | BLK-008 (firmware, P4) |
| REQ-033 | BLK-018 (firmware, P4) |
| REQ-034 | BLK-001 (all) |
| REQ-035 | BLK-001 (all) |
| REQ-036 | BLK-001 (all) |
| REQ-037 | BLK-009, BLK-011, BLK-013 |
| REQ-038 | BLK-001 (all) |
| REQ-039 | BLK-014..017, BLK-011, BLK-012 |
| REQ-040 | BLK-014..017, BLK-004 |
| REQ-041 | BLK-001 (project scope) |

Every `must` requirement maps to ≥ 1 block; every block traces to ≥ 1 requirement. Zero
orphans.

## 14. Assumptions and Open Issues

Assumptions ASM-001..009 carried from spec (acknowledged under the autonomy override, logged
J1..J8 in WORKLOG.md). Open issues: OI-001 (SRAM macro PDK-verify at fe-rtl), OI-002 (BF16
accuracy measured at the P1 golden run — see golden_model/README.md result), OI-003 (shell sram
mapping at fe-yosys). None blocking. New architecture-local decisions (not ASMs — pinned design
choices): the PE 2-stage MAC pipeline (J7), the in-PE accumulation with per-pixel sub-pass
serialisation (cross-pixel pipelining rejected: 1.6 Mbit external FP32 partial storage), the
drain staging + overlapped FM writes, the interleaved weight-bank layout, the 9-bank shifted
image buffer, the write-side-shift zero-padding.

## 15. Estimated Area and Timing Budget

Qualitative (no synthesis at this stage; fe-opensta measures at P3). **Logic flops:**
systolic array 64 PEs × (2×16 w + 32 acc + 16 act + 32 prod ≈ 112) ≈ 7.2 K flops; conv_ctrl +
FSMs + counters ≈ 0.5 K; fc_datapath ≈ 1 K; slave ≈ 0.3 K; shell ≈ 0.5 K (excl. memories);
bias regfile 66×16 ≈ 1.1 K. **Logic gates:** dominated by 64 × fp32_add (24-bit align/add/
normalize/round ≈ 400-600 GE each) ≈ 25-38 KGE + 64 × BF16 mult ≈ 2-4 KGE + sigmoid scale-mul
+ fp32_add ≈ 1.5 KGE. **Memories (SRAM macros, subject to OI-001):** weights 524 Kbit, FM 131
Kbit, img 74 Kbit, p1 33 Kbit ≈ 762 Kbit (vs naive 427+125+56+25 ≈ 633 Kbit — banking
overhead ≈ 20%, documented J5); flop-array fallback would add ≈ 762 K flops ≈ 1.5 MGE (rejected
unless macros unavailable). **Timing:** critical path = fp32_add in the PE stage-2 (~5-6 ns) or
the FC fp32_add (~5-6 ns); everything else ≤ 3 ns; > 3 ns margin at 10 ns across the board
(2-stage PE pipeline, J7). **Area drivers overall:** SRAM macros, then the PE grid.

**Power (summary, see power_plan.md):** single always-on domain; core clock gated by `busy`
(PWR-001, dlclkp ICG); operand isolation on the weight banks/array when idle; expected core
activity ≈ 755K cycles per ~1.4M-cycle image period at CLK_DIV=868 (≈ 54% duty), plus the shell
(CPU spinning in the poll loop, UART 59.9M bit-cycles per 100 images ≈ 40% of the G5 budget).
No DFT-aware cells anywhere.
