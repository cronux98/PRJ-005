# cnn_soc fe-rtl filelist — run iverilog from the cnn_soc project root
# (all $readmemh paths and `include "rtl/..." resolve from there — PLAN.md R5)
#
# Order: reused leaves first (dependency order), custom blocks, top LAST.
# rtl/cnn_defs.vh + rtl/mnist_npu_defs.vh are NOT listed — they are pulled in
# by the reused files' own `include "rtl/..." (cnn project convention).

# ---- Reused IP (byte-for-byte copies; see ip/IP_PROVENANCE.md) ----
ip/ctrl_fsm.v
ip/mac_datapath.v
ip/win_addr_gen.v
ip/fm_ram.v
ip/weight_rom.v
ip/sigmoid_lut.v
ip/uart_tx.v
ip/picorv32.v

# ---- Custom blocks (BLK-011..BLK-003, top last) ----
rtl/image_buffer.v
rtl/apb_gpio.v
rtl/bootrom.v
rtl/vec_rom.v
rtl/sram.v
rtl/apb_uart.v
rtl/axi2apb.v
rtl/axi_lite_interconnect.v
rtl/cnn_infer.v
rtl/cnn_axi_slave.v
rtl/cnn_soc.v
