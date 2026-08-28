/* link.ld — cnn_soc POST firmware, bootrom-bake variant.
 * Pure-ROM image contract (arch.md §2): 0 B .data, 0 B .bss,
 * .text+.rodata <= 4 KB, executes in place at 0x0000_0000 (REQ-003/004).
 * Any .data/.bss/.sdata emitted by the compiler is a HARD link error
 * (--orphan-handling=error): the firmware must be position-independent
 * code with const-only globals; runtime state lives on the SRAM stack
 * or in the fixed SRAM scratch table (volatile pointers, not .bss).
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    rom (rx) : ORIGIN = 0x00000000, LENGTH = 0x1000   /* 4 KB bootrom (MEM-001) */
}

SECTIONS {
    .text : {
        *(.text.start)          /* boot stub FIRST at the reset vector */
        *(.text*)
    } > rom

    .rodata : {
        *(.rodata*)
        *(.srodata*)
    } > rom

    /DISCARD/ : {
        *(.riscv.attributes)    /* metadata only — not loaded */
        *(.comment)
        *(.note*)
        *(.eh_frame*)
    }
}
