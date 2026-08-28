//---------------------------------------------------------------------
// main.c — cnn_systolic 100-image demo driver (fe-firmware P5)
//
// Loops images 0..99: copy image from vec_rom to CNN_IMG, write
// CNN_EXP=label, START, poll DONE, read CNN_RESULT, print the exact
// golden UART line (REQ-024), drive the LED pattern (REQ-026).
// After image 99: spin forever.
//
// Grounded in: arch.md §7.3 register map, spec §4.1 UART framing,
// golden data cnn_systolic/arch/golden_model/{expected_outputs.txt,
// expected.hex} (regenerated FP contract — BRIEF decision 9).
//
// Memory map (arch.md §7.1/§7.3 — IDENTICAL to cnn_soc):
//   vec_rom  images @ 0x1000_0000 (784 B/image), labels @ 0x1000_0000+0x13240
//   CNN_CTRL 0x5000_0000 [0]=START strobe [1]=PARK
//   CNN_STATUS 0x5000_0004 [0]=BUSY [1]=DONE
//   CNN_RESULT 0x5000_0008 [3:0]=pred [14:8]=conf [17:16]=verdict
//   CNN_EXP  0x5000_000C [3:0]=expected label
//   CNN_IMG  0x5000_0100 (784 B, word write packs 4 pixels LE)
//   UART_TX 0x4000_0000 (W), UART_STAT 0x4000_0004 [0]=busy
//   GPIO_OUT 0x4000_1000 -> led[11:0]
//
// UART line (byte-exact, spec §4.1 / REQ-024 — identical to cnn_soc):
//   verdict 0: "IMG %03u: This is number %u | confidence %u%% | expected %u | CORRECT\n"
//   verdict 1: "IMG %03u: This is number %u | confidence %u%% | expected %u | INCORRECT\n"
//   verdict 2: "IMG %03u: NOT A NUMBER | confidence %u%% | expected %u | TRASH\n"
//   Single 0x0A, no 0x0D. exp printed from the firmware's own vec_rom
//   label copy — agrees with CNN_EXP by construction.
//
// Constraints:
//   - Pure-ROM image (arch §2): 0 B .data, 0 B .bss, .text+.rodata <= 4 KB,
//     executes in place from the bootrom at 0x0000_0000.
//   - RV32I only (picorv32 ENABLE_MUL=0 ENABLE_DIV=0): NO mul/div
//     instructions; decimal conversion is manual subtraction loops.
//   - UART fire-and-forget with DROP semantics (REQ-014): busy-poll
//     UART_STAT[0] before every byte.
//   - No volatile store/readback at addr 0x0 (GCC -Os folds NULL-addr
//     deref into ebreak — cnn_soc P4 lesson).
//
// Poll bound (P5, re-derived for cnn_systolic): the accelerator compute
// budget is ≈ 755,400 cycles/image (arch.md §6.5: conv1 137,993 + pool1
// 9,408 + conv2 577,168 + pool2 4,704 + FC1 25,440 + FC2 440 + staging ≈
// 256) → BUSY ≤ 760,000 cycles per START (REQ-021/037, ASM-008).  The
// guard is 760,000 poll iterations ≈ 3.04M cycles ≈ 4× margin over the
// BUSY bound (cnn_soc's 667,208-cycle bound / 3M-iteration guard does NOT
// apply to this design).
//---------------------------------------------------------------------

#define UART_TX     0x40000000UL
#define UART_STAT   0x40000004UL
#define GPIO_OUT    0x40001000UL
#define CNN_CTRL    0x50000000UL
#define CNN_STATUS  0x50000004UL
#define CNN_RESULT  0x50000008UL
#define CNN_EXP     0x5000000CUL
#define CNN_IMG     0x50000100UL
#define VEC_IMG0    0x10000000UL
#define VEC_LABEL0  0x10013240UL     // labels at vec_rom +0x13240 (arch.md §7.3)

typedef unsigned int u32;
typedef volatile u32 vu32;
typedef volatile unsigned char vu8;

// ---- UART (busy-poll before each byte: write-while-busy drops, REQ-014)
static void uart_putc(char c)
{
    while (*(vu32 *)UART_STAT & 1UL)
        ;
    *(vu32 *)UART_TX = (u32)(unsigned char)c;
}

static void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}

// Manual decimal conversion (NO div — RV32I). v <= 999. Writes v's digits
// into out (plain, right-aligned), returns count 1..3.
static unsigned dec3(char *out, u32 v)
{
    char raw[3];
    unsigned n = 0;
    do {
        u32 q = 0;
        while (v >= 10) { v -= 10; q++; }   // q = v/10, v = v%10
        raw[n++] = (char)('0' + v);
        v = q;
    } while (v);
    for (unsigned i = 0; i < n; i++) out[i] = raw[n - 1 - i];
    return n;
}

// zero-padded 3-digit decimal ("%03u"), v <= 999
static void dec3pad(char *out, u32 v)
{
    char raw[3];
    unsigned n = 0;
    do {
        u32 q = 0;
        while (v >= 10) { v -= 10; q++; }
        raw[n++] = (char)('0' + v);
        v = q;
    } while (v);
    out[0] = out[1] = out[2] = '0';
    for (unsigned i = 0; i < n; i++) out[2 - i] = raw[i];
}

// ---- copy image i (784 bytes = 196 words) from vec_rom to CNN_IMG.
//      Little-endian word copy preserves pixel order (arch.md §7.3);
//      the slave's 4-lane drain serializes each word store (backpressure).
static void load_image(u32 img_base)
{
    u32 k;
    for (k = 0; k < 196; k++) {
        *(vu32 *)(CNN_IMG + 4 * k) = *(vu32 *)(img_base + 4 * k);
    }
}

// ---- print the golden UART line for image idx (REQ-024, byte-exact) ----
static void tx_line(u32 idx, u32 pred, u32 conf, u32 exp, u32 verdict)
{
    char line[80];
    char *p = line;
    const char *s;
    unsigned i, n;
    char d[4];

    s = "IMG "; while (*s) *p++ = *s++;
    dec3pad(p, idx); p += 3;                    // image index %03u
    if (verdict == 2) {
        s = ": NOT A NUMBER | confidence "; while (*s) *p++ = *s++;
    } else {
        s = ": This is number "; while (*s) *p++ = *s++;
        n = dec3(d, pred); for (i = 0; i < n; i++) *p++ = d[i];
        s = " | confidence "; while (*s) *p++ = *s++;
    }
    n = dec3(d, conf); for (i = 0; i < n; i++) *p++ = d[i];
    *p++ = '%';                                 // literal %% in the format
    s = " | expected "; while (*s) *p++ = *s++;
    n = dec3(d, exp); for (i = 0; i < n; i++) *p++ = d[i];
    s = " | "; while (*s) *p++ = *s++;
    s = (verdict == 0) ? "CORRECT" : (verdict == 1) ? "INCORRECT" : "TRASH";
    while (*s) *p++ = *s++;
    *p++ = '\n';
    *p = 0;
    uart_puts(line);
}

// ---- LED pattern (REQ-026): [9:0] one-hot pred (0 on TRASH),
//      [10] fail, [11] busy indicator.
static void led_set(u32 pat)
{
    *(vu32 *)GPIO_OUT = pat & 0xFFFUL;
}

void main(void)
{
    u32 i;
    u32 img_base = VEC_IMG0;

    for (i = 0; i < 100; i++) {
        // own vec_rom label copy (spec §6.3 note): BYTE load (lbu) so
        // picorv32 extracts the correct lane for unaligned i (a 32-bit
        // load would always take lane 0 — wrong for i%4 != 0)
        u32 label = (u32)*(vu8 *)(VEC_LABEL0 + i);

        // busy indicator while the image is being copied + inferred
        led_set(0x800UL);                                  // LED[11] busy

        load_image(img_base);
        *(vu32 *)CNN_EXP = label;                          // REQ-019
        *(vu32 *)CNN_CTRL = 0x1UL;                         // START strobe, PARK=0

        // poll DONE (STATUS[1]); bound: compute ≈ 755,400 cycles/image
        // (arch §6.5), BUSY <= 760,000 (REQ-021/037). 760K polls * ~4 cyc
        // ≈ 3.04M cycles ≈ 4x margin.
        u32 guard;
        for (guard = 0; guard < 760000UL; guard++) {
            if (*(vu32 *)CNN_STATUS & 0x2UL) break;
        }
        if (!(*(vu32 *)CNN_STATUS & 0x2UL)) {
            // DONE timeout: park + fail LED, then halt (gate watchdog fires)
            *(vu32 *)CNN_CTRL = 0x2UL;                     // PARK (abort)
            led_set(0x400UL);                              // LED[10] fail
            for (;;) ;
        }

        // result latch: pred[3:0], conf[14:8], verdict[17:16] (arch §7.3)
        u32 r = *(vu32 *)CNN_RESULT;
        u32 pred = r & 0xFUL;
        u32 conf = (r >> 8) & 0x7FUL;
        u32 verdict = (r >> 16) & 0x3UL;

        // LED at the presented instant (REQ-026): one-hot pred, 0 on
        // TRASH, [10] fail = (verdict != 0), [11] busy = 0. Written
        // BEFORE the UART line so the pattern is stable at the DONE edge
        // (VP-TOP-004 samples at the presented instant).
        u32 led = (verdict == 2) ? 0UL : (1UL << pred);
        if (verdict != 0) led |= 0x400UL;
        led_set(led);

        tx_line(i, pred, conf, label, verdict);

        img_base += 784UL;
    }

    for (;;) ;                               // image 99 done: spin forever
}
