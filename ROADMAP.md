# PRJ-005 Roadmap — AI Accelerator → Automotive Object Detection

**North star (thesis):** an IP accelerator for automotive perception — detecting
**moving surrounding objects (pedestrians, cyclists, animals, children)** for
in-car safety. Built incrementally on the verified MNIST CNN foundation, keeping
the golden-first methodology at every step.

**How we get there:** each milestone is a real, verifiable project of the same
shape we already proved: trainer → frozen quantized golden → fe-spec → fe-arch →
fe-rtl → fe-* verification chain → committed evidence. We scale a proven
process; we never start over.

---

## Current state (2026-08-26)

| Sub-project | Status | Result |
|---|---|---|
| mnist_npu (v1 MLP) | Golden done | 92.25% — superseded by CNN |
| qat | COMPLETE | Honest negative (QAT ≤ integer baseline) |
| **cnn (v2)** | **FULL GREEN** | **96.35%, 200/200 bit-exact, cocotb 19/19** (44a1e4e) |
| learn_accel (rinriAI) | VERIFIED-WITH-2-FINDINGS | 2.4M samples mism=0; authoring paused by Rinri |
| **cnn_systolic (v3 ASIC)** | **IN FLIGHT (2026-08-28)** | BF16 8x8 systolic + serial FP FC, front-end chain, gates: func-cov/STA/firmware |

**Key facts of the verified engine (cnn):** 28×28×1 input, conv1 3×3 1→8ch,
pool 2×2, conv2 3×3 8→16ch, pool 2×2, FC1 784→32, FC2 32→10, Q8.8 fixed point,
26,698 weight words, ~70k cycles compute per image, UART + LED out.

---

## The ladder (M1 done; M2 next by Rinri's choice)

### M1 ✅ MNIST single digit — DONE (96.35%)
Single digit, 10 classes, 28×28 gray. Full verification chain green.

### M2 🔜 Multi-digit numbers (2–3 digits) — NEXT
- **What changes:** the *class list* and/or the *input width* — the engine and
  methodology stay.
- **Two valid architectures** (decision needed):
  - **A — fixed-length single-shot classifier:** 2 digits → 100 classes
    (00–99), 3 digits → **1000 classes (000–999)**. FC2 becomes 32→100/32→1000;
    label ROM, argmax width, confidence/verdict, UART text scale accordingly.
    No segmentation needed if digits are pre-aligned (true for synthetic sets).
  - **B — keep the 10-class engine, add a digit-split front-end:** run the
    existing engine once per digit (2–3 inferences per image), compose the
    number in a small controller. Engine unchanged; this is the bridge toward
    localization (M5) since splitting ≈ localizing.
- **Datasets:**
  - Synthetic concatenated MNIST — 2 digits = 28×56, 3 digits = 28×84;
    self-generated with our existing fetch/train tools. Recommended start
    (controlled, aligned, free).
  - SVHN (Street View House Numbers) — real-world, 32×32 RGB, 1–5 digits;
    the standard real benchmark, but needs color + resize → larger RTL delta.
  - Multi-MNIST — two digits *overlapped* in 28×28; deliberately hard, later.
- **Exit criteria:** golden bit-exact across N test images (both passes),
  cocotb independent re-verify, committed evidence. Same bar as M1.

### M3 Fashion-MNIST (28×28 gray, 10 classes)
Same input shape as MNIST — near-zero RTL change; retrain + regen golden.
Teaches generalization to a different domain (clothing).

### M4 CIFAR-10 (32×32×3 color, 10 classes)
**First 3-channel color input** — RTL change: input size, channel count,
datapath/ROM sizing, larger net. Milestone for the camera path (color).

### M5 Single-object localization
Output becomes **class + bounding box (x, y, w, h)**. Detection begins here.
Datasets: MNIST-with-boxes, then CIFAR-based synthetic scenes.

### M6 Multi-object detection
Anchor boxes + non-max suppression — Tiny-YOLO / MobileNet-SSD style head.
Datasets: PASCAL VOC → COCO subset.

### M7 Automotive datasets
**KITTI** (pedestrians, cyclists, cars — the thesis classes), then
BDD100K / nuScenes. Multi-class, real scenes, moving objects.

### M8 Video pipeline
Camera in (OV7670/CSI), PCLK → sysclk CDC, ROI/resize front-end, frame-rate
budgeting (30 fps = 33.3 ms/inference budget), object *tracking* across frames
("moving objects" requirement).

### M9 SoC integration — CPU + AXI + SRAM + bootrom + firmware
See dedicated section below.

### M10 Signoff-class delivery
Full frontend chain (spec → arch → RTL → GLS → STA → formal → equiv → docs)
on the final detection SoC. Tapeout-class evidence.

---

## M9 detail: SoC integration (the architecture Rinri wants)

```
        ┌──────────────────────────────────────────────────────┐
        │  bootrom ──► CPU (ibex / picorv32) ──► firmware      │
        │                    │                                 │
        │                    ▼                                 │
        │              AXI interconnect                        │
        │        ┌──────────┼──────────┬─────────────┐         │
        │        ▼          ▼          ▼             ▼         │
        │     AI IP     SRAM      UART (periph)   LED (periph) │
        │   (AXI slave)  (weights  (firmware out)  (result)    │
        │                + images)                              │
        └──────────────────────────────────────────────────────┘
```

- **Boot flow:** bootrom → CPU → firmware loads weights + images from
  SRAM/ROM image → configures AI IP via AXI writes → starts inference →
  polls/IRQ status → reads class/confidence/bbox → reports over UART + LED.
- **No more `$readmemh` + testbench reliance** — memory contents arrive via
  the bus; TB becomes a firmware-driven POST.
- **AI IP delta (contained):** memory-mapped slave wrapper (control regs,
  image buffer, result regs) around the existing datapath; ROM-loaded weights
  become SRAM-loaded (26,698 words ≈ 53 KB — trivially loadable at boot; hex
  tooling already exists).
- **Proven components in our portfolio:** argus_soc (ibex + SRAM + bootrom +
  UART, verified), trash_robot_soc (14/14 firmware POST), ex6 (picorv32 +
  SRAM + UART + GPIO + timer, firmware boot), fe-firmware skill. AXI is the
  same shape as Wishbone, richer protocol.
- **Verdict: doable — it is the natural milestone after M8, not a fantasy.**

---

## Methodology (non-negotiable, carried through every milestone)

1. **Golden-first:** trainer → frozen quantized golden → bit-exact RTL. The
   contract is the source of truth; RTL must reproduce it exactly.
2. **Honest results:** negative experiments (qat) and tool-wall limits
   (equiv induction capacity) are recorded, never papered over.
3. **Evidence versioned:** run dirs, iterations.log, WORKLOG, docs committed
   with every milestone (cnn policy now in .gitignore).
4. **Verification chain per stage:** fe-spec → fe-arch → fe-rtl → fe-yosys →
   fe-gls → fe-opensta → fe-sby → fe-cocotb/iverilog/verilator → fe-firmware →
   fe-regression → doc-* family.
5. **Every "bug" gets a root-cause note** — RTL defect vs TB miscalibration.

---

## Decisions needed from Rinri

1. **M2 architecture:** A (100/1000-class single shot) vs B (10-class engine +
   digit-split front-end) — or both as variants?
2. **M2 dataset:** synthetic concatenated MNIST first (recommended) vs SVHN?
3. **M2 scope:** 2 digits first, then 3? (Recommend: 2 → 3.)
4. **Ordering:** confirmed multi-digit (M2) before Fashion-MNIST (M3)?
5. **learn_accel (rinriAI):** resume, park, or fold into the roadmap later?
