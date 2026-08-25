# Papers

Annotated list of papers for the learning-accelerator IP. All URLs verified reachable at curation time (2026-08-20). Grouped by usefulness to this project.

## 1. Learning/training in hardware (FPGA) — direct inspiration

**EF-Train: Enable Efficient On-device CNN Training on FPGA Through Data Reshaping for Online Adaptation or Personalization**
- Peipei Zhou et al., ACM TODAES 2022 — https://peipeizhou-eecs.github.io/publication/2022_todaes/2022_todaes.pdf (mirror: https://par.nsf.gov/servlets/purl/10351238)
- On-device CNN training on edge FPGAs (PYNQ-Z1/ZCU102, CIFAR-10/ImageNet). Unified conv kernel does Forward Pass (FP) + Backward Pass (BP) + Weight Update (WU) on the same MAC resources. Data-reshaping for memory efficiency.
- **Takeaway for us:** the FP/BP/WU phase split and "one kernel, three phases" idea scales down to a tiny learner; 46.99 GFLOPS / 6.09 GFLOPS/W at 16-bit-ish precision.

**Efficient and Modularized Training on FPGA for Real-time Applications**
- IJCAI 2020 — https://www.ijcai.org/proceedings/2020/0755.pdf
- 16-bit fixed-point CNN training accelerator + Progressive Segmented Training (PST) for **online learning**: freeze pretrained weights, only update required ones on live data. CIFAR-10 on Stratix-10 MX.
- **Takeaway:** PST = the "small update surface" trick — an online learner doesn't need to retrain everything. Also confirms 16-bit fixed point is the sweet spot for training datapaths.

**Accelerating Training of Deep Neural Networks via Sparse Edge Processing**
- arXiv:1711.01343 — http://arxiv.org/pdf/1711.01343v1
- Reconfigurable architecture for **online training AND inference** on FPGAs; structured sparsity, junction pipelining, operational parallelization; Verilog RTL, MNIST experiments at various fixed-point widths.
- **Takeaway:** the closest "simple-ish" published architecture that trains MNIST-class problems on modest FPGA resources; explicitly built for online training.

**Highly-Parallel CNN Accelerator for RepVGG-like Network Training on FPGAs**
- IEEE TCAD 2024 — http://phwl.org/assets/papers/repvgg_tcad24.pdf
- Edge CNN training, 16-bit fixed point, batch-1 throughput 150 GOPs training / 183 GOPs inference (ZCU102). Task-level parallelism between backprop and weight-gradient computation.
- **Takeaway:** modern SOTA reference for edge training throughput; useful when setting our (much smaller) performance targets.

**Automatic Compiler Based FPGA Accelerator for CNN Training**
- Venkataramanaiah et al., FPL 2019 — https://ieeexplore.ieee.org/document/8892195
- Full FP/BP/WU CNN training in 16-bit fixed point; cyclic weight storage/access scheme for BRAM/DRAM (handles transpose in BP); up to 479 GOPS on Stratix 10 GX.
- **Takeaway:** the weight-storage/access scheme is the kind of micro-architecture detail we'll reuse in a weight-RAM design.

**An FPGA Architecture for Online Learning using the Tsetlin Machine**
- arXiv:2306.01027 — https://export.arxiv.org/pdf/2306.01027v1
- Online learning with the **Tsetlin machine**: logic-based (propositional clauses + reinforcement learning of automata states), only 2 hyperparameters (s, T), very low complexity, on-chip offline AND online learning, runtime class addition, fault mitigation.
- **Takeaway:** a genuine *simple* learning algorithm whose hardware cost is tiny (no multipliers for the core update!) — strong candidate for our IP if we want "learning" without a MAC array.

## 2. LMS / adaptive filters — the classic simple learning-in-silicon path

LMS = stochastic-gradient learning on a linear filter; decades of Verilog/VHDL-level references, deterministic convergence, perfect for sim + firmware experiments (system identification, noise/echo cancellation).

- **Alternative LMS Adaptive Filter Architectures for FPGA** (EUSIPCO 2002) — direct/transposed/hybrid forms; transposed DLMS 4× faster, critical path independent of tap count — https://www.eurasip.org/Proceedings/Eusipco/2002/articles/paper389.pdf
- **Realisation of LMS Adaptive Algorithm using Verilog HDL for Low-Complexity** (2015) — direct-form designs with 0/1/2 adaptation delays; minimal area & energy per sample — https://aetsjournal.com/journal_uploads/Realisation-Of-Lms-Adaptive-Algorithm-Using-Verilog-Hdl-For-Low-Complexity.pdf
- **Normalized LMS adaptive filter algorithm: principles and Verilog HDL implementation** (J. Phys. Conf. Ser. 2025) — NLMS in Verilog, better convergence than LMS — https://iopscience.iop.org/article/10.1088/1742-6596/2991/1/012021
- **An FPGA Implementation of the LMS Adaptive Filter for Active Vibration Control** (IJRET 2013) — fixed vs floating point LMS, FSM-based, Virtex-4 — https://ijret.org/volumes/2013v02/i10/IJRET20130210001.pdf
- **Efficient implementation of LMS adaptive filter-based FECG extraction on an FPGA** (IET Electronics Letters, PMC 2020) — series vs parallel LMS architectures; 32-bit IEEE-754 FPU in Verilog — https://pmc.ncbi.nlm.nih.gov/articles/PMC7704145/
- **FPGA Implementation of LMS and NLMS Adaptive Filters for Acoustic Echo Cancellation** (2011) — FSM-based RTL in VHDL; LMS vs NLMS MSE comparison — https://users.utcluj.ro/~atn/papers/ATN_4_2011_3.pdf
- **Building LMS Adaptive Filters with Register-Based FPGAs** (Old Dominion Univ. thesis) — 8-bit/16-tap LMS, single-multiplier time-shared datapath, control FSM — https://digitalcommons.odu.edu/cgi/viewcontent.cgi?article=1327&context=ece_etds
- **Design and Implementation of LMS Adaptive Filter Using Verilog** (IJISME 2025) — structural Verilog, $readmem-style file-driven testbench with input/desired-signal files — https://www.ijisme.org/wp-content/uploads/papers/v12i12/C456614030225.pdf

## 3. Surveys — the on-device-learning landscape

- **From Tiny Machine Learning to Tiny Deep Learning: A Survey** (JACM 2025, arXiv:2506.18927) — tiny on-device learning methods, hardware platforms, benchmark framework; §8 = on-device learning — https://arxiv.org/html/2506.18927v2
- **Tiny Machine Learning: Progress and Futures** (IEEE Circuits and Systems Magazine 2023, arXiv:2403.19076) — MCUNet; tiny on-device training techniques (TinyTL, TinyOL: train only last layer; POET rematerialization; MCUNetV3 QAS/sparse update) — https://arxiv.org/html/2403.19076v1
- **Efficient Deep Learning Infrastructures for Embedded Computing Systems: A Comprehensive Survey** (arXiv:2411.01431) — §5 on-device learning (continual, transfer, federated) — https://arxiv.org/html/2411.01431v1
- **A Machine Learning-oriented Survey on Tiny Machine Learning** (IEEE Access 2024, arXiv:2309.11932) — systematic review of learning algorithms under the TinyML lens — https://arxiv.org/html/2309.11932
- **Tiny Machine Learning and On-Device Inference: A Survey** (MDPI Sensors 2025) — applications/challenges; hardware landscape (MCUs, Edge TPU-class NPUs) — https://www.mdpi.com/1424-8220/25/10/3191
- **Neural Network Quantization for Microcontrollers: A Comprehensive Survey** (arXiv:2508.15008) — INT8 training/online training; Octo framework; quantization for edge learners — https://arxiv.org/html/2508.15008v4
- **A survey on versatile embedded Machine Learning hardware acceleration** (J. Systems Architecture 2025) — RISC-V custom instructions → PEs → Processing-in-Memory; bit-precision flexibility — https://dl.acm.org/doi/10.1016/j.sysarc.2025.103501

## 4. Datasets papers (for the experiment feed)

- **Fashion-MNIST: a Novel Image Dataset for Benchmarking Machine Learning Algorithms** — arXiv:1708.07747 — https://arxiv.org/abs/1708.07747 (data: https://github.com/zalandoresearch/fashion-mnist)
- MNIST (LeCun et al.) — http://yann.lecun.com/exdb/mnist/ — the canonical byte-oriented dataset.
- KMNIST (Kuzushiji) — https://codh.rois.ac.jp/kmnist/ — drop-in MNIST replacements (Kuzushiji-MNIST / -49 / -Kanji).
