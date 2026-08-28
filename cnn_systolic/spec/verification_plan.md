# cnn_systolic — Verification Plan
Stage: fe-spec | Language: pure Verilog-2001 testbenches (no SVA, no SV coverage)

> **Scope note:** this document specifies verification *intent* only. Writing or running the
> testbenches is the later `fe-firmware`/`fe-verification` stage's job. fe-spec/fe-arch/fe-rtl
> write no TB vectors beyond the golden-model vector files; fe-rtl's exit gate is an
> `iverilog -g2001` compile-only sanity check (REQ-038). Formal/GLS/equivalence are OUT OF SCOPE
> (REQ-041).

## 1. Verification Strategy

- **Levels:** module (interconnect, memories, AXI2APB, APB peripherals, CNN slave + sequencer,
  systolic array + conv control, pool unit, serial FC datapath, piecewise sigmoid, result path)
  -> full-SoC (CPU + firmware + all regions) -> golden-model comparison (G1/G2/G6/G7/G8).
- **Stimulus style:** directed. Three layers:
  1. **FP datapath unit vectors** — the golden model's directed vector set
     (`golden_model_test_vectors.h`, hand-derived expected values): BF16 conversion, FP32
     add/mul (rounding, cancellation, FTZ), piecewise sigmoid (every segment + boundaries +
     negative side), sigma256 quantization, confidence/verdict logic, argmax ties. Consumed by
     the golden self-test mode (`--vectors`) AND by the fe-rtl module TBs (same values via
     `stimulus.hex`/`expected.hex` where applicable).
  2. **Module-level directed TBs** (interconnect decode/wstrb, memory round-trips, bridge, APB
     peripherals, CNN register/sequencer corner cases, array wavefront/weight-load/drain,
     FC pipeline) driving the AXI master-side signals and the array control inputs directly.
  3. **Full-SoC TB (`tb_cnn_soc`-family, reused harness):** 100 MHz clock, `rst_n` held low
     >= 10 cycles, firmware hex preloaded into the bootrom via `$readmemh`, `vec_rom` loads
     `stimulus.hex`/`labels.hex` (relocated golden copies), an **independent bit-level UART
     decoder** captures the stream to `uart_captured.txt` for a post-run `diff` against the
     **regenerated FP** `expected_outputs.txt`.
- **Checking style:** self-checking `task`/`function` scoreboards (pure Verilog) against the
  golden files — `arch/golden_model/expected_outputs.txt` (100 lines, UART) and `expected.hex`
  (400 words: per image pred, conf, expected label, verdict — 4 words/image, same format as the
  old golden), plus hierarchical probes of DUT-internal state (PE accumulators, wavefront
  position, FC accumulator, sigma values).
- **Golden-model role:** the new FP golden (`golden_ref_model.c`) is the single source of truth
  for datapath results (pred/conf/verdict per image) AND for the FP unit behaviours. The numpy
  twin (`check_fp.py`) is the independent cross-check (G8): two independent implementations of
  the same pinned contract must agree 100/100 on the image set; the hand-derived vector set
  validates the FP primitives against hand-computed IEEE results (G7).
- **Sim pacing:** SoC TB may override `UART_CLK_DIV` to 4 (byte stream unchanged, only bit
  timing). Compute pacing: the core is single-shot (no HOLD/BLINK); BUSY <= 750,000
  cycles/START (REQ-021, ASM-008).

## 2. Top Module Verification Intent

| VP-ID | Scenario | Stimulus | Pass criterion | Traces |
|---|---|---|---|---|
| VP-TOP-001 | Cold reset and defaults | Assert `rst_n` low >= 10 cycles, release; read every register via firmware or probe | `led[11:0]==0` and `uart_tx==1` throughout reset; no X/Z on outputs after release; CPU fetches at 0x0000_0000; all registers at reset values; single-domain/posedge-only and no-latch discipline confirmed by inspection | REQ-003, REQ-015, REQ-017, REQ-018, REQ-034, REQ-035, REQ-038 |
| VP-TOP-002 | **G1 — UART byte-exact golden stream (FP)** | Full 100-image demo at `UART_CLK_DIV=4`; independent decoder captures all lines | `diff uart_captured.txt vs arch/golden_model/expected_outputs.txt` (100 lines, regenerated FP) == 0 mismatches (covers the three line formats, `%03u` padding, single 0x0A, zero 0x0D, `|` spacing) | REQ-001, REQ-013, REQ-030, REQ-031 |
| VP-TOP-003 | **G2 — result registers vs regenerated expected.hex** | During the 100-image run, probe `CNN_RESULT`/`CNN_EXP` per image | For every image i in 0..99: `CNN_RESULT[3:0] == expected.hex[4i]` (pred), `[14:8] == expected.hex[4i+1]` (conf), `CNN_EXP[3:0] == expected.hex[4i+2]` (label), `[17:16] == expected.hex[4i+3]` (verdict) — 0 mismatches | REQ-017, REQ-018, REQ-019, REQ-025, REQ-031 |
| VP-TOP-004 | **G3 — LED encoding at presented instants** | Observe `led[11:0]` at each image's presented instant (DONE edge) | 100/100: `led[9:0]` == one-hot(pred) (or 0 when verdict==2), `led[10]` == (verdict != 0), `led[11]` == 0; while an inference is in flight `led[11]` == 1 | REQ-015, REQ-032 |
| VP-TOP-005 | **G4 — reset hygiene** | Reset asserted at start and mid-run (second reset injection mid-demo, then re-run to completion) | `led==0` and `uart_tx==1` throughout every reset window; no X/Z on outputs after release; system re-boots cleanly and re-completes the demo | REQ-034, REQ-035 |
| VP-TOP-006 | **G5 — boot liveness + bounded runtime** | Watchdog in TB; probe `trap` | First complete UART line within 1,500,000 cycles of `rst_n` release; full 100-image demo within 150,000,000 cycles (any `UART_CLK_DIV` in {4,868}); `trap` never asserts; 0 watchdog aborts | REQ-001, REQ-003, REQ-037 |
| VP-TOP-007 | Single-shot and repeatability | Hierarchical probes during the full run; a second START on the same image after DONE | Core parked at reset and re-parked within 2 cycles of done; `BUSY` window <= 750,000 cycles per START; re-running the same image yields an identical `CNN_RESULT`; `DONE` clears on the next START | REQ-016, REQ-017, REQ-021, REQ-037 |
| VP-TOP-008 | Polling-only protocol + no-formal/GLS/equiv scope | Inspection of the firmware + `ENABLE_IRQ=0` instantiation; project tree scan | No IRQ logic exists; firmware observes DONE via poll loop; no sby/gls/equiv artifacts or run records exist (REQ-041) | REQ-027, REQ-033, REQ-041 |
| VP-TOP-009 | Unmapped-access immunity (SoC-level smoke) | Optional firmware smoke: read/write 0x2000_0000 (unmapped), then continue the demo | Reads return 0, writes have no effect, the CPU never hangs; demo completes | REQ-005, REQ-006 |

Includes, per the skill's minimum set: reset & defaults (VP-TOP-001/005), each interface's
protocol-legal sequences (UART VP-TOP-002, AXI VP-IC-001/VP-APB-001, GPIO VP-GPIO-001/VP-TOP-004),
error/illegal sequences (unmapped VP-TOP-009/VP-IC-001, START misuse VP-CNN-001, drop-on-busy
VP-UART-001, PARK abort VP-CNN-001), back-to-back traffic (100 consecutive inferences, VP-TOP-
002/007), full-throughput soak (VP-TOP-002/006), no IRQ (VP-TOP-008), 0 CDC paths (single domain).

## 3. Per-Module Verification Intent

### 3.1 axi_lite_interconnect (reused shell)
Functional intent: combinational decode of the five regions (REQ-007) on `addr[31:28]` (+window-
0x0 sub-split), forwarding + response mux, unmapped completion (REQ-005/006). Single outstanding.

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-IC-001 | Decode + unmapped directed test | Every region boundary address and every unmapped window | Reads return 0, writes ignored, handshake completes in every case; response timing per REQ-005 | REQ-005, REQ-006, REQ-007 |
| VP-IC-002 | wstrb byte-enable forwarding | Word write with `wstrb=4'b1010` to SRAM and to CNN_IMG; read back / probe | Only enabled lanes updated; CNN_IMG packing little-endian (pixel 4k in byte [7:0] of word k) | REQ-009, REQ-020, REQ-036 |

### 3.2 bootrom / sram / vec_rom (reused shell)
Functional intent: 4 KB RO boot memory (REQ-008); 128 KB RW SRAM (REQ-009); 78,500 B RO vector
ROM (REQ-010).

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-BOOT-001 | Bootrom fidelity + bounds | Read back all 4 KB after `$readmemh(BOOT_HEX_FILE)`; attempt a write | Contents == firmware hex; write ignored; rvalid 1 cycle after accept | REQ-004, REQ-008 |
| VP-SRAM-001 | SRAM round-trip + boundaries | Write/read patterns at boundaries and interior; byte-lane writes | Round-trips exact; boundaries map correctly; only enabled lanes change | REQ-009 |
| VP-VEC-001 | vec_rom content fidelity | Read all 78,500 bytes; attempt a write | Bytes 0..78399 == stimulus.hex, 78400..78499 == labels.hex; write ignored | REQ-010 |

### 3.3 axi2apb / apb_uart / apb_gpio (reused shell)
Functional intent: AXI->APB conversion (REQ-011); UART TX pulse + drop-on-busy (REQ-013/014);
GPIO round-trip (REQ-015).

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-APB-001 | Bridge round-trip + sequencing | Directed: write/read UART_TX, UART_STAT, GPIO_OUT; unmapped APB offset 0x2000 | Round-trips exact; PSEL/PENABLE two-phase; unmapped offset returns PRDATA=0 with PREADY; read response <= 3 cycles after accept | REQ-005, REQ-011 |
| VP-UART-001 | TX pulse + frame timing + drop-on-busy | Write bytes back-to-back and while BUSY; decode the pin | `utx_valid` high exactly 1 cycle with correct data; bit widths == `CLK_DIV` cycles, LSB-first; idle-high between frames and during reset; write-while-busy dropped | REQ-013, REQ-014 |
| VP-GPIO-001 | GPIO round-trip + fanout | Write 0x000, 0xFFF, 0x555; read back; observe led | `led[11:0]` == GPIO_OUT; readback == written value; reset value 0 | REQ-015 |

### 3.4 cnn_axi_slave (NEW — registers + image-bank write path + single-shot sequencer)
Functional intent: register map REQ-012/016-020; single-shot sequencer REQ-021 (park at reset,
START launch, latch on done, re-park within 2 cycles); CNN_IMG word writes unpacked and
broadcast to the 9 shifted image banks (REQ-020).

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-CNN-001 | Register map + control corner cases | Directed bus access to every offset; START clean/while-BUSY/while-PARK; PARK abort mid-run; DONE clear on START; WO reads return 0 | Offsets/widths/access types per spec §6.3; corner cases exactly per REQ-016/017; reset values 0 | REQ-012, REQ-016, REQ-017, REQ-018, REQ-019 |
| VP-CNN-002 | Bench-drive (no CPU): single-shot end-to-end | Drive the slave directly: write CNN_EXP, fill CNN_IMG (image 0, then 1, then 18), START, poll DONE | `CNN_RESULT` == regenerated expected.hex[0..3], [4..7], [72..75]; BUSY window <= 750,000 cycles | REQ-018, REQ-019, REQ-020, REQ-021 |
| VP-CNN-003 | Image write path + bank shift correctness | Word writes with all wstrb patterns; probe the 9 bank read ports | Bank t at address (oy,ox) == img[(oy+iy-1),(ox+ix-1)] or 0 when out of range, for every t = iy*3+ix; reads of CNN_IMG return 0 | REQ-020, REQ-036 |
| VP-CNN-004 | Shell + reused-file integrity (inspection) | Diff the reused shell files against `cnn_soc/rtl/` + `cnn_soc/ip/`; grep for forbidden constructs and `#` delays | 0 diffs on the reused files; `iverilog -g2001` compile-only clean; no SV/DFT/latches | REQ-038 |

### 3.5 systolic array + conv control (NEW)
Functional intent: 8x8 weight-stationary PE grid, 2-stage pipelined MAC (BF16 mult -> FP32 add),
wavefront feed (1 column/cycle, left-to-right), shadow weight reload, bias init, in-PE
accumulation across sub-passes, drain at the right edge; conv1 2 passes/pixel, conv2 18
passes/pixel with the pinned (g, k, c) order (REQ-023/024, ASM-006).

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-ARR-001 | PE MAC unit | Drive one PE with pinned BF16 operands + FP32 partials | PE acc == fp32_add(acc, fp32_mul(w,a)) bit-exact vs golden fp32 ops (G7 vectors reused) | REQ-022, REQ-023 |
| VP-ARR-002 | Wavefront + accumulate order | Feed a synthetic 3x3 image; probe PE accumulators every cycle vs the golden's per-oc add sequence | Per-oc add order == (bias, taps/sub-passes/columns in pinned order); intermediate acc values bit-identical to the golden | REQ-023, REQ-024 |
| VP-ARR-003 | Weight load + drain + zero-pad | Shadow load timing across passes; drain strobe; OOB taps produce BF16 zero operands | Reload overlapped with compute (8 cycles per sub-pass steady state); drained values == final per-oc accs; zero-pad exact | REQ-023, REQ-024 |
| VP-ARR-004 | Conv layer end-to-end (unit) | Conv1 + pool1 + conv2 + pool2 on a small synthetic image, golden compared per layer | h1/p1/h2/p2 feature maps bit-identical to the golden's (same BF16 rounding after ReLU) | REQ-023, REQ-024, REQ-025 |

### 3.6 pool_unit (NEW)
Functional intent: 2x2 max pooling over BF16 feature maps; pool1 reads h1 (FM RAM) and writes the
8 per-channel p1 banks in parallel; pool2 reads h2 and writes p2 (FM RAM region B).

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-POOL-001 | Max + write path | Synthetic h1/h2 contents incl. ties and negatives (post-ReLU: all >= 0) | Pooled outputs exact (BF16 compare); p1 bank writes at the pinned addresses; p2 in region B | REQ-023, REQ-025, REQ-039 |

### 3.7 serial FC datapath + piecewise sigmoid (NEW)
Functional intent: serial single-MAC FP datapath (1 MAC/cycle steady state), pinned input order
(REQ-025); piecewise sigmoid with pinned dyadic coefficients (REQ-026); sigma256 quantization +
argmax/conf/verdict (REQ-027).

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-FC-001 | Serial MAC order + pipeline | Synthetic p2/h3 contents; probe acc per cycle | Per-output add order == bias then ascending input index; acc bit-identical to the golden | REQ-025 |
| VP-SIG-001 | Piecewise sigmoid | All 8 segments + both sides of every breakpoint + negative z + |z|>=8 (G7 vectors) | sigma == golden's piecewise evaluation bit-exact (fp32 mul then add, RN-even/FTZ) | REQ-026 |
| VP-SIG-002 | sigma256 + argmax + conf/verdict | Quantization cases incl. .5 ties, TRASH boundary (sigma256 127/128), argmax ties | sigma256 = trunc(sigma*256+0.5); lowest-index ties; conf = (best*100)>>8; verdict 0/1/2 | REQ-027 |

### 3.8 weight banks (NEW)
Functional intent: 8 interleaved BF16 banks, 26,698 words total, `$readmemh` from
`weights_bf16.hex` (REQ-028/039); parallel per-sub-pass reload reads + serial FC reads.

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-WROM-001 | Load fidelity + addressing | Read all 26,698 words via both access modes | Contents == weights_bf16.hex; interleaved bank mapping per fe-arch §7; 8 parallel reads/cycle during reload | REQ-028, REQ-039 |

### 3.9 memories (NEW: FM RAM, image banks, p1 banks)
Functional intent: FM RAM 8,192x16 (h1 0..6271, h2 0..3135 reusing h1's region, p2 6,272..7,055,
h3 0..31); 9 shifted image banks; 8 per-channel p1 banks (REQ-039/040).

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-MEM-001 | Region map + round-trip | Directed writes/reads at every region boundary; SRAM-macro stub behaviour | Region map exact; no read-before-write hazard across layers (hazard-free proof, fe-arch §7); macro stubs + SDC entries present | REQ-039, REQ-040 |

### 3.10 picorv32_axi (reused CPU)
Functional intent: verbatim RV32I core + simplified AXI master (REQ-002/005).

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-CPU-001 | Instantiation + boot behaviour | Inspection of the parameter list; observe first fetch at 0x0000_0000 and `sp` init | Parameter list exactly per REQ-002; boots and executes firmware (G5); no trap | REQ-002, REQ-003 |

### 3.11 firmware (fe-firmware stage intent)
Functional intent: pure-ROM image (REQ-004), golden-exact line formatting (REQ-030), demo loop
(REQ-031), LED encoding (REQ-032), polling drivers (REQ-033), updated poll-bound comment
(ASM-008).

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-FW-001 | Image properties + formatter unit test | Link-map inspection; unit-test the line formatter against expected_outputs.txt lines 1-5 | `.data`==0, `.bss`==0, `.text+.rodata` <= 0x1000; formatter reproduces lines 1-5 byte-exact; no CR ever emitted | REQ-004, REQ-030 |

### 3.12 golden model (P1 deliverable; verification intent)
Functional intent: integer-only C model mirroring the pinned FP/systolic contract (REQ-029).

| VP-ID | Scenario | Pass criterion | Traces |
|---|---|---|---|
| VP-GOLD-001 | **G6/G7/G8 — golden determinism, vectors, twin cross-check** | (P1 evidence, not a TB): re-run the golden (byte-identical outputs); run `--vectors` vs the hand-derived expected_vectors.txt (0 mismatches); run check_fp.py numpy twin over the 100-image set (0 mismatches) | G6: `diff` of two consecutive golden runs == empty; G7: vectors diff == 0; G8: twin diff == 0 | REQ-022, REQ-023, REQ-025, REQ-026, REQ-027, REQ-028, REQ-029 |

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
| REQ-022 | VP-FP-001..003, VP-ARR-001, VP-GOLD-001 | open |
| REQ-023 | VP-ARR-001..004, VP-GOLD-001 | open |
| REQ-024 | VP-ARR-002, VP-GOLD-001 | open |
| REQ-025 | VP-FC-001, VP-ARR-004, VP-GOLD-001 | open |
| REQ-026 | VP-SIG-001, VP-GOLD-001 | open |
| REQ-027 | VP-SIG-002, VP-TOP-003, VP-GOLD-001 | open |
| REQ-028 | VP-GOLD-001, VP-WROM-001 | open |
| REQ-029 | VP-GOLD-001, VP-TOP-002, VP-TOP-003 | open |
| REQ-030 | VP-TOP-002, VP-FW-001 | open |
| REQ-031 | VP-TOP-002, VP-TOP-003 | open |
| REQ-032 | VP-TOP-004 | open |
| REQ-033 | VP-TOP-008 | open |
| REQ-034 | VP-TOP-001, VP-TOP-005 | open |
| REQ-035 | VP-TOP-001, VP-TOP-005 | open |
| REQ-036 | VP-IC-002, VP-CNN-003 | open |
| REQ-037 | VP-TOP-006, VP-TOP-007 | open |
| REQ-038 | VP-CNN-004, VP-TOP-001 | open |
| REQ-039 | VP-WROM-001, VP-MEM-001, VP-POOL-001 | open |
| REQ-040 | VP-MEM-001 | open |
| REQ-041 | VP-TOP-008 | open |

Zero orphan REQs (every row has >= 1 VP) and zero orphan VP items (every VP-ID in §2/§3 appears
in at least one REQ row above — cross-checked by construction). Status is `open` throughout
fe-spec/fe-arch/fe-rtl; the later verification stage flips status to `closed` on a passing run.
Note: VP-FP-001..003 are the G7 vector-based checks (BF16 conversion / fp32 add / fp32 mul) —
carried as VP-FP-* IDs in the REQ-022 row; they are delivered as part of the golden vector set
and the fe-rtl module TBs.

## 5. Verification Closure Criteria

Countable, to be evaluated by the later verification stage (harness gates G1-G5 reused + FP
gates G6-G8):

1. **G1** — `diff` of the decoded SoC UART stream vs `arch/golden_model/expected_outputs.txt`
   (100 lines, regenerated FP) == **0 mismatches** (VP-TOP-002).
2. **G2** — `CNN_RESULT`/`CNN_EXP` vs `expected.hex` == **0 mismatches** across all 100 images
   (VP-TOP-003).
3. **G3** — LED encoding checks == **0 mismatches** at all 100 presented instants (VP-TOP-004).
4. **G4** — reset hygiene: 0 violations (led==0, uart_tx==1 throughout reset; no X/Z after
   release) (VP-TOP-005).
5. **G5** — boot liveness: first complete UART line <= 1,500,000 cycles; full demo <=
   150,000,000 cycles; `trap` never asserts; 0 watchdog aborts (VP-TOP-006).
6. **G6** — golden reproducibility: a fresh golden run reproduces the committed
   `expected_outputs.txt`/`expected.hex`/`stimulus.hex`/`labels.hex` byte-identically
   (VP-GOLD-001).
7. **G7** — FP datapath vectors: golden `--vectors` output vs hand-derived `expected_vectors.txt`
   == **0 mismatches**; fe-rtl module TBs replay the same vectors with 0 mismatches
   (VP-FP-001..003, VP-SIG-001/002).
8. **G8** — accumulate-order cross-check: `check_fp.py` (independent numpy twin) vs the golden
   over the 100-image set == **0 mismatches** (VP-GOLD-001).
9. 100% of `must` requirements (REQ-001..REQ-041, all `must`) have >= 1 passing VP item.
10. 0 orphan REQs, 0 orphan VP items (per §4).
11. All module-level directed VPs pass (VP-IC-001/002, VP-BOOT-001, VP-SRAM-001, VP-VEC-001,
    VP-APB-001, VP-UART-001, VP-GPIO-001, VP-CNN-001..003, VP-ARR-001..004, VP-POOL-001,
    VP-FC-001, VP-SIG-001/002, VP-WROM-001, VP-MEM-001) and all inspection VPs pass
    (VP-CNN-004, VP-CPU-001, VP-TOP-008, VP-FW-001).
12. `iverilog -g2001` compile-only clean on the full SoC filelist (fe-rtl exit gate, REQ-038);
    firmware builds via `ld -m elf32lriscv` with `.data`==0, `.bss`==0, size <= 4 KB.
13. Single-shot integrity: park at reset, re-park within 2 cycles of done; BUSY <= 750,000
    cycles/START (VP-TOP-007/VP-CNN-002).
14. No formal/GLS/equivalence artifacts anywhere in the project (REQ-041, VP-TOP-008).
