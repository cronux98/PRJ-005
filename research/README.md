# Research — Learning AI Accelerator

Curated starting material for a **simple learning AI accelerator IP**: hardware that can *train/adapt online* (on-device learning), testable in sim + firmware, fed by online datasets as experiments.

## How to read this

1. `books.md` — free online textbooks. **Start with Nielsen ch. 1–3** (perceptron, SGD, backprop — the exact math an online-learning accelerator implements) and **UML ch. 21** (online learning theory). Goodfellow ch. 5.9 (SGD) is the deeper reference.
2. `papers.md` — annotated papers. The **FPGA CNN-training** cluster shows what full training hardware looks like (overkill for us, but the FP/BP/WU structure and fixed-point choices are directly reusable); the **LMS/adaptive-filter** cluster is the classic *simple* learning-in-silicon path (plenty of Verilog-level references); the **Tsetlin machine** paper is the low-complexity online-learning alternative; the **surveys** map the on-device-learning landscape.
3. `datasets.md` — downloadable byte-oriented datasets that can be streamed into firmware as experiments.
4. `design-directions.md` — candidate IP architectures synthesized from the above, with a recommendation and a requirements sketch.

## Quick map

| Topic | Where |
|-------|-------|
| Online learning math (SGD, backprop) | books.md (Nielsen, UML, Goodfellow) |
| CNN training on FPGA (FP/BP/WU datapaths) | papers.md §1 |
| Tsetlin machine — logic-based online learning | papers.md §1 |
| LMS adaptive filter — simplest learning hardware | papers.md §2 |
| On-device/tiny training surveys | papers.md §3 |
| Datasets for experiments | datasets.md |
| Candidate IP architectures | design-directions.md |
