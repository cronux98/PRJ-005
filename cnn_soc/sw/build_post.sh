#!/bin/bash
# build_post.sh — cnn_soc POST firmware build (fe-firmware P3, bootrom bake)
# Pure-ROM image: riscv gcc -> elf32 (ld -m elf32lriscv) -> objcopy -O verilog
# -> firmware.hex (byte-oriented, little-endian; bootrom $readmemh at vvp
# runtime, default BOOT_HEX_FILE = "sw/firmware.hex" relative to the cnn_soc
# project root).
set -euo pipefail
cd "$(dirname "$0")"

TC=riscv64-unknown-elf
COMMON="-march=rv32i -mabi=ilp32 -mno-relax -Os -ffreestanding -nostdlib \
-fno-builtin -fno-stack-protector -fno-pic -fno-pie -Wall -Wextra"

echo "== assembling start.S =="
$TC-gcc $COMMON -c start.S -o start.o

echo "== compiling post_fw.c =="
$TC-gcc $COMMON -c post_fw.c -o post_fw.o

echo "== linking (elf32lriscv, rom @ 0x00000000) =="
$TC-ld -m elf32lriscv -T link.ld -o post_fw.elf start.o post_fw.o

echo "== objcopy -O verilog -> firmware.hex =="
$TC-objcopy -O verilog post_fw.elf firmware.hex

echo "== section sizes =="
$TC-size post_fw.elf
$TC-objdump -h post_fw.elf | sed -n '1,20p'

echo "== hex size (must be <= 4096 bytes for the 4 KB bootrom) =="
wc -c firmware.hex

echo "== RV32I audit: any mul/div/rem instruction = BLOCKER =="
$TC-objdump -d post_fw.elf > post_fw.dis
if grep -E '\b(mul|mulh|mulhu|mulhsu|div|divu|rem|remu)\b' post_fw.dis; then
    echo "BLOCKER: M-extension instruction found (picorv32 ENABLE_MUL=0)"
    exit 1
fi
echo "clean: no M-extension instructions"

echo "== BUILD OK =="
