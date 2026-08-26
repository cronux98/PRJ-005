//---------------------------------------------------------------------
// post_fw.c — cnn_soc power-on self-test firmware (fe-firmware P3)
//
// Table-driven POST walker over every peripheral in the cnn_soc RTL:
//   0. UART TX        (apb_uart @ 0x4000_0000, REQ-013/014)
//   1. GPIO / LED     (apb_gpio @ 0x4000_1000, REQ-015/026)
//   2. SRAM           (sram @ 0x0001_0000, REQ-009)
//   3. vec_rom        (image/label source @ 0x1000_0000, REQ-010)
//   4. CNN accel      (cnn_axi_slave + cnn_infer + image_buffer
//                      @ 0x5000_0000, REQ-012/016..021) — full image-0
//                      inference, result checked against golden
//                      (expected_outputs.txt:1 / expected.hex:1-4:
//                      pred=7, conf=94, exp=7, verdict=0)
//   5. bus answers    (unmapped read==0 REQ-006; bootrom write-ignored
//                      REQ-008)
//
// Results scratch table in SRAM (scoreboard polls it):
//   0x0001_0000  magic 'POST' (0x504F5354)
//   0x0001_0004  nper          (6)
//   0x0001_0008  fails         (count, live-updated)
//   0x0001_000C  flags[nper]   (word per peripheral: 0=PASS 1=FAIL)
//   0x0001_0024  done marker   0xA5A5A5A5 when the walk finished
//               (wd-flag slot from the fe-firmware pattern — cnn_soc has
//               NO watchdog, so this slot is repurposed as the done flag)
//
// UART stream (byte-exact, REQ-024): header "POST cnn_soc v1\n" (the
// leading 'P' is the scoreboard's bit-time calibration byte — skill
// convention), then the golden image-0 line, then "POST nper=6 fails=%u\n".
//
// Constraints grounded in the RTL:
//   - CPU is RV32I only (picorv32 ENABLE_MUL=0 ENABLE_DIV=0, cnn_soc.v) —
//     NO mul/div instructions; all decimal conversion is manual
//     subtraction loops (values <= 999, trivially fast).
//   - Pure-ROM image (arch.md §2): 0 B .data, 0 B .bss, .text+.rodata
//     <= 4 KB, executes in place from the bootrom at 0x0000_0000.
//   - UART is fire-and-forget with DROP semantics (REQ-014): busy-poll
//     UART_STAT[0] before every byte.
//   - Register-target writes update on ANY write regardless of wstrb
//     (arch.md §7.3); CNN_IMG word writes pack pixels 4k..4k+3 into
//     bytes [7:0],[15:8],[23:16],[31:24] — a direct little-endian word
//     copy from vec_rom preserves pixel order.
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
#define SRAM_BASE   0x00010000UL
#define SRAM_TEST   0x00010100UL     // test area, clear of the results table
#define BOOTROM0    0x00000000UL
#define UNMAPPED    0x80000000UL

// Results scratch table (SRAM, fixed addresses — not .bss)
#define RES_MAGIC   0x00010000UL
#define RES_NPER    0x00010004UL
#define RES_FAILS   0x00010008UL
#define RES_FLAGS   0x0001000CUL
#define RES_DONE    0x00010024UL     // 0x0C + 6*4
#define NPER        6
#define DONE_MAGIC  0xA5A5A5A5UL
#define POST_MAGIC  0x504F5354UL     // 'POST'

typedef unsigned int u32;
typedef volatile u32 vu32;

// ---- helpers --------------------------------------------------------

static void uart_putc(char c)
{
    // Busy-poll before write: a byte written while uart_tx is busy is
    // DROPPED (REQ-014, apb_uart.v). UART_STAT[0] = !utx_ready.
    while (*(vu32 *)UART_STAT & 1UL)
        ;
    *(vu32 *)UART_TX = (u32)(unsigned char)c;
}

static void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}

// Manual decimal conversion (NO div instruction — RV32I). v <= 999.
// Writes v's digits into out (plain, right-aligned), returns count 1..3.
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

// ---- per-peripheral tests: return 0 = PASS, nonzero = FAIL ----------

// 0. UART TX: transmit a byte and observe the busy window open+close.
static int test_uart(void)
{
    uart_putc('P');                          // also the scoreboard cal byte
    unsigned long guard = 0;
    while (!(*(vu32 *)UART_STAT & 1UL)) {    // busy must rise (frame started)
        if (++guard > 100000UL) return 1;
    }
    guard = 0;
    while (*(vu32 *)UART_STAT & 1UL) {       // then fall (frame done)
        if (++guard > 2000000UL) return 1;
    }
    return 0;
}

// 1. GPIO/LED: 12-bit write/readback roundtrip (bmask 0xFFF).
static int test_gpio(void)
{
    *(vu32 *)GPIO_OUT = 0xAAAUL;
    if ((*(vu32 *)GPIO_OUT & 0xFFFUL) != 0xAAAUL) return 1;
    *(vu32 *)GPIO_OUT = 0x555UL;
    if ((*(vu32 *)GPIO_OUT & 0xFFFUL) != 0x555UL) return 1;
    return 0;
}

// 2. SRAM: full-word roundtrips at several offsets (wstrb lanes all on).
static int test_sram(void)
{
    const u32 pat = 0xDEADBEEFUL;
    u32 off;
    for (off = 0; off < 4; off++) {
        *(vu32 *)(SRAM_TEST + off * 0x100) = pat + off;
        if (*(vu32 *)(SRAM_TEST + off * 0x100) != (pat + off)) return 1;
    }
    return 0;
}

// 3. vec_rom: label of image 0 == 7 and first image word == 0 (golden).
static int test_vecrom(void)
{
    // labels.hex[0] = 07; word read little-endian -> lane 0 carries byte 0.
    if ((*(vu32 *)VEC_LABEL0 & 0xFFUL) != 7UL) return 1;
    // images.hex[0..3] = 00 00 00 00 -> array word 0 == 0.
    if (*(vu32 *)VEC_IMG0 != 0UL) return 1;
    return 0;
}

// 4. CNN accelerator: park roundtrip + full image-0 inference.
//    Golden for image 0: pred=7, conf=94, exp=7, verdict=0
//    (expected_outputs.txt:1, expected.hex:1-4).
static int test_cnn(void)
{
    u32 r;
    // 4a. CNN_CTRL PARK roundtrip: write 1 -> read {30'b0,park,1'b0}=0x2,
    //     write 0 -> read 0. START strobe reads 0 (arch.md §7.3).
    *(vu32 *)CNN_CTRL = 0x2UL;
    if (*(vu32 *)CNN_CTRL != 0x2UL) return 1;
    *(vu32 *)CNN_CTRL = 0x0UL;
    if (*(vu32 *)CNN_CTRL != 0x0UL) return 1;
    // 4b. STATUS idle: {30'b0, done, busy} = 0 (parked after reset).
    if (*(vu32 *)CNN_STATUS != 0UL) return 1;
    // 4c. Copy image 0: 784 bytes = 196 words from vec_rom to CNN_IMG.
    //     Little-endian word copy preserves pixel order (arch.md §7.3);
    //     the slave drains 4 byte-writes per word (backpressure holds the
    //     adapter), so stores serialize by hardware.
    u32 k;
    for (k = 0; k < 196; k++) {
        *(vu32 *)(CNN_IMG + 4 * k) = *(vu32 *)(VEC_IMG0 + 4 * k);
    }
    // 4d. Expected label -> CNN_EXP (REQ-019), then START (REQ-016).
    *(vu32 *)CNN_EXP = 7UL;
    *(vu32 *)CNN_CTRL = 0x1UL;               // START write-1 strobe, PARK=0
    // 4e. Poll DONE (STATUS[1]); BUSY[0] rises first. Bound: 667,208
    //     compute cycles (arch.md §6.5) + image drain; 3M polls * ~4 cyc
    //     is a comfortable margin. LED[11] = busy indicator (REQ-026).
    u32 guard;
    for (guard = 0; guard < 3000000UL; guard++) {
        *(vu32 *)GPIO_OUT = 0x800UL;         // LED[11] busy
        if (*(vu32 *)CNN_STATUS & 0x2UL) break;
    }
    if (!(*(vu32 *)CNN_STATUS & 0x2UL)) return 1;  // DONE timeout
    // 4f. Result latch: pred[3:0], conf[14:8], verdict[17:16] (arch §7.3).
    r = *(vu32 *)CNN_RESULT;
    if ((r & 0xFUL) != 7UL) return 1;        // golden pred
    if (((r >> 8) & 0x7FUL) != 94UL) return 1; // golden confidence
    if (((r >> 16) & 0x3UL) != 0UL) return 1;  // golden CORRECT
    return 0;
}

// 5. Bus answers: unmapped read == 0 (REQ-006); bootrom write-ignored
//    (REQ-008) — read word, write junk, read again, must be unchanged.
static int test_bus(void)
{
    if (*(vu32 *)UNMAPPED != 0UL) return 1;  // unmapped -> read 0
    u32 w1 = *(vu32 *)BOOTROM0;              // first instruction word
    *(vu32 *)BOOTROM0 = 0xDEADBEEFUL;        // ignored write (no store)
    u32 w2 = *(vu32 *)BOOTROM0;
    if (w1 != w2) return 1;
    return 0;
}

// ---- golden UART line for image 0 (REQ-024, byte-exact) -------------
static void tx_golden_line(u32 pred, u32 conf, u32 exp, u32 verdict)
{
    char line[80];
    char *p = line;
    const char *s = "IMG ";
    unsigned i, n;
    char d[4];
    while (*s) *p++ = *s++;
    dec3pad(p, 0); p += 3;                   // image index %03u
    s = ": This is number "; while (*s) *p++ = *s++;
    n = dec3(d, pred); for (i = 0; i < n; i++) *p++ = d[i];
    s = " | confidence "; while (*s) *p++ = *s++;
    n = dec3(d, conf); for (i = 0; i < n; i++) *p++ = d[i];
    *p++ = '%';                              // literal %% in the format
    s = " | expected "; while (*s) *p++ = *s++;
    n = dec3(d, exp); for (i = 0; i < n; i++) *p++ = d[i];
    s = " | "; while (*s) *p++ = *s++;
    s = (verdict == 0) ? "CORRECT" : (verdict == 1) ? "INCORRECT" : "TRASH";
    while (*s) *p++ = *s++;
    *p++ = '\n';
    *p = 0;
    uart_puts(line);
}

// ---- main -----------------------------------------------------------
void main(void)
{
    static int (*const tests[NPER])(void) = {
        test_uart, test_gpio, test_sram, test_vecrom, test_cnn, test_bus
    };
    u32 flags[NPER];                         // stack, not .bss
    u32 fails = 0;
    u32 i;

    // Results table header before the walk (scoreboard can read live).
    *(vu32 *)RES_MAGIC = POST_MAGIC;
    *(vu32 *)RES_NPER  = NPER;
    *(vu32 *)RES_FAILS = 0;
    for (i = 0; i < NPER; i++) *(vu32 *)(RES_FLAGS + 4 * i) = 0xFFFFFFFFUL;

    uart_puts("POST cnn_soc v1\n");          // 'P' = calibration byte

    for (i = 0; i < NPER; i++) {
        int f = tests[i]();
        flags[i] = (u32)(f ? 1 : 0);         // 1 = FAIL, 0 = PASS
        if (f) fails++;
        *(vu32 *)(RES_FLAGS + 4 * i) = flags[i];
        *(vu32 *)RES_FAILS = fails;          // live-update
    }

    // Golden line + summary over UART (REQ-024). Result regs are still
    // latched (held until the next START); exp = firmware's own vec_rom
    // label copy (REQ-024 note).
    u32 r = *(vu32 *)CNN_RESULT;
    u32 exp = *(vu32 *)VEC_LABEL0 & 0xFFUL;
    tx_golden_line(r & 0xFUL, (r >> 8) & 0x7FUL, exp, (r >> 16) & 0x3UL);
    uart_puts("POST nper=6 fails=");
    {
        char d[4]; unsigned n = dec3(d, fails);
        for (unsigned j = 0; j < n; j++) uart_putc(d[j]);
    }
    uart_putc('\n');

    // Walk finished marker (wd-flag slot; no WDT in cnn_soc).
    *(vu32 *)RES_DONE = DONE_MAGIC;

    // Final LED (REQ-026 encoding): [9:0] one-hot pred (0 on TRASH),
    // [10] fail, [11] busy. Result regs still latched.
    u32 led = (fails == 0) ? (1UL << (r & 0xFUL)) : 0UL;
    if (((r >> 16) & 0x3UL) == 2UL) led = 0; // TRASH -> no one-hot
    if (fails) led |= 0x400UL;               // [10] fail indicator
    *(vu32 *)GPIO_OUT = led;

    for (;;) ;                               // halt; scoreboard done
}
