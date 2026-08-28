# cnn_systolic SYNTHESIS filelist — memories replaced by same-name blackbox
# stubs (synth/*_bbox.v) so the gate netlist keeps them opaque; simulation
# uses filelist.f (real bodies).  bias_regfile stays REAL (flop array, not
# a macro).  Order: reused leaves first, custom blocks, top LAST.

# ---- Reused IP ----
ip/uart_tx.v
ip/picorv32.v

# ---- Reused shell (memory bodies replaced by stubs below) ----
rtl/apb_gpio.v
rtl/axi2apb.v
rtl/axi_lite_interconnect.v
rtl/cnn_axi_slave.v
synth/sram_bbox.v
synth/bootrom_bbox.v
synth/vec_rom_bbox.v
rtl/apb_uart.v

# ---- FP units ----
rtl/fpu_fp32_add.v
rtl/fpu_fp32_mul.v
rtl/fpu_bf16_mul.v
rtl/fpu_bf16_round.v
rtl/fpu_bf16_expand.v
rtl/fpu_sigmoid.v
rtl/fpu_sigma256.v

# ---- Accelerator memories (blackbox stubs) + bias regfile (real) ----
synth/weight_rom_bbox.v
synth/fm_ram_bbox.v
synth/img_banks_bbox.v
synth/p1_banks_bbox.v
rtl/bias_regfile.v

# ---- Accelerator core ----
rtl/systolic_array.v
rtl/conv_ctrl.v
rtl/pool_unit.v
rtl/fc_datapath.v
rtl/cnn_core.v

# ---- Top ----
rtl/cnn_systolic.v
