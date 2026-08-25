# mnist_npu — Microarchitecture Specification
Document ID: ARCH-MNIST_NPU-v1.0 | Stage: fe-arch | Input: SPEC-MNIST_NPU-v1.0
Technology: FPGA-generic (Xilinx Artix-7 100T / Nexys A7 eventual target) | RTL: pure
Verilog-2001/2005 | DFT: none

## 1. Architecture Overview

`mnist_npu` is a single-clock-domain, free-running MLP inference engine. One shared
multiply-accumulate (MAC) datapath is time-multiplexed, under the control of a single top-level
FSM (`ctrl_fsm`), across all 25,088 layer-1 MAC steps (32 hidden units x 784 inputs) and all 320
layer-2 MAC steps (10 outputs x 32 hidden units) of one image's forward pass. Weights, images and
labels live in `$readmemh`-initialised ROMs sourced from the frozen golden package. A 65536x8
sigmoid ROM replaces any divider. Per image, the result (`pred`/`confidence`/`verdict`) drives the
LED outputs and is formatted into an exact ASCII line, sent one byte at a time to a standard
115200 8N1 UART transmitter. After a parameterized hold, the next image (index+1 mod 100) begins.

## 2. Design Constraints Inherited from Specification

Restated verbatim from `spec/spec.md` §2 (see that document for the full deviation rationale):
FPGA-generic technology (not Sky130 — explicit, documented deviation, §2.1 there); pure
Verilog-2001/2005; no SystemVerilog; no DFT; no host interface/CSR/APB of any kind; single clock
domain; **fully synchronous** active-low reset (not async-assert/sync-deassert); all program data
via `$readmemh` only.

## 2.1 Technology carried forward unchanged

Per `spec/spec_manifest.yaml : deviation_note`, this stage carries `technology.pdk: fpga_generic`
forward unchanged. `fe-arch`'s own input-validation check #8 (`technology.pdk == sky130 and
node_nm == 130`, else `ARCH-E007`) is **knowingly and explicitly overridden** here for the same
reason given in `spec.md` §2.1: the commissioning brief unambiguously specifies an FPGA deployment
(Nexys A7 / Artix-7 100T), and nothing in this design touches a Sky130-specific artifact (no
analog black boxes, no PDK cell names, no DFT). This is recorded as a deliberate, written
deviation — not a silent skip of the check — consistent with how `spec.md` handled the equivalent
`fe-spec` check (`SPEC-E004`).

## 3. Hierarchy and Partitioning

| BLK-ID | Module | Parent | Clock | Reset | Source |
|---|---|---|---|---|---|
| BLK-001 | `mnist_npu` | (top) | clk_core | rst_n | custom |
| BLK-002 | `ctrl_fsm` | BLK-001 | clk_core | rst_n | custom |
| BLK-003 | `mac_datapath` | BLK-001 | clk_core | rst_n | custom |
| BLK-004 | `sigmoid_lut` | BLK-001 | clk_core | rst_n | custom |
| BLK-005 | `weight_rom` | BLK-001 | clk_core | rst_n | custom |
| BLK-006 | `image_rom` | BLK-001 | clk_core | rst_n | custom |
| BLK-007 | `label_rom` | BLK-001 | clk_core | rst_n | custom |
| BLK-008 | `hidden_ram` | BLK-001 | clk_core | rst_n | custom |
| BLK-009 | `uart_tx` | BLK-001 | clk_core | rst_n | custom |
| BLK-010 | `led_ctrl` | BLK-001 | clk_core | rst_n | custom |
| BLK-011 | `uart_line_fmt` | BLK-001 | clk_core | rst_n | custom |

`mnist_npu` instantiates all ten leaf blocks directly (flat hierarchy — the design is small
enough that an intermediate domain-wrapper layer, per fe-arch Step 2's usual guidance, would add
no value with only one clock domain). `ctrl_fsm` is the sole source of control signals; every other
block is pure datapath/storage/IO with no independent decision-making (control/datapath separation
per fe-arch Step 3), except `uart_tx` and `uart_line_fmt` which each own a small local FSM (FSM-003,
FSM-002 respectively) needed to sequence their own multi-cycle byte/bit-level protocols — `ctrl_fsm`
treats both as black-box engines via a simple strobe/status handshake (IFI-007, IFI-009).

`uart_line_fmt` (BLK-011) was added beyond the project brief's suggested module list (which the
brief itself invited: "suggested split, refine as you see fit") because ASCII decimal formatting of
variable-width numbers (confidence 0-100, no leading zeros) is a distinct responsibility from both
`ctrl_fsm`'s inference sequencing and `uart_tx`'s bit-level shifter — folding it into either would
violate the control/datapath separation rule (Step 3) and blow well past a single responsibility.

## 4. Block Specifications

#### BLK-001 : mnist_npu
- Purpose: top-level integration; owns no state of its own beyond wiring.
- Parent: (none) / Clock: clk_core / Reset: rst_n / Source: custom
- Traces: all REQs (top-level integration)
- Ports: `clk`, `rst_n`, `led[11:0]` (output), `uart_tx` (output) — exactly `interface_defs.yaml`
  external_interfaces IF-001/IF-002/IF-003.
- Parameters: re-exports every leaf parameter (§8) so a single top-level instantiation can override
  all of them (required for the simulation-vs-default value switch, REQ-016/020/021/026).
- Internal structure: instantiates BLK-002..BLK-011, wires per `block_diagram.mmd`.
- Latency/Throughput: N/A (structural only).
- Reset behaviour: none of its own; passes rst_n through.
- Error handling: none (no error conditions in this design, spec.md §8).
- Timing budget: N/A (no logic of its own).

#### BLK-002 : ctrl_fsm
- Purpose: sequences one image's full inference (layer-1 MAC loop, layer-1 activation, layer-2 MAC
  loop, layer-2 activation, argmax/confidence/verdict, UART line dispatch, LED presentation, hold),
  then advances to the next image, forever.
- Parent: BLK-001 / Clock: clk_core / Reset: rst_n / Source: custom
- Traces: REQ-001, REQ-004..REQ-011, REQ-015, REQ-016, REQ-019, REQ-028, REQ-029
- Ports: see IFI-001, IFI-002, IFI-003, IFI-004, IFI-005, IFI-006, IFI-008, IFI-009 (`ctrl_fsm` is
  the "from_source" end of every one of these except IFI-007).
- Parameters: `HOLD_CYCLES` (default 50,000,000; simulation override 4-16 per REQ-016).
- Internal structure: FSM-001 (§6.1, 10 states, binary encoding), `img_idx` counter (0..99, wraps),
  `i_cnt`/`j_cnt`/`c_cnt` MAC-step counters, `best_val`/`best_idx` argmax registers, `hold_cnt`
  counter. No datapath arithmetic lives here beyond address generation and the final
  confidence/verdict combinational logic (§5).
- Latency: one full image = 784x32 (layer 1) + 32x10 (layer 2) + small per-unit activation/writeback
  overhead + UART line time + `HOLD_CYCLES`. See §8 for the exact cycle-count derivation.
- Throughput: 1 image fully classified and presented per (compute + UART + hold) cycle budget.
- Reset behaviour: `state <= ST_IMG_START`, all counters/registers to 0 (see §6.1 for exact reset
  values of every register).
- Error handling: illegal FSM state -> `default:` recovers to `ST_IMG_START` (REQ-024).
- Timing budget: this is the module most likely to set the critical path (40-bit accumulator add +
  16x16 multiply in one cycle, `mac_datapath`) — see §15.

#### BLK-003 : mac_datapath
- Purpose: one shared 16x16->32-bit signed multiplier feeding one shared 40-bit signed accumulator;
  produces the saturated 16-bit `z` at the end of a MAC sequence.
- Parent: BLK-001 / Clock: clk_core / Reset: rst_n / Source: custom
- Traces: REQ-002, REQ-003, REQ-004, REQ-005, REQ-008, REQ-028, REQ-029
- Ports: IFI-001 (`mac_a`, `mac_b`, `mac_bias_ld`, `mac_bias`, `mac_acc_en` in; `mac_z` out).
- Parameters: none (all widths fixed by the golden contract).
- Internal structure: `product = $signed(mac_a) * $signed(mac_b)` (32-bit, combinational);
  `acc` (40-bit reg): on `mac_bias_ld`, `acc <= {{16{mac_bias[15]}}, mac_bias, 8'b0} + product`
  (`ctrl_fsm` drives `mac_a`=0 on this cycle so `product`=0 and the load is bias-only — the bias is
  fetched as its own dedicated ROM read, distinct from the first weight term, see the MAC-loop
  ROM-latency clarification below); on `mac_acc_en` (and not `mac_bias_ld`), `acc <= acc +
  {{8{product[31]}}, product}` (sign-extend 32-bit product to 40 bits); `z` (16-bit, **wire**,
  purely combinational): saturate `$signed(acc) >>> 8` to `[-32768, 32767]` from whatever `acc`
  currently holds — no extra register stage, so `z` is correct the instant `acc` settles (the cycle
  after the last accumulate step, i.e. throughout `ST_L1_ACT`/`ST_L2_ACT`).
- Latency: 1 MAC-step's ADDR+ACC pair spans 2 cycles (ROM read latency — see clarification below);
  `z` is valid combinationally as soon as `acc` holds its final value (no extra latency of its own).
- Throughput: 1 MAC-step accumulate per 2 cycles (ADDR then ACC), sustained, no stalls.
- Reset behaviour: `acc <= 40'sd0` (`z` needs no reset — it is combinational).
- Error handling: none (accumulator provably cannot overflow, REQ-028; saturation is not an error,
  it is the specified behaviour of REQ-005).
- Timing budget: ~6.0 ns of the 10.000 ns period (16x16 multiply + 40-bit add + compare chain) —
  the single largest combinational timing budget in the design; see §15.

#### BLK-004 : sigmoid_lut
- Purpose: 65536x8 ROM implementing `sigma(z) = 128 + trunc(128*z/(256+|z|))` bit-exactly for every
  possible 16-bit signed `z`, replacing any divider circuit.
- Parent: BLK-001 / Clock: clk_core / Reset: rst_n / Source: custom
- Traces: REQ-006
- Ports: IFI-002 (`lut_addr` in, `lut_data` out).
- Parameters: `LUT_HEX_FILE` (default `"rtl/sigmoid_lut.hex"`) — generated by
  `tools/gen_sigmoid_lut.py` (§11), NOT hand-edited, NOT sourced from `arch/golden_model/` (that
  directory holds the network's golden vectors, not the LUT table; the LUT table is a new
  deterministic artifact this project generates, per project brief §5).
- Internal structure: `reg [7:0] rom [0:65535]`, `initial $readmemh(LUT_HEX_FILE, rom);`, one
  registered read port: `addr_r <= lut_addr; ... data_o <= rom[addr_r];` (registered address AND
  registered output, or registered address with combinational-read-then-register — either
  synthesises to a single BRAM with 1-cycle latency on Xilinx; fe-rtl picks the simpler of the two
  equivalent codings, documented in the module header). 1-cycle read latency, matching IFI-002.
- Latency: 1 cycle. Throughput: 1 lookup/cycle (not pipelined further — not needed, only 2
  lookups per image-unit, 42 lookups/image total).
- Reset behaviour: none needed for ROM contents (read-only); any output register resets to 8'd0.
- Error handling: none (defined for all 65536 addresses by construction, REQ-006).
- Timing budget: BRAM access, ~2 ns budget within the period (registered in/out).

#### BLK-005 : weight_rom
- Purpose: single 25,450 x 16-bit signed ROM holding W1|b1|W2|b2, `$readmemh`-initialised from the
  frozen `arch/golden_model/weights.hex`.
- Parent: BLK-001 / Clock: clk_core / Reset: rst_n / Source: custom
- Traces: REQ-012
- Ports: IFI-003 (`wrom_addr` in, `wrom_data` out).
- Parameters: `WEIGHTS_HEX_FILE` (default `"arch/golden_model/weights.hex"`, relative to the
  `mnist_npu` project root — see §7 for the exact `\`define` mechanism).
- Internal structure: `reg signed [15:0] rom [0:25449]`, `initial $readmemh(...)`, 1 registered read
  port (address registered, data available 1 cycle later — Xilinx BRAM-inferable).
- Latency: 1 cycle. Throughput: 1 read/cycle (one read every MAC-step cycle during MAC loops).
- Reset behaviour: none for contents; output register resets to 16'sd0.
- Error handling: address is always in `[0,25449]` by construction (`ctrl_fsm` counters are
  range-checked by the FSM's own loop bounds); out-of-range addressing cannot occur.
- Timing budget: BRAM access, ~2 ns.

#### BLK-006 : image_rom
- Purpose: 78,400 x 8-bit unsigned ROM (100 images x 784 pixels), `$readmemh`-initialised from
  `arch/golden_model/images.hex`.
- Parent: BLK-001 / Clock: clk_core / Reset: rst_n / Source: custom
- Traces: REQ-013
- Ports: IFI-004. Parameters: `IMAGES_HEX_FILE` (default `"arch/golden_model/images.hex"`).
- Internal structure: `reg [7:0] rom [0:78399]`, same registered-read shape as BLK-005.
- Latency/Throughput: 1 cycle / 1 read per cycle. Reset: output register to 8'd0.
- Timing budget: BRAM access, ~2 ns.

#### BLK-007 : label_rom
- Purpose: 100 x 8-bit unsigned ROM, `$readmemh`-initialised from `arch/golden_model/labels.hex`.
- Parent: BLK-001 / Clock: clk_core / Reset: rst_n / Source: custom
- Traces: REQ-014
- Ports: IFI-005. Parameters: `LABELS_HEX_FILE` (default `"arch/golden_model/labels.hex"`).
- Internal structure: `reg [7:0] rom [0:99]`, registered read (small enough to also map to
  distributed RAM/LUTRAM on Xilinx — either mapping is acceptable, REQ-025 only requires
  "cleanly synthesizable", not a specific memory primitive for a 100-word table).
- Latency/Throughput: 1 cycle / 1 read per image (read once per image, held for the whole image).
- Timing budget: negligible (<1 ns effective; not on any critical path — read once per ~25,700
  cycles).

#### BLK-008 : hidden_ram
- Purpose: 32 x 16-bit RAM holding hidden-layer activations h[0..31] between layer 1 (write) and
  layer 2 (read).
- Parent: BLK-001 / Clock: clk_core / Reset: rst_n / Source: custom
- Traces: REQ-007
- Ports: IFI-006 (`hram_addr`, `hram_wdata`, `hram_we` in; `hram_rdata` out).
- Parameters: none.
- Internal structure: `reg [15:0] ram [0:31]`, single R/W port: `if (hram_we) ram[hram_addr] <=
  hram_wdata; hram_rdata <= ram[hram_addr];` (write-first not required — `ctrl_fsm` never reads and
  writes the same address in the same image pass; layer 1 writes all 32 entries before layer 2
  reads any of them, per the FSM transition table §6.1).
- Latency: 1 cycle read latency; write takes effect the following cycle (standard synchronous RAM).
- Throughput: 1 access/cycle. Reset: no reset needed for RAM contents (every entry is written by
  layer 1 before layer 2 reads it, every single image pass — REQ-007 has no "read before write"
  path); `hram_rdata` output register resets to 16'd0.
- Error handling: none (address always in `[0,31]` by FSM construction).
- Timing budget: distributed RAM/LUTRAM access, ~1.5 ns.

#### BLK-009 : uart_tx
- Purpose: standard 115200 8N1 UART transmitter, one byte at a time, parameterized `CLK_DIV`.
- Parent: BLK-001 / Clock: clk_core / Reset: rst_n / Source: custom
- Traces: REQ-021, REQ-031
- Ports: IFI-007 (`utx_data`, `utx_valid` in; `utx_ready`, `utx_busy` out; plus the raw `uart_tx`
  output pin, wired straight to `mnist_npu`'s `uart_tx` port).
- Parameters: `CLK_DIV` (default 868 = round(100,000,000/115,200), ~0.007% baud error, well within
  standard UART tolerance; simulation override: a small value, e.g. 4, so the byte-framing
  structure is still fully exercised — see §8 for the full sim-speed rationale).
- Internal structure: FSM-003 (§6.3, 4 states: IDLE/START/DATA/STOP), a `baud_cnt` counter (0..
  `CLK_DIV`-1) producing a 1-cycle `baud_tick` pulse, an 8-bit `shift_r` (LSB-first shift-out), a
  3-bit `bit_cnt` (0..7). `uart_tx` output: `1'b0` during START, `shift_r[bit_cnt]` during DATA,
  `1'b1` during IDLE/STOP (idle-high per REQ-031).
- Latency: `utx_ready` deasserts the cycle a byte is accepted; a full frame takes `10*CLK_DIV`
  cycles (1 start + 8 data + 1 stop). Throughput: 1 byte every 10*CLK_DIV cycles (no double-buffering
  — `uart_line_fmt` waits for `utx_ready` before presenting the next byte, per IFI-007 semantics).
- Reset behaviour: `state <= ST_UTX_IDLE`, `uart_tx <= 1'b1` (idle-high, satisfies REQ-030's "uart_tx
  held at idle-mark" during/after reset), all counters to 0.
- Error handling: none (no illegal input states — `utx_valid` is only ever pulsed by
  `uart_line_fmt` when `utx_ready` is high, per IFI-007's `backpressure: true` semantics: the
  producer must observe `utx_ready` before asserting `utx_valid`).
- Timing budget: simple shift-register logic, ~2 ns.

#### BLK-010 : led_ctrl
- Purpose: derives `led[11:0]` from `ctrl_fsm`'s presented result and busy/blink status.
- Parent: BLK-001 / Clock: clk_core / Reset: rst_n / Source: custom
- Traces: REQ-017, REQ-018, REQ-019, REQ-020, REQ-030
- Ports: IFI-008 (`lc_pred`, `lc_verdict`, `lc_present`, `lc_busy` in) plus the raw `led[11:0]`
  output, wired straight to `mnist_npu`.
- Parameters: `BLINK_CYCLES` (default 5,000,000 ~10 Hz visible blink at 100 MHz, ASM-003;
  simulation override: a small value, e.g. 2-4, so multiple toggles are observable within one fast
  simulated compute window).
- Internal structure: `led_r[9:0]`/`led_r[10]` (registered result, updated only on `lc_present`);
  `blink_cnt` (0.. `BLINK_CYCLES`-1) and `blink_toggle_r` (toggles when `blink_cnt` wraps, but ONLY
  while `lc_busy` is high — REQ-019's "while running" window); `led[11] = lc_busy ?
  blink_toggle_r : 1'b0` (steady off once presented, satisfies "stops blinking when done").
  `led[9:0]` combinational from `led_r`: one-hot on `led_r_pred` when `led_r_verdict != 2`, all-zero
  when `led_r_verdict == 2` (REQ-017). `led[10] = (led_r_verdict != 0)` (REQ-018).
- Latency: `led[9:0]`/`led[10]` update 1 cycle after `lc_present` pulses (registered). `led[11]`
  updates combinationally from `lc_busy`/`blink_toggle_r` (no extra latency — the busy window
  boundary is exact, per VP-TOP-006).
- Reset behaviour: `led_r <= 11'd0` (led_r[9:0] and led_r[10] together), `blink_cnt <= 0`,
  `blink_toggle_r <= 1'b0` -> `led[11:0] == 12'h000` during reset, satisfying REQ-030.
- Error handling: none. Timing budget: trivial combinational mux, <1 ns.

#### BLK-011 : uart_line_fmt
- Purpose: composes the exact ASCII line (REQ-022) for the current result and streams it, one byte
  at a time, to `uart_tx` via the IFI-007 handshake.
- Parent: BLK-001 / Clock: clk_core / Reset: rst_n / Source: custom
- Traces: REQ-021, REQ-022
- Ports: IFI-009 (`lf_start`, `lf_pred`, `lf_conf`, `lf_exp`, `lf_idx`, `lf_verdict` in; `lf_done`
  out), IFI-007 (`utx_data`, `utx_valid` out; `utx_ready` in, as the source side).
- Parameters: `MAX_LINE_LEN` (default 80; longest actual line is 69 bytes — "IMG 099: This is
  number 9 | confidence 100% | expected 9 | INCORRECT\n" — computed exactly in §6.2; 80 leaves an
  11-byte margin).
- Internal structure: FSM-002 (§6.2, 3 states: IDLE/COMPOSE/SEND), `reg [7:0] line_buf
  [0:MAX_LINE_LEN-1]`, `line_len` register, `byte_idx` counter. On `lf_start`, latches
  `lf_pred`/`lf_conf`/`lf_exp`/`lf_idx`/`lf_verdict`; in `ST_LF_COMPOSE` (one cycle), a purely
  combinational field-by-field byte generator (§6.2) fills `line_buf`/`line_len`; in `ST_LF_SEND`,
  presents `line_buf[byte_idx]` via `utx_data`/`utx_valid` and increments `byte_idx` each time
  `utx_ready` accepts it, until `byte_idx == line_len-1`, then pulses `lf_done`.
- Latency: 1 (compose) + `line_len` byte-accept cycles, each byte-accept taking up to `10*CLK_DIV`
  cycles inside `uart_tx` (frame time dominates — see §8 cycle budget).
- Reset behaviour: `state <= ST_LF_IDLE`, `byte_idx <= 0`, `line_len <= 0`.
- Error handling: `line_len` is always `<= MAX_LINE_LEN` by construction (§6.2's field widths are
  fixed and bounded); no overflow path exists.
- Timing budget: the COMPOSE cycle has the second-largest combinational budget in the design (a
  wide case/if chain over ~15 fields) — see §15.

## 5. Datapath Definition

All arithmetic mirrors `arch/golden_model/golden_ref_model.c` node-for-node (this is the bit-exact
contract, REQ-002). Widths at every node:

| Node | Width | Signed? | Notes |
|---|---|---|---|
| pixel byte (image_rom data) | 8 | unsigned | REQ-003: value 0..255 |
| `mac_a` (widened pixel, layer 1) | 16 | treated as signed, always >=0 | `{8'h00, pixel}` |
| hidden activation (hidden_ram data) | 16 (value range 1..255 in low 8 bits) | treated as signed, always >=0 | REQ-007; LUT output zero-extended |
| `mac_a` (widened hidden act, layer 2) | 16 | treated as signed, always >=0 | `{8'h00, h[j]}` |
| weight word (weight_rom data) | 16 | **signed** | Q8.8, range -32768..32767 |
| `mac_b` | 16 | signed | = weight word, always |
| `product` (multiplier out) | 32 | signed | `$signed(mac_a) * $signed(mac_b)`, REQ-029 |
| bias word (weight_rom data, at bias addresses) | 16 | signed | Q8.8 |
| bias, Q16.16-aligned | 40 | signed | `{{16{bias[15]}}, bias, 8'b0}` — REQ-004 |
| `acc` (accumulator register) | 40 | signed | REQ-028 (>=40-bit bound, no truncation) |
| `acc >>> 8` (pre-saturate) | 40 (effective magnitude ~26 bits worst case) | signed | arithmetic right shift |
| `z` (post-saturate) | 16 | signed | clamp to [-32768,32767] — REQ-005 |
| `lut_addr` | 16 | unsigned index (= `z`'s raw bit pattern) | REQ-006 |
| `lut_data` / sigma | 8 | unsigned | range 1..255 (proven bound, not 0..256 — see §11) |
| `out[c]` (layer-2 sigma, 10 of them, conceptually — only the running best is kept, not all 10) | 8 | unsigned | REQ-008 |
| `best_val` | 8 | unsigned | argmax running max |
| `best_idx` / `pred` | 4 | unsigned | 0..9, REQ-009 |
| `confidence` | 7 | unsigned | 0..100, `(best_val*100)>>8` — REQ-010 |
| `verdict` | 2 | unsigned | 0/1/2 — REQ-011 |

Overflow policy: the accumulator is proven (REQ-028) never to overflow its 40-bit range for any
value combination reachable from the golden weight/pixel ranges, so no accumulator saturation
logic exists — `acc` simply never reaches its bounds. The only saturation in the entire datapath is
the explicit `z` clamp (REQ-005), which is not an overflow bug but a specified part of the golden
algorithm. No pipelining is used anywhere (every node above is either combinational-within-a-cycle
or a single register stage) — the design's cycle budget (§8) is set by the MAC loop length, not by
achievable clock frequency, so pipelining the multiplier/adder is unnecessary at 100 MHz (a
16x16 multiply + 40-bit add comfortably closes timing on Artix-7 at 100 MHz; see §15).

## 6. Control FSMs

### 6.1 FSM-001 : ctrl_fsm (binary encoding, 4-bit state, reset state = ST_IMG_START)

Registers: `state[3:0]`, `img_idx[6:0]` (0..99), `i_cnt[9:0]` (0..783), `j_cnt[5:0]` (0..31),
`c_cnt[3:0]` (0..9), `best_val[7:0]`, `best_idx[3:0]`, `hold_cnt[31:0]`.

| State | Condition | Next state | Registered actions this cycle |
|---|---|---|---|
| ST_IMG_START | (always) | ST_L1_MAC | `j_cnt<=0; i_cnt<=0`; address layer-1 unit 0, input 0; `mac_bias_ld<=1` next cycle |
| ST_L1_MAC | `i_cnt != 783` | ST_L1_MAC | `mac_acc_en<=1` (or `mac_bias_ld` on the very first step, `i_cnt==0`); `i_cnt<=i_cnt+1`; address `wrom_addr = i_cnt*32+j_cnt`, `irom_addr = img_idx*784+i_cnt` |
| ST_L1_MAC | `i_cnt == 783` | ST_L1_ACT | last accumulate for this unit issued |
| ST_L1_ACT | (always) | ST_L1_WB | `lut_addr <= mac_z` (present address) |
| ST_L1_WB | `j_cnt != 31` | ST_L1_MAC | `hram_addr<=j_cnt; hram_wdata<={8'd0,lut_data}; hram_we<=1`; `j_cnt<=j_cnt+1; i_cnt<=0` |
| ST_L1_WB | `j_cnt == 31` | ST_L2_MAC | same writeback; `j_cnt<=0` (reused as layer-2 inner counter); `c_cnt<=0` |
| ST_L2_MAC | `j_cnt != 31` | ST_L2_MAC | `mac_acc_en<=1` (or `mac_bias_ld` on `j_cnt==0`); `j_cnt<=j_cnt+1`; address `wrom_addr = 25120+j_cnt*10+c_cnt`, `hram_addr=j_cnt` (read) |
| ST_L2_MAC | `j_cnt == 31` | ST_L2_ACT | last accumulate for this output issued |
| ST_L2_ACT | (always) | ST_L2_WB | `lut_addr <= mac_z` |
| ST_L2_WB | `c_cnt != 9` | ST_L2_MAC | argmax update: `if (c_cnt==0 \|\| lut_data>best_val) begin best_val<=lut_data; best_idx<=c_cnt; end`; `c_cnt<=c_cnt+1; j_cnt<=0` |
| ST_L2_WB | `c_cnt == 9` | ST_RESULT | same argmax update |
| ST_RESULT | (always) | ST_PRESENT | `confidence<=(best_val*100)>>8`; `verdict<=(confidence<50)?2:((best_idx==lrom_data)?0:1)`; `lc_pred<=best_idx; lc_verdict<=verdict; lc_present<=1`; `lf_start<=1` (with `lf_pred/lf_conf/lf_exp/lf_idx/lf_verdict` latched from the same values) |
| ST_PRESENT | `!lf_done` | ST_PRESENT | `lc_busy<=1` (still busy — REQ-019 blink window extends through line composition/send, see note below) |
| ST_PRESENT | `lf_done` | ST_HOLD | `lc_busy<=0` (busy window ends here); `hold_cnt<=0` |
| ST_HOLD | `hold_cnt != HOLD_CYCLES-1` | ST_HOLD | `hold_cnt<=hold_cnt+1` |
| ST_HOLD | `hold_cnt == HOLD_CYCLES-1` | ST_IMG_START | `img_idx <= (img_idx==99) ? 0 : img_idx+1` |
| (any other state value) | `default:` | ST_IMG_START | illegal-state recovery (REQ-024) |

**MAC-loop ROM-latency clarification (binding on fe-rtl):** `weight_rom`/`image_rom`/`hidden_ram`
are registered-address/registered-output (1-cycle read latency, required for clean Xilinx BRAM
inference, REQ-025). Consequently each self-loop iteration of `ST_L1_MAC`/`ST_L2_MAC` (one
increment of `i_cnt`/`j_cnt`) spans **two** `clk` edges, not one: a hidden 2-bit `mstep` register
cycles ADDR (present this step's weight/pixel or weight/hidden-activation address, hold counters)
-> ACC (the previously presented address's data is now valid; assert `mac_acc_en`; advance the
counter; `mstep` returns to ADDR). Additionally, **the bias for each unit is fetched as its own
explicit ADDR/ACC pair** (`mstep` = BIAS_ADDR -> BIAS_ACC) before the 784/32-term loop begins,
because `weight_rom` is single-port and cannot return the bias word and the first weight word in
the same cycle: on BIAS_ACC, `ctrl_fsm` drives `mac_a`=0 (forcing `mac_datapath`'s product to 0) so
`mac_bias_ld` correctly loads `acc<=bias_q16_16` alone (`mac_datapath.v` header). The **named FSM
states and the transition table above are unchanged** (`ST_L1_MAC`/`ST_L2_MAC` still self-loop on
the same conditions, now for `784+1`/`32+1` `mstep`-pairs instead of `784`/`32`) — `mstep` is a
datapath-timing detail internal to the self-loop, exactly analogous to why `ST_L1_ACT`->`ST_L1_WB`
already uses two named states to cross `sigmoid_lut`'s own 1-cycle latency. `mac_z` itself is
**combinational** from `acc` (not registered — see the revised BLK-003 note above this table),
which is what keeps the post-loop sequence at exactly two states (`ST_L1_ACT` presents `lut_addr`
from the now-settled `mac_z`; `ST_L1_WB` consumes the now-valid `lut_data`) instead of three. This
revises the raw MAC-loop cycle count used in §8's budget below to `(784+1)*2` and `(32+1)*2` per
unit (not `784`/`32`).

**REQ-019 busy-window clarification (binding on fe-rtl):** `lc_busy` (hence `led[11]` blink) is
high from `ST_IMG_START` through the end of `ST_PRESENT` (i.e. through UART line composition and
transmission), and only goes low once `ST_HOLD` begins. `led[9:0]`/`led[10]` are latched
(`lc_present`, a 1-cycle strobe entering `ST_PRESENT`) at the start of `ST_PRESENT`, so the LED
digit/fail-flag are visible immediately while the blink is still running through UART transmission
— matching REQ-019's "from start of image processing until the result is presented" read literally
as the LED-digit/fail-flag becoming visible, while making the blink also honestly reflect that the
UART line for that result is still in flight (a stricter, unambiguous interpretation chosen because
the alternative — stopping the blink before the UART line finishes — would let `led[11]` go steady
while `uart_tx` is still busy, which could read as "done" to an observer when it is not). This
interpretation is recorded here because the brief's wording admits both readings; VP-TOP-006
(`spec/verification_plan.md`) must be evaluated against this exact FSM behaviour.

**Sim-speed / UART-truncation interaction (binding on fe-rtl, resolves project brief §6 vs §7):**
`ST_PRESENT` waits for `lf_done` (full UART line accepted by `uart_tx`) **before** `ST_HOLD` begins
counting `HOLD_CYCLES`. This guarantees the UART byte stream is never truncated or interleaved
between images regardless of how small `HOLD_CYCLES` is set in simulation (even `HOLD_CYCLES` = 0
would still be safe) — see §8 for the resulting cycle budget.

### 6.2 FSM-002 : uart_line_fmt (binary encoding, 2-bit state, reset state = ST_LF_IDLE)

| State | Condition | Next state | Action |
|---|---|---|---|
| ST_LF_IDLE | `!lf_start` | ST_LF_IDLE | idle |
| ST_LF_IDLE | `lf_start` | ST_LF_COMPOSE | latch `pred_r/conf_r/exp_r/idx_r/verdict_r` from the `lf_*` inputs |
| ST_LF_COMPOSE | (always) | ST_LF_SEND | combinational field generator (below) fills `line_buf[0:MAX_LINE_LEN-1]` and `line_len`, registered on this edge; `byte_idx<=0` |
| ST_LF_SEND | `!(byte_idx==line_len-1 && utx_ready)` | ST_LF_SEND | if `utx_ready`: `utx_valid<=1; utx_data<=line_buf[byte_idx]; byte_idx<=byte_idx+1` |
| ST_LF_SEND | `byte_idx==line_len-1 && utx_ready` | ST_LF_IDLE | last byte accepted; `lf_done<=1` (1-cycle pulse) |
| (any other) | `default:` | ST_LF_IDLE | illegal-state recovery |

**Field generator (executed once, in `ST_LF_COMPOSE`, purely combinational, using a block-local
`integer p` write-pointer — legal per `rtl_coding_guidelines.md` §1, not shared across always
blocks):** append, in order — `"IMG "` (4 bytes) · 3-digit zero-padded `idx_r` (hundreds digit is
always `"0"` since `idx_r<=99`) · `": "` (2) · if `verdict_r==2`: `"NOT A NUMBER"` (12) else
`"This is number "` (15) + one digit `"0"+pred_r` (1) · `" | confidence "` (14) · variable-width
`conf_r` with NO leading zeros: `"100"` (3 bytes) if `conf_r==100`, else 2 digits if `conf_r>=10`,
else 1 digit · `"% | expected "` (13) · one digit `"0"+exp_r` (1) · `" | "` (3) · verdict string:
`"CORRECT"` (7) / `"INCORRECT"` (9) / `"TRASH"` (5) · `"\n"` (1, = `8'h0A`). `line_len <= p` after
the last append. Longest possible line (INCORRECT, `conf_r==100`) = 69 bytes, comfortably under
the default `MAX_LINE_LEN`=80.

### 6.3 FSM-003 : uart_tx (binary encoding, 2-bit state, reset state = ST_UTX_IDLE)

| State | Condition | Next state | Action |
|---|---|---|---|
| ST_UTX_IDLE | `!utx_valid` | ST_UTX_IDLE | `uart_tx<=1'b1` (idle-high); `utx_ready<=1'b1` |
| ST_UTX_IDLE | `utx_valid` | ST_UTX_START | `shift_r<=utx_data; bit_cnt<=0; baud_cnt<=0; utx_ready<=1'b0` |
| ST_UTX_START | `!baud_tick` | ST_UTX_START | `uart_tx<=1'b0` (start bit) |
| ST_UTX_START | `baud_tick` | ST_UTX_DATA | `bit_cnt<=0` |
| ST_UTX_DATA | `!(baud_tick && bit_cnt==7)` | ST_UTX_DATA | `uart_tx<=shift_r[bit_cnt]`; on `baud_tick`: `bit_cnt<=bit_cnt+1` |
| ST_UTX_DATA | `baud_tick && bit_cnt==7` | ST_UTX_STOP | last data bit consumed |
| ST_UTX_STOP | `!baud_tick` | ST_UTX_STOP | `uart_tx<=1'b1` (stop bit, also = idle level) |
| ST_UTX_STOP | `baud_tick` | ST_UTX_IDLE | `utx_ready<=1'b1` |
| (any other) | `default:` | ST_UTX_IDLE | illegal-state recovery; `uart_tx<=1'b1` |

`baud_tick`: a free-running `baud_cnt` counter (0..`CLK_DIV`-1, resets to 0 on every state entry
above) pulses `baud_tick` for 1 cycle every `CLK_DIV` cycles while not in `ST_UTX_IDLE`.
`utx_busy = (state != ST_UTX_IDLE)`.

## 7. Memory Map and Register Definition

**None.** No host-visible register file exists (REQ-015, spec.md §6). This design's "memory map"
is instead the set of five ROM/RAM instances and their address spaces:

| MEM-ID | Instance (BLK) | Depth | Width | Address meaning |
|---|---|---|---|---|
| MEM-001 | weight_rom (BLK-005) | 25,450 | 16 (signed) | `0..25087`=W1[i*32+j]; `25088..25119`=b1[j]; `25120..25439`=W2[j*10+c]; `25440..25449`=b2[c] |
| MEM-002 | image_rom (BLK-006) | 78,400 | 8 (unsigned) | `img_idx*784+i`, i=0..783 |
| MEM-003 | label_rom (BLK-007) | 100 | 8 (unsigned) | `img_idx` |
| MEM-004 | hidden_ram (BLK-008) | 32 | 16 (holds 1..255) | `j` (hidden unit index) |
| MEM-005 | sigmoid_lut (BLK-004) | 65,536 | 8 (unsigned) | `z` (16-bit two's-complement bit pattern) |

**Memory initialisation mechanism (binding on fe-rtl):** every ROM/RAM that needs pre-loaded
content uses a synthesis-safe `initial $readmemh(<PARAM>, <array>);` inside its own module, where
`<PARAM>` is a `parameter` string defaulting to the path given above, expressed relative to the
`mnist_npu` project root (so `iverilog` invoked from that root, per the project brief's exit
check, finds the file). A companion `` `define `` in a shared header (`rtl/mnist_npu_defs.vh`,
included by `mnist_npu` and re-exported as parameter defaults — see `rtl_manifest.yaml` and
`filelist.f` in the `fe-rtl` stage) documents the same defaults for a human reader. **FPGA note for
a later stage:** Vivado requires either `$readmemh` support in its own elaboration flow (supported
for behavioural initial blocks with a relative/absolute path resolvable at synthesis time) or a
`.coe`/`.mem` BRAM-init conversion; this project defers that conversion to the (out-of-scope) FPGA
bring-up stage and only guarantees the `$readmemh` mechanism works under `iverilog` from the
project root, per the brief.

Reserved-bit / access-type columns are N/A (no registers exist).

## 8. Internal Interfaces (IFI-###)

See `interface_defs.yaml` for the full signal-level definitions of IFI-001..IFI-009. All nine are
`type: status` (unconditional, no backpressure — `ctrl_fsm` always drives them at exactly the rate
its own FSM produces/consumes data, since it owns both ends of every one of those interfaces'
timing) except **IFI-007** (`uart_tx_port`, `type: valid_ready`, the one genuine handshake in the
design, because `uart_tx` is a real multi-cycle engine whose consumption rate `uart_line_fmt` does
not control) — the `valid_may_depend_on_ready: false` / `data_stable_while_stalled: true` semantics
mean `uart_line_fmt` must hold `utx_data` stable and must only pulse `utx_valid` when it has
already observed `utx_ready` high (never speculatively).

**Pacing parameter cycle budget (REQ-016/020/021/026), derived from the FSM tables above:**

- Layer 1: 32 units x (784+1 bias) MAC steps x **2 phases/step** (ROM latency, see note above) =
  50,240, + 32 x 2 (ACT+WB) = 64 -> 50,304 cycles.
- Layer 2: 10 units x (32+1 bias) MAC steps x 2 phases/step = 660, + 10 x 2 (ACT+WB) = 20 -> 680 cycles.
- ST_RESULT: 1 cycle.
- ST_PRESENT: `line_len` byte-accepts, each up to `10*CLK_DIV` cycles (worst case, no back-to-back
  savings assumed) -> up to `69 * 10 * CLK_DIV` cycles for the longest line.
- ST_HOLD: `HOLD_CYCLES`.
- **Default (real hardware, CLK_DIV=868, HOLD_CYCLES=50,000,000):** ~50,304+680+1 = 50,985 compute
  cycles (~510 us at 100 MHz) + up to 69*10*868 = 598,920 UART cycles (~5.99 ms) + 50,000,000 hold
  cycles (500 ms) ~= **~507 ms/image**, i.e. ~1.97 images/s, consistent with the brief's "human
  visible" pacing intent.
- **Simulation (CLK_DIV=4, HOLD_CYCLES=8):** ~50,985 compute + up to 69*10*4=2,760 UART + 8 hold =
  **~53,753 cycles/image**, x100 images ~= **~5.38M simulated cycles** for the full VP-TOP-002/008
  soak — comfortably "complete in seconds" under `iverilog` (REQ-026). `CLK_DIV`'s simulation
  override is documented here precisely because REQ-026 is a *hard* requirement while REQ-021 only
  requires the framing structure (start/8-data/stop, byte content) to be correct, not the specific
  numeric baud rate — the numeric 868-cycle-per-bit timing (VP-UART-002) should additionally be
  re-run at least once with `CLK_DIV`=868 outside the fast 100-image regression, since that specific
  check depends on the real divider value.

## 9. Clock and Reset Architecture

One domain, `CD_CORE` (`clk`, 100 MHz nominal, CLK-001). One reset, `rst_n`, active-low, **fully
synchronous** (RST-001) — see `spec.md` §5 and `rtl_coding_guidelines.md` §3 for the exact,
mandatory `always @(posedge clk) if (!rst_n) ... else ...` template (no `negedge rst_n` anywhere in
this design). No reset synchroniser exists or is needed (single domain). Minimum assert width: 2
cycles (ASM-001). See `cdc_plan.md` for the (trivial, empty) CDC analysis.

## 10. IP Reuse Plan

| BLK-ID | Decision | Repo | Licence | Status | Adapter needed |
|---|---|---|---|---|---|
| BLK-009 (uart_tx) | custom | n/a | n/a | rejected (IPR-001, `spec/requirements.yaml`) | n/a |

No other block was a reuse candidate (all fully custom per `spec.md` §10); `fe-arch` re-confirms
this rather than re-searching, since `spec.md` §10 already recorded the rationale and the
network-unavailable fallback.

## 11. Golden Model Description

**The golden model is pre-existing and FROZEN — this stage does not generate, regenerate, or
relocate it.** Per the project brief §3/§9: `arch/golden_model/golden_ref_model.c` (C99,
integer-only, transaction-level: one call to `forward()` per image) plus its committed hex vector
files (`weights.hex`, `images.hex`, `labels.hex`, `expected.hex`, `expected_outputs.txt`,
`README.md`) already satisfy every requirement `fe-arch`'s own §7.6 template would normally impose
on a freshly authored model (fixed-width integer arithmetic only, no float, no malloc, deterministic
output, real — not placeholder — expected values). This fe-arch pass instead:

- **Validated it was reproducible:** `gcc -std=c99 -O2 -Wall -Wextra -o gm golden_ref_model.c &&
  ./gm .` was re-run from the `mnist_npu` project root during this architecture pass and reproduced
  the committed baseline exactly — 9225 correct / 270 incorrect / 505 trash on the full 10,000-image
  MNIST test set = 92.25% accuracy, bit-identical to the committed `expected_outputs.txt` (`git
  status` clean after the run). The model was also independently cross-validated against a numpy
  integer emulation, 100/100 bit-identical on the first 100 images (project brief §3, README.md).
- **Derived the RTL algorithm directly from it** (§5/§6 above reproduce every arithmetic step of
  `forward()` node-for-node, including the exact bias-alignment, shift, and saturation order).
- **Does not duplicate its vector files.** The upstream `fe-arch` skill template calls for
  `golden_model/stimulus.hex` + `golden_model/expected.hex` to be (re)emitted by this stage; here,
  `arch/golden_model/images.hex` + `arch/golden_model/labels.hex` (stimulus) and
  `arch/golden_model/expected.hex` (expected) already exist at exactly those paths, already in
  `$readmemh`-loadable form, and are the same files the RTL's own ROMs load from (REQ-012/013/014)
  — regenerating a second copy would create exactly the "two hand-kept copies" drift the skill's own
  format contract (§7.6) warns against. `arch_manifest.yaml`'s `golden_model:` section (§ below)
  points at these existing paths with `source: frozen_preexisting` instead of re-declaring them.
- **Build/run instructions** (unchanged, not executed by this stage): `gcc -std=c99 -O2 -Wall
  -Wextra -o gm arch/golden_model/golden_ref_model.c && ./gm . ` (run from the `mnist_npu` project
  root) reproduces `arch/golden_model/{expected.hex,images.hex,labels.hex,expected_outputs.txt}` in
  place (all four are deterministic outputs of the same deterministic run — this was exercised
  above and confirmed byte-identical to the committed copies).

## 12. Verification Hooks

Pure-Verilog observation points for the later `fe-iverilog`/`fe-cocotb` stage (per
`spec/verification_plan.md`): `ctrl_fsm.state` (FSM coverage, VP-CTRL-001), `mac_datapath.acc`/`z`
(VP-MAC-001..003, compare against a recomputation from the same ROM reads), `sigmoid_lut` address/
data pair every cycle it is read (VP-LUT-001/002 — exhaustive check is done standalone by
`tools/check_lut.py` against the generated hex, not by walking the RTL), `led_ctrl.led_r` and the
top-level `led[11:0]` (VP-TOP-005/006, VP-LED-001..003), `uart_tx`'s `uart_tx` pin bit-by-bit
(VP-TOP-004, VP-UART-001/002), and `ctrl_fsm.img_idx`/`hold_cnt` (VP-TOP-003/007). All of these are
plain hierarchical signal references from a testbench — no DFT observability mux is needed (none is
permitted).

## 13. Traceability: REQ -> BLK

| REQ-ID | BLK-ID(s) |
|---|---|
| REQ-001 | BLK-002 |
| REQ-002 | BLK-003 |
| REQ-003 | BLK-003 |
| REQ-004 | BLK-003 |
| REQ-005 | BLK-003 |
| REQ-006 | BLK-004 |
| REQ-007 | BLK-008 |
| REQ-008 | BLK-003 |
| REQ-009 | BLK-002 |
| REQ-010 | BLK-002 |
| REQ-011 | BLK-002 |
| REQ-012 | BLK-005 |
| REQ-013 | BLK-006 |
| REQ-014 | BLK-007 |
| REQ-015 | BLK-002 |
| REQ-016 | BLK-002 |
| REQ-017 | BLK-010 |
| REQ-018 | BLK-010 |
| REQ-019 | BLK-002, BLK-010 |
| REQ-020 | BLK-010 |
| REQ-021 | BLK-009, BLK-011 |
| REQ-022 | BLK-011 |
| REQ-023 | BLK-001 (all blocks, structurally) |
| REQ-024 | BLK-001 (all blocks, structurally) |
| REQ-025 | BLK-004, BLK-005, BLK-006, BLK-007, BLK-008 |
| REQ-026 | BLK-002, BLK-009, BLK-010, BLK-011 |
| REQ-028 | BLK-003 |
| REQ-029 | BLK-003 |
| REQ-030 | BLK-009, BLK-010 |
| REQ-031 | BLK-009 |

Every `must` requirement maps to >=1 block; every block traces to >=1 requirement (§4 "Traces"
lines). Zero orphans in either direction.

## 14. Assumptions and Open Issues

Carried forward unchanged from `spec/spec.md` §11/§12: ASM-001 (min reset assert = 2 cycles),
ASM-002 (100 MHz exact), ASM-003 (default `BLINK_CYCLES` = 5,000,000) — all three acknowledged,
none affects bit-exactness. Zero open issues (`OI-###`). One new architecture-local decision
recorded here rather than as a new ASM-ID (it is a design choice with an unambiguous rationale, not
an unconfirmed default): the REQ-019 busy-window boundary and the ST_PRESENT/ST_HOLD UART-completion
gating, both in §6.1.

## 15. Estimated Area and Timing Budget

Qualitative (no synthesis is run at this stage). Flop count dominated by: `ctrl_fsm` counters
(~40 bits of counters/registers), `mac_datapath` (56 bits: 40-bit acc + 16-bit z), `uart_line_fmt`
(80x8 = 640 bits of `line_buf`, the single largest flop/LUTRAM user if not BRAM-mapped — a
synthesis tool may map this to distributed RAM), `led_ctrl`/`uart_tx` (small, <30 bits each). Gate
estimate: dominated by the 16x16 signed multiplier (~a few hundred LUTs on Artix-7, or 1 DSP48
slice if the synthesis tool infers one — either is "cleanly synthesizable" per REQ-025) and the
`uart_line_fmt` field-generator's wide combinational case/if chain (small in gate count, wide in
fan-in). Critical path budget within the 10.000 ns period: `mac_datapath`'s multiply-accumulate
(~6.0 ns estimated: 16x16 multiply + 40-bit add) is the largest single combinational budget, leaving
~4.0 ns of margin at 100 MHz on a 7-series FPGA (well within reach, especially if the tool maps the
multiply to a DSP48 slice, which has its own fast carry/multiply hardware) — REQ-025 requires only
"cleanly synthesizable," but this margin note is retained for the FPGA bring-up stage as a sanity
check, not a promise.
