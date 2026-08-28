//---------------------------------------------------------------------
// start.S — cnn_soc boot stub (fe-firmware P3)
// Must be the FIRST bytes at the reset vector (PROGADDR_RESET=0x0000_0000,
// picorv32_axi). Stack = top of 128 KB SRAM = STACKADDR 0x0003_0000
// (cnn_soc.v instantiation). Pure-ROM image: nothing is copied; the
// firmware executes in place from the bootrom (REQ-003/004).
//---------------------------------------------------------------------
    .section .text.start
    .global _start
_start:
    li   sp, 0x00030000       # STACKADDR (top of SRAM, grows down)
    jal  main                 # into the C POST walker
1:  j    1b                   # halt after main returns (scoreboard reads SRAM)
