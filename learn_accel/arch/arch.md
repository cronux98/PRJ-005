# rinriAI — Microarchitecture Specification
Document ID: ARCH-LEARN-ACCEL-v1.0 | Stage: fe-arch | Input: SPEC-LEARN-ACCEL-v1.0
Technology: Sky130 130 nm | RTL: pure Verilog-2001 | DFT: none

## 1. Architecture Overview

`learn_accel` is a single-clock-domain, firmware-driven **online-learning MLP accelerator**:
a two-layer MLP (FEATURES × HIDDEN × CLASSES; defaults 784×32×10) that performs forward
pass, backpropagation and online SGD weight updates per received sample. Firmware controls
it via an APB4 register interface and feeds samples (FEATURES pixel bytes + 1 label byte)
through a byte-streaming port. Learning is observable through saturating accuracy counters,
the last-prediction register, and full weight load/dump.

The datapath is **16-bit signed Q8.8 fixed point** throughout (REQ-004). The sigmoid
activation is implemented as a deterministic **integer rational approximation**
σ(z) = ½ + ½·z/(1+|z|) — no transcendental LUT table is required, so RTL and the C golden
model are bit-exact by construction (ASM-005 refinement, §14). Training uses the Nielsen
ch.1–2 quadratic-cost backprop equations with a shift-based learning rate η = 2^(−lr_shift)
(REQ-005).

Seven blocks, one clock domain, zero CDC paths, zero reused IP (all custom per directive).

## 2. Design Constraints Inherited from Specification

- Sky130, 130 nm; pure Verilog-2001; no DFT; no custom analog; no external IP.
- Single clock domain CD_CORE (25 MHz nominal @ tt, 40.000 ns; original 50 MHz target superseded
  — REQ-015 erratum 2026-08-20, Rinri: relax the clock, no pipelining); synchronous active-low
  reset `rst_n`
  (ASM-002 — synchronous, per design guidance; note the fe-arch default template is
  async-assert/sync-deassert, but this project's spec pins synchronous).
- No `#` delays, no `initial` blocks, no latches, no combinational loops in RTL.
- Q8.8 fixed point (ASM-004); η = 2^(−lr_shift), lr_shift 0..15, register reset 8 (REQ-005).
- Timing budgets: input/output delay 6.0 ns (fixed; originally 30% of the 20 ns period); clock
  uncertainty 1.0 ns setup / 0.1 ns hold (kept per REQ-015 erratum; was 5% of the 20 ns period,
  ASM-009). Per-sample budgets: train ≤ 200,000 cycles, infer ≤ 30,000 cycles at defaults
  (REQ-016 — cycle budgets unchanged; at 25 MHz wall time doubles).
- Bit-exact agreement with `arch/golden_model/golden_ref_model.c` (REQ-011) — the exact
  arithmetic rules in §5 are the contract.

## 3. Hierarchy and Partitioning

| BLK-ID | Module | Parent | Clock | Reset | Source |
|---|---|---|---|---|---|
| BLK-001 | learn_accel | — (top) | clk_core | rst_n | custom |
| BLK-002 | apb_regs | learn_accel | clk_core | rst_n | custom |
| BLK-003 | sample_stream | learn_accel | clk_core | rst_n | custom |
| BLK-004 | learner | learn_accel | clk_core | rst_n | custom |
| BLK-005 | weight_ram | learn_accel | clk_core | rst_n | custom |
| BLK-006 | stats | learn_accel | clk_core | rst_n | custom |
| BLK-007 | div_seq | learn_accel (used by BLK-004) | clk_core | rst_n | custom |

Partitioning rationale: control (BLK-004 FSM) vs datapath (MAC/activation inside BLK-004,
divider BLK-007) vs interface adapters (BLK-002 APB, BLK-003 stream) vs storage (BLK-005
weight RAM) vs observability (BLK-006 counters). Each block 100–600 lines; no block has
more than one responsibility.

## 4. Block Specifications

### 4.1 BLK-001 : learn_accel (top)
- **Purpose**: instantiate and wire BLK-002..007; own the external ports (IF-001, IF-002,
  CLK-001, RST-001); pass through parameters.
- **Parent / Clock / Reset / Source**: — / clk_core / rst_n / custom.
- **Traces**: REQ-001, REQ-008, REQ-009, REQ-012, REQ-014, REQ-015, REQ-022.
- **Ports**: union of `interfaces.yaml` IF-001 (apb_slave) + IF-002 (sample_stream) +
  clk_core + rst_n (see `interface_defs.yaml`).
- **Parameters**: `FEATURES` (784, 1..4096), `HIDDEN` (32, 1..512), `CLASSES` (10, 1..256);
  constraint FEATURES·HIDDEN + HIDDEN + HIDDEN·CLASSES + CLASSES ≤ 65535 (REQ-022).
  Derived localparams: W_TOT, W_F = clog2(FEATURES+1), W_H = clog2(HIDDEN+1),
  W_C = clog2(CLASSES+1), W_A = 16 (weight address), W_CNT32 (counter width 32).
- **Internal structure**: pure wiring + parameter distribution; no logic.
- **Latency/Throughput**: n/a (interconnect).
- **Reset behaviour**: n/a.
- **Error handling**: n/a.
- **Timing budget**: 40.000 ns period shared; see §15.

### 4.2 BLK-002 : apb_regs (APB4 register block)
- **Purpose**: decode APB4 transfers into the §7 register map; enforce access types and
  self-clearing strobes; bridge CSR weight accesses (WADDR/WDATA) to weight_ram port B with
  auto-increment; gate init_weights on `!busy`; assemble STATUS.
- **Parent / Clock / Reset / Source**: learn_accel / clk_core / rst_n / custom.
- **Traces**: REQ-006, REQ-009, REQ-010, REQ-013, REQ-017, REQ-020.
- **Ports**: IF-001 (external), IFI-001, IFI-005, IFI-006, IFI-009 (see interface_defs.yaml).
- **Parameters**: none (uses top parameters).
- **Internal structure**: address decode (combinational; window 0x00..0x24), register file
  (CTRL, LRN_RATE, WADDR, WDATA shadow, W_INIT_VAL), strobe generator (start/step/halt/
  clr_stats/init_weights = 1-cycle pulses from APB writes, self-clearing by construction),
  WADDR auto-increment logic, STATUS mux. No FSM (zero-wait APB is combinational decode).
- **Latency/Throughput**: 1 transfer/cycle, zero wait states; PREADY=1 in ACCESS phase;
  PSLVERR=1 for addresses outside 0x00..0x24.
- **Reset behaviour**: CTRL=0, LRN_RATE=0x08, WADDR=0, WDATA=0, W_INIT_VAL=0 (STATUS and
  counters come from other blocks; PRED from stats).
- **Error handling**: reserved address → PSLVERR, no side effects; writes to RO registers
  and reserved bits ignored; WDATA write while `init_busy` is dropped (documented, §4.5);
  init_weights strobe ignored while `busy` (STATUS.busy) is asserted.
- **Timing budget**: address decode → mux → prdata path ≤ 6.0 ns output budget.

### 4.3 BLK-003 : sample_stream (framing + sample RAM)
- **Purpose**: accept the byte stream (IF-002), frame samples (FEATURES pixels + label),
  detect malformed frames, store the sample in MEM-002, present `sample_valid`/label to the
  learner, provide the pixel read port.
- **Parent / Clock / Reset / Source**: learn_accel / clk_core / rst_n / custom.
- **Traces**: REQ-008, REQ-016, REQ-018.
- **Ports**: IF-002 (external), IFI-003, IFI-007, IFI-008.
- **Parameters**: FEATURES, W_F.
- **Internal structure**: FSM-002, pixel counter `px_cnt` (W_F bits), label register
  `label_ff[7:0]`, MEM-002 (sample RAM), `sample_valid` level + `ack_p` clear.
- **Latency/Throughput**: 1 byte/cycle while `s_ready`; s_ready = `accept_en` from learner.
- **Reset behaviour**: px_cnt=0, label_ff=0, sample_valid=0, state=WAIT.
- **Error handling**: malformed frames per REQ-018 → `err_p` pulse to stats, RESYNC until
  next s_last (FSM-002).
- **Timing budget**: s_data → MEM-002 write, RAM read → learner ≤ 8 ns.

### 4.4 BLK-004 : learner (training/inference datapath + control)
- **Purpose**: execute forward pass, backpropagation, online SGD update per sample; own
  `run_active`/step/halt semantics; produce prediction and counter pulses.
- **Parent / Clock / Reset / Source**: learn_accel / clk_core / rst_n / custom.
- **Traces**: REQ-002, REQ-003, REQ-004, REQ-005, REQ-011, REQ-016, REQ-017, REQ-021.
- **Ports**: IFI-001, IFI-002, IFI-003, IFI-004, IFI-008, IFI-009; instantiates BLK-007.
- **Parameters**: FEATURES, HIDDEN, CLASSES, W_F, W_H, W_C.
- **Internal structure**: FSM-001; datapath: 16×16 signed multiplier (combinational,
  32-bit product), 48-bit accumulator, sat16, trunc_pow2 helper, sigmoid call unit
  (128·z / (256+|z|) via BLK-007), argmax comparator; local memories MEM-003 (act_h),
  MEM-004 (out/delta buffer), MEM-005 (delta_h); control registers: run_active,
  step_mode, halt_pending, freeze_ff, lr_shift_ff, label_ff, best_val/best_idx,
  phase counters f_cnt/h_cnt/c_cnt, micro-state `ms` (per phase, 2 bits), acc, z_reg,
  a_reg, q_reg.
- **Latency (defaults)**: FWD_H = HIDDEN·(FEATURES+35) = 26,208 cyc; FWD_O =
  CLASSES·(HIDDEN+35) = 670 cyc; BP_O = CLASSES·4 = 40; BP_H = HIDDEN·(CLASSES+6) = 512;
  UPD_O = CLASSES·(3·HIDDEN+2) ≈ 980; UPD_H = HIDDEN·(3·FEATURES+2) ≈ 75,300.
  **Total: inference ≈ 26,900 cycles; training ≈ 103,700 cycles** — meets REQ-016
  (≤ 30,000 / ≤ 200,000). [Estimates assume 1 MAC/cycle and 33-cycle division.]
- **Reset behaviour**: run_active=0, step_mode=0, halt_pending=0, freeze_ff=0,
  lr_shift_ff=8, label_ff=0, best_val=0, best_idx=0, counters 0, FSM=IDLE, acc=0.
- **Error handling**: none internal (all inputs validated upstream); start/step strobes
  while running are ignored; halt is graceful (completes current sample).
- **Timing budget**: weight RAM read → multiplier → 48-bit adder → mux ≤ 8 ns (§15).

### 4.5 BLK-005 : weight_ram (parameterized dual-port weight memory)
- **Purpose**: store W_TOT × 16-bit words (weights + biases, address map §7); port A =
  learner datapath, port B = CSR (apb_regs) + bulk-init walk.
- **Parent / Clock / Reset / Source**: learn_accel / clk_core / rst_n / custom.
- **Traces**: REQ-006, REQ-013, REQ-020, REQ-021, REQ-022.
- **Ports**: IFI-004, IFI-005.
- **Parameters**: W_TOT, W_A (16).
- **Internal structure**: MEM-001 as inferred `reg [15:0] mem [0:W_TOT-1]` with two
  always blocks (port A, port B). **Write-first** read-during-write on both ports
  (documented; never relied upon — FSM-001 separates read and write by ≥ 1 cycle).
  FSM-003 `init_walk` drives port B for bulk init (W_TOT writes of `init_val`).
  Port B arbitration: init_walk owns port B while `init_busy`; CSR WDATA write during
  `init_busy` is dropped (deterministic, documented in §7 note); CSR reads during
  `init_busy` return the current word (benign).
- **Latency/Throughput**: combinational read (1 cycle access); 1 write/cycle.
- **Reset behaviour**: all words 0 (reset in the `if (!rst_n)` branch of the memory
  write logic; note: 25,450-word reset loop at defaults — synthesis tool will expand;
  acceptable for sim, documented for macro replacement, OI-001).
- **Error handling**: n/a.
- **Timing budget**: read mux path ≤ 6 ns at tiny configs; at default config the array is
  intended for SRAM-macro replacement at integration (OI-001) — see §14.
- **Macro-replacement boundary (OI-001)**: ports A/B are the SRAM boundary: replace
  MEM-001 with a `sky130_sram_*` (verify cell name against installed PDK, OI-002) having
  the same two read/write ports; note that an SRAM macro adds 1-cycle read latency, which
  would extend WDATA CSR reads to 1 wait state (APB `pready`) — a documented deviation
  requiring spec erratum before adoption (OI-001).

### 4.6 BLK-006 : stats (counters + error sticky)
- **Purpose**: SAMPLE/CORRECT/ERROR saturating counters, `err` sticky flag, PRED register.
- **Parent / Clock / Reset / Source**: learn_accel / clk_core / rst_n / custom.
- **Traces**: REQ-007, REQ-013, REQ-018, REQ-019.
- **Ports**: IFI-002, IFI-006, IFI-007.
- **Internal structure**: three 32-bit saturating counters (add with saturation compare),
  err_ff, pred_ff[7:0]; clr_stats_p clears counters + err (not pred).
- **Latency**: combinational read; +1 per sample_done_p.
- **Reset behaviour**: all 0.
- **Error handling**: saturation at 0xFFFFFFFF (no wrap).
- **Timing budget**: n/a (≤ 2 ns).

### 4.7 BLK-007 : div_seq (sequential restoring divider)
- **Purpose**: compute `trunc(num/den)` toward zero for the sigmoid evaluation:
  num = 128·z (signed 32-bit), den = 256+|z| (unsigned 17-bit); quotient 17-bit signed.
- **Parent / Clock / Reset / Source**: learn_accel / clk_core / rst_n / custom.
- **Traces**: REQ-004, REQ-011.
- **Ports**: `div_start` (pulse), `div_num[31:0]` (signed), `div_den[16:0]` (unsigned),
  `div_busy`, `div_done` (pulse), `div_q[16:0]` (signed, valid with div_done).
- **Internal structure**: FSM-004; sign-magnitude restoring: mag = |num|, iterate
  32 bits (shift-subtract), q_mag; result sign = num[31] XOR 0 (den unsigned positive);
  q = sign ? −q_mag : q_mag. **Truncation toward zero by construction.**
- **Latency**: 33 cycles from div_start to div_done (32 iterations + 1).
- **Reset behaviour**: idle, q=0, busy=0.
- **Error handling**: den=0 → q=0, done (cannot occur: den ≥ 256 by construction).
- **Timing budget**: 1 subtract+compare per iteration ≤ 8 ns.

## 5. Datapath Definition (bit-exactness contract)

The following rules are **the** contract between RTL and `golden_ref_model.c`. fe-rtl must
implement exactly these semantics; every helper is named and defined identically in both.

### 5.1 Fixed-point formats and widths at every node

| Node | Width | Format | Notes |
|---|---|---|---|
| pixel x[f] | 8-bit stored, 16-bit zero-extended | Q8.8 raw = byte (0..255) | signed 16-bit in MAC |
| weights w, biases b | 16-bit signed | Q8.8 (raw −32768..32767) | |
| activations a, outputs y | 16-bit signed | Q8.8, range [1,255] raw | sigmoid output |
| deltas δ_o, δ_h | 16-bit signed | Q8.8 | sat16 applied |
| multiplier product | 32-bit signed | Q16.16 | 16×16 signed |
| accumulator acc | 48-bit signed | Q16.16 | bias added as bias<<8 |
| e16 (hidden error sum) | 48-bit signed | Q16.16 | Σ_c w_o·δ_o |
| z (pre-activation) | 16-bit signed | Q8.8 | sat16(trunc_pow2(acc,8)) |
| δ_o product tmp | 48-bit signed | — | (y−t)·y·(256−y) |
| δ_h product | 48-bit signed | — | e16·a·(256−a) |
| update operand | 32-bit signed | — | δ·a_prev |
| sigmoid numerator | 32-bit signed | — | 128·z (max ±4,194,304) |
| sigmoid denominator | 17-bit unsigned | — | 256+|z| (max 33,024) |
| sigmoid quotient q | 17-bit signed | — | trunc toward zero; σ = 128+q ∈ [1,255] |

### 5.2 Arithmetic helpers (identical semantics in C and Verilog)

1. **trunc_pow2(x, n)**, n ≥ 0: `(x >= 0) ? (x >> n) : -((-x) >> n)` — truncation toward
   zero. Verilog: compute magnitude `m = x[MSB] ? -x : x` (48-bit), `m = m >> n`,
   result = sign ? −m : m. Never use a bare `>>>` (that floors).
2. **sat16(x)**: clamp to [−32768, 32767].
3. **trunc_div(num, den)**: C99 `/` (truncation toward zero); Verilog `div_seq` block
   (sign-magnitude restoring, same result). Used only in sigmoid.
4. **MAC**: `acc = acc + a*w` per cycle, 48-bit signed; no intermediate saturation.
5. **z conversion**: `z = sat16(trunc_pow2(acc, 8))` — bias is pre-loaded as `bias<<8`.

### 5.3 Exact equations (one sample, training mode; freeze=1 skips BP+WU)

- Forward hidden: `acc = (b_h[h]<<8) + Σ_f w_h[h][f]·x[f]`; `z = sat16(trunc_pow2(acc,8))`;
  `a_h[h] = σ(z)`.
- Forward output: `acc = (b_o[c]<<8) + Σ_h w_o[c][h]·a_h[h]`; `y[c] = σ(z)`.
- **Sigmoid**: `q = trunc_div(128·z, 256+|z|)`; `σ = 128 + q` (range [1,255]).
  Rational approximation σ(z) = ½ + ½·z/(1+|z|) — see §14 (ASM-005 refinement).
- argmax: `pred = argmax_c y[c]`, **strict `>` comparison, lowest index on ties**.
- Counters: `sample++`; `y[pred] == label ? correct++ : error++` (before weight update).
- Output delta: `tmp = (y[c]−t[c])·y[c]·(256−y[c])` with `t[c] = (c==label) ? 256 : 0`;
  `δ_o[c] = sat16(trunc_pow2(tmp, 16))`.
- Hidden delta: `e16[h] = Σ_c w_o[c][h]·δ_o[c]`;
  `δ_h[h] = sat16(trunc_pow2(e16[h]·a_h[h]·(256−a_h[h]), 24))`.
  (Derivative surrogate: a·(1−a) using the stored activation — documented, §14.)
- Updates (η = 2^(−lr_shift)):
  `w_o[c][h] = sat16(w_o[c][h] − trunc_pow2(δ_o[c]·a_h[h], lr_shift+8))`
  `b_o[c]    = sat16(b_o[c]    − trunc_pow2(δ_o[c], lr_shift))`
  `w_h[h][f] = sat16(w_h[h][f] − trunc_pow2(δ_h[h]·x[f], lr_shift+8))`
  `b_h[h]    = sat16(b_h[h]    − trunc_pow2(δ_h[h], lr_shift))`
- MAC order: increasing index (f then h then c), as written above — sequential,
  single accumulator; never reordered.

### 5.4 Overflow policy

- Accumulator/e16: 48-bit — cannot overflow (max |Σ| ≈ 6.6e9 « 2^47).
- Every 16-bit result goes through sat16 (clamp, never wrap).
- Counters: saturate at 0xFFFFFFFF.
- Sigmoid output inherently in [1,255]; z bounded by sat16.

## 6. Control FSMs

### 6.1 FSM-001 : learner (binary encoding, reset state = IDLE)

State reg 3 bits: IDLE=000, FWD_H=001, FWD_O=010, BP_O=011, BP_H=100, UPD_O=101,
UPD_H=110, DONE=111. `default: -> IDLE` (illegal-state recovery; also resets phase
counters).

Per-state micro-schedule (datapath sequencing; `ms` = 2-bit micro-state where shown):

| State | Micro-step | Action this cycle | Next |
|---|---|---|---|
| IDLE | — | if `start_p \|\| step_p`: run_active<=1, step_mode<=step_p, done_ff<=0; if `halt_p`: done_ff<=1; if `run_active && sample_valid`: sample_ack<=1, label_ff<=label, best_val<=0, best_idx<=0, h_cnt<=0, c_cnt<=0, f_cnt<=0, freeze_ff<=freeze, lr_shift_ff<=lr_shift | FWD_H (on run_active && sample_valid) else IDLE |
| FWD_H | ms=0 | acc <= {bias_ff,8'b0} (read b_h[h_cnt] from MEM-001 via port A); f_cnt<=0; ms<=1 | stay |
| | ms=1 | if f_cnt < FEATURES: acc <= acc + w·x (read w_h[h_cnt][f_cnt], x[f_cnt]); f_cnt++ | stay (ms=1) |
| | | else: z_reg <= sat16(trunc_pow2(acc,8)); div_start<=1; ms<=2 | stay |
| | ms=2 | div_start<=0 | if div_done: MEM-003[h_cnt] <= 128+q (q = div_q; combinational add); ms<=3 else stay |
| | ms=3 | if h_cnt == HIDDEN−1: c_cnt<=0; ms<=0 | FWD_O else h_cnt++, ms<=0 | stay |
| FWD_O | ms=0 | acc <= {b_o[c_cnt],8'b0}; h_cnt<=0; ms<=1 | stay |
| | ms=1 | if h_cnt < HIDDEN: acc <= acc + w·a (read w_o[c_cnt][h_cnt], MEM-003[h_cnt]); h_cnt++ | stay |
| | | else: z_reg<=..., div_start<=1; ms<=2 | stay |
| | ms=2 | div_start<=0 | if div_done: y_reg<=128+q; MEM-004[c_cnt]<=(128+q) (same value, non-blocking); if (128+q)>best_val: best_val<=(128+q), best_idx<=c_cnt (compare the new value, not stale y_reg); ms<=3 else stay |
| | ms=3 | if c_cnt == CLASSES−1: if freeze_ff | DONE else h_cnt<=0, c_cnt<=0, ms<=0 | BP_O else c_cnt++, ms<=0 | stay |
| BP_O | ms=0 | tmp <= (y_reg−t)·y_reg (t = (c_cnt==label_ff)?256:0; read MEM-004[c_cnt]); ms<=1 | stay |
| | ms=1 | tmp <= tmp·(256−y_reg); ms<=2 | stay |
| | ms=2 | δ <= sat16(trunc_pow2(tmp,16)); MEM-004[c_cnt]<=δ; ms<=3 | stay |
| | ms=3 | if c_cnt == CLASSES−1: h_cnt<=0, c_cnt<=0 | BP_H else c_cnt++, ms<=0 | stay |
| BP_H | ms=0 | e16<=0; c_cnt<=0; ms<=1 | stay |
| | ms=1 | if c_cnt < CLASSES: e16 <= e16 + w_o[c_cnt][h_cnt]·δ_o[c_cnt] (read MEM-004[c_cnt]); c_cnt++ | stay |
| | | else: tmp <= a_h[h_cnt]·(256−a_h[h_cnt]) (read MEM-003[h_cnt]); ms<=2 | stay |
| | ms=2 | tmp <= e16·tmp; ms<=3 | stay |
| | ms=3 | δ_h <= sat16(trunc_pow2(tmp,24)); MEM-005[h_cnt]<=δ_h; ms<=4 | stay |
| | ms=4 | if h_cnt == HIDDEN−1: c_cnt<=0, h_cnt<=0 | UPD_O else h_cnt++, ms<=0 | stay |
| UPD_O | ms=0 | if h_cnt < HIDDEN: read w_o[c_cnt][h_cnt] (port A); ms<=1; else: read b_o[c_cnt]; upd<=trunc_pow2(δ_o[c_cnt], lr_shift_ff); ms<=3 | stay |
| | ms=1 | upd <= trunc_pow2(δ_o[c_cnt]·a_h[h_cnt], lr_shift_ff+8) (read MEM-004[c_cnt], MEM-003[h_cnt]); ms<=2 | stay |
| | ms=2 | write port A: w_o[c_cnt][h_cnt] <= sat16(w − upd); h_cnt++; ms<=0 | stay |
| | ms=3 | write port A: b_o[c_cnt] <= sat16(w − upd); if c_cnt == CLASSES−1: h_cnt<=0 | UPD_H else c_cnt++, ms<=0 | stay |
| UPD_H | ms=0 | if f_cnt < FEATURES: read w_h[h_cnt][f_cnt]; ms<=1; else: read b_h[h_cnt]; upd<=trunc_pow2(δ_h[h_cnt], lr_shift_ff); ms<=3 | stay |
| | ms=1 | upd <= trunc_pow2(δ_h[h_cnt]·x[f_cnt], lr_shift_ff+8) (read MEM-005[h_cnt], MEM-002[f_cnt]); ms<=2 | stay |
| | ms=2 | write port A: w_h[h_cnt][f_cnt] <= sat16(w − upd); f_cnt++; ms<=0 | stay |
| | ms=3 | write port A: b_h[h_cnt] <= sat16(w − upd); if h_cnt == HIDDEN−1 | DONE else h_cnt++, f_cnt<=0, ms<=0 | stay |
| DONE | — | `sample_done_p`<=1, `correct_p`<= (best_idx==label_ff), `error_p`<= !(best_idx==label_ff); if step_mode \|\| halt_pending: run_active<=0, done_ff<=1; step_mode<=0, halt_pending<=0 | IDLE |

Notes: `start_p/step_p/halt_p` are 1-cycle pulses from BLK-002; start/step are ignored in
all states except IDLE; `halt_p` anywhere sets `halt_pending` (checked at DONE). All
`<=` are non-blocking (single clock). MEM-001 port A read is combinational; write at
posedge ≥ 1 cycle after the read (RMW separation guaranteed by ms schedule).

### 6.2 FSM-002 : sample_stream (binary, reset = WAIT)

| State | Condition (this cycle, on a beat `s_valid && s_ready`) | Action | Next |
|---|---|---|---|
| WAIT | !(s_valid && s_ready) | none | WAIT |
| WAIT | beat && !s_last && px_cnt < FEATURES | MEM-002[px_cnt] <= s_data; px_cnt++ | WAIT |
| WAIT | beat && s_last && px_cnt == FEATURES | label_ff <= s_data; sample_valid<=1; px_cnt<=0 | WAIT |
| WAIT | beat && s_last && px_cnt < FEATURES | `err_p`; sample_valid<=0 | RESYNC |
| WAIT | beat && !s_last && px_cnt == FEATURES | `err_p` (missing last); sample_valid<=0 | RESYNC |
| RESYNC | !(beat) | none | RESYNC |
| RESYNC | beat && !s_last | discard | RESYNC |
| RESYNC | beat && s_last | px_cnt<=0 | WAIT |

`sample_valid` also clears on `ack_p` from the learner (level → 0). `s_ready` is
combinational: `s_ready = accept_en` (IFI-008 = learner run_active && learner IDLE).
`err_p` is a 1-cycle pulse; the sticky `err` lives in BLK-006.

### 6.3 FSM-003 : init_walk (weight_ram; binary, reset = IDLE)

| State | Condition | Action | Next |
|---|---|---|---|
| IDLE | `init_go` (pulse, gated on !busy in BLK-002) | init_busy<=1; addr<=0 | WALK |
| WALK | addr < W_TOT−1 | port B write mem[addr]<=init_val; addr++ | WALK |
| WALK | addr == W_TOT−1 | port B write; init_busy<=0 | IDLE |

### 6.4 FSM-004 : div_seq (binary, reset = IDLE)

| State | Condition | Action | Next |
|---|---|---|---|
| IDLE | `div_start` | capture num, den; mag<=|num|; acc<=0; iter<=0; busy<=1 | ITER |
| ITER | iter < 32 | restoring step: shift-subtract (acc = (acc<<1) + next bit of mag; if acc ≥ den: acc−=den, qbit=1); iter++ | ITER |
| ITER | iter == 32 | q_mag done; q <= (num[31] ? −q_mag : q_mag); busy<=0; `div_done`<=1 | DONE |
| DONE | — | div_done<=0 | IDLE |

## 7. Memory Map and Register Definition

Full register map is fixed by SPEC section 6 (offsets, widths, access, reset values).
This section adds implementation binding notes only:

| Offset | Name | Access | Reset | Implementation notes |
|---|---|---|---|---|
| 0x00 | CTRL | RW | 0x00000000 | [0] start, [1] step, [2] halt, [3] freeze (level), [4] clr_stats, [5] init_weights — strobes are 1-cycle pulses, read back 0; [31:6] rsvd read 0, writes ignored |
| 0x04 | LRN_RATE | RW | 0x00000008 | [3:0] lr_shift; η = 2^−lr_shift; [31:4] rsvd |
| 0x08 | STATUS | RO | 0x00000000 | [0] busy (IFI-009), [1] done (IFI-009), [2] err (IFI-006), [3] frozen (CTRL[3]); [31:4] read 0 |
| 0x0C | SAMPLE_COUNT | RO | 0 | saturating |
| 0x10 | CORRECT_COUNT | RO | 0 | saturating |
| 0x14 | ERROR_COUNT | RO | 0 | saturating |
| 0x18 | PRED | RO | 0 | [7:0] last pred; [31:8] read 0 |
| 0x1C | WADDR | RW | 0 | [15:0]; auto-increment after **each** WDATA access (write and read) |
| 0x20 | WDATA | RW | 0 | [15:0]; write → port B write at WADDR then WADDR++; read → port B read at WADDR then WADDR++. Writes dropped while init_busy (§4.5). |
| 0x24 | W_INIT_VAL | RW | 0 | [15:0] |

**Weight address map** (word addresses; W_TOT = F·H + H + H·C + C ≤ 65535):
`0 .. F·H−1`: w_h[h][f] = mem[h·F + f] · `F·H .. F·H+H−1`: b_h[h] ·
`F·H+H .. F·H+H+H·C−1`: w_o[c][h] = mem[F·H+H + c·H + h] ·
`F·H+H+H·C .. W_TOT−1`: b_o[c].

Reserved-bit behaviour: reads-as-zero, writes-ignored (all registers). Unmapped APB
addresses: PSLVERR, no side effects.

## 8. Internal Interfaces (IFI-###)

Full signal lists in `interface_defs.yaml`. Semantics:

- All handshakes synchronous to clk_core. Valid/ready: `valid` never depends
  combinationally on `ready`; data held stable while `valid && !ready` (not applicable to
  IF-002 slave — the IP is the sink; s_ready may deassert freely).
- IFI-003 (stream↔learner): `sample_valid` is a level set at label capture, cleared by
  `sample_ack` (pulse) or at the next label capture. `x_addr/x_rdata` form a
  combinational read port of MEM-002 (valid_only, no handshake; only used while learner
  is in FWD_H/UPD_H, never while sample_stream writes — mutually exclusive by `accept_en`).
- IFI-004/IFI-005 (memory ports): combinational read, posedge write, write-first
  read-during-write (never relied upon).
- IFI-001 strobes: 1-cycle pulses, level `freeze`, `lr_shift[3:0]`.

## 9. Clock and Reset Architecture

- One domain CD_CORE (`clk_core`, 25 MHz nominal @ tt, 40.000 ns, external pad; original 50 MHz
  target superseded — REQ-015 erratum 2026-08-20). All blocks clocked by
  clk_core. No gated clocks in the RTL netlist (clock enable = RTL `if (en)`; power_plan.md
  PWR-001..004; tool-inferred ICG only).
- `rst_n`: active-low, **synchronous** (assert and de-assert on posedge clk_core) per
  ASM-002; min assert 16 cycles; single domain → no cross-domain sequencing.
- No CDC paths exist (all inputs synchronous); `cdc_plan.md` states this explicitly.
- SDC intent for fe-rtl (→ sdc_spec.json for fe-opensta): one clock `clk_core`
  40.000 ns; clock uncertainty 1.0 ns setup (kept per REQ-015 erratum; was 5 % of the 20 ns
  period) / 0.1 ns hold; input delay 6.0 ns / output delay
  6.0 ns on all ports; no clock groups (single clock); no false paths.

## 10. IP Reuse Plan

| BLK | Decision | Repo | Licence | Status | Notes |
|---|---|---|---|---|---|
| all blocks | custom | none | n/a | rejected-by-policy | Rinri directive 2026-08-20: no external IP; survey re-run at fe-arch (queries in requirements.yaml IPR-001..003); nothing adopted |

No Sky130 cells are instantiated anywhere in the RTL (no pads, no level shifters, no SRAM
macros, no ICG cells). Any future SRAM macro replacement (OI-001) requires PDK cell-name
verification (OI-002).

## 11. Golden Model Description

`arch/golden_model/golden_ref_model.c` — C99, transaction-level (per sample), integer-only
(int64 intermediates; masks per §5.1). Implements exactly §5.2–5.3. Default build
configures the **tiny config** FEATURES=4, HIDDEN=4, CLASSES=2, lr_shift=0 (η=1) with 5
vectors (initial weights + 5 samples) in `golden_model_test_vectors.h`. Output format:

```
SAMPLE %03u label=0x%02X pred=0x%02X correct=0x%01X sample=0x%08X correct_cnt=0x%08X error_cnt=0x%08X
WEIGHT 0x%04X=0x%04X      (final weights, address order)
```

Build/run (user executes, this skill never does):
```
gcc -std=c99 -O2 -Wall -Wextra -o gm arch/golden_model/golden_ref_model.c
./gm > got.txt && diff -u arch/golden_model/expected_outputs.txt got.txt
```
`expected_outputs.txt` values were **hand-derived** (double-checked) from §5.3 with the
tiny config and are value-identical to `stimulus.hex`/`expected.hex` (same golden data in
three formats: C header, .txt diff, $readmemh hex). The Verilog testbench: load initial
weights (stimulus words 0..29) via WADDR/WDATA, stream the 5 samples (words 30..54), then
compare per-sample {pred, correct, counts} and the final 30 weights against expected.hex.
Vector coverage: reset defaults (S4 all-zero), maximum inputs (S5 all-255), negative
pre-activations (all samples), both labels, correct and incorrect classifications,
non-zero δ_o and δ_h paths, tie rule (not exercised — VP-LRN-004 covers it directed).
To generate vectors for the default 784×32×10 config, change FEATURES/HIDDEN/CLASSES/
LR_SHIFT defines and regenerate the header + hex (documented in golden_model/README.md).

## 12. Verification Hooks

- IFI-009 busy/done + IFI-006 counters: firmware-visible learning status.
- PRED + weight dump: full observability (no DFT — register-mapped only).
- Per-block pure-Verilog TB checkers (fe-rtl tb/, fe-cocotb): APB4 monitor (PSLVERR,
  access types), frame monitor (malformed cases), weight-RAM snapshot compare,
  counter checker (saturation/clr), cycle counters (REQ-016), golden replay
  (stimulus/expected.hex scoreboard, REQ-011).
- `sample_count`/`correct_count`/`error_count` are the accuracy readout for firmware
  experiments (REQ-025).

## 13. Traceability: REQ -> BLK

| REQ | BLK(s) | REQ | BLK(s) |
|---|---|---|---|
| REQ-001 | BLK-001, BLK-004 | REQ-013 | BLK-002, BLK-005, BLK-006 |
| REQ-002 | BLK-004 | REQ-014 | all (guidelines) |
| REQ-003 | BLK-004 | REQ-015 | all (budgets §15) |
| REQ-004 | BLK-004, BLK-007 | REQ-016 | BLK-004 |
| REQ-005 | BLK-004 | REQ-017 | BLK-004, BLK-002 |
| REQ-006 | BLK-005, BLK-002 | REQ-018 | BLK-003, BLK-006 |
| REQ-007 | BLK-006 | REQ-019 | BLK-006 |
| REQ-008 | BLK-003 | REQ-020 | BLK-002, BLK-005 |
| REQ-009 | BLK-002 | REQ-021 | BLK-005, BLK-004 |
| REQ-010 | BLK-002 | REQ-022 | BLK-001, BLK-005 |
| REQ-011 | BLK-004 (golden §5/§11) | REQ-023/024 | analysis (top) |
| REQ-012 | BLK-001 (all) | REQ-025 | BLK-006 (counters feed firmware) |

Every `must` requirement (REQ-001..022) maps to ≥ 1 block. Should/may (023–025) are
analysis/firmware items.

## 14. Assumptions and Open Issues

Assumptions ASM-001..009 (spec/requirements.yaml) — all acknowledged for this run
(`assumptions_acknowledged: true`). Refinements made at fe-arch within that delegation:

- **ASM-005 refinement (sigmoid)**: implemented as the integer rational approximation
  σ(z) = ½ + ½·z/(1+|z|) evaluated in Q8.8 (σ_raw = 128 + trunc(128·z/(256+|z|))), and the
  backprop derivative uses the surrogate a·(1−a) with the stored activation. No
  precomputed LUT table is needed — this keeps RTL and C bit-exact **by construction**
  (a hardcoded transcendental table would require values I cannot generate without
  running tools). The approximation is a valid bounded squashing function; MNIST-class
  online learning is unaffected in kind (documented for review).
- **Learning-rate scaling note (OI-004)**: with Q8.8 weights, one weight LSB = 1/256;
  the update is trunc_pow2(δ·a, lr_shift+8). Typical |δ_raw·a_raw| ≈ 1k–16k, so
  lr_shift ≥ 6 yields sub-LSB updates (effectively frozen) and **lr_shift 0–3 is the
  usable range**; the REQ-025 experiment recipe wording "lr_shift=8" would not learn —
  see OI-004. Register semantics (η = 2^−lr_shift, reset 8) are unchanged (REQ-005).

Open issues (registry, cross-stage numbering):

| ID | Description | Blocks | Owner |
|---|---|---|---|
| OI-001 | Weight RAM target: inferred dual-port reg array (this RTL) vs Sky130 SRAM macro at integration; macro adds 1-cycle CSR read latency (would extend WDATA reads to 1 wait state — spec deviation, needs erratum before adoption) | none | architect |
| OI-002 | Verify sky130_sram_* cell names against installed PDK before any macro stub/constraint | none | user |
| OI-003 | REQ-025 stretch target needs downstream firmware/experiment harness | none | user |
| OI-004 | REQ-025 recipe says lr_shift=8; Q8.8 scale makes lr_shift 0–3 the usable range (η=2^-8 → sub-LSB updates). Spec erratum suggested: reword to "lr_shift=2". Golden vectors use lr_shift=0. Non-blocking (REQ-025 is may). | none | user |

## 15. Estimated Area and Timing Budget

| Block | Flops | Std-cell GE (excl. mem) | Critical path budget (ns @40 ns) |
|---|---|---|---|
| BLK-002 apb_regs | ~120 | ~800 | 6.0 (decode→mux→prdata) |
| BLK-003 sample_stream + MEM-002 | ~120 + 6.3 kbit | ~1,200 | 8.0 (RAM read→learner) |
| BLK-004 learner (incl. MEM-003/4/5) | ~300 + ~1 kbit | ~4,000 | 8.0 (RAM→mul→acc48→mux) |
| BLK-005 weight_ram (logic only) | ~40 | ~500 | 6.0 (read mux) |
| BLK-006 stats | ~100 | ~300 | 2.0 |
| BLK-007 div_seq | ~80 | ~500 | 8.0 (subtract/compare) |
| **Total (excl. weight RAM 407 kbit)** | | **≈ 7,500 GE** | ≤ 8.0 ns critical |

REQ-024 (≤ 100 kGE excl. memory) is met with ~25× margin. REQ-015 (25 MHz nominal @ tt,
40.000 ns) has ~13 ns slack on the measured 26.7 ns tt critical path (weight-RAM read mux
→ 16×16 mult → 48-bit acc; measured 37.5 MHz @ tt, frontend STA 2026-08-20). Worst-corner
ss_n40C_1v44 reports 108.97 ns = 9.2 MHz — documented as the reported number, NOT a closure
target. Pipelining is deferred by decision (Rinri 2026-08-20: relax the clock, no
pipelining); re-verify STA at the new target before sign-off. Power estimate (REQ-023):
learner/divider gated off when idle (PWR-001/003); idle fraction in firmware experiments
≈ 90% → dynamic power estimate ≈ 1 mW at 25 MHz, 1.8 V typical (scaled linearly from the
< 2 mW @ 50 MHz original-target estimate; analysis item, VP-TOP-017).
