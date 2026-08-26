//---------------------------------------------------------------------
// File        : mnist_npu_defs.vh
// Project     : mnist_npu                Technology : FPGA-generic (Artix-7 100T / Nexys A7 target)
// Description : Shared `define defaults for memory-init file paths. Paths are
//               relative to the mnist_npu project root, so `iverilog` invoked
//               from that root (per the project brief's fe-rtl exit check)
//               finds them. Not a parameter file: Verilog-2001 module
//               parameters cannot hold string defaults portably across all
//               simulators when shared across many modules, so the golden
//               hex paths are centralised here via `define and each module's
//               own `parameter ... = \`MNIST_NPU_WEIGHTS_HEX` picks them up
//               (arch/arch.md §7 memory-initialisation mechanism).
// Traces      : REQ-012, REQ-013, REQ-014, arch.md §7
//---------------------------------------------------------------------
`ifndef MNIST_NPU_DEFS_VH
`define MNIST_NPU_DEFS_VH

`ifndef MNIST_NPU_WEIGHTS_HEX
`define MNIST_NPU_WEIGHTS_HEX "arch/golden_model/weights.hex"
`endif

`ifndef MNIST_NPU_IMAGES_HEX
`define MNIST_NPU_IMAGES_HEX "arch/golden_model/images.hex"
`endif

`ifndef MNIST_NPU_LABELS_HEX
`define MNIST_NPU_LABELS_HEX "arch/golden_model/labels.hex"
`endif

`ifndef MNIST_NPU_SIGMOID_LUT_HEX
`define MNIST_NPU_SIGMOID_LUT_HEX "rtl/sigmoid_lut.hex"
`endif

`endif // MNIST_NPU_DEFS_VH
