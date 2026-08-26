# cnn_soc — MNIST CNN Accelerator SoC: Front-End Specification
Document ID: SPEC-CNN-SOC-v1.0 | Stage: fe-spec | Input: PLAN-CNN-SOC-v1.0 (Rinri-approved 2026-08-26) | Technology: see §2 (FPGA-generic, not Sky130 — documented deviation, project precedent)

## 1. Scope and Overview

`cnn_soc` (top module `cnn_soc`) is a small RISC-V SoC that wraps the verified, bit-exact `cnn/`
MNIST CNN accelerator (96.35%, 200/200 bit-exact, cocotb 19/19 — `ROADMAP.md:21`) so that **C
firmware boots from a bootrom, feeds one image at a time to the CNN over a simplified AXI4-Lite
bus, reads back the result registers, and prints the exact golden UART line + drives the LEDs** —
replacing the `$readmemh` + free-running-testbench flow (`cnn/spec/spec.md:37`, `spec.md:66-73`)
with a real CPU boot flow (`cnn_soc/README.md:5-8`, `PLAN.md §1`).

**Three load-bearing design decisions (binding, PLAN.md §1):**

1. **CPU = `picorv32_axi` verbatim** (`skill-tests/ex6/rtl/picorv32.v:2517`), the built-in
   AXI4-Lite master wrapper (+ `picorv32_axi_adapter`, `picorv32.v:2731`). This is a *simplified*
   AXI4-Lite: no `BRESP`/`RRESP`/IDs (`picorv32.v:2731-2767`) — no custom bus, no custom adapter.
2. **The bit-exact core is untouched; the top is rebuilt from its verified leaves** (`cnn_npu.v`
   wiring `cnn_npu.v:99-233`) plus one new CPU-writable 784-byte image buffer. `image_rom` →
   `image_buffer`; `label_rom` → a CPU register (`CNN_EXP`); `uart_line_fmt`/`uart_tx`/`led_ctrl`
   move out of the core — the CPU formats the identical UART bytes and writes the LED pattern.
3. **Single-shot by reset-parking the free-runner.** The core is held in its synchronous reset
   until `START`, then re-parked within 2 cycles of the `lc_present` strobe (`ctrl_fsm.v:198`) so
   exactly one image (index 0, addressing the 784-byte buffer) is processed per `START` — zero
   edits to `ctrl_fsm`.

**v1 scope (PLAN.md §1, Decision Record):** `picorv32_axi` + flat single-master AXI4-Lite
interconnect; 4 KB bootrom (firmware baked, executes in place); 128 KB SRAM (data/stack); read-only
`vec_rom` preloaded from the frozen `images.hex`/`labels.hex` (the CPU's image source — stand-in
for a future camera/DMA); CNN AXI slave (CTRL/STATUS/RESULT/EXP + 784-byte image buffer; weights +
sigmoid LUT stay in internal `$readmemh` ROM — OQ7); AXI→APB bridge feeding an APB UART (reusing
`cnn/rtl/uart_tx.v`, `CLK_DIV=868`) and APB GPIO/LED; firmware + a full-SoC iverilog testbench that
boots, runs 100 images, and diffs UART vs the first 100 lines of
`cnn/arch/golden_model/expected_outputs.txt`. IRQ, DMA, weight-from-SRAM, and camera input are
explicitly **v2** (`README.md:15`, `README.md:27`) — out of scope, not open issues.

## 2. Global Constraints

| Constraint | Rule |
|---|---|
| Technology | **FPGA-synthesizable generic RTL** (`fpga_generic`) — NOT Sky130; see §2.1 deviation. Eventual target context: Xilinx Artix-7-class FPGA (project precedent `cnn`). FPGA implementation (bitstream/timing closure/pin planning) is out of scope for fe-spec/fe-arch/fe-rtl; the design need only be *cleanly synthesizable* (cnn REQ-036 precedent). |
| RTL language | **Pure Verilog-2001 (IEEE 1364-2001) or earlier.** No SystemVerilog, no VHDL. |
| Analog | **None.** No Sky130 or any other analog macro. No black-box stubs. |
| DFT | **None.** No scan, BIST, JTAG/TAP, MBIST, compression. |
| Tool execution | This stage **writes files only**. No simulator, synthesizer, linter, or build is invoked. |
| Guessing | Missing mandatory input → halt (`FE-SPEC HALTED`). Documented assumptions only per §11. |
| Memory-init | `$readmemh` remains the mechanism for bootrom, vec_rom, weight_rom, sigmoid_lut, image_buffer-free contents (OQ7: v1 is CPU-path for **program/image/label** only — weights/LUT stay ROM). |

### 2.1 Technology and reset deviations from the fe-spec defaults (documented, binding)

Identical deviation precedent to `cnn/spec/spec.md §2.1` and `cnn/spec/spec.md §5` (both carried
forward from v1 `mnist_npu`), restated here rather than silently inherited:

1. **Technology: `fpga_generic`, not SkyWater Sky130 130 nm.** The `fe-spec` skill's hard scope
   targets Sky130 and would normally halt (`SPEC-E004`) on a brief naming a non-Sky130 technology.
   This project's commissioning brief **explicitly and deliberately** specifies the project
   precedent (the verified `cnn` engine and the ex6 reference SoC are both FPGA-generic, fully
   synchronous designs) — this is not an ambiguity or a silent default, it is a direct,
   unambiguous instruction (`PLAN.md` Decision Record "Additional bindings": *"project precedent —
   fpga_generic technology, NOT sky130"*). No part of the brief asks for any Sky130-specific
   artifact. This spec therefore proceeds with the fe-spec artifact schemas, ID conventions, and
   coding rigor unchanged, with `technology: fpga_generic` instead of `sky130`, recorded here, in
   `requirements.yaml`, and in `spec_manifest.yaml`. Downstream fe-arch/fe-rtl must carry it
   forward unchanged and must not substitute Sky130-specific artifacts (cell names, analog black
   boxes, DFT policy) anywhere.
2. **Reset: fully SYNCHRONOUS active-low `rst_n`**, not the skill default async-assert /
   sync-de-assert. Same project precedent as `cnn` (`cnn/arch/arch.md:564-570`,
   `cnn/spec/spec.md:126-135`): every flop uses `always @(posedge clk) if (!rst_n) ... else ...` —
   **no** `always @(posedge clk or negedge rst_n)` anywhere. Restated in RST-001 / REQ-029;
   fe-arch's reset-synchroniser guidance does not apply (single domain, no CDC).

## 3. Functional Description

1. **SoC skeleton (all NEW RTL, PLAN.md Appendix A):** `cnn_soc.v` (top) instantiates
   `picorv32_axi` (verbatim, §5 parameters), `axi_lite_interconnect.v`, `bootrom.v`, `sram.v`,
   `vec_rom.v`, `axi2apb.v`, `apb_uart.v`, `apb_gpio.v`, `cnn_axi_slave.v`, `cnn_infer.v`,
   `image_buffer.v` — plus the verified `cnn/rtl/` leaves and `skill-tests/ex6/rtl/picorv32.v` via
   the project filelist (includes `cnn/rtl` so `cnn_defs.vh`/`mnist_npu_defs.vh` resolve).
2. **Boot flow (§8):** reset → CPU fetches at `PROGADDR_RESET=0x0000_0000` (bootrom) → boot stub
   `li sp, 0x0003_0000; jal main` (`fe-firmware/SKILL.md:61-62`, `ex6/sw/hello.c:21`) → `main()`
   runs the 100-image demo loop; firmware `.text`/`.rodata` execute in place from the bootrom (no
   copy step); `.data`/`.bss` are **zero** in v1 (pure-ROM image, `fe-firmware/SKILL.md:139-141`);
   SRAM holds the stack only.
3. **Per-image flow (firmware):** read image `i` (784 bytes, `vec_rom 0x1000_0000 + i*784`) and
   label `i` (`0x1001_3240 + i`) → write `CNN_EXP` → copy 784 bytes to `CNN_IMG` → write
   `CNN_CTRL.START` → poll `CNN_STATUS.DONE` → read `CNN_RESULT` → print the exact golden UART
   line → write the LED pattern to `GPIO_OUT`. After image 99: spin forever.
4. **CNN integration (§6.3):** `cnn_infer` re-instantiates the verified leaves with the exact
   wiring of `cnn_npu.v:99-233` — `weight_rom` (`:99`), `sigmoid_lut` (`:135`, structural
   `addr=mac_z`, `:140`), `mac_datapath` (`:144`), `win_addr_gen` (`:156`), `fm_ram` (`:126`),
   `ctrl_fsm` (`:175`) — with `image_rom` replaced by the 784×8 CPU-writable `image_buffer`
   (1-cycle registered read identical to `image_rom.v:27-30`, preserving ctrl_fsm's ADDR→ACC
   timing, `arch.md:401-402`), `label_rom` replaced by the `CNN_EXP` register (drives
   `ctrl_fsm.lrom_data[3:0] = {4'd0, exp_label}`, `ctrl_fsm.v:47`), and `lf_done` tied to 1 so
   `PH_WAIT_UART` exits immediately (`ctrl_fsm.v:449-455`). `uart_line_fmt`, `uart_tx`, `led_ctrl`,
   `image_rom`, `label_rom` are **not** instantiated inside `cnn_infer`.
5. **Single-shot (PLAN.md §6.2):** at SoC reset and after each `lc_present` (within 2 cycles), the
   sequencer in `cnn_axi_slave` holds the core's `rst_n_core=0` (parked: ctrl_fsm resets to
   `ST_CONV1`, `img_idx=0`, `ctrl_fsm.v:280-295`). `START` releases park; the core runs one full
   inference (~667,208 compute cycles, `arch.md:481`); on the `lc_present` pulse (`ctrl_fsm.v:198`,
   architecturally exactly 1 cycle, `arch.md:427-434`) the sequencer latches
   `pred/conf/verdict` into `CNN_RESULT`, sets `DONE=1`, clears `BUSY`, and re-parks — stopping the
   core before `img_idx` advances to 1 (`ctrl_fsm.v:463`). `HOLD_CYCLES`/`BLINK_CYCLES` are
   irrelevant (park precedes HOLD); core defaults remain.
6. **Outputs:** top-level `uart_tx` (115200 8N1, idle-high mark) and `led[11:0]`. The CPU formats
   the same three line variants the IP-level `uart_line_fmt` produces (REQ-024) and writes the
   LED pattern per REQ-026 (firmware-side `led_ctrl` reproduction; no `led_ctrl.v` re-instantiation
   — OQ4).

### 3.1 Memory map (32-bit, byte-addressed, little-endian; PLAN.md §3 — binding)

| Base | Size | Region | Access | Notes |
|---|---|---|---|---|
| `0x0000_0000` | 4 KB (`0x0000_0000..0x0000_0FFF`) | **bootrom** | RO/exec | Reset vector; firmware `.text`+`.rodata` baked (`$readmemh`, `BOOT_HEX_FILE`); executes in place. `PROGADDR_RESET` default `0x0000_0000` (`picorv32.v:2540`). |
| `0x0001_0000` | 128 KB (`0x0001_0000..0x0002_FFFF`) | **SRAM** | RW | `.data`/`.bss`/stack (v1: stack only). Stack top `0x0003_0000` → `STACKADDR` (`picorv32.v:2542`). |
| `0x1000_0000` | 78,500 B (`0x1000_0000..0x1001_32A3`) | **vec_rom** | RO | Images `+0x0000..+0x1323F` (78,400 B, `images.hex`), labels `+0x13240..+0x132A3` (100 B, `labels.hex`); `$readmemh` from frozen golden files (`golden_model/README.md:50-54`). |
| `0x4000_0000` | window | **AXI2APB** | — | APB peripheral window. |
| ├ `+0x0000` | 8 B | APB UART | RW | `+0x00` UART_TX (W), `+0x04` UART_STAT (R). |
| └ `+0x1000` | 4 B | APB GPIO/LED | RW | `+0x00` GPIO_OUT → `led[11:0]`. |
| `0x5000_0000` | window | **cnn_axi_slave** | RW | Register map §6.3; image buffer at `+0x100` (784 B, `+0x100..+0x40F`). |

Decode rule (combinational, on `addr[31:28]`): `0x0` = bootrom/SRAM sub-window (within it:
`addr[31:16]==0x0000 && addr[15:12]==0` → bootrom; `addr[31:16] ∈ {0x0001, 0x0002}` → SRAM;
everything else in the window unmapped), `0x1` = vec_rom, `0x4` = AXI2APB, `0x5` = cnn. All other
addresses (including `0x0000_1000..0x0000_FFFF`, `0x0003_0000..0x0FFF_FFFF`, `0x2`, `0x3`,
`0x6..0xF`) are **unmapped**: read returns 0, write ignored, handshake completes — the CPU must
never hang (PLAN.md R2).

## 4. External Interfaces

See `interfaces.yaml` for the signal-level definitions. Top-level ports of `cnn_soc` (exactly
four, matching the TB contract `PLAN.md §9`):

- **`sys_if`:** `clk` (100 MHz nominal, CLK-001), `rst_n` (active-low, **fully synchronous**,
  RST-001).
- **`uart_tx_if` (IF-001):** `uart_tx` (output only). 115200 8N1, `CLK_DIV` = 868 (default, via
  top parameter `UART_CLK_DIV`; `arch.md:224`). No RX. Idles high (mark) outside frames and during
  reset (`uart_tx.v` reset: `uart_tx <= 1'b1`, REQ-013/029).
- **`led_status_if` (IF-002):** `led[11:0]` (output only) = `GPIO_OUT[11:0]`; firmware encoding per
  REQ-026.
- **Internal IF-003:** simplified AXI4-Lite master (picorv32_axi port list, `picorv32.v:2549-2569`;
  full signal list in `interfaces.yaml`). **Contract (binding, PLAN.md R2):** AW+W issued together
  (`picorv32.v:2773,2781`); the adapter completes when `mem_ready = bvalid || rvalid`
  (`picorv32.v:2785`); no `BRESP`/`RRESP`/ID exist. Slaves: accept combinationally when idle;
  assert a 1-cycle `bvalid` exactly 1 cycle after the write-accept cycle; assert a 1-cycle
  `rvalid`+`rdata` exactly 1 cycle after the read-accept cycle (memory/register slaves; the
  AXI2APB bridge no later than 3 cycles after the accept cycle); never wait for `bready`/`rready`.
  The adapter holds `mem_valid` until it observes `bvalid||rvalid`, so a 1-cycle response pulse is
  always observed.
- **Internal IF-004:** APB bus (bridge → peripherals): `PSEL/PENABLE/PWRITE/PADDR[11:0]/
  PWDATA[31:0]/PRDATA[31:0]/PREADY`; no `PSTRB` (both APB targets are sub-word registers updated
  in full on any write; `wstrb` is consumed at the AXI side). `PADDR[11:0]` selects UART
  (`+0x0000`) vs GPIO (`+0x1000`); other APB offsets → `PRDATA=0`, `PREADY` (no hang).
- **Internal IF-005:** `cnn_core_if` (cnn_axi_slave ↔ cnn_infer): `core_rst_n` (out, active-low
  park), `exp_label[3:0]` (out), `img_waddr[9:0]`/`img_wdata[7:0]`/`img_we` (out, buffer write
  port), `pred[3:0]`/`conf[6:0]`/`verdict[1:0]`/`busy`/`present` (in, from ctrl_fsm `lf_*`/`lc_*`
  outputs, `ctrl_fsm.v:186-198`).

### 4.1 UART line framing (byte-exact, REQ-024) — identical strings to the golden stream

```
verdict 0 (CORRECT)  : "IMG %03u: This is number %u | confidence %u%% | expected %u | CORRECT\n"
verdict 1 (INCORRECT): "IMG %03u: This is number %u | confidence %u%% | expected %u | INCORRECT\n"
verdict 2 (TRASH)    : "IMG %03u: NOT A NUMBER | confidence %u%% | expected %u | TRASH\n"
```

`%03u` = image index 0..99, zero-padded to 3 ASCII decimal digits. All other `%u` fields are plain
ASCII decimal, no padding. `%%` is a literal `%`. Line terminator is a single `0x0A` (LF); no
`0x0D` (CR) is ever transmitted (`cnn/spec/spec.md:116-118`; golden `printf`,
`golden_ref_model.c` lines 239-245). Example golden line 1: `IMG 000: This is number 7 |
confidence 94% | expected 7 | CORRECT` (`expected_outputs.txt:1`). The CPU computes the same
pred/conf/verdict the CNN's own `uart_line_fmt` would (same HW result registers), so the byte
stream is identical to the IP-level golden — unifying the contract.

## 5. Clock and Reset Architecture

- **One clock domain, `CD_CORE`**, `clk` port, 100 MHz nominal / 10.000 ns period (CLK-001,
  ASM-002). No second domain exists: no UART RX, no external async input, no camera (`README.md:28`).
  **Zero CDC paths** — `cdc_plan.md` (fe-arch) will contain an empty enumeration.
- **One reset, `rst_n`**, active-low, **fully SYNCHRONOUS** (RST-001, deviation §2.1): every flop
  is `always @(posedge clk) if (!rst_n) ... else ...` — never `negedge rst_n`. Fans out directly
  to `picorv32.resetn` and every slave (as `ex6_soc.v:59`). Minimum assert width: 2 cycles
  (ASM-001); the SoC TB asserts ≥ 10 cycles at start (`PLAN.md §9`, `ex6_tb.v:118-119` precedent).
  During reset: `led[11:0]==12'h000` and `uart_tx==1'b1` (REQ-029, G4). No reset synchroniser
  exists or is needed (single domain).

## 6. Register Map

All registers 32-bit, word-aligned, little-endian (RV32). Reset value of every register = 0
unless stated. Widths/fields are grounded in the CNN result signals they carry (PLAN.md §4).

### 6.1 APB UART (`0x4000_0000`, via AXI2APB)

| Offset | Name | Width | Access | Reset | Fields |
|---|---|---|---|---|---|
| `+0x00` | `UART_TX` | 8 | W | 0 | `[7:0]` byte to transmit; write pulses `utx_valid` for exactly 1 cycle with `utx_data=PWDATA[7:0]` into the reused `uart_tx` (valid/ready contract `uart_tx.v:11-13`, IFI-007 `arch.md:559-562`). Write-while-busy: byte dropped (REQ-014). |
| `+0x04` | `UART_STAT` | 1 | R | 0 | `[0]` BUSY = `!utx_ready` (`uart_tx.v:44-45`); `[31:1]` read 0. Poll before write. |

### 6.2 APB GPIO/LED (`0x4000_1000`, via AXI2APB)

| Offset | Name | Width | Access | Reset | Fields |
|---|---|---|---|---|---|
| `+0x00` | `GPIO_OUT` | 12 | RW | 0 | `[11:0]` → top-level `led[11:0]`. Any write (any `wstrb`) updates the full 12-bit value from `PWDATA[11:0]`. Read returns the register. Firmware encoding per REQ-026 (reproduces `led_ctrl` scheme, `led_ctrl.v:66-78`: `[9:0]` one-hot pred / 0 on TRASH, `[10]` fail, `[11]` busy indicator). |

### 6.3 CNN AXI slave (`0x5000_0000`)

| Offset | Name | Width | Access | Reset | Fields |
|---|---|---|---|---|---|
| `+0x00` | `CNN_CTRL` | 2 | RW | 0 | `[0]` START — **write-1 strobe** (reads back 0): releases core park, launches one inference. Ignored while `PARK=1` or `BUSY=1`. `[1]` PARK — RW: 1 = hold core in synchronous reset and clear BUSY/DONE (soft-reset/abort); 0 = normal. |
| `+0x04` | `CNN_STATUS` | 2 | RO | 0 | `[0]` BUSY: 1 from START-accept until result latch. `[1]` DONE: set on result latch (`lc_present`), cleared by next START or by a PARK write. `[31:2]` read 0. |
| `+0x08` | `CNN_RESULT` | 18 | RO | 0 | `[3:0]` pred (`lf_pred` = `best_idx`, `ctrl_fsm.v:189`); `[14:8]` confidence 0..100 (`lf_conf`, `ctrl_fsm.v:190`, `:179-180`); `[17:16]` verdict 0/1/2 (`lf_verdict`, `ctrl_fsm.v:193`, `:182-183`); all other bits read 0. Latched on `lc_present`. |
| `+0x0C` | `CNN_EXP` | 4 | WO | 0 | `[3:0]` expected label for the current image; drives `ctrl_fsm.lrom_data[3:0] = {4'd0, EXP}` (IFI-005 port `ctrl_fsm.v:47`) so the hardware verdict (`ctrl_fsm.v:182`) matches the golden verdict for that image. Reads return 0. |
| `+0x100..+0x40F` | `CNN_IMG` | 8×784 | WO | — | 784-byte image buffer (row-major, byte p = pixel value p, `golden_model/README.md:20`). Byte-addressed; word write to `+0x100+4k` packs pixels `4k..4k+3` into bytes `[7:0],[15:8],[23:16],[31:24]` (little-endian, `wstrb` lane-enables). Reads return 0. Core read port: 1-cycle registered read, `irom_addr[9:0]` (with `img_idx=0` the core's image address is the in-image offset 0..783, `arch.md:506`). No read/write contention: CPU writes only while the core is parked (REQ-021). |

> `CNN_RESULT` deliberately exposes verdict as well as pred/conf so the firmware picks the line
> format (CORRECT/INCORRECT/TRASH) directly, but it must still print `expected %u` from its own
> label copy (read from vec_rom) — the two agree because `CNN_EXP` was written from that same
> label (PLAN.md §4.3).

## 7. Requirements

The full requirement set (32 items, all `priority: must`) is in `requirements.yaml`. Categories:

| Category | REQ-IDs |
|---|---|
| Functional — SoC scope, CPU, boot | REQ-001, REQ-002, REQ-003, REQ-004 |
| Interface — AXI contract, decode, memory map | REQ-005, REQ-006, REQ-007, REQ-008, REQ-009, REQ-010, REQ-011, REQ-012 |
| Interface — peripherals | REQ-013, REQ-014, REQ-015 |
| Interface — CNN slave | REQ-016, REQ-017, REQ-018, REQ-019, REQ-020 |
| Functional — CNN integration | REQ-021, REQ-022, REQ-023 |
| Functional — firmware behaviour | REQ-024, REQ-025, REQ-026, REQ-027 |
| Clocking / Reset | REQ-028, REQ-029 |
| Interface — widths | REQ-030 |
| Performance | REQ-031 |
| Compliance | REQ-032 |

## 8. Error, Interrupt and Exception Behaviour

- **Interrupts: none in v1.** `ENABLE_IRQ=0`, `irq` tied to `32'd0` (REQ-027). The CPU never
  vectors to `PROGADDR_IRQ`; the mis-armed-IRQ failure class is designed out
  (`fe-firmware/SKILL.md:90-96`). The `trap` output is observed by the TB and must never assert
  during a healthy run (CATCH_MISALIGN/CATCH_ILLINSN=0, firmware trusted).
- **Unmapped bus addresses:** read returns 0, write ignored, handshake completes (REQ-006) — the
  CPU never hangs on any address (PLAN.md R2).
- **UART_TX write while BUSY:** byte dropped (`uart_tx` samples `utx_valid` only in IDLE,
  `uart_tx.v:59`); firmware polls `UART_STAT[0]` first (REQ-014).
- **START while BUSY or PARK:** ignored (REQ-016).
- **PARK written mid-inference (abort):** core held in synchronous reset immediately (ctrl_fsm
  returns to `ST_CONV1`, `img_idx=0`, all counters 0 — defined state, no X); partial results
  discarded; `BUSY`/`DONE` cleared. Re-start requires a fresh START after PARK=0 (REQ-016).
- **TRASH classification** (confidence < 50, `ctrl_fsm.v:182`) is a defined, always-legal third
  output state, not an error (cnn REQ-016 precedent).
- **FSM illegal states:** ctrl_fsm recovers to `ST_CONV1` via `default:` (cnn REQ-035); uart_tx
  recovers to IDLE (cnn REQ-024); the bridge/sequencer/interconnect shall include safe `default:`
  arcs (REQ-032).

## 9. Power and Area Targets

Not specified by the brief and not load-bearing for this small SoC (single-issue RV32I, one MAC,
memories dominate). No numeric power/area targets are set; fe-arch's `power_plan.md` shall
document a single always-on domain with no clock gating (cnn precedent). Qualitative area driver:
memories — SRAM 128 KB, vec_rom 78,500 B, bootrom 4 KB, weight_rom 26,698×16 (~53 KB), sigmoid_lut
65,536×8 (64 KB), fm_ram 7,840×16 (~15 KB), image_buffer 784×8. No gate budget exists to
contradict; §3 arithmetic sanity checks pass (single 100 MHz domain, one outstanding transaction,
no throughput ceiling).

## 10. IP Reuse Plan

| IPR-ID | Block | Decision | Source | Licence | Status |
|---|---|---|---|---|---|
| IPR-001 | `picorv32_axi` (+ `picorv32` core + `picorv32_axi_adapter`) | reuse (verbatim, no adapter of our own) | `skill-tests/ex6/rtl/picorv32.v` L2517/L62/L2731 (local copy, read this session) | ISC (file header, © 2015 Claire Xenia Wolf) | verified |
| IPR-002 | CNN inference leaves: `ctrl_fsm`, `mac_datapath`, `win_addr_gen`, `fm_ram`, `weight_rom`, `sigmoid_lut` | reuse (byte-for-byte, zero edits) | `cnn/rtl/*.v` (project-internal; `rtl_manifest.yaml:34-46` status complete) | project-internal | verified |
| IPR-003 | `uart_tx` (APB UART shell) | reuse (byte-for-byte, `CLK_DIV` parameter) | `cnn/rtl/uart_tx.v` (project-internal, verified per `rtl_manifest.yaml:43`) | project-internal | verified |
| IPR-004 | Frozen golden vectors + LUT: `weights.hex`, `images.hex`, `labels.hex`, `expected.hex`, `expected_outputs.txt`, `sigmoid_lut.hex` | reuse (frozen data, `$readmemh`) | `cnn/arch/golden_model/` + `cnn/rtl/sigmoid_lut.hex` (project-internal, FROZEN) | project-internal | verified |

No external (GitHub) search was executed: the binding brief directs verbatim reuse of local,
already-verified project sources, which is stronger than any external candidate; no external repo
URL or licence is claimed anywhere in this spec. All other blocks (`cnn_soc`, `axi_lite_
interconnect`, `bootrom`, `sram`, `vec_rom`, `axi2apb`, `apb_uart`, `apb_gpio`, `cnn_axi_slave`,
`cnn_infer`, `image_buffer`, firmware, SoC TB) are **custom** (PLAN.md Appendix A) — no block is
`undecided`.

## 11. Assumptions (ASM-###)

| ASM-ID | Statement | Requires confirmation |
|---|---|---|
| ASM-001 | Minimum reset assert width = 2 `clk` cycles (SoC TB asserts ≥ 10 cycles at start, `PLAN.md §9` / ex6 precedent). | true |
| ASM-002 | Core clock = exactly 100.000 MHz (10.000 ns), matching the CNN's nominal 100 MHz (`arch.md:564-570`). | true |

Both are cosmetic/timing defaults with **zero effect on the bit-exact datapath contract**
(mirroring `cnn/spec/spec.md §11`). `UART_CLK_DIV=868`, `PROGADDR_RESET=0x0000_0000`,
`STACKADDR=0x0003_0000` are NOT assumptions: they are explicit binding values from the approved
plan (PLAN.md §5, §7). Per `spec_manifest.yaml`, ASM-001/002 are listed in `unconfirmed_
assumptions` with `assumptions_acknowledged: true` (cnn precedent) so fe-arch may proceed without
a human round-trip.

## 12. Open Issues (OI-###)

None. All PLAN.md §11 open questions (OQ1..OQ7) were resolved by the project owner and are
recorded in the PLAN.md Decision Record (2026-08-26); those decisions are binding requirements
above, not open issues. Explicit v2 scope-out (not open issues): IRQ (ENABLE_IRQ=1), DMA, weights
via CPU into SRAM, camera input/CDC, `led_ctrl` re-instantiation, fusesoc `.core` packaging
(OQ6: plain Makefile + iverilog flow for v1).

## 13. Verification Closure Criteria

See `verification_plan.md` §5 for the full countable list. Headline: G1 UART diff vs the first
100 lines of `expected_outputs.txt` = 0 mismatches; G2 `CNN_RESULT`/`CNN_EXP` vs `expected.hex` =
0 mismatches over 100 images; G3 LED encoding = 0 mismatches at all 100 presented instants;
G4 reset hygiene (led==0, uart_tx==1 during reset, no X/Z after release) = 0 violations; G5 boot
liveness within the bounded budgets; plus 0 orphan REQs/VP items and an `iverilog -g2001`
compile-only clean gate.

## 14. Glossary

- **Simplified AXI4-Lite** — the picorv32_axi adapter's reduced AXI master: AW+W issued together,
  completion = `bvalid||rvalid`, no `BRESP`/`RRESP`/ID/region signals (`picorv32.v:2731-2808`).
- **Park / parked** — holding `cnn_infer`'s core `rst_n_core=0` (synchronous reset) so the
  free-running ctrl_fsm stays at `ST_CONV1`/`img_idx=0`; the single-shot mechanism (REQ-021).
- **Bootrom-bake** — firmware `.hex` loaded into the bootrom via parameterized `$readmemh`
  (`fe-firmware/SKILL.md:56-58`); executes in place.
- **Pure-ROM image** — firmware with 0 bytes `.data` and 0 bytes `.bss`; constants in `.rodata`,
  variables on the stack (`fe-firmware/SKILL.md:139-141`).
- **vec_rom** — the read-only vector source region preloaded from the frozen `images.hex`/
  `labels.hex`; the CPU's image/label source; stand-in for a future camera/DMA (OQ1).
- **Single-shot** — exactly one inference (image index 0) per START (REQ-021).
- **verdict** — 0=CORRECT, 1=INCORRECT, 2=TRASH (cnn REQ-016, `ctrl_fsm.v:182-183`).
- **Golden stream** — `cnn/arch/golden_model/expected_outputs.txt`; the byte-exact UART contract
  (first 100 lines = the demo set).
- **Q8.8** — 16-bit signed fixed point, 8 integer + 8 fractional bits (cnn arithmetic contract).
