# cnn_soc — Microarchitecture Specification
Document ID: ARCH-CNN-SOC-v1.0 | Stage: fe-arch | Input: SPEC-CNN-SOC-v1.0 (commit 9b7b10e)
Technology: FPGA-generic (documented deviation — spec.md §2.1) | RTL: pure Verilog-2001 | DFT: none

## 1. Architecture Overview

`cnn_soc` is a single-clock-domain, single-master RISC-V SoC that drives the verified `cnn/` MNIST
CNN engine (bit-exact, 96.35%, `ROADMAP.md:21`) through a CPU boot flow. `picorv32_axi`
(`skill-tests/ex6/rtl/picorv32.v:2517`) — RV32I + built-in simplified AXI4-Lite master — executes
firmware from a 4 KB bootrom (baked, executes in place), copies one 784-byte image at a time from
a read-only `vec_rom` into a CPU-writable image buffer inside the CNN wrapper, starts exactly one
inference per `START` (reset-parking the free-running core), reads back
pred/confidence/verdict registers, prints the byte-exact golden UART line, and drives the LEDs.

The SoC is a flat hierarchy of eleven new modules (BLK-001..BLK-011) around eight reused blocks
(BLK-012..BLK-019): the CPU, the `uart_tx` UART transmitter, and the six verified CNN leaves
(`ctrl_fsm`, `mac_datapath`, `win_addr_gen`, `fm_ram`, `weight_rom`, `sigmoid_lut` — byte-for-byte
reuse, zero edits, REQ-022). The CNN datapath itself is **inherited, not re-architected**: its
microarchitecture (FSMs, address maps, Q8.8 arithmetic, ping-pong feature-map reuse) is specified
in `cnn/arch/arch.md` and referenced here; this document adds only the SoC wrapper layer around
it. The arch must not contradict `cnn/arch/arch.md` anywhere.

Three load-bearing mechanisms (from PLAN.md §1, frozen in spec):

1. **Simplified AXI4-Lite contract (PLAN.md R2).** The adapter (`picorv32.v:2731`) issues AW+W
   together (`picorv32.v:2773,2781`) and completes when `mem_ready = bvalid || rvalid`
   (`picorv32.v:2785`); no `BRESP`/`RRESP`/IDs exist. All slaves accept combinationally when idle
   and answer with 1-cycle response pulses; unmapped addresses still complete (read 0 / write
   ignored) — the CPU can never hang (REQ-005/006).
2. **Single-shot by reset-parking (PLAN.md §6.2).** `cnn_axi_slave` holds `cnn_infer`'s core in
   synchronous reset (parked) at SoC reset and re-parks it within 2 cycles of the `lc_present`
   strobe (`ctrl_fsm.v:198`, architecturally exactly 1 cycle, `cnn/arch/arch.md:427-434`), before
   `img_idx` can advance (`ctrl_fsm.v:463`). Every inference processes image index 0 exactly once
   per START (REQ-021).
3. **CPU owns UART/LED text (OQ4).** `uart_line_fmt`/`led_ctrl` are not instantiated; the CPU
   formats the identical golden bytes (REQ-024) and writes the 12-bit LED pattern to `GPIO_OUT`
   (REQ-026) using the `led_ctrl` encoding (`led_ctrl.v:66-78`).

## 2. Design Constraints Inherited from Specification

Restated from `spec/spec.md §2` (binding, carry forward unchanged):

| Constraint | Rule |
|---|---|
| Technology | **FPGA-generic** (`fpga_generic`), NOT Sky130 — explicit documented deviation (spec.md §2.1; cnn precedent `cnn/spec/spec.md §2.1`). No Sky130 cell names, no analog black boxes, no Sky130 DFT policy anywhere. |
| RTL language | **Pure Verilog-2001 (IEEE 1364-2001).** No SystemVerilog, no VHDL. |
| Analog | None. No black-box stubs needed. |
| DFT | **None.** No scan, BIST, JTAG/TAP, MBIST, compression. Debug = register-mapped + hierarchical TB probes only. |
| Reset | **Fully synchronous active-low `rst_n`** — deviation from the fe-arch skill default (async assert / sync de-assert); project precedent (cnn spec.md §5, `cnn/arch/arch.md:564-570`, ex6). Every flop: `always @(posedge clk) if (!rst_n) ... else ...`; **no** `negedge rst_n` anywhere (REQ-029). No reset synchroniser (single domain). |
| Clocking | One domain, `clk`, 100 MHz nominal / 10.000 ns (CLK-001, REQ-028). 0 CDC paths. |
| Memory-init | `$readmemh` for bootrom, vec_rom, weight_rom, sigmoid_lut (REQ-023, OQ7). v1 is CPU-path for program/image/label only. |
| Bus contract | Simplified AXI4-Lite per §1 mechanism 1; slave response timing pinned in §8 (IFI-003). |
| Firmware contract | Pure-ROM image (0 B `.data`, 0 B `.bss`), `.text+.rodata` ≤ 4 KB, executes in place from bootrom (REQ-003/004); SRAM = stack only, top `0x0003_0000` = `STACKADDR`. |
| Verification | G1–G5 gates are the contract (spec verification_plan.md §5). |

**Read-response timing interpretation (pinned here, binding on fe-rtl):** spec REQ-005 requires
`rvalid`+`rdata` "exactly 1 cycle after the read-accept cycle" and spec IF-003 bounds the read
response at ≤ 3 cycles after the accept cycle. With the spec-mandated **1-cycle registered read
latency** (REQ-008/009/010), the absolute timing is: accept cycle N (`arvalid && arready`),
address captured at edge N, memory access during cycle N+1 (the read-accept cycle — the cycle in
which the accepted address is read), response `rvalid`+`rdata` asserted for exactly 1 cycle at
cycle **N+2** (= 1 cycle after the memory-access cycle; within the ≤ 3 bound). Writes: accept
cycle N, `bvalid` asserted for exactly 1 cycle at cycle **N+1**. The AXI2APB bridge accepts only
during its APB ACCESS phase, so its responses are also exactly 1 cycle after *its* accept cycle
(read response total: request cycle N → accept at N+2 → `rvalid` at N+3; within the ≤ 3 bound).
Every slave keeps response data stable while its response pulse is high; slaves never wait for
`bready`/`rready` (the adapter holds `mem_valid` until it observes the pulse, `picorv32.v:2785`).

## 3. Hierarchy and Partitioning

| BLK-ID | Module | Parent | Clock | Reset | Source |
|---|---|---|---|---|---|
| BLK-001 | `cnn_soc` | (top) | clk | rst_n | custom |
| BLK-002 | `axi_lite_interconnect` | BLK-001 | clk | rst_n | custom |
| BLK-003 | `bootrom` | BLK-001 | clk | rst_n | custom |
| BLK-004 | `sram` | BLK-001 | clk | rst_n | custom |
| BLK-005 | `vec_rom` | BLK-001 | clk | rst_n | custom |
| BLK-006 | `axi2apb` | BLK-001 | clk | rst_n | custom |
| BLK-007 | `apb_uart` | BLK-001 | clk | rst_n | custom |
| BLK-008 | `apb_gpio` | BLK-001 | clk | rst_n | custom |
| BLK-009 | `cnn_axi_slave` | BLK-001 | clk | rst_n | custom |
| BLK-010 | `cnn_infer` | BLK-009 | clk | rst_n (core_rst_n from BLK-009) | custom |
| BLK-011 | `image_buffer` | BLK-010 | clk | rst_n | custom |
| BLK-012 | `picorv32_axi` (+ `picorv32`, `picorv32_axi_adapter`) | BLK-001 | clk | rst_n | ip: `skill-tests/ex6/rtl/picorv32.v` (ISC) |
| BLK-013 | `uart_tx` | BLK-007 | clk | rst_n | ip: `cnn/rtl/uart_tx.v` (project-internal) |
| BLK-014 | `ctrl_fsm` | BLK-010 | clk | rst_n | ip: `cnn/rtl/ctrl_fsm.v` (project-internal) |
| BLK-015 | `mac_datapath` | BLK-010 | clk | rst_n | ip: `cnn/rtl/mac_datapath.v` |
| BLK-016 | `win_addr_gen` | BLK-010 | clk | rst_n | ip: `cnn/rtl/win_addr_gen.v` |
| BLK-017 | `fm_ram` | BLK-010 | clk | rst_n | ip: `cnn/rtl/fm_ram.v` |
| BLK-018 | `weight_rom` | BLK-010 | clk | rst_n | ip: `cnn/rtl/weight_rom.v` |
| BLK-019 | `sigmoid_lut` | BLK-010 | clk | rst_n | ip: `cnn/rtl/sigmoid_lut.v` |

All blocks are in CD_CORE, all use the same fully-synchronous `rst_n` (BLK-010 receives the
sequencer-controlled `core_rst_n` = `rst_n` gated by the park mechanism — still fully synchronous,
still one domain). Every new module is 100–600 lines; the reused leaves are used verbatim. No
module exceeds ~4 responsibilities; the interconnect (decode+mux), the CNN slave (regs + accept +
sequencer), and cnn_infer (wiring only) are kept as separate blocks on the function axis.

**Filelist guidance for fe-rtl (binding):** the SoC filelist must include the eleven new
`cnn_soc/rtl/*.v` files, `cnn/rtl/{ctrl_fsm,mac_datapath,win_addr_gen,fm_ram,weight_rom,
sigmoid_lut,uart_tx}.v`, `cnn/rtl/cnn_defs.vh` + `cnn/rtl/mnist_npu_defs.vh` (via include path
`-I cnn/rtl` — the reused leaves `` `include "rtl/cnn_defs.vh" `` / `` `include
"rtl/mnist_npu_defs.vh" ``), and `skill-tests/ex6/rtl/picorv32.v`. `cnn/rtl/image_rom.v`,
`label_rom.v`, `uart_line_fmt.v`, `led_ctrl.v`, `cnn_npu.v` are **not** in the SoC filelist
(REQ-022: not instantiated).

## 4. Block Specifications

#### BLK-001 : cnn_soc
- Purpose: top-level integration; owns no state beyond wiring. Ports: `clk`, `rst_n`, `uart_tx`
  (output), `led[11:0]` (output) — exactly spec IF-001/IF-002/CLK-001/RST-001.
- Parent: (none) / Clock: clk / Reset: rst_n / Source: custom
- Traces: REQ-001, REQ-003, REQ-028, REQ-029, REQ-031, REQ-032 (+ SoC-level REQ-024/025/026/027
  via the firmware contract)
- Parameters (re-exported so the TB can override): `UART_CLK_DIV` (default 868, sim override e.g.
  4), `BOOT_HEX_FILE` (default `"sw/firmware.hex"`), `IMAGES_HEX_FILE` (default
  `"../cnn/arch/golden_model/images.hex"`), `LABELS_HEX_FILE` (default
  `"../cnn/arch/golden_model/labels.hex"`), `WEIGHTS_HEX_FILE` (default
  `"../cnn/arch/golden_model/weights.hex"`), `LUT_HEX_FILE` (default `"../cnn/rtl/sigmoid_lut.hex"`).
  Defaults are relative to the **cnn_soc project root**; the TB must run from there (PLAN.md R5;
  the cnn `define defaults `"arch/golden_model/…"` are correct for the cnn root only — the SoC
  must override them via these parameters, see §7.2).
- Internal structure: instantiates BLK-002..BLK-012; wires per block_diagram.mmd; ties
  `pcpi_wr=0, pcpi_rd=0, pcpi_wait=0, pcpi_ready=0`, `irq=32'd0`; leaves `eoi`, `trace_valid`,
  `trace_data`, `trap` unconnected at the top (TB observes `trap` hierarchically).
- Latency/Throughput: N/A (structural). Reset: passes `rst_n` through. Error handling: none of
  its own. Timing budget: N/A.

#### BLK-002 : axi_lite_interconnect
- Purpose: combinational decode (spec §3.1 rule) + forwarding + response mux + the unmapped
  responder. Single outstanding transaction (CPU is single-issue) → **no arbitration, no ID
  tracking** (PLAN.md §2).
- Parent: BLK-001 / Clock: clk / Reset: rst_n / Source: custom
- Traces: REQ-005, REQ-006, REQ-007, REQ-030
- Ports: IFI-003 master-side (from BLK-012) and five IFI-003 slave-side instances (boot_, sram_,
  vec_, apb_, cnn_ prefixes) + internal unmapped-responder.
- Internal structure: decode function §7.1 (combinational); one 5:1 + unmapped response mux per
  channel (awready/wready/arready/bvalid/rvalid/rdata); the unmapped responder is the FSM-002
  pattern with read data constant 0.
- Latency: 0 cycles (combinational forward); unmapped read response accept+2, write accept+1
  (same as memory slaves). Throughput: 1 transaction at a time (bus limit).
- Reset: all state = IDLE (unmapped responder). Error handling: unmapped → read 0 / write
  ignored / complete (REQ-006). Timing budget: mux tree ~1 ns.

#### BLK-003 : bootrom
- Purpose: 4 KB read-only boot memory at `0x0000_0000`, firmware baked via `$readmemh`
  (bootrom-bake, OQ2). Executes in place (instruction fetches are ordinary reads; `arprot` hint
  ignored).
- Parent: BLK-001 / Clock: clk / Reset: rst_n / Source: custom
- Traces: REQ-003, REQ-004, REQ-008
- Ports: IFI-003 slave (boot_ prefix). Parameters: `BOOT_HEX_FILE` (string).
- Internal structure: MEM-001 (`reg [7:0] rom [0:4095]`), registered read
  `rdata <= {rom[addr_r+3], rom[addr_r+2], rom[addr_r+1], rom[addr_r+0]}` (little-endian word,
  addr[1:0] ignored — the CPU extracts byte lanes, picorv32 native behaviour), FSM-002 pattern.
- Latency: read accept+2, write bvalid accept+1 (write ignored). Reset: read register 0, state
  IDLE. Error: writes ignored; out-of-range impossible (decode bounds addresses). Timing: ~1 ns.

#### BLK-004 : sram
- Purpose: 128 KB read/write data memory at `0x0001_0000` (`0x0001_0000..0x0002_FFFF`); v1 use =
  firmware stack (top `0x0003_0000`). Not reset-initialised — the v1 pure-ROM firmware never
  reads unwritten SRAM (REQ-004); documented, not a hazard.
- Parent: BLK-001 / Clock: clk / Reset: rst_n / Source: custom
- Traces: REQ-009, REQ-030
- Ports: IFI-003 slave (sram_ prefix). Parameters: none.
- Internal structure: MEM-002 (`reg [31:0] mem [0:32767]`, word index = `addr_r[16:2]` for reads,
  `addr[16:2]` for writes), byte-enable writes `if (wstrb[j]) mem[w][8j+:8] <= wdata[8j+:8]`,
  registered read, FSM-002 pattern.
- Latency: read accept+2, write accept+1. Reset: read register 0, state IDLE; contents undefined
  (stack-only use). Error: none (all addresses in range by decode). Timing: ~1 ns.

#### BLK-005 : vec_rom
- Purpose: read-only vector source at `0x1000_0000` (78,500 B): `images.hex` (78,400 B) at
  `+0x0000..+0x1323F`, `labels.hex` (100 B) at `+0x13240..+0x132A3`; the CPU's image/label source
  (OQ1). `$readmemh` from the frozen golden files (PLAN.md R5: path parameters).
- Parent: BLK-001 / Clock: clk / Reset: rst_n / Source: custom
- Traces: REQ-010
- Ports: IFI-003 slave (vec_ prefix). Parameters: `IMAGES_HEX_FILE`, `LABELS_HEX_FILE` (strings).
- Internal structure: MEM-003 (`reg [7:0] rom [0:78499]`), two `initial $readmemh` calls:
  `$readmemh(IMAGES_HEX_FILE, rom, 0, 78399)` and `$readmemh(LABELS_HEX_FILE, rom, 78400,
  78499)` (Verilog-2001 start/end arguments), word read `rdata <= {rom[addr_r+3], …}` (aligned
  word; label reads at `0x1001_3240+i` are within the array — word 19624 covers bytes
  78496..78499, the last label), FSM-002 pattern.
- Latency: read accept+2, write accept+1 (ignored). Reset: read register 0. Error: writes
  ignored; addresses range-bounded by decode. Timing: ~1 ns.

#### BLK-006 : axi2apb
- Purpose: convert one simplified-AXI transaction in window `0x4000_0000` into an APB access
  (PSEL/PENABLE/PWRITE/PADDR/PWDATA/PRDATA/PREADY); `PADDR[11:0]` selects UART (`+0x0000`) vs
  GPIO (`+0x1000`); other APB offsets → `PRDATA=0` with `PREADY` (REQ-011).
- Parent: BLK-001 / Clock: clk / Reset: rst_n / Source: custom
- Traces: REQ-005, REQ-011
- Ports: IFI-003 slave (apb_ prefix) + IFI-002 APB master.
- Internal structure: FSM-001 (4 states, §6.1). **Accept policy (pinned):** `awready`/`wready`/
  `arready` are asserted only during the APB ACCESS phase, so the response is always exactly 1
  cycle after the bridge's accept cycle; write data and address are stable from the adapter while
  `mem_valid` holds (single outstanding), so no buffering is needed (PLAN.md §7 "no buffering").
- Latency: write request→bvalid = 3 cycles (SETUP N+1, ACCESS accept N+2, bvalid N+3); read
  request→rvalid = 3 cycles. Throughput: 1 txn / 3 cycles. Reset: state IDLE.
- Error handling: unmapped APB offset → PREADY with PRDATA=0 (no PSLVERR — not in the APB subset,
  spec IF-004). Timing: ~1.5 ns.

#### BLK-007 : apb_uart
- Purpose: APB shell over the reused `uart_tx` (BLK-013): `UART_TX` write → 1-cycle `utx_valid`
  pulse with `PWDATA[7:0]`; `UART_STAT` read → `{31'b0, utx_busy}` (REQ-013/014).
- Parent: BLK-001 / Clock: clk / Reset: rst_n / Source: custom
- Traces: REQ-013, REQ-014
- Ports: IFI-002 APB slave (psel_uart, penable, pwrite, paddr, pwdata, prdata, pready) + IFI-005
  valid/ready to BLK-013; `uart_tx` pin output (via BLK-013) to top.
- Internal structure: no FSM — a registered 1-cycle write strobe: `if (wr_tx) utx_valid <= 1'b1;
  else utx_valid <= 1'b0;` with `utx_data <= pwdata[7:0]` on the same edge; read mux.
  `wr_tx = psel_uart && penable && pwrite && (paddr[3:0]==4'h0)`; `prdata = (paddr[3:0]==4'h4) ?
  {31'b0, utx_busy} : 32'd0`; `pready = 1'b1` (0-wait).
- Latency: write applied at the APB ACCESS edge; byte visible on `uart_tx` from the next frame
  start. Reset: `utx_valid=0`, `utx_data=0`; BLK-013 idles high (`uart_tx.v` reset).
- Error handling: **write-while-busy → byte dropped** (uart_tx samples `utx_valid` only in IDLE,
  `uart_tx.v:59`; REQ-014). Documented drop semantics — the shell is a fire-and-forget producer,
  deliberately NOT the hold-until-ready producer `uart_line_fmt` is. Timing: ~0.5 ns.

#### BLK-008 : apb_gpio
- Purpose: 12-bit RW `GPIO_OUT` register → top-level `led[11:0]` (REQ-015).
- Parent: BLK-001 / Clock: clk / Reset: rst_n / Source: custom
- Traces: REQ-015, REQ-026 (firmware encoding target)
- Ports: IFI-002 APB slave (psel_gpio, …), `led[11:0]` output to top.
- Internal structure: `reg [11:0] gpio_out`; any write (any wstrb) → `gpio_out <= pwdata[11:0]`;
  read → `{20'b0, gpio_out}`; `led = gpio_out`; `pready = 1`. No FSM.
- Latency: 0 (registered at ACCESS edge). Reset: 0. Error: none. Timing: ~0.5 ns.

#### BLK-009 : cnn_axi_slave
- Purpose: MMIO shell + single-shot sequencer around `cnn_infer` (PLAN.md §6.2): registers
  `CNN_CTRL/STATUS/RESULT/EXP` (§7.3), 784-byte image-buffer write path, start/done handshake,
  PARK abort, result latch on `lc_present`.
- Parent: BLK-001 / Clock: clk / Reset: rst_n / Source: custom
- Traces: REQ-012, REQ-016, REQ-017, REQ-018, REQ-019, REQ-020, REQ-021, REQ-030
- Ports: IFI-003 slave (cnn_ prefix) + IFI-001 to BLK-010.
- Internal structure: FSM-002 accept pattern (register reads accept+2), FSM-003 sequencer (§6.3),
  register file (7 registers, §7.3), image-buffer write decode (`awaddr[11:0]` in
  `[0x100,0x40F]` → buffer byte offset `awaddr[11:0]-10'd256`; per-lane writes from `wdata`/
  `wstrb`, REQ-020), result latch `result_r <= {14'b0, verdict, 1'b0, conf, 4'b0, pred}` on the
  `present` edge.
- Latency: register read accept+2; register write applied at accept edge; `BUSY` window per
  REQ-021 (≤ 667,500 cycles). Reset: all registers 0, FSM-003 = ST_PARK, core parked.
- Error handling: START-while-BUSY / START-while-PARK ignored; PARK write = abort (core held in
  reset, BUSY/DONE cleared, partial results discarded); non-implemented offsets in the window
  read 0 / write ignored (complete). Timing: ~1 ns.

#### BLK-010 : cnn_infer
- Purpose: the rebuilt inference top — the verified leaves with the exact wiring of
  `cnn_npu.v:99-233`, minus the I/O skin (REQ-022). **Zero edits to BLK-014..BLK-019.**
- Parent: BLK-009 / Clock: clk / Reset: rst_n (= `core_rst_n` from BLK-009, the park mechanism)
  / Source: custom
- Traces: REQ-018, REQ-019, REQ-020, REQ-021, REQ-022, REQ-023, REQ-031
- Ports: IFI-001 (see interface_defs.yaml): `exp_label[3:0]` in, `img_waddr[9:0]`/`img_wdata[7:0]`/
  `img_we` in, `pred[3:0]`/`conf[6:0]`/`verdict[1:0]`/`busy`/`present` out.
- Internal structure (exact instance list, from `cnn_npu.v:99-233`):
  - `weight_rom` (BLK-018, `cnn_npu.v:99`): `.addr(wrom_addr), .rdata(wrom_data)`,
    `WEIGHTS_HEX_FILE` parameter.
  - `sigmoid_lut` (BLK-019, `cnn_npu.v:135`): `.addr(mac_z[15:0])` — structural, bypasses
    ctrl_fsm (`cnn_npu.v:140`, REQ-022) — `.rdata(lut_data)`, `LUT_HEX_FILE` parameter.
  - `mac_datapath` (BLK-015, `cnn_npu.v:144`): full IFI set.
  - `win_addr_gen` (BLK-016, `cnn_npu.v:156`): full IFI set.
  - `fm_ram` (BLK-017, `cnn_npu.v:126`): `.addr(fmram_addr), .wdata(fmram_wdata), .we(fmram_we),
    .rdata(fmram_rdata)`.
  - `ctrl_fsm` (BLK-014, `cnn_npu.v:175`): all ports per `cnn_npu.v:175-227` **except**:
    - `.lrom_data({4'd0, exp_label})` — replaces `label_rom` (REQ-019); `lrom_addr` output left
      open (nothing consumes it).
    - `.lf_done(1'b1)` — tied, so `PH_WAIT_UART` exits in 1 cycle (`ctrl_fsm.v:449-455`); the
      single-shot sequencer parks the core before ST_HOLD can matter.
    - `.lf_start`, `.lf_exp`, `.lf_idx` outputs left open (no `uart_line_fmt`).
    - Result exposure: `pred = lf_pred`, `conf = lf_conf`, `verdict = lf_verdict`
      (`ctrl_fsm.v:189-193`), `busy = lc_busy` (`ctrl_fsm.v:187`), `present = lc_present`
      (`ctrl_fsm.v:198`).
  - `image_buffer` (BLK-011): core read `.addr(irom_addr[9:0]), .rdata(irom_data)` — with
    `img_idx=0` the image address is the in-image offset 0..783 (`cnn/arch/arch.md:506`); CPU
    write `.waddr(img_waddr), .wdata(img_wdata), .we(img_we)`.
  - `HOLD_CYCLES`/`BLINK_CYCLES`/`CLK_DIV`/`MAX_LINE_LEN`: not re-exported; core defaults stand
    (park precedes HOLD — the free-runner never reaches its hold/advance path).
- Latency: 1 inference = 667,208 compute cycles (`cnn/arch/arch.md:481`) + 2 PRESENT cycles
  (PH_RESULT + PH_WAIT_UART with `lf_done=1`). Throughput: 1 image per START + CPU overhead.
- Reset behaviour: park (`rst_n=0`) → ctrl_fsm `ST_CONV1`, `img_idx=0`, all counters 0
  (`ctrl_fsm.v:280-295`); ROM/RAM read outputs 0. Error handling: inherited (ctrl_fsm
  illegal-state recovery, cnn REQ-035). Timing: inherited; MAC path ~6.5 ns of 10 ns
  (`cnn/arch/arch.md §15`).

#### BLK-011 : image_buffer
- Purpose: 784×8 CPU-writable image buffer replacing `image_rom` (REQ-020). Core read port has
  the same 1-cycle registered read timing as `image_rom.v:25-29` so ctrl_fsm's ADDR→ACC timing is
  preserved (`cnn/arch/arch.md:401-402`).
- Parent: BLK-010 / Clock: clk / Reset: rst_n / Source: custom
- Traces: REQ-020, REQ-030
- Ports: `raddr[9:0]` in, `rdata[7:0]` out (registered), `waddr[9:0]`/`wdata[7:0]`/`we` in.
- Internal structure: MEM-004 (`reg [7:0] buf [0:783]`); `always @(posedge clk) begin if (we)
  buf[waddr] <= wdata; rdata <= buf[raddr]; end` — read-first on same-address collision
  (deterministic; CPU never reads the buffer and never writes while the core runs, so collisions
  are harmless by construction — while parked the core read address is held at 0 and its data is
  discarded).
- Latency: 1 cycle (registered read). Reset: `rdata <= 0`; contents uninitialised (written
  before each START by firmware). Error: none. Timing: ~0.5 ns.

#### BLK-012 : picorv32_axi (reused IP)
- Purpose: RV32I CPU + built-in simplified AXI4-Lite master (adapter `picorv32.v:2731`). Instantiated
  verbatim, one file (`picorv32.v` contains `picorv32_axi`, `picorv32`, `picorv32_axi_adapter`).
- Parent: BLK-001 / Clock: clk / Reset: rst_n → `resetn` / Source: ip (ISC, file header © 2015
  Claire Xenia Wolf)
- Traces: REQ-002, REQ-003, REQ-005, REQ-027
- Parameters (REQ-002, PLAN.md §5): `PROGADDR_RESET=32'h0000_0000` (default, `picorv32.v:2540`),
  `STACKADDR=32'h0003_0000` (default is `ffff_ffff`, `picorv32.v:2542` — must be overridden),
  `ENABLE_MUL=0`, `ENABLE_DIV=0`, `ENABLE_FAST_MUL=0`, `COMPRESSED_ISA=0`, `ENABLE_IRQ=0`,
  `ENABLE_COUNTERS=0`, `ENABLE_COUNTERS64=0`, `CATCH_MISALIGN=0`, `CATCH_ILLINSN=0`,
  `ENABLE_PCPI=0`; all others at file defaults. Ties: `pcpi_wr=0, pcpi_rd=0, pcpi_wait=0,
  pcpi_ready=0`, `irq=32'd0`; `eoi`/`trace_*`/`trap` open at top (TB probes `trap`).
- Latency: variable (single-issue). Reset: per file. Error: `trap` must never assert in a healthy
  run (CATCH_* = 0, trusted firmware). Timing: small core, comfortable at 100 MHz.

#### BLK-013 : uart_tx (reused IP)
- Purpose: 115200 8N1 transmitter (REQ-013). Verbatim `cnn/rtl/uart_tx.v`; parameter `CLK_DIV`
  driven from the top `UART_CLK_DIV` (default 868 = round(100e6/115200), `cnn/arch/arch.md:224`).
  Idles high (mark) between frames and during reset (`uart_tx.v` reset: `uart_tx <= 1'b1`).
- Parent: BLK-007 / Clock: clk / Reset: rst_n / Source: ip (project-internal, verified per
  `cnn/rtl_manifest.yaml:43`)
- Traces: REQ-013, REQ-014, REQ-029 (idle-high during reset)
- Ports: IFI-005 (`utx_data`, `utx_valid` in; `utx_ready`, `utx_busy` out; `uart_tx` out).
- Latency: frame = 10×CLK_DIV cycles. Error: write-while-busy ignored (drop, REQ-014).

#### BLK-014..BLK-019 : cnn leaves (reused IP, verbatim)
- BLK-014 `ctrl_fsm` — sequences one inference; all result ports per `ctrl_fsm.v:186-198`; the
  single-shot relies on its reset semantics (`ST_CONV1`, `img_idx=0`, `ctrl_fsm.v:280-295`) and
  the `lc_present` strobe (`ctrl_fsm.v:198`). lf_done driven 1 by BLK-010.
- BLK-015 `mac_datapath` — 16×16→32 signed multiplier + 64-bit signed accumulator, Q8.8, saturate
  at `mac_z`, ReLU at `mac_h` (REQ-002..018 inherited; `cnn/arch/arch.md §5`).
- BLK-016 `win_addr_gen` — combinational address generator (zero-padding, ping-pong map).
- BLK-017 `fm_ram` — 7,840×16 signed, single R/W port, hazard-free reuse (`cnn/arch/arch.md §7.1`).
- BLK-018 `weight_rom` — 26,698×16 signed, `$readmemh` weights.hex (REQ-023).
- BLK-019 `sigmoid_lut` — 65,536×8, `$readmemh` sigmoid_lut.hex (REQ-023).
- All: Source ip (project-internal), clock clk, reset rst_n, byte-for-byte reuse (REQ-022),
  internal FSMs/memories per `cnn/arch/arch.md` (FSM-001..006, MEM-001..005 there) — not
  renumbered or re-specified here.

## 5. Datapath Definition

**CNN datapath (BLK-014..BLK-019): inherited unchanged.** Every node width, Q-format, saturation
and overflow policy is fixed by the bit-exact contract and specified in `cnn/arch/arch.md §5`
(16×16→32 multiplier, 64-bit `acc`, Q8.8, `mac_z` clamp to [-32768,32767], ReLU, 8-bit LUT
outputs, 4-bit argmax, 7-bit confidence 0..100, 2-bit verdict). The accumulator overflow proof
(FC1 worst case ~2^39.6, 64-bit acc) is inherited; no saturation logic exists in `acc`. Nothing
in the SoC wrapper touches these widths.

**SoC datapath (new logic only):**

| Node | Width | Signed? | Notes |
|---|---|---|---|
| AXI address/data | 32 | unsigned addr / data | little-endian RV32 |
| `wstrb` | 4 | — | byte lanes |
| `rdata` mux (interconnect) | 32 | — | 6:1 (5 slaves + unmapped), combinational |
| bootrom word read | 32 | — | `{rom[a+3],rom[a+2],rom[a+1],rom[a+0]}`, `a=addr_r[11:2]` |
| SRAM word | 32 | — | `mem[addr_r[16:2]]`; lane writes `wstrb[j] → mem[w][8j+:8]` |
| vec_rom word read | 32 | — | `{rom[a+3],…}`, `a=addr_r[16:2]`, depth 19,625 words |
| image pixel | 8 | unsigned | buffer word = 1 pixel; word-write packing: pixel `4k+j` ← `wdata[8j+:8]` |
| `CNN_RESULT` | 32 | — | `{14'b0, verdict[1:0], 1'b0, conf[6:0], 4'b0, pred[3:0]}` |
| `CNN_CTRL` read | 32 | — | `{30'b0, park, 1'b0}` (START reads 0) |
| `CNN_STATUS` read | 32 | — | `{30'b0, done, busy}` |
| `UART_STAT` read | 32 | — | `{31'b0, utx_busy}` |
| `GPIO_OUT` read | 32 | — | `{20'b0, gpio_out[11:0]}` |
| bridge PADDR | 12 | — | `awaddr[11:0]`/`araddr[11:0]` held from request to accept |

Overflow policy: no arithmetic exists in the new datapath (muxes, registers, packing only) —
nothing can overflow; the only "policy" is exact bit-preserving assembly per the register map
(§7.3). Pipeline stage boundaries: AXI accept registers (per slave), memory read-output
registers, result latch, APB target registers — all named in §4/§6.

## 6. Control FSMs

Three new FSMs (reused-leaf FSMs are inherited from `cnn/arch/arch.md §6` — ctrl_fsm FSM-001..004,
uart_tx FSM-006 — and are NOT re-authored here). All new FSMs: binary encoding, synchronous
reset, `default:` recovery.

### 6.1 FSM-001 : axi2apb bridge (BLK-006) — 4 states, reset = ST_IDLE

| State | Condition | Next state | Registered actions this cycle |
|---|---|---|---|
| ST_IDLE | `awvalid && wvalid` (write request) | ST_SETUP | capture `paddr_r<=awaddr[11:0]`, `pwrite_r<=1`; (no accept yet) |
| ST_IDLE | `arvalid` (read request) | ST_SETUP | capture `paddr_r<=araddr[11:0]`, `pwrite_r<=0` |
| ST_IDLE | (else) | ST_IDLE | — |
| ST_SETUP | (always) | ST_ACCESS | `psel<=1; penable<=0` (APB SETUP) |
| ST_ACCESS | `pready` (targets are 0-wait: `pready==1`) | ST_RESP | `penable<=1` (ACCESS); **accept**: `awready<=1; wready<=1` (write) or `arready<=1` (read); capture `prdata_r<=prdata` (read) / `pwdata_r<=pwdata` (write, for the response path) |
| ST_ACCESS | `!pready` | ST_ACCESS | stay (never occurs: targets 0-wait; kept for completeness) |
| ST_RESP | (always) | ST_IDLE | assert `bvalid<=1` (write) or `rvalid<=1; rdata<=prdata_r` (read), exactly 1 cycle; `psel<=0; penable<=0` |
| (any other) | `default:` | ST_IDLE | illegal-state recovery |

Response timing: accept during ST_ACCESS (cycle N+2 of the transaction) → `bvalid`/`rvalid` at
N+3 = exactly 1 cycle after the bridge's accept cycle (spec REQ-005; total ≤ 3 cycles from
request). The `awready`/`wready`/`arready` are only asserted in ST_ACCESS, so the adapter holds
the address/data stable until then (standard AXI backpressure; single outstanding ⇒ no buffering).

### 6.2 FSM-002 : axil_slave_accept (BLK-003/004/005/009 + interconnect unmapped responder) — 3 states, reset = ST_IDLE

The identical accept/response pattern in every memory/register slave. Per-instance prefixes
(boot_/sram_/vec_/cnn_/um_) on the AXI signals.

| State | Condition | Next state | Registered actions this cycle |
|---|---|---|---|
| ST_IDLE | `awvalid && wvalid` | ST_WRESP | accept (`awready<=1; wready<=1`); write applied at this edge: SRAM `wstrb` lanes; cnn registers; image buffer (or ignored for RO) |
| ST_IDLE | `arvalid` | ST_RRESP | accept (`arready<=1`); capture `addr_r<=araddr` (RO-memories/SRAM) or `addr_r<=araddr[11:0]` (cnn regs/buffer decode) |
| ST_IDLE | (else) | ST_IDLE | — |
| ST_WRESP | (always) | ST_IDLE | `bvalid<=1` exactly 1 cycle (no BRESP) |
| ST_RRESP | (always) | ST_RRESP_DLY | — (memory-access cycle: registered read `rdata<=mem[addr_r]` happens at this edge) |
| ST_RRESP_DLY | (always) | ST_IDLE | `rvalid<=1; rdata<=<read result>` exactly 1 cycle (read result = memory output, cnn register decode, or 0 for unmapped) |
| (any other) | `default:` | ST_IDLE | illegal-state recovery |

Timing: write accept at cycle N → `bvalid` at N+1; read accept at N → `rvalid` at N+2 (the
"1 cycle after the read-accept cycle" of REQ-005 — see §2 interpretation). Unmapped responder:
same states, read result constant 0. cnn register reads: decode is combinational on `addr_r`,
registered into the read-result register at the ST_RRESP edge.

### 6.3 FSM-003 : single-shot sequencer (BLK-009) — 3 states, reset = ST_PARK

Inputs: `start_strobe` (= AXI write to CNN_CTRL with `pwdata[0]==1` and `wstrb[0]`, evaluated at
the accept edge), `park_write` (= AXI write to CNN_CTRL with `pwdata[1]==1`), `park_reg`
(CNN_CTRL[1] flop), `present` (`lc_present` from BLK-010). Outputs: `busy_r`, `done_r`,
`seq_park`; `rst_n_core = !(seq_park || park_reg)` (combinational).

| State | Condition | Next state | Registered actions this cycle |
|---|---|---|---|
| ST_PARK | `park_write` | ST_PARK | `park_reg<=1` (stay parked; redundant but harmless) |
| ST_PARK | `start_strobe && !park_reg` | ST_RUN | `busy_r<=1; done_r<=0; seq_park<=0` (launch; core unparked next cycle) |
| ST_PARK | (else) | ST_PARK | `done_r<=0` (kept 0) |
| ST_RUN | `park_write` | ST_PARK | abort: `park_reg<=1; busy_r<=0; done_r<=0; seq_park<=1` (core held in reset; partial results discarded — REQ-016) |
| ST_RUN | `present` | ST_DONE | latch `result_r<={14'b0,verdict,1'b0,conf,4'b0,pred}`; `done_r<=1; busy_r<=0; seq_park<=1` (re-park — lands 1 cycle after the present cycle, ≤ 2-cycle REQ-021 bound) |
| ST_RUN | (else) | ST_RUN | `start_strobe` ignored while BUSY (REQ-016); `park_reg<=0` writes have no effect |
| ST_DONE | `park_write` | ST_PARK | `park_reg<=1; busy_r<=0; done_r<=0; seq_park<=1` |
| ST_DONE | `start_strobe && !park_reg` | ST_RUN | `done_r<=0; busy_r<=1; seq_park<=0` (DONE cleared on next START — REQ-017) |
| ST_DONE | (else) | ST_DONE | `done_r` held 1 |
| (any other) | `default:` | ST_PARK | illegal-state recovery |

Edge semantics (pinned): `start_strobe`/`park_write` are derived from the FSM-002 write accept of
CNN_CTRL (same edge the register file updates). `CNN_STATUS` = `{30'b0, done_r, busy_r}`. The
core's reset de-asserts on the edge following START-accept; `lc_present` is architecturally
exactly 1 cycle (`cnn/arch/arch.md:427-434`) and is latched on the sequencer edge while
`best_val/best_idx` are stable (FC2 last WB → PRESENT, `ctrl_fsm.v:176-178`; PLAN.md R3). Result
registers hold from latch until the next START.

## 7. Memory Map and Register Definition

### 7.1 Address decode (BLK-002, combinational; spec §3.1)

Let `A` = `awaddr` (writes) / `araddr` (reads). One-hot select:

```
sel_boot = (A[31:28]==4'h0) && (A[31:16]==16'h0000) && (A[15:12]==4'h0)   // 0x0000_0000..0x0000_0FFF
sel_sram = (A[31:28]==4'h0) && ((A[31:16]==16'h0001) || (A[31:16]==16'h0002))  // 0x0001_0000..0x0002_FFFF
sel_vec  = (A[31:28]==4'h1)                                                // 0x1000_0000 window
sel_apb  = (A[31:28]==4'h4)                                                // 0x4000_0000 window
sel_cnn  = (A[31:28]==4'h5)                                                // 0x5000_0000 window
sel_unmapped = !(sel_boot || sel_sram || sel_vec || sel_apb || sel_cnn)
```

No aliasing (each address selects exactly one path). Unmapped includes `0x0000_1000..0x0000_FFFF`,
`0x0003_0000..0x0FFF_FFFF`, windows `0x2/0x3/0x6..0xF` (REQ-006/007).

### 7.2 Memory-init mechanism (paths relative to the cnn_soc project root; PLAN.md R5)

| MEM-ID | Instance (BLK) | Depth × Width | Init |
|---|---|---|---|
| MEM-001 | bootrom (BLK-003) | 4,096 × 8 | `initial $readmemh(BOOT_HEX_FILE, rom);` default `"sw/firmware.hex"` |
| MEM-002 | sram (BLK-004) | 32,768 × 32 | none (stack-only use; REQ-004) |
| MEM-003 | vec_rom (BLK-005) | 78,500 × 8 | `$readmemh(IMAGES_HEX_FILE, rom, 0, 78399)` + `$readmemh(LABELS_HEX_FILE, rom, 78400, 78499)`; defaults `"../cnn/arch/golden_model/images.hex"` / `"../cnn/arch/golden_model/labels.hex"` |
| MEM-004 | image_buffer (BLK-011) | 784 × 8 | none (CPU-written before each START) |
| MEM-005 | weight_rom (BLK-018, reused) | 26,698 × 16 signed | `$readmemh(WEIGHTS_HEX_FILE)`; default `"../cnn/arch/golden_model/weights.hex"` (overrides the cnn `define default, which is cnn-root-relative — the SoC must override, see BLK-001 params) |
| MEM-006 | sigmoid_lut (BLK-019, reused) | 65,536 × 8 | `$readmemh(LUT_HEX_FILE)`; default `"../cnn/rtl/sigmoid_lut.hex"` |
| MEM-007 | fm_ram (BLK-017, reused) | 7,840 × 16 signed | none (hazard-free reuse, `cnn/arch/arch.md §7.1`) |

Synthesis note: `initial $readmemh` is the sanctioned exception to the no-`initial` rule (cnn
precedent, `cnn/arch/arch.md §7.2`); all other `initial` blocks are forbidden (guidelines §14).

### 7.3 Register map (spec §6, with edge semantics pinned)

All 32-bit, word-aligned, little-endian; reserved bits read-as-zero, writes-ignored (RAZ/WI);
every register resets to 0. Register-target writes (UART_TX, GPIO_OUT, CNN_CTRL, CNN_EXP) update
on any write to their offset regardless of `wstrb` (PWDATA supplies the bits — matches REQ-015
"any write"); CNN_IMG and SRAM honour `wstrb` lane-by-lane; RO memories ignore writes.

| Region / Offset | Name | W | Access | Reset | Fields / semantics |
|---|---|---|---|---|---|
| 0x4000_0000+0x00 | `UART_TX` | 8 | W | 0 | `[7:0]` byte; write → 1-cycle `utx_valid` pulse with `PWDATA[7:0]` (BLK-007). Write-while-busy: byte dropped (REQ-014). Read returns 0. |
| 0x4000_0000+0x04 | `UART_STAT` | 1 | R | 0 | `[0]` BUSY = `!utx_ready` (`uart_tx.v:44-45`); `[31:1]` RAZ. |
| 0x4000_1000+0x00 | `GPIO_OUT` | 12 | RW | 0 | `[11:0]` → `led[11:0]`; any write updates from `PWDATA[11:0]`; read returns the register. |
| 0x5000_0000+0x00 | `CNN_CTRL` | 2 | RW | 0 | `[0]` START write-1 strobe (reads 0; ignored while PARK=1 or BUSY=1); `[1]` PARK RW (1 = hold core in reset + clear BUSY/DONE, abort). Read = `{30'b0, park, 1'b0}`. |
| 0x5000_0000+0x04 | `CNN_STATUS` | 2 | R | 0 | `[0]` BUSY (sequencer `busy_r`: 1 from START-accept until result-latch edge); `[1]` DONE (set on result latch, cleared by next START or PARK write). Read = `{30'b0, done, busy}`. |
| 0x5000_0000+0x08 | `CNN_RESULT` | 18 | R | 0 | `[3:0]` pred (`lf_pred`); `[14:8]` conf 0..100 (`lf_conf`); `[17:16]` verdict 0/1/2 (`lf_verdict`); `[31:18],[15],[7:4]` RAZ. Latched on `lc_present`, held until next START. |
| 0x5000_0000+0x0C | `CNN_EXP` | 4 | W | 0 | `[3:0]` expected label; drives `ctrl_fsm.lrom_data[3:0]={4'd0,EXP}` (REQ-019). Read returns 0. |
| 0x5000_0100..0x040F | `CNN_IMG` | 8×784 | W | — | 784 bytes, byte-offset `p = awaddr[11:0]-10'd256`; word write at `+0x100+4k` packs pixels `4k..4k+3` into bytes `[7:0],[15:8],[23:16],[31:24]` with `wstrb` lanes; reads return 0. |
| cnn window, other offsets (0x10..0xFF, 0x410..0xFFF) | — | — | — | — | Read 0 / write ignored / handshake completes (never hang). |
| APB UART region, other offsets (0x01..0x03, 0x05..0x07) | — | — | — | — | Read 0 / write ignored, PREADY. |

## 8. Internal Interfaces (IFI-###)

Full signal-level definitions in `interface_defs.yaml`. New SoC interfaces:

- **IFI-001 `cnn_core_if`** (BLK-009 ↔ BLK-010): `core_rst_n` (out, active-low — combinational
  `!(seq_park||park_reg)`), `exp_label[3:0]`, `img_waddr[9:0]`, `img_wdata[7:0]`, `img_we` (out);
  `pred[3:0]`, `conf[6:0]`, `verdict[1:0]`, `busy`, `present` (in). Type: status/control, no
  backpressure. Mirrors spec IF-005.
- **IFI-002 `apb_bus`** (BLK-006 → BLK-007/008): `psel` (one of two), `penable`, `pwrite`,
  `paddr[11:0]`, `pwdata[31:0]`, `prdata[31:0]` (from target), `pready` (from target, always 1).
  Type: handshake (SETUP/ACCESS); targets 0-wait. Mirrors spec IF-004.
- **IFI-003 `axil_slave_port`** (pattern; interconnect ↔ each slave, 5 instances + unmapped
  responder): the full simplified-AXI slave channel set (awvalid/awready/awaddr/awprot/
  wvalid/wready/wdata/wstrb/bvalid/bready/arvalid/arready/araddr/arprot/rvalid/rready/rdata).
  Semantics pinned in §2/§6.2: accept combinationally when idle; 1-cycle response pulses;
  `valid` may depend on `ready` (adapter holds request until accept — standard); data stable
  while stalled; never wait for bready/rready. Mirrors spec IF-003.
- **IFI-004 `cpu_axil_master`** (BLK-012 → BLK-002): same signal set, master side; identical to
  spec IF-003.
- **IFI-005 `utx_port`** (BLK-007 → BLK-013): `utx_data[7:0]`, `utx_valid` (1-cycle pulse from
  the shell), `utx_ready`, `utx_busy`. Note: the shell is a fire-and-forget producer (drop
  semantics, REQ-014) — deliberately different from `uart_line_fmt`'s hold-until-ready producer
  (cnn IFI-007); `uart_tx` itself is unchanged.

**Inherited leaf interfaces (verbatim from `cnn/arch/interface_defs.yaml`, NOT renumbered):**
cnn IFI-001 (mac port), IFI-002 (lut port), IFI-003 (weight_rom port), IFI-004 (image_rom port —
now served by BLK-011's read port), IFI-005 (label_rom port — now served by `exp_label`),
IFI-006 (fm_ram port), IFI-007 (uart valid/ready), IFI-008 (led_ctrl port — unused in the SoC,
the signals `lc_pred/lc_verdict` are exposed via BLK-010 result ports), IFI-009 (uart_line_fmt
port — `lf_*` consumed/exposed as per BLK-010), IFI-010 (win_addr_gen port). The cnn leaf port
lists in those definitions are the exact connection contracts for BLK-014..BLK-019.

## 9. Clock and Reset Architecture

- **One domain, CD_CORE** (`clk`, 100 MHz nominal / 10.000 ns, CLK-001). No second domain, no
  generated/gated clocks (REQ-028). `cdc_plan.md` enumerates **0 crossings** explicitly.
- **One reset, `rst_n`**, active-low, **fully synchronous** (RST-001, deviation §2): every flop
  `always @(posedge clk) if (!rst_n) ... else ...`; no `negedge rst_n` anywhere (REQ-029). Fans
  out to `picorv32.resetn` and every slave. Min assert 2 cycles (ASM-001); TB asserts ≥ 10.
  During reset: `led==0`, `uart_tx==1` (G4). No reset synchroniser, no async reset domain, no
  reset sequencing needed (single domain). Note for FPGA bring-up (out of scope): an external
  reset source must itself be clean relative to `clk`; synchronisation of a board-level reset is
  a board/constraint concern, not RTL.
- The park mechanism (`core_rst_n`) is a **functionally gated synchronous reset** of BLK-010
  only — it is combinational `!(seq_park||park_reg)` on the same clock edge, never an async term.

## 10. IP Reuse Plan

| BLK-ID | Decision | Source | Licence | Status | Adapter needed |
|---|---|---|---|---|---|
| BLK-012 (picorv32_axi + core + adapter) | reuse, verbatim | `skill-tests/ex6/rtl/picorv32.v` (local copy, read this session) | ISC (file header) | verified | none — instantiate `picorv32_axi` with parameters §4 |
| BLK-013 (uart_tx) | reuse, verbatim | `cnn/rtl/uart_tx.v` (project-internal) | project-internal | verified | none — `CLK_DIV` parameter only |
| BLK-014..BLK-019 (ctrl_fsm, mac_datapath, win_addr_gen, fm_ram, weight_rom, sigmoid_lut) | reuse, byte-for-byte, zero edits | `cnn/rtl/*.v` (project-internal; `cnn/rtl_manifest.yaml:34-46` status complete) | project-internal | verified | none — wiring per §4 BLK-010 (mirrors `cnn_npu.v:99-233`) |
| Golden vectors + LUT hex (images.hex, labels.hex, weights.hex, expected.hex, expected_outputs.txt, sigmoid_lut.hex) | reuse, frozen data | `cnn/arch/golden_model/` + `cnn/rtl/sigmoid_lut.hex` | project-internal | verified | n/a (data) |

No external (GitHub) search was executed this stage: every reuse candidate is local and verified
from disk (spec §10 same decision). No repo URL or licence is claimed outside the four entries
above; no Sky130 cell is named anywhere. All other blocks (BLK-001..011) are **custom**
(PLAN.md Appendix A); no block is `undecided`.

## 11. Golden Model Description

**Reference-only, FROZEN — not generated, regenerated, or relocated by this stage** (binding
instruction; identical precedent to `cnn/arch/arch.md §11`). The executable golden contract is the
pre-existing CNN package:

- `cnn/arch/golden_model/golden_ref_model.c` — C99 integer-only transaction-level forward pass
  (the bit-exact datapath contract; already reproduced byte-identically by the cnn project,
  `cnn/rtl_manifest.yaml` golden_package_commit e7569dbd).
- Vectors: `weights.hex` (26,698 words), `images.hex` (78,400), `labels.hex` (100),
  `expected.hex` (400 = 100 images × [pred, conf, exp, verdict]), `expected_outputs.txt`
  (10,003 lines; **first 100 lines = the SoC demo set**, `PLAN.md §9` G1).

The SoC's verification contract (spec verification_plan.md §5, G1/G2) diffs the CPU-formatted
UART stream against `expected_outputs.txt` lines 1..100 and the result registers against
`expected.hex` — the same golden data, reused verbatim. No new C model is authored (the SoC adds
no arithmetic). Build/run of the frozen model (user action, not executed here):
`gcc -std=c99 -O2 -Wall -Wextra -o gm arch/golden_model/golden_ref_model.c && ./gm .` from the
`cnn` root (reproduces the committed package byte-identically).

## 12. Verification Hooks

Pure-Verilog observation points for the SoC TB (hierarchical probes; no DFT muxes):

- `u_picorv32.trap` — must never assert (G5; VP-TOP-006).
- `u_cnn_axi_slave.u_seq.state`, `busy_r`, `done_r`, `park_reg`, `seq_park` — single-shot
  lifecycle, PARK abort, START corners (VP-TOP-007, VP-CNN-001).
- `u_cnn_axi_slave.result_r` — G2 check source alongside the register read (VP-TOP-003).
- `u_cnn_infer.u_ctrl_fsm.img_idx` — must be 0 at all times (REQ-021); `state`/`phase` for FSM
  coverage (VP-CNN-004/VP-CTRL-001-style checks); `lc_present` edge vs `rst_n_core` — park ≤ 2
  cycles (VP-TOP-007).
- `u_cnn_infer.u_ctrl_fsm.lrom_data` — == `{4'd0, exp_label}` (REQ-019).
- `u_cnn_infer.u_image_buffer.buf` — write-path fidelity, little-endian packing (VP-CNN-003).
- `u_axi_lite_interconnect.sel_*` — decode coverage incl. unmapped (VP-IC-001).
- `u_axi2apb.state` — bridge FSM coverage (VP-APB-001).
- Top-level `led[11:0]` at DONE edges (VP-TOP-004) and `uart_tx` via the independent bit-level
  decoder to `uart_captured.txt` (VP-TOP-002; decoder self-calibrates bit time from the first
  char, `fe-firmware/SKILL.md:71-76`).

## 13. Traceability: REQ -> BLK

| REQ-ID | BLK-ID(s) |
|---|---|
| REQ-001 | BLK-001 |
| REQ-002 | BLK-012 |
| REQ-003 | BLK-001, BLK-003, BLK-012 |
| REQ-004 | BLK-001, BLK-003 (firmware image property; verified at fe-firmware) |
| REQ-005 | BLK-002, BLK-003, BLK-004, BLK-005, BLK-006, BLK-009, BLK-012 |
| REQ-006 | BLK-002 |
| REQ-007 | BLK-002 |
| REQ-008 | BLK-003 |
| REQ-009 | BLK-004 |
| REQ-010 | BLK-005 |
| REQ-011 | BLK-006 |
| REQ-012 | BLK-009 |
| REQ-013 | BLK-007, BLK-013 |
| REQ-014 | BLK-007 |
| REQ-015 | BLK-008 |
| REQ-016 | BLK-009 |
| REQ-017 | BLK-009 |
| REQ-018 | BLK-009, BLK-010 |
| REQ-019 | BLK-009, BLK-010 |
| REQ-020 | BLK-009, BLK-010, BLK-011 |
| REQ-021 | BLK-009, BLK-010 |
| REQ-022 | BLK-010, BLK-014, BLK-015, BLK-016, BLK-017, BLK-018, BLK-019 |
| REQ-023 | BLK-010, BLK-018, BLK-019 |
| REQ-024 | BLK-001 (firmware contract), BLK-007, BLK-013 |
| REQ-025 | BLK-001 (firmware contract), BLK-005, BLK-009 |
| REQ-026 | BLK-001 (firmware contract), BLK-008 |
| REQ-027 | BLK-012, BLK-001 (firmware contract) |
| REQ-028 | BLK-001 (all blocks) |
| REQ-029 | BLK-001 (all blocks) |
| REQ-030 | BLK-002, BLK-009, BLK-011 |
| REQ-031 | BLK-001, BLK-010 (budgets: §6.5) |
| REQ-032 | BLK-001 (all blocks, coding discipline) |

Every `must` REQ maps to ≥ 1 block; every block traces to ≥ 1 REQ (§4 "Traces" lines). REQ-024/
025/026/027 additionally bind the firmware (fe-firmware stage) via the SoC-level contract in
spec §3/§8; BLK-001 carries those traces. Zero orphans.

## 14. Assumptions and Open Issues

- ASM-001 (min reset assert ≥ 2 cycles) and ASM-002 (100.000 MHz) carried from spec §11,
  acknowledged (`assumptions_acknowledged: true`, spec_manifest).
- The §2 read-response interpretation and §6.2 FSM-002 timing pin the exact slave response
  cycles; this is an architecture-level pinning within the spec's bounds, not a spec change.
- **Open issues: none.** All PLAN OQ1..OQ7 are binding decisions (spec); the only arch-level
  decisions made here (response timing pinning, bridge accept policy, image-buffer read-first,
  `$readmemh` path defaults relative to the cnn_soc root, register-write wstrb policy, BOOT_HEX_FILE
  default `"sw/firmware.hex"`) are documented, non-blocking, and reversible at fe-rtl only with a
  spec-level OI (none required — all are within the frozen spec's bounds).
- Out of scope (v2, not open issues): IRQ, DMA, weights-in-SRAM, camera/CDC, fusesoc packaging.

## 15. Estimated Area and Timing Budget

Qualitative (no synthesis run; fpga_generic — no Sky130 cell numbers). Flop/bit estimate:

| Block | Dominant storage / logic | Estimate |
|---|---|---|
| BLK-012 picorv32_axi | register file + core | ~1,100 flops (small RV32I) |
| BLK-002 interconnect | muxes, unmapped responder | < 100 flops, ~1 ns path |
| BLK-003 bootrom | 4,096×8 (distributed/BRAM) | 32 kbit |
| BLK-004 sram | 32,768×32 | 1 Mbit (BRAM on FPGA) |
| BLK-005 vec_rom | 78,500×8 | ~628 kbit (BRAM) |
| BLK-006 bridge | 4-state FSM | < 50 flops, ~1.5 ns |
| BLK-007/008 apb shells | registers | < 30 flops |
| BLK-009 cnn_axi_slave | regs + 2 FSMs + buffer port | < 150 flops |
| BLK-010 cnn_infer | wiring only | 0 own flops |
| BLK-011 image_buffer | 784×8 | 6.3 kbit |
| BLK-013..019 cnn leaves | inherited (`cnn/arch/arch.md §15`: 64-bit acc, 7,840×16 fm_ram, 26,698×16 wrom, 65,536×8 LUT) | inherited; MAC path ~6.5 ns of 10 ns |

Critical-path budget within 10.000 ns: the inherited MAC multiply-accumulate path (~6.5 ns,
`cnn/arch/arch.md §15`) remains the largest single budget; every new SoC path (decode mux, AXI
response, APB) is ≤ ~1.5 ns. The CPU is a small RV32I — comfortable at 100 MHz on the target
FPGA class. No timing closure claim is made (FPGA implementation out of scope).

### 6.5 (referenced above) Cycle budgets (REQ-031)

Per-image CPU-side + compute (100 MHz):

| Phase | Cycles |
|---|---|
| Boot: stub (`li sp; jal main`) + prologue | ~50 |
| Image copy: 196 word loads (vec_rom) + 196 word stores (CNN_IMG) + loop | ≤ 3,000 |
| Label read + CNN_EXP write + START + poll setup | ~100 |
| CNN inference (compute + 2 PRESENT cycles, `cnn/arch/arch.md:481`) | 667,210 |
| UART line (worst 69 B × 10 × CLK_DIV): CLK_DIV=868 / 4 | 598,920 / 2,760 |
| **Per image: 868 / 4** | **≈ 1.269M / ≈ 673k** |
| **First complete line after reset (868 / 4)** | **≈ 1.27M / ≈ 673k ≤ 1.5M ✓ (REQ-031)** |
| **Full 100-image demo (868 / 4)** | **≈ 127M / ≈ 67.4M ≤ 150M ✓ (REQ-031)** |

UART at CLK_DIV=868 dominates; the SoC TB uses `UART_CLK_DIV=4` (sim override, byte stream
unchanged) → ~67.4M cycles ≈ tens of seconds wall-clock under iverilog, same order as the IP-level
soak (`cnn/arch/arch.md:487-496`).
