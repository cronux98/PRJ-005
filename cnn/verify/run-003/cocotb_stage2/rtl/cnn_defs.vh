//---------------------------------------------------------------------
// File        : cnn_defs.vh
// Project     : cnn (mnist_npu v2)      Technology : FPGA-generic (Artix-7 100T / Nexys A7 target)
// Description : Shared `define defaults for memory-init file paths of the
//               NEW cnn-specific ROMs (weight_rom/image_rom/label_rom).
//               sigmoid_lut.v is reused verbatim from v1 and keeps using
//               mnist_npu_defs.vh / MNIST_NPU_SIGMOID_LUT_HEX unchanged
//               (also copied into this rtl/ directory) — this file does
//               NOT redefine that macro, avoiding any edit to the reused
//               file. Paths are relative to the cnn project root, so
//               `iverilog` invoked from that root finds them.
// Traces      : REQ-019, REQ-020, REQ-021, arch.md §7.2
//---------------------------------------------------------------------
`ifndef CNN_DEFS_VH
`define CNN_DEFS_VH

`ifndef CNN_WEIGHTS_HEX
`define CNN_WEIGHTS_HEX "arch/golden_model/weights.hex"
`endif

`ifndef CNN_IMAGES_HEX
`define CNN_IMAGES_HEX "arch/golden_model/images.hex"
`endif

`ifndef CNN_LABELS_HEX
`define CNN_LABELS_HEX "arch/golden_model/labels.hex"
`endif

`endif // CNN_DEFS_VH
