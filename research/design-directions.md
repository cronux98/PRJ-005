# Design directions — candidate IP architectures

Synthesized from the papers/books in this directory. The goal is a **simple learning AI accelerator**: RTL that performs online learning (weights update from a stream of samples), testable in sim AND firmware, fed by downloadable datasets.

## The design space (what "learning" can mean here)

1. **Online SGD on a neural net** (Nielsen ch.1–2; sparse-edge-processing arXiv:1711.01343)
   - Full forward pass + backward pass + weight update in RTL. Most "real" option; the FPGA-CNN-training papers (EF-Train, FPL 2019, IJCAI 2020) are scale-down references.
   - Cost: needs a MAC datapath + activation (sigmoid/tanh or ReLU) + error-gradient path. Multiplier-heavy but at our tiny scale (e.g., 784→32→10) it's modest.
   - MNIST accuracy target ~90%+ with plain SGD — directly comparable to Nielsen's software results.

2. **LMS adaptive filter core** (papers.md §2 — the deepest hardware literature)
   - The simplest true "learning" circuit: y = w·x, error e = d − y, w ← w + μ·e·x. One MAC, one weight RAM, one FSM. Step size μ = power of two → shift, no multiplier for the update.
   - Deterministic convergence, easy to verify in sim AND in firmware (system identification / noise-cancellation experiments with generated traces).
   - Weakness: linear model — "AI accelerator" claim is modest. Can be presented as a **learnable linear layer / online linear classifier** (which IS a perceptron — the same math as a single-layer NN).

3. **Tsetlin machine** (arXiv:2306.01027)
   - Logic-based online learning: propositional clauses, automata states updated by reinforcement — **no multipliers in the learning core**. Very low complexity, 2 hyperparameters.
   - Hardware-friendly and genuinely "learning"; less mainstream math for reviewers, and firmware/driver support must be authored from scratch.

4. **Tiny transfer learning** (TinyML surveys: TinyOL — train only the last layer on-device)
   - Fixed feature extractor + trainable output layer. Reduces the backward pass to last-layer-only (no backprop through hidden layers) — dramatically simpler RTL while keeping a real "learning" claim.
   - Middle ground between (1) and (2).

## Recommendation

**Primary: a small MLP with online SGD training (direction 1), structured so the training surface is simple.** Concretely:

- **Learner:** 2-layer MLP (e.g., 784-32-10 for MNIST-class data, parameterized: FEATURES × HIDDEN × CLASSES), online SGD per sample (or tiny mini-batches), 16-bit signed fixed point (the proven precision from the FPGA-training papers), power-of-2 learning rate, weights in a dual-port RAM.
- **Interface:** register/CSR block (APB or simple bus) for firmware: control (start/step/halt, learning rate, freeze), status (busy, sample count, error/accuracy counters), weight load/dump, sample push (streaming port or mailbox RAM).
- **Experiments:** firmware streams MNIST/Fashion/Kuzushiji samples (converted to hex), runs train/eval loops, prints accuracy — the "fed by online datasets" story.
- **Phased RTL:** (a) MAC + activation + inference only; (b) + last-layer training (direction 4 trick, reduces backprop); (c) + full backprop. Each phase is sim- and firmware-testable independently — fits the front-end pipeline gates.

**Alternative if Rinri wants maximum simplicity:** LMS adaptive-filter core (direction 2) as a "learnable linear layer" with system-identification experiments. Cheapest to verify, deepest Verilog literature to borrow from.

**Wildcard:** Tsetlin machine (direction 3) if we want the most distinctive "learning accelerator" story with minimal arithmetic.

## Requirements sketch (to hand to the architect agent)

- Pure Verilog-2001/2005 (front-end pipeline hard requirement), no SystemVerilog.
- Clock + synchronous reset; single clock domain; no latches; no `#` delays in RTL.
- Memory: inferred SRAM (weight RAM, sample buffer) as synthesis-ready `reg` arrays or SRAM blackbox (fe-yosys bbox boundary) — decide with the architect.
- CSR interface for firmware (follows fe-arch bus conventions from the front-end skills).
- Deterministic, bit-exact vs. a software golden model (fe-arch emits golden_ref_model.c + expected vectors — the accuracy counters must match).
- Deliverables per front-end pipeline: spec/ (fe-spec), arch/ (fe-arch incl. golden model + verification plan), rtl/ (fe-rtl with filelist.f + sdc_spec.json).
