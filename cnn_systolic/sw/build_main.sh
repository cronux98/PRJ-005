#!/bin/bash
# build_main.sh — cnn_soc 100-image demo firmware build (fe-firmware P4 REDO)
# Same toolchain discipline as build_post.sh: riscv gcc -> elf32lriscv ->
# objcopy -O verilog -> sw/firmware.hex (bootrom-bake, RTL-default path).
set -euo pipefail
cd "$(dirname "$0")"

TC=riscv64-unknown-elf
COMMON="-march=rv32i -mabi=ilp32 -mno-relax -Os -ffreestanding -nostdlib \
-fno-builtin -fno-stack-protector -fno-pic -fno-pie -Wall -Wextra"

echo "== assembling start.S =="
$TC-gcc $COMMON -c start.S -o main_start.o

echo "== compiling main.c =="
$TC-gcc $COMMON -c main.c -o main.o

echo "== linking (elf32lriscv, rom @ 0x00000000) =="
$TC-ld -m elf32lriscv -T link.ld -o main.elf main_start.o main.o

echo "== objcopy -O verilog -> firmware.hex =="
$TC-objcopy -O verilog main.elf firmware.hex

echo "== section sizes =="
$TC-size main.elf
$TC-objdump -h main.elf | sed -n '1,20p'

echo "== hex size (must be <= 4096 bytes for the 4 KB bootrom) =="
wc -c firmware.hex
md5sum firmware.hex

echo "== RV32I audit: any mul/div/rem instruction = BLOCKER =="
$TC-objdump -d main.elf > main.dis
if grep -E '\b(mul|mulh|mulhu|mulhsu|div|divu|rem|remu)\b' main.dis; then
    echo "BLOCKER: M-extension instruction found (picorv32 ENABLE_MUL=0)"
    exit 1
fi
echo "clean: no M-extension instructions"

echo "== BUILD OK =="
