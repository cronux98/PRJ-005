# cnn_soc — Verification Plan
Stage: fe-spec | Language: pure Verilog-2001 testbenches (no SVA, no SV coverage)

> **Scope note:** this document specifies verification *intent* only. Writing or running the SoC
> testbench is the later `fe-firmware`/`fe-verification` stage's job (PLAN.md §9, P4). fe-spec/
> fe-arch/fe-rtl write no TB vectors; fe-rtl's exit gate is an `iverilog -g2001` compile-only
> sanity check (REQ-032).

## 1. Verification Strategy

- **Levels:** module (interconnect, memories, AXI2APB, APB peripherals, CNN slave + sequencer,
  cnn_infer integration) -> full-SoC (CPU + firmware + all regions) -> golden-model comparison
  (G1/G2).
- **Stimulus style:** directed. Two layers:
  1. **Module-level directed TBs** (interconnect decode/wstrb, memory round-trips, bridge, APB
     peripherals, CNN register/sequencer corner cases) that drive the AXI master-side signals
     directly from the TB.
  2. **Full-SoC TB (`tb_cnn_soc.v`)** — the primary gate (PLAN.md §9): 100 MHz clock, `rst_n`
     held low >= 10 cycles, firmware hex preloaded into the bootrom via `$readmemh`
     (bootrom-bake; if SRAM preload were used it must be a **second top** — `iverilog -s cnn_soc
     -s sram_preload`, `fe-firmware/SKILL.md:88-90`), `vec_rom` loads `images.hex`/`labels.hex`
     by its own `$readmemh` (paths relative to the run dir, CNN convention `arch.md:540-551`),
     an **independent bit-level UART decoder** (not the DUT's own FSM — reuse the
     `ex6_tb.v:43-108` 8N1 receiver or the CNN's `verify/tb_common/uart_monitor.vh` capture
     approach, `tb_mnist_top.v:14-17,129-132`; self-calibrate bit time from the first char,
     `fe-firmware/SKILL.md:71-76`) captures the stream to `uart_captured.txt` for a post-run
     `diff`.
- **Checking style:** self-checking `task`/`function` scoreboards (pure Verilog) against the
  frozen golden files — `cnn/arch/golden_model/expected_outputs.txt` (first 100 lines, UART) and
  `expected.hex` (400 words: per image pred, conf, expected label, verdict — 4 words/image,
  `golden_model/README.md:50-54`), plus hierarchical probes of DUT-internal state
  (`tb_mnist_top.v:53-58,173-180` pattern).
- **Golden-model role:** the frozen CNN golden package is the single source of truth for the
  datapath results (the datapath itself is already proven bit-exact at IP level —
  `tb_mnist_top.v` 200-image bit-exact + cocotb 19/19, `ROADMAP.md:21`). The SoC layer proves the
  **CPU-bus integration**: address decode, simplified-AXI handshake, image-buffer write path,
  single-shot start/done, CPU-formatted UART. G1 passing at SoC level *and* `tb_mnist_top`
  passing at IP level together close the loop (PLAN.md §9).
- **Sim pacing:** SoC TB may override `UART_CLK_DIV` to 4 (sim override, CNN precedent
  `arch.md:224`); the byte stream is unchanged, only bit timing. Compute pacing parameters
  (`HOLD_CYCLES`/`BLINK_CYCLES`) are irrelevant — the core parks before HOLD (REQ-021).

## 2. Top Module Verification Intent

| VP-ID | Scenario | Stimulus | Pass criterion | Traces |
|---|---|---|---|---|
| VP-TOP-001 | Cold reset and defaults | Assert `rst_n` low >= 10 cycles, release; read every register via firmware or probe | `led[11:0]==0` and `uart_tx==1` throughout reset; no X/Z on outputs after release; CPU fetches at 0x0000_0000; all registers at reset values (UART_STAT=0, GPIO_OUT=0, CNN_STATUS=0, CNN_RESULT=0, CNN_CTRL reads 0); single-domain/posedge-only and no-latch discipline confirmed by inspection | REQ-003, REQ-015, REQ-017, REQ-018, REQ-028, REQ-029, REQ-032 |
| VP-TOP-002 | **G1 — UART byte-exact golden stream** | Full 100-image demo at `UART_CLK_DIV=4`; independent decoder captures all lines | `diff uart_captured.txt vs first 100 lines of cnn/arch/golden_model/expected_outputs.txt` == 0 mismatches (100/100 lines; covers the exact three line formats, `%03u` padding, single 0x0A, zero 0x0D, `|` spacing) | REQ-001, REQ-013, REQ-024, REQ-025 |
| VP-TOP-003 | **G2 — result registers vs expected.hex** | During the 100-image run, probe `CNN_RESULT`/`CNN_EXP` (or firmware-report) per image | For every image i in 0..99: `CNN_RESULT[3:0] == expected.hex[4i]` (pred), `CNN_RESULT[14:8] == expected.hex[4i+1]` (conf), `CNN_EXP[3:0] == expected.hex[4i+2]` (label), `CNN_RESULT[17:16] == expected.hex[4i+3]` (verdict) — 0 mismatches | REQ-017, REQ-018, REQ-019, REQ-025 |
| VP-TOP-004 | **G3 — LED encoding at presented instants** | Observe `led[11:0]` at each image's presented instant (DONE edge) | 100/100: `led[9:0]` == one-hot(pred) (or 0 when verdict==2), `led[10]` == (verdict != 0), `led[11]` == 0; while an inference is in flight `led[11]` == 1 | REQ-015, REQ-026 |
| VP-TOP-005 | **G4 — reset hygiene** | Reset asserted at start and mid-run (a second reset injection mid-demo, then re-run to completion) | `led==0` and `uart_tx==1` throughout every reset window; no X/Z on outputs after release; system re-boots cleanly after the mid-run reset and re-completes the demo (single-shot still correct) | REQ-028, REQ-029 |
| VP-TOP-006 | **G5 — boot liveness + bounded runtime** | Watchdog in TB (pattern `ex6_tb.v:141-145`); probe `trap` | First complete UART line within 1,500,000 cycles of `rst_n` release; full 100-image demo within 150,000,000 cycles (any `UART_CLK_DIV` in {4,868}); `trap` never asserts; 0 watchdog aborts | REQ-001, REQ-003, REQ-031 |
| VP-TOP-007 | Single-shot and repeatability | Hierarchical probes during the full run; a second START on the same image after DONE | `ctrl_fsm.img_idx == 0` at all times; park re-asserted within 2 cycles of `lc_present`; `BUSY` window <= 667,500 cycles per START; re-running the same image yields an identical `CNN_RESULT`; `DONE` clears on the next START | REQ-016, REQ-017, REQ-021, REQ-031 |
| VP-TOP-008 | Polling-only protocol | Inspection of the firmware + `ENABLE_IRQ=0` instantiation; observe no interrupt path activity | No IRQ logic exists; firmware observes DONE via poll loop and BUSY via UART_STAT poll (evidenced by G1/G2 passing); no CSR/vector-table use | REQ-027 |
| VP-TOP-009 | Unmapped-access immunity (SoC-level smoke) | Optional firmware smoke: read from 0x2000_0000 and write to 0x2000_0000 (unmapped), then continue the demo | Reads return 0, writes have no effect, the CPU never hangs; demo continues to completion (formal coverage of all windows is VP-IC-001) | REQ-005, REQ-006 |

Includes, per the skill's minimum set: reset & defaults (VP-TOP-001/005), each interface's
protocol-legal sequences (UART VP-TOP-002, AXI VP-IC-001/VP-APB-001, GPIO VP-GPIO-001/VP-TOP-004),
error/illegal sequences (unmapped VP-TOP-009/VP-IC-001, START misuse VP-CNN-001, drop-on-busy
VP-UART-001, PARK abort VP-CNN-001), back-to-back traffic (100 consecutive inferences with no idle
gaps beyond the DONE poll, VP-TOP-002/007), full-throughput soak (VP-TOP-002/006), no IRQ
(VP-TOP-008), no clock gating (REQ-028 inspection), 0 CDC paths (single domain — no CDC stress
exists by construction).

## 3. Per-Module Verification Intent

### 3.1 axi_lite_interconnect
Functional intent: combinational decode of the five regions (REQ-007) on `addr[31:28]` (+window-0x0
sub-split), forwarding AW/W/AR + response mux, unmapped completion with rdata=0 (REQ-005/006).
Single outstanding, no arbitration.

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-IC-001 | Decode + unmapped directed test | Drive master-side AXI from the TB: every region boundary address (bootrom 0x0000_0000/0x0000_0FFF, SRAM 0x0001_0000/0x0002_FFFF, vec_rom 0x1000_0000/0x1001_32A3, AXI2APB 0x4000_0000, cnn 0x5000_0000) and every unmapped window (0x2, 0x3, 0x6..0xF, 0x0000_1000, 0x0003_0000): reads return 0, writes ignored, handshake completes in every case; response timing per REQ-005 | REQ-005, REQ-006, REQ-007 |
| VP-IC-002 | wstrb byte-enable forwarding | Word write with `wstrb=4'b1010` to SRAM and to CNN_IMG; read back / probe | Only lanes 1 and 3 updated; CNN_IMG packing little-endian (pixel 4k in byte [7:0] of word k) | REQ-009, REQ-020, REQ-030 |

### 3.2 bootrom / sram / vec_rom
Functional intent: 4 KB RO boot memory (REQ-008); 128 KB RW SRAM (REQ-009); 78,500 B RO vector
ROM (REQ-010). All 1-cycle registered read latency, `$readmemh`-initialised where applicable.

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-BOOT-001 | Bootrom fidelity + bounds | Read back all 4 KB after `$readmemh(BOOT_HEX_FILE)`; attempt a write | Contents == firmware hex byte-for-byte; write ignored; rvalid 1 cycle after accept; size exactly 4 KB | REQ-004, REQ-008 |
| VP-SRAM-001 | SRAM round-trip + boundaries | Write/read patterns at 0x0001_0000, 0x0002_FFFF, interior; byte-lane writes | Round-trips exact; boundaries map correctly; only enabled lanes change | REQ-009 |
| VP-VEC-001 | vec_rom content fidelity | Read all 78,500 bytes; attempt a write | Bytes 0..78399 == images.hex, 78400..78499 == labels.hex; write ignored; rvalid 1 cycle after accept | REQ-010 |

### 3.3 axi2apb
Functional intent: one simplified-AXI transaction in window 0x4000_0000 -> APB access
(SETUP/ACCESS, PSEL/PENABLE/PWRITE/PADDR/PWDATA/PRDATA/PREADY); PADDR[11:0] selects UART vs GPIO
(REQ-011); response per REQ-005.

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-APB-001 | Bridge round-trip + sequencing | Directed: write/read UART_TX, UART_STAT, GPIO_OUT; APB offset 0x2000 (unmapped) | Data round-trips exactly; PSEL/PENABLE two-phase observed; PREADY handshake completes; unmapped APB offset returns PRDATA=0 with PREADY; read response no later than 3 cycles after accept | REQ-005, REQ-011 |

### 3.4 apb_uart (reused uart_tx shell)
Functional intent: UART_TX write -> 1-cycle `utx_valid` pulse with `PWDATA[7:0]` (REQ-013);
UART_STAT[0] = BUSY (REQ-014); 115200 8N1 via the reused `uart_tx` (IPR-003).

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-UART-001 | TX pulse + frame timing + drop-on-busy | Write bytes back-to-back and while BUSY; decode the pin at `UART_CLK_DIV` | `utx_valid` high exactly 1 cycle per write with correct data; start/data/stop bit widths == `CLK_DIV` cycles, LSB-first; idle-high between frames and during reset; a write while BUSY is dropped (documented) | REQ-013, REQ-014 |

### 3.5 apb_gpio
Functional intent: 12-bit RW GPIO_OUT -> led[11:0] (REQ-015).

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-GPIO-001 | GPIO round-trip + fanout | Write 0x000, 0xFFF, 0x555 via APB; read back; observe led | led[11:0] == GPIO_OUT after each write; readback == written value; reset value 0 | REQ-015 |

### 3.6 cnn_axi_slave (registers + single-shot sequencer)
Functional intent: register map REQ-012/016-020; single-shot sequencer REQ-021 (park at reset,
START launch, latch on `lc_present`, re-park within 2 cycles).

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-CNN-001 | Register map + control corner cases | Directed bus access to every offset: CTRL/STATUS/RESULT/EXP/IMG(0x100,0x200,0x40F); START clean, START-while-BUSY, START-while-PARK, PARK abort mid-run, DONE clear on START, WO reads return 0 | Offsets/widths/access types per §6.3; corner-case behaviour exactly per REQ-016/017; reset values 0 | REQ-012, REQ-016, REQ-017, REQ-018, REQ-019 |
| VP-CNN-002 | Bench-drive (no CPU): single-shot end-to-end | Drive the slave directly: write CNN_EXP, fill CNN_IMG (image 0, then 1, then 18 from images.hex), START, poll DONE | `CNN_RESULT` == expected.hex[0..3] (7/94/7/CORRECT), [4..7], [72..75] (TRASH image 18: pred/conf/verdict==2) — matches PLAN.md P2 exit gate; BUSY window <= 667,500 cycles | REQ-018, REQ-019, REQ-020, REQ-021 |
| VP-CNN-003 | Image buffer write path + core read timing | Word writes with all wstrb patterns; probe core-side `irom_data` | Core read presents the written pixels with 1-cycle registered latency (image_rom.v:27-30 timing); reads of CNN_IMG return 0; no contention while parked | REQ-020, REQ-030 |
| VP-CNN-004 | cnn_infer reuse integrity (inspection) | Diff the six reused leaf files against `cnn/rtl/`; check cnn_infer wiring vs `cnn_npu.v:99-233`; grep for forbidden instantiations and `#` delays | 0 diffs on the six leaves; wiring matches; `image_rom`/`label_rom`/`uart_line_fmt`/`uart_tx`/`led_ctrl` absent from cnn_infer; `lf_done` tied to 1; weights/LUT ROMs `$readmemh` (REQ-023); `iverilog -g2001` compile-only clean | REQ-022, REQ-023, REQ-032 |

### 3.7 picorv32_axi (reused CPU)
Functional intent: verbatim RV32I core + simplified AXI master (REQ-002/005), PROGADDR_RESET=0x0,
STACKADDR=0x0003_0000.

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-CPU-001 | Instantiation + boot behaviour | Inspection of the parameter list; observe first fetch at 0x0000_0000 and `sp` init (probe); PCPI tied off, irq=0 | Parameter list exactly per REQ-002; boots and executes firmware (G5); no trap | REQ-002, REQ-003 |

### 3.8 firmware (fe-firmware stage intent)
Functional intent: pure-ROM image (REQ-004), golden-exact line formatting (REQ-024), demo loop
(REQ-025), LED encoding (REQ-026), polling drivers (REQ-027).

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-FW-001 | Image properties + formatter unit test | Link-map inspection; unit-test `uart_putu`/line formatter against `expected_outputs.txt:1-5` before the full run | `.data`==0, `.bss`==0, `.text+.rodata` <= 0x1000; formatter reproduces golden lines 1-5 byte-exact; no CR ever emitted | REQ-004, REQ-024 |

## 4. Traceability Matrix

| REQ-ID | Verified by | Status |
|---|---|---|
| REQ-001 | VP-TOP-002, VP-TOP-006 | open |
| REQ-002 | VP-CPU-001 | open |
| REQ-003 | VP-TOP-001, VP-TOP-006 | open |
| REQ-004 | VP-FW-001, VP-BOOT-001 | open |
| REQ-005 | VP-IC-001, VP-APB-001, VP-TOP-009 | open |
| REQ-006 | VP-IC-001, VP-TOP-009 | open |
| REQ-007 | VP-IC-001 | open |
| REQ-008 | VP-BOOT-001 | open |
| REQ-009 | VP-SRAM-001, VP-IC-002 | open |
| REQ-010 | VP-VEC-001 | open |
| REQ-011 | VP-APB-001 | open |
| REQ-012 | VP-CNN-001 | open |
| REQ-013 | VP-UART-001, VP-TOP-002 | open |
| REQ-014 | VP-UART-001 | open |
| REQ-015 | VP-GPIO-001, VP-TOP-004 | open |
| REQ-016 | VP-CNN-001, VP-TOP-007 | open |
| REQ-017 | VP-CNN-001, VP-TOP-003, VP-TOP-007 | open |
| REQ-018 | VP-CNN-001, VP-CNN-002, VP-TOP-003 | open |
| REQ-019 | VP-CNN-001, VP-CNN-002, VP-TOP-003 | open |
| REQ-020 | VP-CNN-003, VP-CNN-002, VP-IC-002 | open |
| REQ-021 | VP-TOP-007, VP-CNN-002 | open |
| REQ-022 | VP-CNN-004 | open |
| REQ-023 | VP-CNN-004 | open |
| REQ-024 | VP-TOP-002, VP-FW-001 | open |
| REQ-025 | VP-TOP-002, VP-TOP-003 | open |
| REQ-026 | VP-TOP-004 | open |
| REQ-027 | VP-TOP-008 | open |
| REQ-028 | VP-TOP-001, VP-TOP-005 | open |
| REQ-029 | VP-TOP-001, VP-TOP-005 | open |
| REQ-030 | VP-IC-002, VP-CNN-003 | open |
| REQ-031 | VP-TOP-006, VP-TOP-007 | open |
| REQ-032 | VP-CNN-004, VP-TOP-001 | open |

Zero orphan REQs (every row has >= 1 VP) and zero orphan VP items (every VP-ID in §2/§3 appears in
at least one REQ row above — cross-checked by construction). Status is `open` throughout
fe-spec/fe-arch/fe-rtl: those stages do not execute the plan; the later verification stage flips
status to `closed` on a passing run. The CNN IP-level gates (`tb_mnist_top.v` 200-image bit-exact,
cocotb 19/19) remain the IP-level gate on the datapath and are **not** re-run at SoC level
(PLAN.md §9).

## 5. Verification Closure Criteria

Countable, to be evaluated by the later verification stage (PLAN.md §9 gates G1-G5):

1. **G1** — `diff` of the decoded SoC UART stream vs the first 100 lines of
   `cnn/arch/golden_model/expected_outputs.txt` == **0 mismatches** (VP-TOP-002).
2. **G2** — `CNN_RESULT`/`CNN_EXP` vs `expected.hex` == **0 mismatches** across all 100 images
   (VP-TOP-003).
3. **G3** — LED encoding checks == **0 mismatches** at all 100 presented instants (VP-TOP-004).
4. **G4** — reset hygiene: 0 violations (led==0, uart_tx==1 throughout reset; no X/Z after
   release) (VP-TOP-005).
5. **G5** — boot liveness: first complete UART line <= 1,500,000 cycles; full demo <=
   150,000,000 cycles; `trap` never asserts; 0 watchdog aborts (VP-TOP-006).
6. 100% of `must` requirements (REQ-001..REQ-032, all `must`) have >= 1 passing VP item.
7. 0 orphan REQs, 0 orphan VP items (per §4).
8. All module-level directed VPs pass (VP-IC-001/002, VP-BOOT-001, VP-SRAM-001, VP-VEC-001,
   VP-APB-001, VP-UART-001, VP-GPIO-001, VP-CNN-001..003) and all inspection VPs pass
   (VP-CNN-004, VP-CPU-001, VP-TOP-008, VP-FW-001).
9. `iverilog -g2001` compile-only clean on the full SoC filelist (fe-rtl exit gate, REQ-032);
   firmware builds via `ld -m elf32lriscv` (fe-firmware/SKILL.md:91) with `.data`==0, `.bss`==0,
   size <= 4 KB.
10. Single-shot integrity: `img_idx==0` at all times; park within 2 cycles of `lc_present`
    (VP-TOP-007/VP-CNN-002).
