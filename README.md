# PRJ-005 — AI Accelerator Projects

Umbrella repo for two AI-accelerator IP projects. Both target Sky130 via the
front-end ASIC pipeline (fe-spec → fe-arch → fe-rtl → fe-yosys → fe-gls →
fe-opensta → fe-sby → … → fe-regression) and are verified in simulation first
(FPGA on Nexys A7 is planned but deferred — simulation-first per Rinri
2026-08-25).

## Projects

| Directory | Project | What it does |
|-----------|---------|--------------|
| `learn_accel/` | **rinriAI** (training + inference) | MLP (784-32-10) that *learns*: streams labeled MNIST-class samples, online SGD per sample (forward = inference, backward + weight update = training), freeze bit for inference-only, APB CSR + streaming interface, live correct/error counters. |
| `mnist_npu/` | **MNIST inference NPU** (inference only) | Tiny inference-only accelerator: pre-trained Q8.8 weights + dataset loaded from memory ($readmemh BRAM), LUT sigmoid, single MAC forward pass, argmax; LED 0-9 digit display, LED10 trash/failure, LED11 busy blink, UART TX "This is number N | confidence % | expected | CORRECT/INCORRECT". No training, no host CPU. |

## Repo history

- 2026-08-20: repo created as `learning-accelerator-ip`, renamed PRJ-005 (rinriAI).
- 2026-08-25: reorganized into `learn_accel/` (existing training+inference project,
  moved intact) + `mnist_npu/` (new inference-only project). FPGA deferred;
  golden-model-first flow for mnist_npu.
