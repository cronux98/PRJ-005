# cnn_soc — MNIST CNN Accelerator SoC: Implementation Plan

Document ID: PLAN-CNN-SOC-v1.0 | Stage: pre-fe-spec (design consultation) | Date: 2026-08-26
Scope: PRJ-005 Milestone **M9** (SoC integration) — `ROADMAP.md:82`, `ROADMAP.md:91-120`
Status: **PLAN ONLY** — no RTL/firmware written yet. This document is the executable brief for the
`fe-spec → fe-arch → fe-rtl → fe-firmware` chain.

> **Grounding note.** Every design statement below cites the file(s) it is derived from. Facts that
> could not be fully verified from the repository are collected in **§11 Open Questions**, never
> guessed. This is a read-only consultation: no existing RTL, doc, or firmware is modified.

---

## 1. Executive Summary

**Goal.** Wrap the verified, bit-exact `cnn/` MNIST engine (96.35%, 200/200 bit-exact, cocotb 19/19
— `ROADMAP.md:21`) in a small RISC-V SoC so that **C firmware boots from a bootrom, feeds one image
at a time to the CNN over an AXI4-Lite bus, reads back the result registers, and prints the exact
golden UART line + drives LEDs** — replacing the `$readmemh` + free-running-testbench flow
(`cnn/spec/spec.md:37`, `spec.md:66-73`) with a real CPU boot flow (`cnn_soc/README.md:5-8`).

**Three load-bearing design decisions:**

1. **CPU = `picorv32_axi` (built-in AXI4-Lite master), not a custom bus.** The wrapper at
   `skill-tests/ex6/rtl/picorv32.v:2517` already contains the AXI master + adapter
   (`picorv32_axi_adapter`, `picorv32.v:2731`); we instantiate it verbatim, matching
   `cnn_soc/README.md:12-14`. This is a *simplified* AXI4-Lite (no `BRESP`/`RRESP`/IDs — see the
   adapter's port list, `picorv32.v:2731-2767`), which makes the interconnect and slaves small.

2. **Do not touch the bit-exact core; rebuild the top from its verified leaves + one new writable
   image buffer.** The verified `cnn_npu` (`cnn/rtl/cnn_npu.v`) is a sealed free-runner whose only
   outputs are `led`/`uart_tx` (`cnn_npu.v:31-36`). A new inference top re-instantiates the
   verified leaf blocks *with the exact wiring of `cnn_npu.v:99-233`*, swaps `image_rom` → a
   CPU-writable `image_buffer`, drives the label port from a CPU register, and taps the already-
   existing result ports (`ctrl_fsm` `lf_pred`/`lf_conf`/`lf_verdict`, `ctrl_fsm.v:189-193`). The
   MAC/pool/FC/sigmoid datapath — the part that was proven bit-exact — is reused byte-for-byte.

3. **Single-shot by reset-parking the free-runner; CPU owns UART/LED text.** The free-running FSM
   auto-increments `img_idx` and loops forever (`ctrl_fsm.v:461-469`, `spec.md:66`). We convert it
   to single-shot by holding the core in its synchronous reset until `START`, then re-parking it the
   moment `lc_present` pulses (`ctrl_fsm.v:198`), so exactly one image (index 0, addressing the
   784-byte buffer) is processed. `uart_line_fmt`/`uart_tx`/`led_ctrl` move *out* of the core — the
   CPU formats the identical bytes and drives an APB UART + GPIO. This makes the SoC's UART stream
   diffable against the **same** golden `expected_outputs.txt` the IP-level TB uses.

**One-paragraph scope.** v1 delivers: `picorv32_axi` + a flat single-master AXI4-Lite decoder/mux;
a 4 KB bootrom (firmware baked) and a 128 KB SRAM (data/stack); a read-only "vectors ROM" preloaded
from the frozen `images.hex`/`labels.hex` (the CPU's image source — stand-in for a future
camera/DMA); a CNN AXI4-Lite slave wrapper (CTRL/STATUS/RESULT/EXP_LABEL + 784-byte image buffer,
weights stay in internal ROM); an AXI→APB bridge feeding an APB UART (reusing `cnn/rtl/uart_tx.v`,
`CLK_DIV=868`) and APB GPIO/LED; and firmware + a full-SoC iverilog testbench that boots, runs 100
images, and diffs UART vs the first 100 lines of `cnn/arch/golden_model/expected_outputs.txt`. IRQ,
DMA, weight-from-SRAM, and camera input are explicitly **v2** (`README.md:15`, `README.md:27`).

---

## 2. Architecture & Block Diagram

Single clock domain `clk` (100 MHz nominal), single active-low **synchronous** reset `rst_n` — the
same discipline the CNN mandates (`cnn/arch/arch.md:564-570`, `spec.md:126-135`) and that ex6 uses
(`ex6/rtl/ex6_soc.v:12`). `rst_n` drives the CPU's `resetn` and every slave's `rst_n` directly (as
in `ex6_soc.v:59`). No CDC (no camera yet — `README.md:28`).

```
                              cnn_soc  (top: cnn_soc.v — NEW)
  ┌──────────────────────────────────────────────────────────────────────────────────┐
  │  clk ─┬──────────────────────────────────────────────────────────────────────┐    │
  │ rst_n─┤ (active-low, synchronous — fans out to CPU.resetn and every slave)    │    │
  │       ▼                                                                        │    │
  │  ┌─────────────┐  AXI4-Lite master (simplified: no BRESP/RRESP/ID)            │    │
  │  │ picorv32_axi│  picorv32.v:2517  (PROGADDR_RESET=0x0, STACKADDR=SRAM top)   │    │
  │  │  RV32I      │  AW/W/B , AR/R  (picorv32.v:2549-2569)                        │    │
  │  └─────┬───────┘                                                              │    │
  │        │ mem_axi_{aw,w,b,ar,r}*                                               │    │
  │   ┌────▼─────────────────────────────────────────────────────┐               │    │
  │   │  axi_lite_interconnect (NEW): comb address decode +       │               │    │
  │   │  return mux. Single outstanding (CPU is single-issue),    │               │    │
  │   │  so NO arbitration/ID tracking needed.                    │               │    │
  │   └─┬────────┬──────────┬───────────┬───────────────┬─────────┘               │    │
  │     │0x0     │0x0001_0000│0x1000_0000│0x4000_0000    │0x5000_0000               │    │
  │     ▼        ▼          ▼           ▼               ▼                          │    │
  │ ┌───────┐ ┌──────┐ ┌─────────┐ ┌──────────────┐ ┌───────────────────────────┐ │    │
  │ │bootrom│ │ SRAM │ │ vec_rom │ │ axi2apb brdg │ │  cnn_axi_slave (NEW)       │ │    │
  │ │4 KB RO│ │128 KB│ │images+  │ │ (NEW)        │ │  CTRL/STATUS/RESULT/EXP    │ │    │
  │ │ f/w   │ │d/stk │ │labels RO│ │   │      │   │ │  + 784B image buffer       │ │    │
  │ │baked  │ │      │ │$readmemh│ │   ▼      ▼   │ │  ┌──────────────────────┐  │ │    │
  │ └───────┘ └──────┘ └─────────┘ │ APB UART APB │ │  │ cnn_infer (NEW top)  │  │ │    │
  │                                │ (uart_tx GPIO│ │  │  reuses verified     │  │ │    │
  │                                │  CLK_DIV     │ │  │  leaves + img_buffer │  │ │    │
  │                                │  =868) LED   │ │  └──────────────────────┘  │ │    │
  │                                └───┬──────┬───┘ └───────────────────────────┘ │    │
  └────────────────────────────────────┼──────┼─────────────────────────────────────┘  │
                                        ▼      ▼
                                     uart_tx  led[11:0]   (top-level output pins)
```

**cnn_infer internal (the reused datapath) — wiring copied from `cnn/rtl/cnn_npu.v:99-233`:**

```
  image_buffer(NEW,784×8, CPU-wr / core-rd, 1-cyc reg read like image_rom.v:27-30)
        │ irom_data
        ▼
  ┌──────────┐  wrom  ┌──────────┐  mac_a/b   ┌──────────────┐ mac_z ┌────────────┐
  │ weight_  │───────▶│          │───────────▶│ mac_datapath │──────▶│ sigmoid_lut│
  │ rom      │        │ ctrl_fsm │   mac_h ◀──│ (16×16,acc64)│  lut_ ├────────────┘
  │(int ROM, │◀──────▶│ (BLK-002)│◀───────────│  arch.md §5  │ data  │  (65536×8)
  │ weights. │ addrs  │ FSM-001  │            └──────────────┘       └────────────┘
  │ hex)     │        │          │  fmram      ┌──────────┐
  └──────────┘        │          │◀───────────▶│  fm_ram  │ (7,840×16, ping-pong §7.1)
                      │          │  wag_*      └──────────┘
   exp_label reg ────▶│lrom_data │───────────▶ win_addr_gen (comb addr gen, BLK-012)
   (from CPU)         └────┬─────┘
                           │ lf_pred/lf_conf/lf_verdict (ctrl_fsm.v:189-193), strobe lc_present (:198)
                           ▼
                    RESULT latch  +  single-shot sequencer (park core rst_n after lc_present)
```

`uart_line_fmt`, `uart_tx`, `led_ctrl`, `label_rom`, `image_rom` from `cnn_npu.v` are **not**
instantiated inside `cnn_infer` — UART/LED text is produced by the CPU; the image source is the
writable buffer; the label is a CPU register.

---

## 3. Memory Map (32-bit)

Base addresses follow `cnn_soc/README.md:33-39`, made exact and justified. All regions are naturally
aligned; the decoder keys on the top address bits.

| Base           | Size    | Region       | Access | Notes / grounding |
|----------------|---------|--------------|--------|-------------------|
| `0x0000_0000`  | 4 KB    | **bootrom**  | RO/exec| Reset vector. `PROGADDR_RESET` default `0x0000_0000` (`picorv32.v:2540`). Firmware `.text`+`.rodata` baked in (fe-firmware bootrom-bake, `fe-firmware/SKILL.md:56-58`). |
| `0x0001_0000`  | 128 KB  | **SRAM**     | RW     | `.data`/`.bss`/stack. Placed at `0x0001_0000` (not README's `0x1000`) mirroring the proven fe-firmware/ex3 layout (`fe-firmware/SKILL.md:109-113`) and leaving the bootrom room to grow. Stack top `0x0003_0000` → `STACKADDR`. |
| `0x1000_0000`  | ~78.5 KB| **vec_rom**  | RO     | Demo dataset the CPU feeds to the CNN: images `+0x0000..+0x1323F` (78,400 bytes, `images.hex`), labels `+0x13240..+0x132A3` (100 bytes, `labels.hex`). `$readmemh` from the frozen golden files (`golden_model/README.md:50-54`). Stand-in for a future camera/DMA (§6). |
| `0x4000_0000`  | window  | **AXI2APB**  | —      | APB peripheral window (`README.md:37`). |
| ├ `+0x0000_0000` | 8 B   | APB UART     | RW     | `+0x00` TX data (W), `+0x04` status (R). Pattern from `ex6_soc.v:108-111,160-170`. |
| └ `+0x0000_1000` | 4 B   | APB GPIO/LED | RW     | `+0x00` LED out. `README.md:37`. |
| `0x5000_0000`  | window  | **cnn_axi_slave** | RW| CNN control/data (`README.md:38-39`). Register map in §4. Image buffer at `+0x100` (784 B). |

Decode rule (combinational, mirrors `ex6_soc.v:150-166` but AXI-shaped): compare
`mem_axi_araddr[31:28]`/`awaddr[31:28]` → `0x0`=bootrom (with `[31:16]==0` sub-split for
SRAM at `0x0001_xxxx`), `0x1`=vec_rom, `0x4`=axi2apb, `0x5`=cnn. Unmapped → read `0`, write ignored,
handshake still completes (never hang the CPU).

---

## 4. Register Map

All registers are 32-bit, word-aligned, little-endian (RV32). Widths/fields are grounded in the CNN
result signals they carry.

### 4.1 APB UART (`0x4000_0000`)
| Offset | Name       | Width | R/W | Fields |
|--------|------------|-------|-----|--------|
| `+0x00`| `UART_TX`  | 8     | W   | `[7:0]` byte to transmit; write starts a frame (drives `uart_tx.utx_valid`/`utx_data`, `cnn/rtl/uart_tx.v:25-26`). |
| `+0x04`| `UART_STAT`| 1     | R   | `[0]` BUSY (= `!utx_ready` / `utx_busy`, `uart_tx.v:44-45`). Poll before write (as `ex6/sw/hello.c:9`). |

### 4.2 APB GPIO/LED (`0x4000_1000`)
| Offset | Name      | Width | R/W | Fields |
|--------|-----------|-------|-----|--------|
| `+0x00`| `GPIO_OUT`| 12    | RW  | `[11:0]` → top-level `led[11:0]`. Firmware chooses the encoding (recommended: reproduce `led_ctrl` scheme — `[9:0]` one-hot pred / 0 on TRASH, `[10]` fail, per `cnn/rtl/led_ctrl.v:66-71`). |

### 4.3 CNN AXI slave (`0x5000_0000`)
| Offset | Name        | Width | R/W | Fields (grounding) |
|--------|-------------|-------|-----|--------------------|
| `+0x00`| `CNN_CTRL`  | 2     | RW  | `[0]` START (1→0 auto or write-1-to-start: releases core park); `[1]` PARK/soft-reset (1 = hold core in sync reset). |
| `+0x04`| `CNN_STATUS`| 2     | RO  | `[0]` BUSY (= core `lc_busy`, `ctrl_fsm.v:187`); `[1]` DONE (set when `lc_present` latched a result, `ctrl_fsm.v:198`). Cleared on next START. |
| `+0x08`| `CNN_RESULT`| 18    | RO  | `[3:0]` pred (`lf_pred`=`best_idx`, `ctrl_fsm.v:189`); `[14:8]` confidence 0..100 (`lf_conf`, `ctrl_fsm.v:190`, `:179-180`); `[17:16]` verdict 0/1/2 (`lf_verdict`, `ctrl_fsm.v:193`, `:183`). |
| `+0x0C`| `CNN_EXP`   | 4     | WO  | `[3:0]` expected label for the current image; drives `ctrl_fsm.lrom_data[3:0]` (IFI-005 port, `ctrl_fsm.v:47`) so HW verdict (`ctrl_fsm.v:182`) matches golden. |
| `+0x100..+0x100+783` | `CNN_IMG` | 8×784 | WO | 784-byte image buffer (row-major pixel, byte p = value p, `golden_model/README.md:20`). Byte-addressed; word writes pack 4 pixels (little-endian, like `hex2words.py`). Read by the core as `irom_data` (8-bit, `image_rom.v:21`). |

> `CNN_RESULT` deliberately exposes verdict as well as pred/conf so the firmware can pick the line
> format (CORRECT/INCORRECT/TRASH) directly, but it must still print `expected %u` from its own
> label copy — the two agree because `CNN_EXP` was written from that same label.

---

## 5. picorv32_axi Integration

**Instantiate `picorv32_axi` (`picorv32.v:2517`) — not the native core, not a custom bus** — per
`README.md:12-14`. Its AXI4-Lite master ports are `picorv32.v:2549-2569`; its parameter block is
`picorv32.v:2517-2542`.

**Recommended parameters** (grounded in the ex6 RV32I config `ex6_soc.v:45-56`, adjusted for this map):

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `PROGADDR_RESET` | `32'h0000_0000` | Boot from bootrom (default, `picorv32.v:2540`). |
| `STACKADDR`      | `32'h0003_0000` | Top of the 128 KB SRAM (`0x0001_0000`+`0x2_0000`). Startup also sets `sp` (`ex6/sw/hello.c:21`). |
| `PROGADDR_IRQ`   | `32'h0000_0010` | Default (`picorv32.v:2541`); unused in v1 (`ENABLE_IRQ=0`). |
| `ENABLE_MUL` / `ENABLE_DIV` | `0` / `0` | Firmware is `-march=rv32i`; decimal `/10`,`%10` for `%u` resolve via libgcc soft-routines. Matches `ex6_soc.v:46-47`. |
| `COMPRESSED_ISA` | `0` | rv32i, no `C`. |
| `ENABLE_IRQ`     | `0` | **Polling for v1** (see below); IRQ deferred to v2. Matches `ex6_soc.v:48`. |
| `ENABLE_COUNTERS`| `0` | Area (`ex6_soc.v:49`). |
| `CATCH_MISALIGN` / `CATCH_ILLINSN` | `0` / `0` | Small-area config (`ex6_soc.v:51-52`); firmware is trusted. (Defaults are `1`, `picorv32.v:2527-2528` — either is acceptable.) |
| `BARREL_SHIFTER`, `TWO_CYCLE_*` | defaults / `1` | Optional area/timing knobs; not load-bearing. |

**Do NOT pass `LATCHED_MEM_RDATA` or `mem_la_*`** — those belong to the *native* `picorv32`
(`ex6_soc.v:56,68-72`); `picorv32_axi`'s port/param list (`picorv32.v:2517-2610`) does not include
them. Connect `clk`, `resetn(=rst_n)`, and tie off PCPI (`pcpi_wr=0,pcpi_rd=0,pcpi_wait=0,
pcpi_ready=0`), `irq=32'd0`, leave `eoi`/`trace_*`/`trap` open or observed (as `ex6_soc.v:73-84`).

**Reset strategy.** Single `rst_n` → `resetn`. Synchronous throughout (§2). Hold reset ≥ a few
cycles at TB start (`ex6_tb.v:118-119` holds 10 cycles).

**Polling vs IRQ (v1 recommendation): polling.** The firmware busy-waits on `CNN_STATUS[1]` (DONE)
and `UART_STAT[0]` (busy), exactly like ex6 polls UART (`ex6/sw/hello.c:9`). Rationale: (a) the CNN
runs ~667,208 compute cycles/image (`arch.md:481`) — an IRQ saves nothing a poll loop costs; (b)
`fe-firmware/SKILL.md:90-96` warns that mis-armed IRQs on picorv32 vector to `0x10` and hang; polling
sidesteps that whole failure class for v1. IRQ (`ENABLE_IRQ=1`, `PROGADDR_IRQ`) is a clean v2 add.

---

## 6. CNN Wrapper Design (minimal touch to the verified core)

**Principle:** the bit-exact datapath is reused *unmodified*; only the I/O skin changes. Two new
files: `cnn_infer.v` (the reused-leaf inference top) and `cnn_axi_slave.v` (the MMIO shell).

### 6.1 `cnn_infer.v` — reused leaves + writable image buffer
Re-instantiate, with the **exact wiring of `cnn/rtl/cnn_npu.v:99-233`**, these verified blocks:
`weight_rom` (`cnn_npu.v:99`), `sigmoid_lut` (`:135`, note structural `addr=mac_z`, `:140`),
`mac_datapath` (`:144`), `win_addr_gen` (`:156`), `fm_ram` (`:126`), `ctrl_fsm` (`:175`). Changes vs
`cnn_npu.v`:

- **Replace `image_rom` with `image_buffer` (NEW).** 784×8 RAM, **1-cycle registered read** identical
  to `image_rom.v:27-30` (so `ctrl_fsm`'s ADDR→ACC timing, `arch.md:401-402`, is preserved), plus a
  synchronous CPU write port used only while the core is parked (no read/write contention). Core read
  address = `irom_addr[9:0]` (with `img_idx=0`, `win_addr_gen`'s image address is the in-image offset
  0..783 — `arch.md:506` `img_idx*784+…` with `img_idx=0`).
- **Drop `label_rom`; drive `ctrl_fsm.lrom_data` from the `CNN_EXP` register.** `ctrl_fsm` exposes
  `lrom_addr`/`lrom_data` as ports (`ctrl_fsm.v:46-47`); feed `lrom_data <= {4'd0, exp_label}` so the
  combinational verdict (`ctrl_fsm.v:182-183`) is correct for the current image.
- **Drop `uart_line_fmt`, `uart_tx`, `led_ctrl`.** UART/LED text is produced by the CPU (§8). Tie
  `ctrl_fsm.lf_done` so `PRESENT` completes cleanly (feed `lf_done=1`, or the single-shot sequencer's
  own strobe) — `ctrl_fsm.v:450-454` needs `lf_done` to leave `PH_WAIT_UART`.
- **Expose result ports:** `pred=lf_pred`, `conf=lf_conf`, `verdict=lf_verdict`, `busy=lc_busy`,
  `present=lc_present` (all existing `ctrl_fsm` outputs, `ctrl_fsm.v:186-198`).

Weights stay in the internal `weight_rom` (`$readmemh weights.hex`, `weight_rom.v:29`) for v1 —
`README.md:27` ("v1 = internal ROM"). The sigmoid LUT stays internal (`sigmoid_lut.hex`,
`arch.md:150`). So v1 still uses `$readmemh` for *weights + LUT*; the CPU-boot flow replaces the
*program + image + label* path (firmware in bootrom, image via buffer, label via register).

### 6.2 `cnn_axi_slave.v` — MMIO shell + single-shot sequencer
- **Registers** per §4.3, on the simplified AXI4-Lite slave handshake (provide `awready`/`wready`/
  `bvalid` for writes, `arready`/`rvalid`/`rdata` for reads — the adapter needs no `BRESP`/`RRESP`,
  `picorv32.v:2731-2767`). One outstanding, so a 2-state accept FSM suffices.
- **Single-shot sequencer (start/done handshake):**
  1. Idle/park: hold `cnn_infer` core `rst_n_core=0` (parked; `ctrl_fsm` resets to `ST_CONV1`,
     `img_idx=0`, `ctrl_fsm.v:280-295`).
  2. CPU writes `CNN_EXP`, fills `CNN_IMG[0..783]`, then `CNN_CTRL[0]=START`.
  3. START → deassert park (`rst_n_core=1`); `BUSY=1`, `DONE=0`. Core runs one full inference
     (~667,208 cycles, `arch.md:481`).
  4. On `present` pulse (`lc_present`, `ctrl_fsm.v:198`): latch `pred/conf/verdict` into `CNN_RESULT`,
     set `DONE=1`, `BUSY=0`, **re-assert park** — this stops the core before `img_idx` advances to 1
     (`ctrl_fsm.v:463`), giving exact single-shot from a free-running core with **zero core edits**.
  5. CPU polls `DONE`, reads `CNN_RESULT`, proceeds to the next image.
- `HOLD_CYCLES`/`BLINK_CYCLES` are irrelevant here (we park before HOLD); leave core defaults.

**Why not just wrap `cnn_npu` whole?** `cnn_npu` has only `led`/`uart_tx` outputs (`cnn_npu.v:34-35`)
— no result bus and no image input — so a register-mapped read/verdict flow is impossible without
re-topping. Rebuilding from leaves is the minimal *and* the only clean option.

---

## 7. AXI2APB Bridge + APB Peripherals

**Bridge (`axi2apb.v`, NEW).** Converts one AXI4-Lite transaction in the `0x4000_0000` window to an
APB access (`PSEL/PENABLE/PWRITE/PADDR/PWDATA/PRDATA/PREADY`). Because the CPU is single-issue and the
AXI is simplified, the bridge is a ~4-state FSM (IDLE→SETUP→ACCESS→resp) with no buffering — it
asserts AXI `bvalid`/`rvalid` when APB `PREADY` returns. `PADDR[11:0]` selects UART (`+0x000`) vs GPIO
(`+0x1000`) sub-region.

**APB UART (`apb_uart.v`, NEW — thin shell over the verified `cnn/rtl/uart_tx.v`).** Instantiate
`uart_tx #(.CLK_DIV(868))` (`uart_tx.v:19-20`; 868 = round(100e6/115200), `arch.md:224`). Map:
- write `UART_TX` → pulse `utx_valid` with `utx_data=PWDATA[7:0]` for one cycle (respecting the
  valid/ready contract, `uart_tx.v:11-13` / IFI-007, `arch.md:559-562`);
- read `UART_STAT` → `{31'b0, utx_busy}` (`uart_tx.v:45`).
Reuse is byte-for-byte; `uart_tx.v` is already verified (`rtl_manifest.yaml:43`). (`ex6_uart_tx.v`
with `BAUD_DIV` is an equivalent reference pattern, `ex6/rtl/ex6_uart_tx.v:4-13`.)

**APB GPIO/LED (`apb_gpio.v`, NEW).** A 12-bit output register → top-level `led[11:0]`, exactly the
`ex6_soc.v:116,171-172,180` GPIO pattern widened to 12 bits. Optionally reuse `led_ctrl.v` in a later
variant, but for v1 the firmware writes the final 12-bit pattern directly (simpler; no `lc_present`
handshake needed on the CPU side).

---

## 8. Boot Flow & Firmware

**Boot flow.** Reset → CPU fetches at `PROGADDR_RESET=0x0` (bootrom) → `start.S` boot stub
(`li sp, 0x0003_0000; jal main`, per `fe-firmware/SKILL.md:61-62`, `ex6/sw/hello.c:21`) → `main()`:
init nothing special (polling), then the per-image loop. Firmware `.text/.rodata` live in the bootrom
(bake); `.data/.bss/stack` in SRAM. No copy-to-SRAM step is needed if `.text` executes in place from
the bootrom (picorv32 fetches instructions over the same AXI master, `picorv32.v:2562-2569`); a
copy-to-SRAM optimization is possible later but out of scope for v1.

**C structure** (`sw/` — new; modeled on `ex6/sw/hello.c` + `fe-firmware/SKILL.md:37-49`):
- `start.S` — `.section .text.start`, KEEP-first (`fe-firmware/SKILL.md:61`, `:92`); sets `sp`, calls `main`.
- `soc.h` — the §3/§4 base addresses + field macros (as `ex6/sw/hello.c:3-5`).
- `drv_uart.c` — `uart_putc` (poll `UART_STAT[0]` then write `UART_TX`, `ex6/sw/hello.c:7-11`),
  `uart_puts`, plus `uart_putu`/`uart_put03u` decimal formatters (no libc).
- `drv_cnn.c` — `cnn_run(img_ptr, exp_label, *pred, *conf, *verdict)`: write `CNN_EXP`, copy 784 bytes
  to `CNN_IMG`, set `CNN_CTRL.START`, poll `CNN_STATUS.DONE`, read `CNN_RESULT`.
- `main.c` — for `i` in 0..99: read `vec_rom` image `i` (`0x1000_0000+i*784`) and label `i`
  (`0x1000_0000+0x13240+i`); `cnn_run(...)`; print the exact line (below); write LED via `GPIO_OUT`;
  then spin forever after image 99 (as `ex6/sw/hello.c:31-33`).

**UART output format (byte-exact gate).** The firmware must emit, per image, exactly (from
`spec.md:111-113`, `uart_line_fmt.v:89-207`, and confirmed against `expected_outputs.txt`):
```
verdict 0: IMG %03u: This is number %u | confidence %u%% | expected %u | CORRECT\n
verdict 1: IMG %03u: This is number %u | confidence %u%% | expected %u | INCORRECT\n
verdict 2: IMG %03u: NOT A NUMBER | confidence %u%% | expected %u | TRASH\n
```
`%03u` = image index zero-padded to 3 digits; other `%u` unpadded; single `0x0A`, no `0x0D`
(`spec.md:116-118`; golden `printf`, `golden_ref_model.c:240,243`). Example golden line 1:
`IMG 000: This is number 7 | confidence 94% | expected 7 | CORRECT` (`expected_outputs.txt:1`). Because
the CPU computes the same `pred/conf/verdict` the CNN's own `uart_line_fmt` would (same HW result
regs), the byte stream is identical to the IP-level golden — unifying the contract.

**Linker script sketch** (`link.ld`, from `ex6/sw/link.ld` + `fe-firmware/SKILL.md:67`):
```
MEMORY { rom (rx): ORIGIN = 0x00000000, LENGTH = 0x1000     /* bootrom */
         ram(rwx): ORIGIN = 0x00010000, LENGTH = 0x20000 }  /* SRAM   */
SECTIONS { .text : { KEEP(*(.text.start)) *(.text*) } > rom
           .rodata : { *(.rodata*) } > rom
           .data : { *(.data*) } > ram   .bss : { *(.bss*) } > ram
           /DISCARD/ : { *(.eh_frame*) *(.comment*) } }
```
(For a pure-ROM image with zero `.data`/`.bss`, the "zero-data dual-injection" pattern of
`fe-firmware/SKILL.md:139-141` lets the *same* image boot from ROM (bake) or SRAM (preload).)

**Hex generation (fe-firmware flow, `SKILL.md:52-58`, `ex6/sw/Makefile:11-19`):**
`gcc -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles -Os -ffreestanding` → `ld -m elf32lriscv -T
link.ld` (`SKILL.md:26-27,91`) → `objcopy -O verilog` (byte stream) → `scripts/hex2words.py`
(`ex6/scripts/hex2words.py`) → word-format `.hex` for `$readmemh` into the bootrom (and SRAM if
preloaded). Toolchain is fixed: `riscv64-unknown-elf-gcc 10.2.0` (`SKILL.md:24`); gcc-10 has no Zicsr
— not needed here (no CSR/IRQ in v1, cf. `SKILL.md:133`).

---

## 9. Verification Plan

**Primary gate — full-SoC iverilog TB (`tb_cnn_soc.v`, NEW).** Structure from `ex6/tests/ex6_tb.v`:
1. Instantiate `cnn_soc` (`clk`, `rst_n`, `uart_tx`, `led`); 100 MHz clock; hold `rst_n` low ≥ a few
   cycles then release (`ex6_tb.v:24,118-119`).
2. **Preload firmware** into the bootrom array via `$readmemh` of the built `.hex` (bootrom-bake). If
   using SRAM preload instead, the preload module must be a **second top** (`iverilog … -s cnn_soc -s
   sram_preload`) — `iverilog` only runs `initial` of top modules (`SKILL.md:88-90`). `vec_rom` loads
   `images.hex`/`labels.hex` via its own `$readmemh` (paths relative to run dir, as the CNN ROMs do,
   `arch.md:540-551`).
3. **Independent UART decoder** (bit-level, not the DUT's own FSM) captures `uart_tx` to
   `uart_captured.txt` — reuse the `ex6_tb.v:43-108` 8N1 receiver, or the CNN's
   `verify/tb_common/uart_monitor.vh` capture approach (`tb_mnist_top.v:14-17,129-132`). Self-calibrate
   bit time from the first char (`SKILL.md:71-76`).
4. Run until 100 lines captured (or watchdog, `ex6_tb.v:141-145` / `tb_mnist_top.v:58-64`).

**Pass gates (countable):**
- **G1 — UART byte-exact:** `diff` captured UART vs the **first 100 lines** of
  `cnn/arch/golden_model/expected_outputs.txt` → 0 mismatches. (That file is 10,003 lines = 10,000
  images + summary; the demo set is the first 100, `expected_outputs.txt:1-5`, tail summary
  `…first 100 images -> …images.hex`.) This is the SoC analog of `VP-TOP-004`
  (`verification_plan.md:34`).
- **G2 — result registers:** optionally cross-check `CNN_RESULT` per image vs `expected.hex`
  (4 words/image: pred,conf,exp,verdict — `expected.hex` head `0007/005e/0007/0000` = 7/94/7/CORRECT),
  via a hierarchical probe, mirroring `tb_mnist_top.v:53-55,173-180`.
- **G3 — LED:** at each image's presented instant, `led` matches the firmware's chosen encoding
  (if reproducing `led_ctrl`: `led[9:0]` one-hot pred / 0 on TRASH, `led[10]`=fail — `led_ctrl.v:66-69`,
  `tb_mnist_top.v:195-197`).
- **G4 — reset hygiene:** `led==0` and `uart_tx==1` throughout reset; no X/Z on outputs after release
  (`tb_mnist_top.v:66-78`, `verification_plan.md:31`).
- **G5 — boot liveness:** CPU reaches `main` and drives the first UART frame within a bounded cycle
  budget (watchdog, `ex6_tb.v:141-145`).

**How it complements the existing IP-level TBs.** The CNN unit TB `tb_mnist_top.v` (200-image
bit-exact + LED + FSM coverage) and cocotb stage-2 remain the **IP-level gate** on the datapath
(`README.md:45`, `ROADMAP.md:21`). The SoC TB is a **new, higher layer**: it proves the *CPU-bus
integration* (address decode, AXI4-Lite handshake, image-buffer write path, single-shot start/done,
CPU-formatted UART) — the layer directed/formal tests can't reach, exactly the value fe-firmware cites
for its POST walker catching an integration bug 11/11 directed tests missed (`SKILL.md:16-18`). The
datapath is unchanged, so G1 passing at SoC level *and* `tb_mnist_top` passing at IP level together
close the loop.

**fusesoc packaging (optional, from `ex6/ex6_soc.core`).** A `cnn_soc.core` (CAPI=2) with `sim`
(iverilog boot + UART diff), `lint` (verilator), and a `firmware` generator target
(`ex6_soc.core:59-113`) gives the same one-command flow ex6 has.

---

## 10. Implementation Milestones (ordered, entry/exit gates)

| Phase | Work | Entry gate | Exit gate |
|-------|------|-----------|-----------|
| **P0 Spec freeze** (fe-spec) | Freeze §3 map, §4 registers, single-shot handshake, UART contract = golden first-100. | This plan approved by Rinri (`README.md:3`). | `spec.md`+`requirements.yaml` for cnn_soc; every register/addr traced to a REQ. |
| **P1 Infra RTL** (fe-arch/fe-rtl) | `cnn_soc.v` top, `axi_lite_interconnect.v`, `bootrom.v`, `sram.v`, `vec_rom.v`, `axi2apb.v`, `apb_uart.v`, `apb_gpio.v`. | P0 done. | `iverilog -g2005` compile-only clean (as `rtl_manifest.yaml:69`); an "AXI hello": CPU boots a stub, toggles GPIO + one UART char (de-risks `picorv32_axi`, §11-R1). |
| **P2 CNN wrapper** (fe-rtl) | `cnn_infer.v` (reused leaves + `image_buffer.v`), `cnn_axi_slave.v` (regs + single-shot sequencer). | P1 AXI-hello passes; CNN `filelist.f` leaves available (`cnn/filelist.f`). | Bench-drive `cnn_infer` (no CPU): poke one image + label, pulse START, check `CNN_RESULT`==`expected.hex[0..3]` (7/94/7/CORRECT). |
| **P3 Firmware** (fe-firmware) | `start.S`, drivers, `main.c`, `link.ld`, build → `.hex`. | P2 wrapper result-correct. | Firmware builds via `ld -m elf32lriscv` (`SKILL.md:91`); boots in TB; first UART line == `expected_outputs.txt:1` byte-exact. |
| **P4 SoC verification** | `tb_cnn_soc.v` + independent UART decoder + diff harness; (opt) `cnn_soc.core`. | P3 first line matches. | **G1–G5** all pass: 100/100 UART lines vs golden first-100, LED/reset checks, bounded runtime. |
| **P5 Docs/evidence** | WORKLOG, run dir, iterations.log, README v1 (drop "draft"), commit. | P4 green. | Evidence committed per methodology (`ROADMAP.md:130-133`). |

Runtime expectation: ~667k cycles/image × 100 ≈ 66.7M compute cycles (`arch.md:481,487-496`) + CPU
overhead (image copy ≈ 78,400 writes ≈ ~1M cycles, negligible) → tens of seconds wall-clock under
`iverilog`, the same order as the IP-level soak (`arch.md:490-496`).

---

## 11. Risks & Open Questions

**Risks (with mitigation):**
- **R1 — `picorv32_axi` under iverilog is unproven *in these repos*.** ex6 exercised the **native**
  `picorv32` (`ex6_soc.v:45`), not `picorv32_axi`, though both live in the same iverilog-clean file
  (`picorv32.v`). *Mitigation:* the P1 "AXI hello" smoke test gates the whole flow on
  `picorv32_axi`+interconnect actually running before any CNN work.
- **R2 — Simplified AXI4-Lite (no `BRESP`/`RRESP`/ID).** The adapter (`picorv32.v:2731-2808`) issues
  AW+W together (`:2773,:2781`) and expects `mem_ready = bvalid||rvalid` (`:2785`). Slaves/bridge must
  match this exact contract; a slave that waits for a nonexistent `BRESP` will hang. *Mitigation:*
  specify the handshake explicitly in fe-spec; unmapped addresses must still complete (§3).
- **R3 — Single-shot park timing.** Latching on the 1-cycle `lc_present` strobe (`ctrl_fsm.v:198`)
  and re-asserting park must not race the core's own edge. *Mitigation:* `lc_present` is
  architecturally exactly 1 cycle (`ctrl_fsm.v:195-199`, `arch.md:427-434`); latch it registered and
  park on the following cycle — the result regs (`best_val/best_idx`) are stable from FC2's last WB
  through PRESENT (`ctrl_fsm.v:176-178`).
- **R4 — Bootrom size.** 4 KB must hold `.text`+`.rodata`. The POST-style firmware is ~300 words
  (`SKILL.md:34`); this firmware adds decimal formatting + a copy loop — still comfortably < 4 KB, but
  if it overflows, grow the bootrom (trivial, `SKILL.md:110-111`).
- **R5 — `$readmemh` path resolution.** vec_rom + weight_rom + sigmoid_lut load by relative path
  (`cnn_defs.vh`, `arch.md:540-551`); the TB must run from a root where those paths resolve (the CNN
  convention, `tb_mnist_top.v:22`). *Mitigation:* fix run-dir in the `.core`/Makefile, or pass
  absolute paths as vlogparams (as `ex6_soc.core:170-175` does for `BOOT_HEX`).
- **R6 — UART byte-exactness from CPU formatting.** Any deviation (extra CR, wrong padding, space
  around `|`) fails G1. *Mitigation:* hard-code the format strings from `spec.md:111-113` and unit-test
  the formatter against `expected_outputs.txt:1-5` before the full run.

**Open questions (could not be resolved from the files — decide in fe-spec):**
- **OQ1 — Image source.** This plan adds a `vec_rom` slave preloaded from `images.hex`/`labels.hex`
  so the CPU has data to feed. The README says the buffer "replaces image_rom `$readmemh`"
  (`README.md:24`) but does **not** state where the CPU obtains pixels. Confirm: dedicated `vec_rom`
  (this plan) vs pixels packed into SRAM vs keeping an internal image_rom addressed by a CPU
  `img_idx` register. (Recommend `vec_rom` — reuses frozen vectors verbatim, mirrors a future camera
  source.)
- **OQ2 — Boot mode.** Bootrom-bake (this plan, matches README map) vs ex6-style single unified SRAM
  at `0x0` with firmware preloaded (`ex6_soc.v:95-103`). fe-firmware supports both (`SKILL.md:56-58`).
- **OQ3 — SRAM size.** README says 128 KB (`README.md:36`); with weights in ROM and image in the CNN
  buffer, firmware needs only KBs of `.data`/stack. Confirm 128 KB (headroom for v2 weight-in-SRAM,
  53 KB — `README.md:27`) vs a smaller v1 SRAM.
- **OQ4 — LED encoding owner.** Firmware writes the 12-bit pattern (this plan) vs re-instantiating
  `led_ctrl.v` inside `cnn_axi_slave` driven by the core's `lc_*` (`led_ctrl.v:24-27`). Firmware-side
  is simpler; HW-side reproduces the exact blink behavior. Confirm.
- **OQ5 — SRAM base.** This plan uses `0x0001_0000` (fe-firmware/ex3 precedent, `SKILL.md:109-113`);
  README text says `0x0000_1000` (`README.md:36`). Pick one; both are valid (4 KB bootrom ends at
  `0x1000`).
- **OQ6 — `.core`/toolchain paths.** Whether cnn_soc is packaged as a fusesoc core
  (`ex6_soc.core`) or a plain Makefile+iverilog flow, and the exact absolute path to
  `riscv64-unknown-elf-gcc` on the build host (`SKILL.md:24` fixes the version, not the path).
- **OQ7 — Weight/LUT stay `$readmemh` in v1.** Confirmed intent (`README.md:27`), but note this means
  v1 is not a *fully* boot-loaded system — only program/image/label are CPU-path. v2 loads weights via
  CPU into SRAM (`README.md:27`, `ROADMAP.md:113-115`). Flag so nobody mistakes v1 for zero-`$readmemh`.

---

### Appendix A — Files this plan implies (all NEW; nothing existing is modified)
`cnn_soc/rtl/`: `cnn_soc.v`, `axi_lite_interconnect.v`, `bootrom.v`, `sram.v`, `vec_rom.v`,
`axi2apb.v`, `apb_uart.v`, `apb_gpio.v`, `cnn_axi_slave.v`, `cnn_infer.v`, `image_buffer.v`
(+ `filelist` that also pulls the verified `cnn/rtl/*` leaves and `skill-tests/ex6/rtl/picorv32.v`).
`cnn_soc/sw/`: `start.S`, `soc.h`, `drv_uart.c`, `drv_cnn.c`, `main.c`, `link.ld`, `Makefile`.
`cnn_soc/tests/`: `tb_cnn_soc.v` (+ optional `sram_preload.v`, `cnn_soc.core`).

### Appendix B — Reused verified blocks (byte-for-byte, no edits)
From `cnn/rtl/` (`rtl_manifest.yaml:34-46`): `ctrl_fsm.v`, `mac_datapath.v`, `win_addr_gen.v`,
`fm_ram.v`, `weight_rom.v`, `sigmoid_lut.v` (+`sigmoid_lut.hex`), `uart_tx.v`. From
`skill-tests/ex6/rtl/picorv32.v`: `picorv32_axi` (`:2517`) + `picorv32_axi_adapter` (`:2731`) +
`picorv32` core (`:62`). Frozen vectors from `cnn/arch/golden_model/`: `weights.hex`, `images.hex`,
`labels.hex`, `expected.hex`, `expected_outputs.txt`.

---

## Decision Record — Rinri-approved 2026-08-26 (fe-spec input, all binding)

| OQ | Decision | Notes |
|----|----------|-------|
| OQ1 | **Read-only `vec_rom` slave** preloaded from frozen `images.hex`/`labels.hex` | CPU reads pixels/labels from vec_rom, writes image into CNN buffer; stand-in for future camera/DMA |
| OQ2 | **Bootrom-bake**: firmware `.text/.rodata` execute in place from bootrom at `0x0000_0000` | No copy-to-SRAM for v1 |
| OQ3 | **128 KB SRAM** @ `0x0001_0000` | Headroom for v2 weight-in-SRAM (~53 KB) |
| OQ4 | **Firmware writes the 12-bit LED pattern** to APB GPIO | No `led_ctrl.v` re-instantiation in v1 |
| OQ5 | SRAM base = **`0x0001_0000`** (fe-firmware/ex3 precedent) | Resolves README's `0x1000` ambiguity |
| OQ6 | **Plain Makefile + iverilog flow** for v1 (fusesoc `.core` optional, not required) | Match cnn/verify precedent; path to riscv gcc recorded at fe-firmware skill |
| OQ7 | **Weights + sigmoid LUT stay internal ROM (`$readmemh`) in v1** | v1 = CPU-path for program/image/label only; v2 loads weights via CPU into SRAM. Honest note: v1 is NOT zero-`$readmemh` |

Additional bindings: single clock domain 100 MHz nominal, synchronous active-low reset
(project precedent — fpga_generic technology, NOT sky130; pure Verilog-2001; no DFT).
