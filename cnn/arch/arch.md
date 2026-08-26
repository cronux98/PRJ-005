# cnn (mnist_npu v2) — Microarchitecture Specification
Document ID: ARCH-CNN-v1.0 | Stage: fe-arch | Input: SPEC-CNN-v1.0
Technology: FPGA-generic (Xilinx Artix-7 100T / Nexys A7 eventual target) | RTL: pure
Verilog-2001/2005 | DFT: none

## 1. Architecture Overview

`cnn_npu` is a single-clock-domain, free-running CNN inference engine: Conv1(3x3,1->8,pad1,ReLU)
-> Pool1(2x2 max) -> Conv2(3x3,8->16,pad1,ReLU) -> Pool2(2x2 max) -> FC1(784->32,sigmoid) ->
FC2(32->10,sigmoid). One shared multiply-accumulate (MAC) datapath (`mac_datapath`, 16x16
multiplier + 64-bit signed accumulator) is time-multiplexed, under the control of a single
top-level FSM (`ctrl_fsm`), across every conv tap, pool comparison, and FC MAC step of one image's
forward pass. A combinational window-address generator (`win_addr_gen`) computes every ROM/RAM
address and the zero-padding in/out-of-bounds flag from `ctrl_fsm`'s loop counters. All
inter-layer feature maps live in a single reused RAM (`fm_ram`, two ping-pong regions, §7).
Weights, images and labels live in `$readmemh`-initialised ROMs sourced from the frozen golden
package. The 65536x8 sigmoid ROM (`sigmoid_lut`, reused verbatim from v1) replaces any divider on
the FC path; the conv path uses ReLU (a sign mux) instead. Per image, the result
(`pred`/`confidence`/`verdict`) drives the LED outputs and is formatted into an exact ASCII line,
sent one byte at a time to a standard 115200 8N1 UART transmitter (`uart_tx`, reused verbatim from
v1, via `uart_line_fmt`, also reused verbatim). After a parameterized hold, the next image
(index+1 mod 100) begins.

## 2. Design Constraints Inherited from Specification

Restated verbatim from `spec/spec.md` §2 (see that document for the full deviation rationale):
FPGA-generic technology (not Sky130 — explicit, documented deviation, §2.1 there); pure
Verilog-2001/2005; no SystemVerilog; no DFT; no host interface/CSR/APB of any kind; single clock
domain; **fully synchronous** active-low reset (not async-assert/sync-deassert); all program data
via `$readmemh` only; `BLINK_CYCLES` default MUST be 100,000 (REQ-026, fixes the v1 defect).

## 2.1 Technology carried forward unchanged

Per `spec/spec_manifest.yaml : deviation_note`, this stage carries `technology.pdk: fpga_generic`
forward unchanged. `fe-arch`'s own input-validation check #8 (`technology.pdk == sky130 and
node_nm == 130`, else `ARCH-E007`) is **knowingly and explicitly overridden** here for the same
reason given in `spec.md` §2.1 and identically to v1 `mnist_npu/arch/arch.md` §2.1: the
commissioning task unambiguously specifies an FPGA deployment (Nexys A7 / Artix-7 100T), and
nothing in this design touches a Sky130-specific artifact.

## 3. Hierarchy and Partitioning

| BLK-ID | Module | Parent | Clock | Reset | Source |
|---|---|---|---|---|---|
| BLK-001 | `cnn_npu` | (top) | clk_core | rst_n | custom |
| BLK-002 | `ctrl_fsm` | BLK-001 | clk_core | rst_n | custom |
| BLK-003 | `mac_datapath` | BLK-001 | clk_core | rst_n | custom |
| BLK-004 | `sigmoid_lut` | BLK-001 | clk_core | rst_n | reuse (verbatim copy, `mnist_npu/rtl/sigmoid_lut.v`) |
| BLK-005 | `weight_rom` | BLK-001 | clk_core | rst_n | custom |
| BLK-006 | `image_rom` | BLK-001 | clk_core | rst_n | custom |
| BLK-007 | `label_rom` | BLK-001 | clk_core | rst_n | custom |
| BLK-008 | `fm_ram` | BLK-001 | clk_core | rst_n | custom |
| BLK-009 | `uart_tx` | BLK-001 | clk_core | rst_n | reuse (verbatim copy, `mnist_npu/rtl/uart_tx.v`) |
| BLK-010 | `led_ctrl` | BLK-001 | clk_core | rst_n | reuse (verbatim copy, `mnist_npu/rtl/led_ctrl.v`) |
| BLK-011 | `uart_line_fmt` | BLK-001 | clk_core | rst_n | reuse (verbatim copy, `mnist_npu/rtl/uart_line_fmt.v`) |
| BLK-012 | `win_addr_gen` | BLK-001 | clk_core | rst_n | custom |

`cnn_npu` instantiates all eleven leaf blocks directly (flat hierarchy, identical rationale to v1:
one clock domain, small design, an intermediate wrapper layer adds no value). `ctrl_fsm` is the
sole source of control signals; `win_addr_gen` is pure combinational address arithmetic with no
state of its own (control/datapath separation, fe-arch Step 3); every ROM/RAM is pure
storage/interface; `uart_tx` and `uart_line_fmt` each own a small local FSM needed to sequence
their own multi-cycle byte/bit-level protocols, unchanged from v1 — `ctrl_fsm` treats both as
black-box engines via the same strobe/status handshake v1 used (IFI-007, IFI-009).

`win_addr_gen` (BLK-012) is new versus v1: v1's fully-connected layers needed only a single
multiply-add per ROM address (`i*32+j`), computed inline in `ctrl_fsm`. The CNN's 3x3
zero-padded sliding windows (conv1/conv2) and 2x2 stride-2 pooling (pool1/pool2) need boundary
detection and multiple, layer-dependent address formulas — a distinct responsibility large enough
to violate `ctrl_fsm`'s "control signals only" charter if folded in (Step 3 separation rule), so it
is its own block.

## 4. Block Specifications

#### BLK-001 : cnn_npu
- Purpose: top-level integration; owns no state of its own beyond wiring.
- Parent: (none) / Clock: clk_core / Reset: rst_n / Source: custom
- Traces: all REQs (top-level integration)
- Ports: `clk`, `rst_n`, `led[11:0]` (output), `uart_tx` (output) — exactly `interface_defs.yaml`
  external_interfaces IF-001/IF-002/IF-003.
- Parameters: re-exports every leaf parameter so a single top-level instantiation can override all
  of them: `HOLD_CYCLES` (default 50,000,000), `BLINK_CYCLES` (default **100,000** — REQ-026,
  passed down to `led_ctrl`'s `BLINK_CYCLES` instance parameter, overriding that file's own
  internal default of 5,000,000; the `led_ctrl.v` file itself is copied byte-for-byte unchanged
  from v1 — only the instantiation's parameter override differs), `CLK_DIV` (default 868).
- Internal structure: instantiates BLK-002..BLK-012, wires per `block_diagram.mmd`.
- Latency/Throughput: N/A (structural only).
- Reset behaviour: none of its own; passes rst_n through.
- Error handling: none (no error conditions in this design, spec.md §8).
- Timing budget: N/A (no logic of its own).

#### BLK-002 : ctrl_fsm
- Purpose: sequences one image's full inference (CONV1, POOL1, CONV2, POOL2, FC1, FC2, argmax,
  confidence/verdict, UART line dispatch, LED presentation, hold), then advances to the next
  image, forever.
- Parent: BLK-001 / Clock: clk_core / Reset: rst_n / Source: custom
- Traces: REQ-001, REQ-004..REQ-018, REQ-024, REQ-025, REQ-027
- Ports: see IFI-001..IFI-006, IFI-008, IFI-009, IFI-010 in `interface_defs.yaml` (`ctrl_fsm` is
  the "from_source" end of every one of these except IFI-007).
- Parameters: `HOLD_CYCLES` (default 50,000,000; simulation override 4-16 per REQ-025).
- Internal structure: FSM-001 (§6.1, outer state, 8 states + default, binary encoding) plus three
  shared sub-phase machines reused across the outer states — FSM-002 `mac_phase` (CONV1/CONV2/
  FC1/FC2), FSM-003 `pool_phase` (POOL1/POOL2), FSM-004 `present_phase` (PRESENT) — and the
  register set of §6.0. No datapath arithmetic lives here beyond driving `win_addr_gen`'s selects
  and the final confidence/verdict combinational logic (§5).
- Latency: one full image = the sum of all six layers' MAC/pool step counts + PRESENT (UART line
  time) + `HOLD_CYCLES`. See §6.5 for the exact cycle-count derivation.
- Throughput: 1 image fully classified and presented per (compute + UART + hold) cycle budget.
- Reset behaviour: `state <= ST_CONV1`, all loop/phase counters and `img_idx` to 0 (see §6.1/§6.0
  for exact reset values of every register).
- Error handling: illegal outer or phase state -> `default:` recovers to `ST_CONV1`/idle phase
  (REQ-035).
- Timing budget: `mac_datapath`'s 64-bit add is this design's largest single-cycle combinational
  path (§15).

#### BLK-003 : mac_datapath
- Purpose: one shared 16x16->32-bit signed multiplier, sign-extended into one shared 64-bit signed
  accumulator; produces the ReLU'd or saturated-and-LUT-addressed activation at the end of a MAC
  sequence.
- Parent: BLK-001 / Clock: clk_core / Reset: rst_n / Source: custom
- Traces: REQ-002, REQ-003, REQ-004, REQ-005, REQ-006, REQ-008, REQ-010, REQ-011, REQ-017, REQ-018
- Ports: IFI-001 (`mac_a`, `mac_b`, `mac_bias_ld`, `mac_bias`, `mac_acc_en` in; `mac_z`, `mac_h`
  out).
- Parameters: none (all widths fixed by the golden contract).
- Internal structure: `product = $signed(mac_a) * $signed(mac_b)` (32-bit, combinational); `acc`
  (64-bit reg): on `mac_bias_ld`, `acc <= {{40{mac_bias[15]}}, mac_bias, 8'b0}` (bias sign-extended
  and Q16.16-aligned into the full 64 bits — REQ-004/REQ-008/REQ-010/REQ-011); on `mac_acc_en` (and
  not `mac_bias_ld`), `acc <= acc + {{32{product[31]}}, product}` (sign-extend the 32-bit product
  to 64 bits before adding); `mac_z` (16-bit, **wire**, purely combinational): saturate
  `$signed(acc) >>> 8` to `[-32768, 32767]` (REQ-005); `mac_h` (16-bit, **wire**, purely
  combinational): `mac_z[15] ? 16'sd0 : mac_z` (ReLU, REQ-006 — used only by conv states; FC states
  route `mac_z` to `sigmoid_lut`'s address input instead, not `mac_h`).
- Latency: 1 MAC-step's ADDR+ACC pair spans 2 cycles (ROM read latency, §6.2); `mac_z`/`mac_h` are
  valid combinationally as soon as `acc` holds its final value.
- Throughput: 1 MAC-step accumulate per 2 cycles (ADDR then ACC), sustained, no stalls.
- Reset behaviour: `acc <= 64'sd0` (`mac_z`/`mac_h` need no reset — combinational).
- Error handling: none (accumulator provably cannot overflow — REQ-017 margin analysis, §5;
  saturation of `mac_z` is not an error, it is specified REQ-005 behaviour).
- Timing budget: ~6.5 ns of the 10.000 ns period (16x16 multiply + 64-bit add + compare/saturate
  chain) — the single largest combinational timing budget in the design; see §15.

#### BLK-004 : sigmoid_lut (reused verbatim from v1)
- Purpose: 65536x8 ROM implementing `sigma(z) = 128 + trunc(128*z/(256+|z|))` bit-exactly for
  every possible 16-bit signed `z`, replacing any divider circuit on the FC path.
- Parent: BLK-001 / Clock: clk_core / Reset: rst_n / Source: reuse, `mnist_npu/rtl/sigmoid_lut.v`
  copied byte-for-byte unchanged (same module name, ports, parameter).
- Traces: REQ-022
- Ports: `clk`, `rst_n`, `addr[15:0]` in, `rdata[7:0]` out (registered, 1-cycle latency) — identical
  to v1's IFI-002.
- Parameters: `LUT_HEX_FILE` (default `` `MNIST_NPU_SIGMOID_LUT_HEX ``, i.e.
  `"rtl/sigmoid_lut.hex"`) — the v1-generated hex content is reused unchanged (identical sigmoid
  function, REQ-022; not regenerated).
- Internal structure: `reg [7:0] rom [0:65535]`, `initial $readmemh(...)`, registered read.
- Latency/Throughput: 1 cycle / 1 lookup per cycle (only 2 lookups per image — one per FC layer's
  32/10 units, each after its own MAC sequence — far below any bandwidth limit).
- Reset behaviour: `rdata <= 8'd0` on reset (ROM contents need no reset).
- Error handling: none (defined for all 65536 addresses by construction).
- Timing budget: BRAM access, ~2 ns.

#### BLK-005 : weight_rom
- Purpose: single 26,698 x 16-bit signed ROM holding conv1_w|conv1_b|conv2_w|conv2_b|fc1_w|fc1_b|
  fc2_w|fc2_b, `$readmemh`-initialised from the frozen `arch/golden_model/weights.hex`.
- Parent: BLK-001 / Clock: clk_core / Reset: rst_n / Source: custom
- Traces: REQ-013, REQ-019
- Ports: IFI-003 (`wrom_addr` in, `wrom_data` out).
- Parameters: `WEIGHTS_HEX_FILE` (default `"arch/golden_model/weights.hex"`, relative to the `cnn`
  project root — §7 memory-init mechanism).
- Internal structure: `reg signed [15:0] rom [0:26697]`, `initial $readmemh(...)`, 1 registered
  read port (address registered, data available 1 cycle later — Xilinx BRAM-inferable).
- Latency: 1 cycle. Throughput: 1 read/cycle (one read every MAC-step ADDR cycle).
- Reset behaviour: none for contents; output register resets to 16'sd0.
- Error handling: address always in `[0,26697]` by construction (`win_addr_gen`'s formulas are
  range-bounded by `ctrl_fsm`'s own loop bounds); out-of-range addressing cannot occur.
- Timing budget: BRAM access, ~2 ns.

#### BLK-006 : image_rom
- Purpose: 78,400 x 8-bit unsigned ROM (100 images x 784 pixels), `$readmemh`-initialised from
  `arch/golden_model/images.hex`.
- Parent: BLK-001 / Clock: clk_core / Reset: rst_n / Source: custom
- Traces: REQ-020
- Ports: IFI-004. Parameters: `IMAGES_HEX_FILE` (default `"arch/golden_model/images.hex"`).
- Internal structure: `reg [7:0] rom [0:78399]`, same registered-read shape as BLK-005.
- Latency/Throughput: 1 cycle / 1 read per cycle. Reset: output register to 8'd0.
- Timing budget: BRAM access, ~2 ns.

#### BLK-007 : label_rom
- Purpose: 100 x 8-bit unsigned ROM, `$readmemh`-initialised from `arch/golden_model/labels.hex`.
- Parent: BLK-001 / Clock: clk_core / Reset: rst_n / Source: custom
- Traces: REQ-021
- Ports: IFI-005. Parameters: `LABELS_HEX_FILE` (default `"arch/golden_model/labels.hex"`).
- Internal structure: `reg [7:0] rom [0:99]`, registered read (small enough to also map to
  distributed RAM on Xilinx — either mapping satisfies REQ-036, which only requires "cleanly
  synthesizable").
- Latency/Throughput: 1 cycle / 1 read per image (read once per image, held for the whole image).
- Timing budget: negligible; not on any critical path.

#### BLK-008 : fm_ram
- Purpose: single feature-map RAM instance storing every inter-layer activation (conv1 output,
  pool1 output, conv2 output, pool2 output, FC1 output) across two ping-pong regions, per the
  address map and hazard-free reuse proof in §7 (REQ-023).
- Parent: BLK-001 / Clock: clk_core / Reset: rst_n / Source: custom
- Traces: REQ-006, REQ-007, REQ-009, REQ-012, REQ-023
- Ports: IFI-006 (`fmram_addr`, `fmram_wdata`, `fmram_we` in; `fmram_rdata` out).
- Parameters: none (depth/width fixed by §7's address map: 7,840 x 16-bit signed).
- Internal structure: `reg signed [15:0] ram [0:7839]`, single R/W port: `if (fmram_we)
  ram[fmram_addr] <= fmram_wdata; fmram_rdata <= ram[fmram_addr];` (one operation — read OR write —
  per cycle; `ctrl_fsm`'s phase sequencing, §6, never issues both to the same instance in the same
  cycle).
- Latency: 1 cycle read latency; write takes effect the following cycle (standard synchronous RAM).
- Throughput: 1 access/cycle.
- Reset behaviour: no reset needed for RAM contents (every region is fully written by its producer
  layer before any consumer layer reads it, every single image pass — §7's hazard proof); output
  register `fmram_rdata` resets to 16'sd0.
- Error handling: none (address always in `[0,7839]` by construction, §7).
- Timing budget: distributed RAM/BRAM access, ~2 ns (depth qualifies for either mapping on Xilinx).

#### BLK-009 : uart_tx (reused verbatim from v1)
- Purpose: standard 115200 8N1 UART transmitter, one byte at a time, parameterized `CLK_DIV`.
- Parent: BLK-001 / Clock: clk_core / Reset: rst_n / Source: reuse, `mnist_npu/rtl/uart_tx.v`
  copied byte-for-byte unchanged.
- Traces: REQ-031, REQ-033
- Ports: IFI-007 (`utx_data`, `utx_valid` in; `utx_ready`, `utx_busy` out; plus the raw `uart_tx`
  output pin, wired straight to `cnn_npu`'s `uart_tx` port) — identical to v1.
- Parameters: `CLK_DIV` (default 868 = round(100,000,000/115,200); simulation override e.g. 4).
- Internal structure: FSM-006 (§6.6, 4 states: IDLE/START/DATA/STOP, unchanged from v1's FSM-003),
  `baud_cnt` counter, 8-bit `shift_r` (LSB-first shift-out), 3-bit `bit_cnt`.
- Latency: a full frame takes `10*CLK_DIV` cycles. Throughput: 1 byte every 10*CLK_DIV cycles.
- Reset behaviour: `state <= ST_UTX_IDLE`, `uart_tx <= 1'b1` (idle-high, REQ-033/REQ-030).
- Error handling: none. Timing budget: simple shift-register logic, ~2 ns.

#### BLK-010 : led_ctrl (reused verbatim from v1, integration parameter changed)
- Purpose: derives `led[11:0]` from `ctrl_fsm`'s presented result and busy/blink status.
- Parent: BLK-001 / Clock: clk_core / Reset: rst_n / Source: reuse, `mnist_npu/rtl/led_ctrl.v`
  copied byte-for-byte unchanged.
- Traces: REQ-026, REQ-027, REQ-028, REQ-029, REQ-030
- Ports: IFI-008 (`lc_pred`, `lc_verdict`, `lc_present`, `lc_busy` in) plus the raw `led[11:0]`
  output, wired straight to `cnn_npu` — identical to v1.
- Parameters: `BLINK_CYCLES` — **the file's own internal default is 5,000,000 (unchanged, since
  the file is copied verbatim), but `cnn_npu` MUST instantiate this module with an explicit
  parameter override `#(.BLINK_CYCLES(BLINK_CYCLES))` where `cnn_npu`'s own top-level
  `BLINK_CYCLES` parameter defaults to 100,000 (REQ-026).** This is the one binding integration
  rule that makes verbatim file reuse and the v2 default-value fix compatible; `fe-rtl` MUST NOT
  edit `led_ctrl.v` to change its internal default.
- Internal structure: unchanged from v1 (`led_r`/`blink_cnt`/`blink_toggle_r`, one-hot mux, reset
  override forcing `led==12'd0` during `rst_n==0`).
- Latency/Reset/Error/Timing: unchanged from v1 (led_ctrl.v BLK-010 description).

#### BLK-011 : uart_line_fmt (reused verbatim from v1)
- Purpose: composes the exact ASCII line (REQ-032) for the current result and streams it, one byte
  at a time, to `uart_tx` via the IFI-007 handshake.
- Parent: BLK-001 / Clock: clk_core / Reset: rst_n / Source: reuse, `mnist_npu/rtl/uart_line_fmt.v`
  copied byte-for-byte unchanged — the format strings are identical to v1 (REQ-032), so zero
  content changes are needed.
- Traces: REQ-031, REQ-032
- Ports: IFI-009 (`lf_start`, `lf_pred[3:0]`, `lf_conf[6:0]`, `lf_exp[3:0]`, `lf_idx[6:0]`,
  `lf_verdict[1:0]` in; `lf_done` out), IFI-007 (source side) — identical to v1.
- Parameters: `MAX_LINE_LEN` (default 80; longest actual line is 69 bytes, unchanged from v1 since
  the line format is byte-identical).
- Internal structure: FSM-005 (§6.5[a], 3 states: IDLE/COMPOSE/SEND, unchanged from v1's FSM-002).
- Latency/Reset/Error/Timing: unchanged from v1 (uart_line_fmt.v BLK-011 description).

#### BLK-012 : win_addr_gen
- Purpose: purely combinational window-address generator. From `ctrl_fsm`'s current loop counters
  and a `layer_sel` input, computes every ROM/RAM address needed this cycle (image_rom, weight_rom,
  fm_ram read, fm_ram write) plus the zero-padding `tap_valid` flag for 3x3 conv taps.
- Parent: BLK-001 / Clock: clk_core (combinational only, no registers) / Reset: n/a / Source: custom
- Traces: REQ-004, REQ-006, REQ-007, REQ-008, REQ-009, REQ-012, REQ-013, REQ-023
- Ports: IFI-010 (`layer_sel[2:0]`, `u_cnt[4:0]`, `y_cnt[4:0]`, `x_cnt[4:0]`, `ic_cnt[3:0]`,
  `iy_cnt[1:0]`, `ix_cnt[1:0]`, `i_cnt[9:0]`, `img_idx[6:0]` in; `irom_addr[16:0]`,
  `wrom_addr[14:0]`, `fmram_rd_addr[12:0]`, `fmram_wr_addr[12:0]`, `tap_valid` out).
- Parameters: none (all formulas are fixed constants from the golden layout, spec.md §3/§7 below).
- Internal structure: one `case (layer_sel)` block of purely combinational `assign`-style formulas
  (§7 gives every formula per layer). No FSM, no registers, no latch risk (every output assigned in
  every branch, `default` branch ties all outputs to 0).
- Latency: 0 cycles (combinational); the address is valid at the moment `ctrl_fsm` presents its
  counters, ready to register into the ROM/RAM's own address input on the same edge `ctrl_fsm`
  advances to the next ADDR phase.
- Throughput: 1 address set/cycle (every cycle the outer state is CONV1/POOL1/CONV2/POOL2/FC1/FC2).
- Reset behaviour: none needed (no state).
- Error handling: none (every counter is range-bounded by `ctrl_fsm`'s own loop structure, so every
  computed address is provably in-range for its target memory — §7).
- Timing budget: small combinational adder/comparator tree, ~1.5 ns.

## 5. Datapath Definition

All arithmetic mirrors `arch/golden_model/golden_ref_model.c` node-for-node (bit-exact contract,
REQ-002). Widths at every node:

| Node | Width | Signed? | Notes |
|---|---|---|---|
| pixel byte (image_rom data) | 8 | unsigned | REQ-003: value 0..255 |
| `mac_a` (widened pixel, conv1) | 16 | treated as signed, always >=0 | `{8'h00, pixel}`, or `16'sd0` when `tap_valid_r`==0 (zero-pad) |
| feature-map word (fm_ram data) | 16 | signed | REQ-006: conv outputs, range 0..32767 after ReLU (MSB always 0) |
| `mac_a` (widened fm_ram read, conv2/FC1/FC2) | 16 | signed, always >=0 | fm_ram data directly, or `16'sd0` when `tap_valid_r`==0 |
| weight word (weight_rom data) | 16 | **signed** | Q8.8, range -32768..32767 |
| `mac_b` | 16 | signed | = weight word, always |
| `product` (multiplier out) | 32 | signed | `$signed(mac_a) * $signed(mac_b)`, REQ-018 |
| bias word (weight_rom data, at bias addresses) | 16 | signed | Q8.8 |
| bias, Q16.16-aligned into 64 bits | 64 | signed | `{{40{bias[15]}}, bias, 8'b0}` — REQ-004/008/010/011 |
| `acc` (accumulator register) | 64 | signed | REQ-017 (>=41-bit bound proven below; 64-bit used, bit-exact to golden's int64_t) |
| `acc >>> 8` (pre-saturate) | 64 (effective magnitude <=40 bits worst case) | signed | arithmetic right shift |
| `mac_z` (post-saturate) | 16 | signed | clamp to [-32768,32767] — REQ-005 |
| `mac_h` (post-ReLU, conv path only) | 16 | signed, always >=0 | `mac_z[15] ? 0 : mac_z` — REQ-006 |
| `lut_addr` (FC path only) | 16 | unsigned index (= `mac_z`'s raw bit pattern) | REQ-022 |
| `lut_data` / sigma (FC path only) | 8 | unsigned | range 1..255 |
| `best_val` (FC2 argmax) | 8 | unsigned | argmax running max |
| `best_idx` / `pred` | 4 | unsigned | 0..9, REQ-014 |
| `confidence` | 7 | unsigned | 0..100, `(best_val*100)>>8` — REQ-015 |
| `verdict` | 2 | unsigned | 0/1/2 — REQ-016 |

### REQ-017 accumulator overflow margin proof

Worst-case magnitude, per layer, excluding bias (weight magnitude bound 32768, per-layer max
activation magnitude and tap count from spec.md REQ-004/008/010/011):

| Layer | Activation max | Taps | Worst-case |SUM|  |
|---|---|---|---|
| conv1 | 255 (pixel) | 9 | 9 x 255 x 32768 = 75,202,560 |
| conv2 | 32767 (post-ReLU fm word) | 72 | 72 x 32767 x 32768 = 77,307,052,032 |
| FC1 | 32767 (post-ReLU fm word) | 784 | 784 x 32767 x 32768 = 841,787,899,904 |
| FC2 | 255 (sigma) | 32 | 32 x 255 x 32768 = 267,386,880 |

FC1 dominates: worst-case `|acc|` <= 841,787,899,904 + (32767<<8) = 841,787,899,904 + 8,388,352 =
**841,796,288,256** (~2^39.6). A signed accumulator needs `ceil(log2(841,796,288,256))+1` = 41 bits
to represent this bound without overflow — the design uses a full **64-bit** signed accumulator
(bit-exact match to the golden model's `int64_t acc`, `golden_ref_model.c` line ~110), which is
provably sufficient with roughly 2^24 x headroom over the 41-bit bound, chosen over a
tighter-but-still-safe 48-bit implementation specifically so the RTL accumulator is bit-exact to
the golden's own type width, not merely bounded — eliminating any residual risk that a narrower
width silently changes rounding/shift behaviour at the margin. No accumulator saturation logic
exists anywhere: `acc` is proven to never approach its 64-bit bound. The only saturation in the
datapath is the explicit `mac_z` clamp (REQ-005), which is specified golden-model behaviour, not
an overflow bug.

No pipelining is used anywhere (every node above is either combinational-within-a-cycle or a
single register stage) — the design's cycle budget (§6.5) is set by the sheer MAC step count
(hundreds of thousands per image), not by achievable clock frequency; a 16x16 multiply + 64-bit add
comfortably closes timing on Artix-7 at 100 MHz (§15).

## 6. Control FSMs

### 6.0 Shared `ctrl_fsm` registers

`state[2:0]` (outer, FSM-001), `phase[2:0]` (inner, reused meaning per outer state — FSM-002/003/
004), `img_idx[6:0]` (0..99), `u_cnt[4:0]` (output unit/channel index: oc for conv/pool, j for FC1,
c for FC2 — max range 0..31), `y_cnt[4:0]` (output row oy, conv/pool only), `x_cnt[4:0]` (output
col ox, conv/pool only), `ic_cnt[3:0]` (input channel, conv2 only, 0..7), `iy_cnt[1:0]`/`ix_cnt[1:0]`
(conv tap position, 0..2), `i_cnt[9:0]` (FC input index, 0..783 for FC1 / 0..31 for FC2 — reused in
place of ic/iy/ix since FC has no spatial structure), `tap_valid_r` (registered zero-pad flag from
`win_addr_gen`, aligned to the ADDR->ACC 1-cycle ROM latency), `best_val[7:0]`, `best_idx[3:0]`
(FC2 argmax), `confidence[6:0]`, `verdict[1:0]`, `hold_cnt[31:0]`.

`layer_sel[2:0]` (combinational function of `state`, wired to `win_addr_gen`): `CONV1=0, POOL1=1,
CONV2=2, POOL2=3, FC1=4, FC2=5`.

### 6.1 FSM-001 : ctrl_fsm outer state (binary encoding, 3-bit state, reset state = ST_CONV1)

| State | Condition | Next state | Registered actions this cycle |
|---|---|---|---|
| ST_CONV1 | mac_phase not done | ST_CONV1 | run FSM-002 (mac_phase) with tap count 9, loop bounds u_cnt<8,y_cnt<28,x_cnt<28 |
| ST_CONV1 | mac_phase done, loop not exhausted (u_cnt/y_cnt/x_cnt not all at max) | ST_CONV1 | advance outer loop counters (x_cnt, then y_cnt, then u_cnt), restart mac_phase |
| ST_CONV1 | mac_phase done, loop exhausted (u_cnt==7,y_cnt==27,x_cnt==27 unit just finished) | ST_POOL1 | reset u_cnt/y_cnt/x_cnt<=0; restart pool_phase |
| ST_POOL1 | pool_phase not done | ST_POOL1 | run FSM-003 (pool_phase), loop bounds u_cnt<8,y_cnt<14,x_cnt<14 |
| ST_POOL1 | pool_phase done, loop not exhausted | ST_POOL1 | advance outer loop counters, restart pool_phase |
| ST_POOL1 | pool_phase done, loop exhausted (u_cnt==7,y_cnt==13,x_cnt==13) | ST_CONV2 | reset u_cnt/y_cnt/x_cnt/ic_cnt<=0; restart mac_phase |
| ST_CONV2 | mac_phase not done | ST_CONV2 | run FSM-002, tap count 72 (ic_cnt 0..7 x iy_cnt/ix_cnt 0..2), loop bounds u_cnt<16,y_cnt<14,x_cnt<14 |
| ST_CONV2 | mac_phase done, loop not exhausted | ST_CONV2 | advance outer loop counters, restart mac_phase |
| ST_CONV2 | mac_phase done, loop exhausted (u_cnt==15,y_cnt==13,x_cnt==13) | ST_POOL2 | reset u_cnt/y_cnt/x_cnt<=0; restart pool_phase |
| ST_POOL2 | pool_phase not done | ST_POOL2 | run FSM-003, loop bounds u_cnt<16,y_cnt<7,x_cnt<7 |
| ST_POOL2 | pool_phase done, loop not exhausted | ST_POOL2 | advance outer loop counters, restart pool_phase |
| ST_POOL2 | pool_phase done, loop exhausted (u_cnt==15,y_cnt==6,x_cnt==6) | ST_FC1 | reset u_cnt/i_cnt<=0; restart mac_phase |
| ST_FC1 | mac_phase not done | ST_FC1 | run FSM-002, tap count 784 (i_cnt 0..783), loop bound u_cnt<32 |
| ST_FC1 | mac_phase done, loop not exhausted (u_cnt<31) | ST_FC1 | u_cnt<=u_cnt+1; i_cnt<=0; restart mac_phase |
| ST_FC1 | mac_phase done, loop exhausted (u_cnt==31) | ST_FC2 | reset u_cnt/i_cnt<=0; best_val/best_idx<=0; restart mac_phase |
| ST_FC2 | mac_phase not done | ST_FC2 | run FSM-002, tap count 32 (i_cnt 0..31), loop bound u_cnt<10 |
| ST_FC2 | mac_phase done, loop not exhausted (u_cnt<9) | ST_FC2 | argmax update (§6.4); u_cnt<=u_cnt+1; i_cnt<=0; restart mac_phase |
| ST_FC2 | mac_phase done, loop exhausted (u_cnt==9) | ST_PRESENT | argmax update (§6.4); restart present_phase |
| ST_PRESENT | present_phase not done | ST_PRESENT | run FSM-004 |
| ST_PRESENT | present_phase done | ST_HOLD | `hold_cnt<=0` |
| ST_HOLD | `hold_cnt != HOLD_CYCLES-1` | ST_HOLD | `hold_cnt<=hold_cnt+1` |
| ST_HOLD | `hold_cnt == HOLD_CYCLES-1` | ST_CONV1 | `img_idx <= (img_idx==99) ? 0 : img_idx+1`; reset all loop counters<=0 |
| (any other state value) | `default:` | ST_CONV1 | illegal-state recovery (REQ-035); all counters reset |

"Loop not exhausted" advances the innermost-to-outermost counter in this fixed order for
conv/pool states: `x_cnt` first (wrap to 0, carry into `y_cnt`), then `y_cnt` (wrap to 0, carry
into `u_cnt`/`ic_cnt` as applicable per phase — conv taps carry `ix_cnt`->`iy_cnt`->`ic_cnt`
*inside* `mac_phase`, not here); for FC states, only `u_cnt` advances at this level (`i_cnt` is
entirely internal to `mac_phase`).

### 6.2 FSM-002 : `mac_phase` (shared by CONV1/CONV2/FC1/FC2; binary encoding, 3-bit, reset =
PH_BIAS_ADDR)

Parameterised per outer state by `tap_count` (9 / 72 / 784 / 32) and whether the tap index is
(ic_cnt,iy_cnt,ix_cnt) [conv] or i_cnt [FC]. `done` output pulses for exactly the cycle `ctrl_fsm`
should treat the unit as complete (§6.1 reads it as "mac_phase done").

| Phase | Condition | Next phase | Action |
|---|---|---|---|
| PH_BIAS_ADDR | (always) | PH_BIAS_ACC | present `wrom_addr` = this unit's bias address (`win_addr_gen`, `layer_sel`-dependent) |
| PH_BIAS_ACC | (always) | PH_TAP_ADDR | `mac_bias_ld<=1; mac_bias<=wrom_data`; reset tap index (ic_cnt/iy_cnt/ix_cnt or i_cnt) <=0 |
| PH_TAP_ADDR | (always) | PH_TAP_ACC | present `irom_addr`/`fmram_rd_addr` (activation) and `wrom_addr` (weight) for the current tap; latch `tap_valid_r <= win_addr_gen.tap_valid` |
| PH_TAP_ACC | tap index != last tap | PH_TAP_ADDR | `mac_acc_en<=1; mac_a<=tap_valid_r?act_data:0; mac_b<=wrom_data`; advance tap index (ix_cnt->iy_cnt->ic_cnt for conv, i_cnt for FC) |
| PH_TAP_ACC | tap index == last tap (`tap_count`-1) | PH_ACT | last accumulate for this unit issued |
| PH_ACT | (always) | PH_WB | conv states (CONV1/CONV2): `fmram_wdata <= mac_h`; FC states (FC1/FC2): `lut_addr <= mac_z` (1-cycle sigmoid_lut latency begins) |
| PH_WB | conv states: (always) | PH_BIAS_ADDR, `done<=1` | `fmram_we<=1; fmram_addr<=` this unit's write address (`win_addr_gen`) |
| PH_WB | FC states: (always) | PH_BIAS_ADDR, `done<=1` | FC1: `fmram_we<=1; fmram_addr<=u_cnt; fmram_wdata<={8'd0,lut_data}`. FC2: no RAM write — `lut_data` feeds the §6.4 argmax combinational update directly |
| (any other) | `default:` | PH_BIAS_ADDR | illegal-state recovery |

### 6.3 FSM-003 : `pool_phase` (shared by POOL1/POOL2; binary encoding, 3-bit, reset = PH_READ0)

| Phase | Condition | Next phase | Action |
|---|---|---|---|
| PH_READ0 | (always) | PH_READ1 | present `fmram_addr` for source (2y,2x); latch `pool_max<=fmram_rdata` next phase |
| PH_READ1 | (always) | PH_READ2 | `pool_max<=fmram_rdata` (from READ0's address); present `fmram_addr` for (2y,2x+1) |
| PH_READ2 | (always) | PH_READ3 | `pool_max<=(fmram_rdata>pool_max)?fmram_rdata:pool_max` (from READ1); present `fmram_addr` for (2y+1,2x) |
| PH_READ3 | (always) | PH_CMP | `pool_max<=(fmram_rdata>pool_max)?fmram_rdata:pool_max` (from READ2); present `fmram_addr` for (2y+1,2x+1) |
| PH_CMP | (always) | PH_WB | `pool_max<=(fmram_rdata>pool_max)?fmram_rdata:pool_max` (from READ3, final compare) |
| PH_WB | (always) | PH_READ0, `done<=1` | `fmram_we<=1; fmram_addr<=` this unit's write address; `fmram_wdata<=pool_max` |
| (any other) | `default:` | PH_READ0 | illegal-state recovery |

### 6.4 FC2 argmax update (combinational, evaluated on the `mac_phase done` cycle inside ST_FC2)

`if (u_cnt==0 || lut_data>best_val) begin best_val<=lut_data; best_idx<=u_cnt; end` — matches
`golden_ref_model.c`'s `if (out[i] > out[best]) best = i;` exactly (lowest-index tie-break, REQ-014,
since `u_cnt` only overwrites `best_idx` on a **strict** `>`).

### 6.5 FSM-004 : `present_phase` (binary encoding, 2-bit, reset = PH_RESULT)

| Phase | Condition | Next phase | Action |
|---|---|---|---|
| PH_RESULT | (always) | PH_WAIT_UART | `confidence<=(best_val*100)>>8`; `verdict<=(confidence<50)?2:((best_idx==lrom_data)?0:1)`; `lc_pred<=best_idx; lc_verdict<=verdict; lc_present<=1`; `lf_start<=1` (with `lf_pred/lf_conf/lf_exp/lf_idx/lf_verdict` latched from the same values, `lrom_data`=`label_rom` read at `img_idx`, latched at PRESENT entry) |
| PH_WAIT_UART | `!lf_done` | PH_WAIT_UART | `lc_busy<=1` (blink continues through UART transmission, identical rationale to v1's REQ-019 clarification) |
| PH_WAIT_UART | `lf_done` | PH_RESULT, `done<=1` | `lc_busy<=0` (busy window ends here, exits to ST_HOLD) |
| (any other) | `default:` | PH_RESULT | illegal-state recovery |

**Sim-speed / UART-truncation interaction (binding on fe-rtl, identical rationale to v1):**
`ST_PRESENT` waits for `lf_done` before `ST_HOLD` begins counting `HOLD_CYCLES`, guaranteeing the
UART byte stream is never truncated regardless of how small `HOLD_CYCLES` is set in simulation.

### 6.6 FSM-005 : `uart_line_fmt` (reused verbatim from v1, binary encoding, 2-bit, reset =
ST_LF_IDLE) — see `mnist_npu/rtl/uart_line_fmt.v` for the exact byte-generator logic (unchanged;
REQ-032's line format is byte-identical to v1).

| State | Condition | Next state | Action |
|---|---|---|---|
| ST_LF_IDLE | `!lf_start` | ST_LF_IDLE | idle |
| ST_LF_IDLE | `lf_start` | ST_LF_COMPOSE | latch `pred_r/conf_r/exp_r/idx_r/verdict_r` |
| ST_LF_COMPOSE | (always) | ST_LF_SEND | combinational field generator fills `line_buf`/`line_len`; `byte_idx<=0` |
| ST_LF_SEND | `!(byte_idx==line_len-1 && utx_ready)` | ST_LF_SEND | if `utx_ready`: send byte, `byte_idx<=byte_idx+1` |
| ST_LF_SEND | `byte_idx==line_len-1 && utx_ready` | ST_LF_IDLE | last byte accepted; `lf_done<=1` |
| (any other) | `default:` | ST_LF_IDLE | illegal-state recovery |

### 6.7 FSM-006 : `uart_tx` (reused verbatim from v1, binary encoding, 2-bit, reset = ST_UTX_IDLE)

| State | Condition | Next state | Action |
|---|---|---|---|
| ST_UTX_IDLE | `!utx_valid` | ST_UTX_IDLE | `uart_tx<=1; utx_ready<=1` |
| ST_UTX_IDLE | `utx_valid` | ST_UTX_START | latch `shift_r<=utx_data`; `utx_ready<=0` |
| ST_UTX_START | `!baud_tick` | ST_UTX_START | `uart_tx<=0` (start bit) |
| ST_UTX_START | `baud_tick` | ST_UTX_DATA | `bit_cnt<=0` |
| ST_UTX_DATA | `!(baud_tick && bit_cnt==7)` | ST_UTX_DATA | `uart_tx<=shift_r[bit_cnt]`; on tick, `bit_cnt<=bit_cnt+1` |
| ST_UTX_DATA | `baud_tick && bit_cnt==7` | ST_UTX_STOP | last data bit consumed |
| ST_UTX_STOP | `!baud_tick` | ST_UTX_STOP | `uart_tx<=1` (stop bit) |
| ST_UTX_STOP | `baud_tick` | ST_UTX_IDLE | `utx_ready<=1` |
| (any other) | `default:` | ST_UTX_IDLE | illegal-state recovery; `uart_tx<=1` |

## 6.8 Compute cycle-budget derivation (REQ-037)

Using the `(tap_count+1 bias)*2 phases + 2 (ACT+WB)` per-unit costing convention (identical
methodology to v1), unit counts from spec.md §1:

| Layer | Units | Taps/unit | Cycles/unit | Total cycles |
|---|---|---|---|---|
| CONV1 | 8x28x28=6272 | 9 | (9+1)x2+2=22 | 137,984 |
| POOL1 | 8x14x14=1568 | n/a (4 reads+cmp+wb=6 phases) | 6 | 9,408 |
| CONV2 | 16x14x14=3136 | 72 | (72+1)x2+2=148 | 464,128 |
| POOL2 | 16x7x7=784 | n/a | 6 | 4,704 |
| FC1 | 32 | 784 | (784+1)x2+2=1572 | 50,304 |
| FC2 | 10 | 32 | (32+1)x2+2=68 | 680 |

Compute total = 667,208 cycles/image. Plus PRESENT (worst-case 69-byte line x 10 x `CLK_DIV`
cycles) and HOLD (`HOLD_CYCLES`).

- **Default (real hardware, CLK_DIV=868, HOLD_CYCLES=50,000,000):** 667,208 + 598,920 (UART,
  worst case) + 50,000,000 = ~50,666,128 cycles/image (~507 ms at 100 MHz, ~2 images/s) —
  consistent with the "human visible" pacing intent, same order as v1.
- **Simulation (CLK_DIV=4, HOLD_CYCLES=8):** 667,208 + 2,760 (UART) + 8 = 669,976 cycles/image, x
  100 images = **~67.0M simulated cycles** for a full VP-TOP-002/008 soak. This is dominated by
  CONV2 (46.4M of the 67.0M total across 100 images) — an intrinsic consequence of a single shared
  MAC unit doing 3,136 output units x 72 taps sequentially; it is not reducible by any pacing
  parameter (`HOLD_CYCLES`/`BLINK_CYCLES`/`CLK_DIV` only affect UART/hold time, not MAC step count).
  At typical `iverilog`/`vvp` throughput for a design this size (single-digit to low-tens of
  millions of cycles/second), 67M cycles is estimated at **on the order of 10-30 seconds**
  wall-clock — this satisfies REQ-037's "complete in seconds" read as "CI-reasonable, not
  minutes/hours", and is recorded honestly here rather than claimed as sub-second; `fe-rtl`/later
  verification stages should re-confirm the actual wall-clock time on the target machine.

## 7. Memory Map and Register Definition

**None (register file).** No host-visible register file exists (REQ-024, spec.md §6). This
design's "memory map" is instead the set of six ROM/RAM instances and their address spaces:

| MEM-ID | Instance (BLK) | Depth | Width | Address meaning |
|---|---|---|---|---|
| MEM-001 | weight_rom (BLK-005) | 26,698 | 16 (signed) | per spec.md §3 region table: `0..71`=conv1_w, `72..79`=conv1_b, `80..1231`=conv2_w, `1232..1247`=conv2_b, `1248..26335`=fc1_w, `26336..26367`=fc1_b, `26368..26687`=fc2_w, `26688..26697`=fc2_b |
| MEM-002 | image_rom (BLK-006) | 78,400 | 8 (unsigned) | `img_idx*784 + py*28+px` |
| MEM-003 | label_rom (BLK-007) | 100 | 8 (unsigned) | `img_idx` |
| MEM-004 | fm_ram (BLK-008) | 7,840 | 16 (signed) | Region A `0..6271`, Region B `6272..7839` — full per-layer map below |
| MEM-005 | sigmoid_lut (BLK-004) | 65,536 | 8 (unsigned) | `z` (16-bit two's-complement bit pattern) |

### 7.1 `fm_ram` per-layer address map and hazard-free reuse proof (REQ-023)

Two fixed regions inside the single `fm_ram` instance: **Region A** (base 0, depth 6,272 = max of
conv1-out 6,272 / conv2-out 3,136 / FC1-out 32) and **Region B** (base 6,272, depth 1,568 = max of
pool1-out 1,568 / pool2-out 784).

| Step | Layer | Reads from | Writes to | Address formula (write) |
|---|---|---|---|---|
| 1 | CONV1 | image_rom (not fm_ram) | Region A | `oc*784 + oy*28 + ox` (0..6271) |
| 2 | POOL1 | Region A (h1) | Region B | read: `oc*784+(2oy+dy)*28+(2ox+dx)`, dy,dx in {0,1}; write: `6272 + oc*196+oy*14+ox` (0..1567 offset) |
| 3 | CONV2 | Region B (p1) | Region A | read: `6272 + ic*196+py*14+px`; write: `oc*196+oy*14+ox` (0..3135) |
| 4 | POOL2 | Region A (h2) | Region B | read: `oc*196+(2oy+dy)*14+(2ox+dx)`; write: `6272 + oc*49+oy*7+ox` (0..783 offset) |
| 5 | FC1 | Region B (p2, flattened) | Region A | read: `6272 + i` for `i` in 0..783 (== `oc*49+oy*7+ox`, matching REQ-012's flatten order exactly, since region B's own address IS `oc*49+oy*7+ox`); write: `u_cnt` (0..31) |
| 6 | FC2 | Region A (h3) | (registers only, `best_val`/`best_idx`) | read: `i_cnt` (0..31) |

**Hazard-free proof:** the outer FSM (§6.1) only transitions to the next layer's state after every
output unit of the current layer has completed its `PH_WB` (`done` pulses once per unit, and the
outer loop only advances to the next layer once `u_cnt`/`y_cnt`/`x_cnt` reach their final value —
i.e. the layer's very last unit has been written). Consequently: Region A's CONV1 contents (h1) are
fully consumed by POOL1 (which reads all of Region A before CONV1's *own* successor, CONV2, ever
writes Region A) before CONV2 overwrites Region A with h2; Region B's POOL1 contents (p1) are fully
consumed by CONV2 (which reads all of Region B before POOL2 writes Region B) before POOL2 overwrites
Region B with p2; Region A's CONV2 contents (h2) are fully consumed by POOL2 before FC1 overwrites
Region A with h3; Region B's POOL2 contents (p2) are fully consumed by FC1 before anything overwrites
Region B again (nothing does — FC1 is the last consumer of Region B for this image); Region A's FC1
contents (h3) are fully consumed by FC2, which does not write `fm_ram` at all. No write ever
precedes the last read of the data it would overwrite — REQ-023 satisfied by construction, not by
timing luck.

### 7.2 Memory initialisation mechanism (binding on fe-rtl)

Every ROM/RAM that needs pre-loaded content uses a synthesis-safe `initial $readmemh(<PARAM>,
<array>);` inside its own module, `<PARAM>` a `parameter` string defaulting to the path given
above, relative to the `cnn` project root. A shared header (`rtl/cnn_defs.vh`, modelled on v1's
`mnist_npu_defs.vh`) centralises the `` `define `` defaults: `CNN_WEIGHTS_HEX`
("arch/golden_model/weights.hex"), `CNN_IMAGES_HEX` ("arch/golden_model/images.hex"),
`CNN_LABELS_HEX` ("arch/golden_model/labels.hex"), `CNN_SIGMOID_LUT_HEX` ("rtl/sigmoid_lut.hex" —
same file v1 generated, reused unchanged, REQ-022). **FPGA note for a later stage:** identical
caveat to v1 — this project only guarantees the `$readmemh` mechanism works under `iverilog` from
the project root; Vivado BRAM-init conversion is deferred to the (out-of-scope) FPGA bring-up
stage.

Reserved-bit / access-type columns are N/A (no registers exist).

## 8. Internal Interfaces (IFI-###)

See `interface_defs.yaml` for the full signal-level definitions of IFI-001..IFI-010. All ten are
`type: status` (unconditional, no backpressure — `ctrl_fsm` always drives them at exactly the rate
its own FSM produces/consumes data) except **IFI-007** (`uart_tx_port`, `type: valid_ready`, the
one genuine handshake in the design, unchanged from v1) — `valid_may_depend_on_ready: false` /
`data_stable_while_stalled: true` semantics mean `uart_line_fmt` must hold `utx_data` stable and
must only pulse `utx_valid` when it has already observed `utx_ready` high.

## 9. Clock and Reset Architecture

One domain, `CD_CORE` (`clk`, 100 MHz nominal, CLK-001). One reset, `rst_n`, active-low, **fully
synchronous** (RST-001) — see `spec.md` §5 and `rtl_coding_guidelines.md` §3 for the exact,
mandatory `always @(posedge clk) if (!rst_n) ... else ...` template (no `negedge rst_n` anywhere).
No reset synchroniser exists or is needed (single domain). Minimum assert width: 2 cycles
(ASM-001). See `cdc_plan.md` for the (trivial, empty) CDC analysis.

## 10. IP Reuse Plan

| BLK-ID | Decision | Repo | Licence | Status | Adapter needed |
|---|---|---|---|---|---|
| BLK-004 (sigmoid_lut) | reuse | `mnist_npu/rtl/sigmoid_lut.v` (sibling in-repo, v1) | project-internal | verified | none — byte-for-byte copy |
| BLK-009 (uart_tx) | reuse | `mnist_npu/rtl/uart_tx.v` (sibling in-repo, v1) | project-internal | verified | none — byte-for-byte copy |
| BLK-010 (led_ctrl) | reuse | `mnist_npu/rtl/led_ctrl.v` (sibling in-repo, v1) | project-internal | verified | integration-level parameter override only (BLINK_CYCLES=100,000 at instantiation, §4 BLK-010) — file itself unmodified |
| BLK-011 (uart_line_fmt) | reuse | `mnist_npu/rtl/uart_line_fmt.v` (sibling in-repo, v1) | project-internal | verified | none — byte-for-byte copy |

`ctrl_fsm`, `mac_datapath`, `weight_rom`, `image_rom`, `label_rom`, `fm_ram`, `win_addr_gen` are all
fully custom, CNN-specific, per `spec/spec.md` §10 (no external reuse candidate for any of them).

## 11. Golden Model Description

**The golden model is pre-existing and FROZEN — this stage does not generate, regenerate, or
relocate it.** Per the task brief and `arch/golden_model/README.md`:
`arch/golden_model/golden_ref_model.c` (C99, integer-only, transaction-level: one call to
`forward()` per image) plus its committed hex vector files (`weights.hex`, `images.hex`,
`labels.hex`, `expected.hex`, `expected_outputs.txt`, `README.md`) already satisfy every requirement
`fe-arch`'s own §7.6 template would normally impose on a freshly authored model (fixed-width
integer arithmetic only, no float, no malloc, deterministic output, real expected values). This
fe-arch pass instead:

- **Validated it was reproducible:** `gcc -std=c99 -O2 -Wall -Wextra -o gm
  arch/golden_model/golden_ref_model.c && ./gm .` was re-run from the `cnn` project root during
  this architecture pass and reproduced the committed baseline exactly — 9635 correct / 146
  incorrect / 219 trash on the full 10,000-image MNIST test set = 96.35% accuracy, bit-identical to
  the committed `expected_outputs.txt` (`git status` clean after the run). The model was also
  independently cross-validated against a numpy integer emulation, 100/100 bit-identical on the
  first 100 images (`WORKLOG.md`, `tools/check_cnn.py`).
- **Derived the RTL algorithm directly from it** (§5/§6 above reproduce every arithmetic step of
  `forward()` node-for-node, including the exact bias-alignment, shift, saturation, ReLU, and
  sigmoid order).
- **Does not duplicate its vector files.** `arch/golden_model/images.hex` + `labels.hex` (stimulus)
  and `arch/golden_model/expected.hex` (expected) already exist at exactly the paths the RTL's own
  ROMs load from (REQ-019/020/021), already in `$readmemh`-loadable form. `arch_manifest.yaml`'s
  `golden_model:` section points at these existing paths with `source: frozen_preexisting` instead
  of re-declaring them, identical to v1's precedent.
- **Build/run instructions** (unchanged, not executed by this stage): `gcc -std=c99 -O2 -Wall
  -Wextra -o gm arch/golden_model/golden_ref_model.c && ./gm .` (run from the `cnn` project root)
  reproduces `arch/golden_model/{expected.hex,images.hex,labels.hex,expected_outputs.txt}` in place
  (all four are deterministic outputs of the same deterministic run — confirmed byte-identical to
  the committed copies above).

## 12. Verification Hooks

Pure-Verilog observation points for the later `fe-iverilog`/`fe-cocotb` stage (per
`spec/verification_plan.md`): `ctrl_fsm.state`/`ctrl_fsm.phase` (FSM coverage, VP-CTRL-001),
`mac_datapath.acc`/`mac_z`/`mac_h` (VP-MAC-001..003, VP-RELU-001, compare against a recomputation
from the same ROM/RAM reads), `win_addr_gen`'s address/`tap_valid` outputs every cycle
(VP-MEM-001/002), `sigmoid_lut` address/data pair (VP-LUT-001/002, exhaustive check done standalone
by `tools/check_lut.py`, reused from v1), `led_ctrl.led_r` and top-level `led[11:0]`
(VP-TOP-005/006, VP-LED-001..003), `uart_tx`'s `uart_tx` pin bit-by-bit (VP-TOP-004,
VP-UART-001/002), `fm_ram`'s read/write address+data every cycle (VP-POOL-001, VP-MEM-001), and
`ctrl_fsm.img_idx`/`hold_cnt` (VP-TOP-003/007). All plain hierarchical signal references from a
testbench — no DFT observability mux (none permitted).

## 13. Traceability: REQ -> BLK

| REQ-ID | BLK-ID(s) |
|---|---|
| REQ-001 | BLK-002 |
| REQ-002 | BLK-003 |
| REQ-003 | BLK-003, BLK-012 |
| REQ-004 | BLK-003, BLK-012 |
| REQ-005 | BLK-003 |
| REQ-006 | BLK-003, BLK-008 |
| REQ-007 | BLK-002, BLK-008, BLK-012 |
| REQ-008 | BLK-003, BLK-012 |
| REQ-009 | BLK-002, BLK-008, BLK-012 |
| REQ-010 | BLK-002, BLK-003, BLK-004 |
| REQ-011 | BLK-002, BLK-003, BLK-004 |
| REQ-012 | BLK-008, BLK-012 |
| REQ-013 | BLK-005 |
| REQ-014 | BLK-002 |
| REQ-015 | BLK-002 |
| REQ-016 | BLK-002 |
| REQ-017 | BLK-003 |
| REQ-018 | BLK-003 |
| REQ-019 | BLK-005 |
| REQ-020 | BLK-006 |
| REQ-021 | BLK-007 |
| REQ-022 | BLK-004 |
| REQ-023 | BLK-008 |
| REQ-024 | BLK-001 (all blocks, structurally) |
| REQ-025 | BLK-002, BLK-010 |
| REQ-026 | BLK-010 |
| REQ-027 | BLK-002, BLK-010 |
| REQ-028 | BLK-010 |
| REQ-029 | BLK-010 |
| REQ-030 | BLK-009, BLK-010 |
| REQ-031 | BLK-009, BLK-011 |
| REQ-032 | BLK-011 |
| REQ-033 | BLK-009 |
| REQ-034 | BLK-001 (all blocks, structurally) |
| REQ-035 | BLK-001 (all blocks, structurally) |
| REQ-036 | BLK-004, BLK-005, BLK-006, BLK-007, BLK-008 |
| REQ-037 | BLK-002 |

Every `must` requirement maps to >=1 block; every block traces to >=1 requirement (§4 "Traces"
lines). Zero orphans in either direction.

## 14. Assumptions and Open Issues

Carried forward unchanged from `spec/spec.md` §11/§12: ASM-001 (min reset assert = 2 cycles),
ASM-002 (100 MHz exact) — both acknowledged, neither affects bit-exactness. Zero open issues
(`OI-###`). One new architecture-local decision recorded here rather than as a new ASM-ID (an
unambiguous design choice, not an unconfirmed default): the `fm_ram` two-region ping-pong layout
(§7.1) and the `led_ctrl` verbatim-file-plus-integration-override pattern for `BLINK_CYCLES`
(§4 BLK-010).

## 15. Estimated Area and Timing Budget

Qualitative (no synthesis is run at this stage). Flop count dominated by: `ctrl_fsm` counters
(~60 bits of counters/registers — more than v1 due to the extra loop dimensions oy/ox/ic/iy/ix),
`mac_datapath` (80 bits: 64-bit acc + 16-bit mac_z, mac_h combinational), `fm_ram` (7,840 x 16 =
125,440 bits — will map to Xilinx BRAM, not flops, on a real FPGA target), `uart_line_fmt` (80x8 =
640 bits of `line_buf`, unchanged from v1), `led_ctrl`/`uart_tx` (small, <30 bits each). Gate
estimate: dominated by the 16x16 signed multiplier (a few hundred LUTs on Artix-7, or 1 DSP48 slice
if inferred — either is "cleanly synthesizable" per REQ-036) and `win_addr_gen`'s per-layer address
arithmetic (small adders/comparators, wider fan-in than v1's single formula due to the multi-layer
`case`). Critical path budget within the 10.000 ns period: `mac_datapath`'s multiply-accumulate
(~6.5 ns estimated: 16x16 multiply + 64-bit add, slightly larger than v1's 40-bit accumulator) is
the largest single combinational budget, leaving ~3.5 ns of margin at 100 MHz on a 7-series FPGA —
REQ-036 requires only "cleanly synthesizable," this margin note is retained for the FPGA bring-up
stage as a sanity check, not a promise.
