/*-------------------------------------------------------------------------
 * golden_ref_model.c — cnn_systolic FP golden reference model (fe-arch)
 *
 * Bit-exact mirrored-dataflow reference for the BF16 systolic CNN accelerator
 * (REQ-029, BRIEF.md decisions 1/2/4/8).  INTEGER-ONLY C99: the FP32 datapath
 * is emulated bit-for-bit (RN-even, flush-to-zero) with no floating point in
 * the model's arithmetic — the same bits the RTL must produce.
 *
 * Contract (binding):
 *   - BF16 operands (weights, activations, biases), FP32 accumulate.
 *   - fp32 add/mul: IEEE-754 RN-even with subnormal FLUSH-TO-ZERO (ASM-003);
 *     x + +/-0 = x; exact-zero results are +0; overflow -> +/-Inf
 *     (unreachable by range analysis, arch.md §5.1).
 *   - Conv accumulate order: systolic_dataflow.md §3-4 (bias first, then the
 *     pinned sub-pass/column order; conv1: pass A taps 0..7, pass B tap 8 in
 *     column 0 fed from bank 8, columns 1..7 zero-weighted; conv2: (iy,ix)
 *     k=0..8 outer, ic c=0..7 inner, oc-group 0 before 1).
 *   - FC order: systolic_dataflow.md §5 (bias first, inputs ascending).
 *   - Piecewise sigmoid: piecewise_sigmoid.md (dyadic constants as exact
 *     uint32 bit patterns; sigma = fadd(fmul(m,|z|),c); z<0 -> 1-sigma).
 *   - Confidence: sigma256 = trunc(fadd(fmul(sigma,256.0),0.5));
 *     argmax strict '>' lowest-index ties; conf = (best*100)>>8;
 *     verdict = conf<50 ? 2 : (best==exp ? 0 : 1).
 *   - Weights: weights_bf16.hex (26,698 BF16 words, layout per
 *     systolic_dataflow.md §6) — the identical converted values the RTL
 *     weight ROM loads (ASM-009).
 *
 * Build:  gcc -std=c99 -O2 -Wall -Wextra -o gm golden_ref_model.c
 * Run  :  ./gm [root]            -> full 10,000-image run; writes
 *             {root}/arch/golden_model/{expected_outputs.txt (100 lines),
 *             expected.hex (400 words), stimulus.hex (78,400 words),
 *             labels.hex (100 words)}; prints the full UART stream + summary.
 *         ./gm --vectors         -> directed vector self-test; prints
 *             "VEC ..." lines (diff vs expected_vectors.txt).
 * Determinism: fixed-width integer arithmetic only; no float, no malloc,
 * no time/address-dependent output; byte-identical on every run/machine.
 *-------------------------------------------------------------------------*/
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "golden_model_test_vectors.h"

/* ---------------------------- FP32 emulation ---------------------------- */

typedef uint32_t fp32;

static int g_dbg = -1;          /* cached GM_DEBUG flag (hot-loop safe)    */
#define GM_DBG (g_dbg < 0 ? (g_dbg = getenv("GM_DEBUG") != NULL) : g_dbg)

static uint64_t g_ftz_add;      /* subnormal RESULT flushes in fp32 add   */
static uint64_t g_ftz_mul;      /* subnormal RESULT flushes in fp32 mul   */
static uint64_t g_ftz_bf16;     /* subnormal-INPUT flushes in bf16_round  */
static uint64_t g_ftz_in;       /* subnormal-INPUT flushes in add/mul     */

static fp32 f32_add(fp32 a, fp32 b);
static fp32 f32_mul(fp32 a, fp32 b);

static inline int clz64_u(uint64_t x)
{
    return __builtin_clzll(x);
}

/* fp32 add: IEEE-754 RN-even, FTZ.  Exact-zero result -> +0 (pinned). */
static fp32 f32_add(fp32 a, fp32 b)
{
    uint32_t sa = a >> 31, sb = b >> 31;
    int32_t  ea = (int32_t)((a >> 23) & 0xFF);
    int32_t  eb = (int32_t)((b >> 23) & 0xFF);
    uint32_t ma = a & 0x7FFFFFu, mb = b & 0x7FFFFFu;
    uint32_t ma0 = ma, mb0 = mb;

    if (ea == 0) { ma = 0; if (ma0 != 0) g_ftz_in++; }        /* FTZ inputs */
    if (eb == 0) { mb = 0; if (mb0 != 0) g_ftz_in++; }
    if (ea == 0xFF || eb == 0xFF)             /* NaN/Inf: unreachable (contract); */
        return (ea == 0xFF ? sa : sb) ? 0xFF800000u : 0x7F800000u;
    if (ea == 0 && eb == 0) return 0x00000000u;        /* +0 (RN exact-zero rule) */
    if (ea == 0) return b;                    /* 0 + b = b */
    if (eb == 0) return a;                    /* a + 0 = a */

    int is_sub = (sa != sb);
    int saq = sa;                          /* sign of the operand held in aq */
    int32_t g_add_diff = 0;                /* hoisted alignment diff (sign decision) */

    /* 27-bit aligned operands: 24-bit significand + 3 GRS bits, sticky flag S */
    uint64_t aq = (0x800000ull | ma) << 3;
    uint64_t bq = (0x800000ull | mb) << 3;
    int32_t  e  = ea;
    int      S  = 0;

    if (ea < eb) {                            /* ensure a has the larger exponent */
        uint64_t t = aq; aq = bq; bq = t;
        e = eb;
        saq = sb;
    }
    {
        int32_t diff = e - (ea < eb ? ea : eb);
        if (diff > 0) {
            if (diff >= 27) { S = 1; bq = 0; }
            else {
                uint64_t lost = bq & ((1ull << diff) - 1);
                bq >>= diff;
                if (lost) S = 1;
            }
        }
        g_add_diff = diff;                    /* hoisted for the sign decision */
    }

    int64_t s = is_sub ? (int64_t)aq - (int64_t)bq : (int64_t)aq + (int64_t)bq;
    if (s == 0) return 0x00000000u;           /* exact zero (s==0 implies S==0) */

    /* Result sign: same-sign add keeps the common sign; opposite-sign add takes
     * the sign of the LARGER-MAGNITUDE operand (for diff > 0 that is the aq
     * operand by exponent order; for diff == 0 the mantissa comparison in s
     * decides).  NEVER the sign of s itself — that was a sign bug that flipped
     * every mixed-sign accumulation whose larger operand was negative. */
    int neg;
    if (is_sub) neg = (g_add_diff > 0) ? (int)saq : ((s > 0) ? (int)saq : (int)sb);
    else        neg = (int)sa;                /* = sb (same-sign add) */
    if (s < 0) s = -s;                        /* work on the magnitude */

    /* normalize: MSB to bit 26 */
    int msb = 63 - clz64_u((uint64_t)s);
    if (msb > 26) { S |= (int)(s & 1); s >>= (msb - 26); e += (msb - 26); }
    else if (msb < 26) { s <<= (26 - msb); e -= (26 - msb); }

    uint64_t keep = (uint64_t)s >> 3;         /* 24-bit mantissa candidate */
    uint32_t r    = (uint32_t)s & 7u;         /* GRS bits */

    /* RN-even with the direction-correct sticky handling (see the derivation
     * in the fe-arch notes; r==4 is the midpoint): */
    int up = 0;
    if (r >= 5) up = 1;
    else if (r == 4) {
        if (S) up = is_sub ? 0 : 1;           /* sticky breaks the tie: sub -> below, add -> above */
        else  up = (int)(keep & 1);           /* exact tie -> round-half-even */
    }
    if (up) keep++;
    if (keep == 0x1000000ull) { keep >>= 1; e++; }

    if (e <= 0) {                             /* subnormal result -> FTZ */
        g_ftz_add++;
        return neg ? 0x80000000u : 0x00000000u;
    }
    if (e >= 0xFF)                            /* overflow: unreachable by range analysis */
        return neg ? 0xFF800000u : 0x7F800000u;

    return (neg ? 0x80000000u : 0u)
         | ((uint32_t)e << 23) | (uint32_t)(keep & 0x7FFFFFu);
}

/* fp32 mul: IEEE-754 RN-even, FTZ.  (Exact for BF16 x BF16 operands.) */
static fp32 f32_mul(fp32 a, fp32 b)
{
    uint32_t sa = a >> 31, sb = b >> 31;
    int32_t  ea = (int32_t)((a >> 23) & 0xFF);
    int32_t  eb = (int32_t)((b >> 23) & 0xFF);
    uint32_t ma = a & 0x7FFFFFu, mb = b & 0x7FFFFFu;
    uint32_t ma0 = ma, mb0 = mb;
    if (ea == 0) { ma = 0; if (ma0 != 0) g_ftz_in++; }        /* FTZ inputs */
    if (eb == 0) { mb = 0; if (mb0 != 0) g_ftz_in++; }
    if (ea == 0xFF || eb == 0xFF)             /* NaN/Inf: unreachable (contract) */
        return (sa ^ sb) ? 0xFF800000u : 0x7F800000u;
    if (ea == 0 || eb == 0)
        return (sa ^ sb) ? 0x80000000u : 0x00000000u;

    uint32_t sign = sa ^ sb;
    int32_t  e    = ea + eb - 126;            /* value = keep * 2^(e-150); see notes */
    uint64_t m    = (uint64_t)(0x800000u | ma) * (uint64_t)(0x800000u | mb);

    int msb = 63 - clz64_u(m);                /* 46 or 47 */
    if (msb < 47) { m <<= (47 - msb); e -= (47 - msb); }

    uint64_t keep = m >> 24;
    uint32_t r    = (uint32_t)m & 0xFFFFFFu;
    if (r > 0x800000u || (r == 0x800000u && (keep & 1))) keep++;
    if (keep == 0x1000000ull) { keep >>= 1; e++; }

    if (e <= 0) { g_ftz_mul++; return sign ? 0x80000000u : 0x00000000u; }
    if (e >= 0xFF) return sign ? 0xFF800000u : 0x7F800000u;

    return (sign << 31) | ((uint32_t)e << 23) | (uint32_t)(keep & 0x7FFFFFu);
}

static inline fp32 f32_sub(fp32 a, fp32 b) { return f32_add(a, b ^ 0x80000000u); }
static inline fp32 f32_abs(fp32 a)         { return a & 0x7FFFFFFFu; }
static inline int  f32_is_neg(fp32 a)      { return (a >> 31) & 1; }

/* FP32 -> BF16: RN-even, FTZ (subnormal/zero input -> signed zero). */
static uint16_t bf16_round(fp32 a)
{
    uint32_t sa = a >> 31;
    int32_t  ea = (int32_t)((a >> 23) & 0xFF);
    uint32_t ma = a & 0x7FFFFFu;

    if (ea == 0) {                            /* zero or subnormal input -> FTZ */
        if (ma != 0) g_ftz_bf16++;
        return (uint16_t)(sa << 15);
    }
    if (ea == 0xFF)                           /* Inf/NaN: unreachable */
        return (uint16_t)((sa << 15) | 0x7F80u);

    uint32_t keep = ma >> 16;
    uint32_t r    = (ma >> 15) & 1u;
    uint32_t S    = (ma & 0x7FFFu) != 0u;
    if (r && (S || (keep & 1u))) keep++;
    if (keep == 0x80u) { keep = 0; ea++; }
    if (ea >= 0xFF) return (uint16_t)((sa << 15) | 0x7F80u);

    return (uint16_t)((sa << 15) | ((uint32_t)ea << 7) | keep);
}

/* BF16 -> FP32: exact expansion. */
static inline fp32 bf16_to_f32(uint16_t b)
{
    return ((uint32_t)(b & 0x8000u) << 16)
         | ((uint32_t)(b & 0x7F80u) << 16)
         | ((uint32_t)(b & 0x007Fu) << 16);
}

/* pixel p (0..255) -> BF16 of p/256: exact (p has <= 8 significant bits).
 * p = 1.xxx * 2^e7 with e7 = floor(log2 p) = 31 - clz32(p). */
static uint16_t bf16_of_pixel(unsigned p)
{
    if (p == 0) return 0x0000u;
    unsigned e7 = 31u - (unsigned)__builtin_clz((unsigned)p);   /* 0..7 */
    return (uint16_t)(((119u + e7) << 7) | ((p << (7u - e7)) & 0x7Fu));
}

static inline fp32 relu_f32(fp32 a) { return (a >> 31) ? 0x00000000u : a; }

/* ------------------------- piecewise sigmoid ---------------------------- */
/* Target: the TRAINED rational sigmoid act_float(z) = 0.5 + 0.5*z/(1+|z|)
 * (the old Q8.8 LUT's function — NOT the logistic).  Constants: exact FP32
 * bit patterns of the dyadic values in piecewise_sigmoid.md §2 (never float
 * literals).  Segment i applies for BP[i-1] <= x < BP[i]; x >= BP[12] saturates. */
#define F32_1   0x3F800000u   /* 1     */
#define F32_256 0x43800000u   /* 256   */
#define F32_1H  0x3F000000u   /* 1/2   */
#define SIG_SAT 0x3F7B0000u   /* 251/256 */

static const fp32 BP[13] = {  /* 1/4, 1/2, 3/4, 1, 3/2, 2, 3, 4, 6, 8, 12, 16, 24 */
    0x3E800000u, 0x3F000000u, 0x3F400000u, 0x3F800000u, 0x3FC00000u, 0x40000000u,
    0x40400000u, 0x40800000u, 0x40C00000u, 0x41000000u, 0x41400000u, 0x41800000u,
    0x41C00000u
};
static const fp32 SM[13] = {  /* 13/32, 1/4, 13/64, 9/64, 13/128, 9/128, 5/128,
                                 3/128, 1/64, 1/128, 1/256, 3/1024, 1/1024 */
    0x3ED00000u, 0x3E800000u, 0x3E500000u, 0x3E100000u, 0x3DD00000u, 0x3D900000u,
    0x3D200000u, 0x3CC00000u, 0x3C800000u, 0x3C000000u, 0x3B800000u, 0x3B400000u,
    0x3A800000u
};
static const fp32 SC[13] = {  /* 1/2, 69/128, 9/16, 39/64, 83/128, 89/128, 97/128,
                                 103/128, 107/128, 113/128, 117/128, 237/256, 245/256 */
    0x3F000000u, 0x3F0A0000u, 0x3F100000u, 0x3F1C0000u, 0x3F260000u, 0x3F320000u,
    0x3F420000u, 0x3F4E0000u, 0x3F560000u, 0x3F620000u, 0x3F6A0000u, 0x3F6D0000u,
    0x3F750000u
};

static fp32 sigmoid_piecewise(fp32 z)
{
    fp32 x = f32_abs(z);                      /* |z|: exact */
    fp32 sigma;

    if (x >= BP[12]) {
        sigma = SIG_SAT;
    } else {
        int seg = 12;
        int i;
        for (i = 0; i < 12; i++) {            /* first BP[i] with x < BP[i] */
            if (x < BP[i]) { seg = i; break; }
        }
        sigma = f32_add(f32_mul(SM[seg], x), SC[seg]);   /* mul FIRST, then add — pinned */
    }
    if (f32_is_neg(z)) sigma = f32_sub(F32_1, sigma);
    return sigma;
}

/* sigma256 = trunc(fadd(fmul(sigma, 256.0), 0.5)) — all exact FP32 steps. */
static uint32_t sigma256_of(fp32 sigma)
{
    fp32 t = f32_add(f32_mul(sigma, F32_256), F32_1H);
    /* truncate non-negative value in [0, 256.5): */
    int32_t e = (int32_t)((t >> 23) & 0xFF);
    if (e == 0) return 0u;                    /* 0 or subnormal (FTZ'd to 0) */
    uint32_t m24 = 0x800000u | (t & 0x7FFFFFu);
    int32_t shift = 150 - e;                  /* e <= 135 here -> shift in 15..150 */
    if (shift <= 0) return 0u;                /* cannot happen in [0,256.5) */
    if (shift >= 24) return 0u;
    return m24 >> shift;
}

/* ------------------------------- network -------------------------------- */

#define C1 8
#define C2 16
#define N_FC_IN 784
#define N_H 32
#define N_OUT 10
#define N_WORDS (9*C1 + C1 + 9*C1*C2 + C2 + N_FC_IN*N_H + N_H + N_H*N_OUT + N_OUT)

static uint16_t W1[9*C1], b1[C1], W2[9*C1*C2], b2[C2];
static uint16_t W3[N_FC_IN*N_H], b3[N_H], W4[N_H*N_OUT], b4[N_OUT];
static fp32 W1f[9*C1], b1f[C1], W2f[9*C1*C2], b2f[C2];
static fp32 W3f[N_FC_IN*N_H], b3f[N_H], W4f[N_H*N_OUT], b4f[N_OUT];

static uint16_t h1[28*28*C1];       /* conv1 out, BF16 (ReLU'd) */
static uint16_t p1[C2][14*14];      /* pool1 out, BF16 (channel-major banks) */
static uint16_t h2[14*14*C2];       /* conv2 out, BF16 (ReLU'd) */
static uint16_t p2[7*7*C2];         /* pool2 out, BF16 (flatten = FC1 input) */
static uint16_t h3[N_H];            /* FC1 out, BF16 */
static fp32 z3dbg[N_H];             /* FC1 pre-activation (GM_DEBUG hook) */
static uint16_t px_bf16[784];       /* pixel -> BF16(p/256), per image */

static int load_weights(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return 1; }
    unsigned v; int i = 0;
    const int n1 = 9*C1, n2 = 9*C1*C2, n3 = N_FC_IN*N_H, n4 = N_H*N_OUT;
    while (fscanf(f, "%x", &v) == 1) {
        if (i >= N_WORDS) { fprintf(stderr, "too many words\n"); fclose(f); return 1; }
        uint16_t w = (uint16_t)(v & 0xFFFF);
        if (i < n1)                      { W1[i] = w; }
        else if (i < n1 + C1)            { b1[i - n1] = w; }
        else if (i < n1 + C1 + n2)       { W2[i - n1 - C1] = w; }
        else if (i < n1 + C1 + n2 + C2)  { b2[i - n1 - C1 - n2] = w; }
        else if (i < n1 + C1 + n2 + C2 + n3)            { W3[i - n1 - C1 - n2 - C2] = w; }
        else if (i < n1 + C1 + n2 + C2 + n3 + N_H)      { b3[i - n1 - C1 - n2 - C2 - n3] = w; }
        else if (i < n1 + C1 + n2 + C2 + n3 + N_H + n4) { W4[i - n1 - C1 - n2 - C2 - n3 - N_H] = w; }
        else                                            { b4[i - n1 - C1 - n2 - C2 - n3 - N_H - n4] = w; }
        i++;
    }
    fclose(f);
    if (i != N_WORDS) { fprintf(stderr, "expected %d words, got %d\n", N_WORDS, i); return 1; }
    return 0;
}

static void expand_weights(void)
{
    int i;
    for (i = 0; i < 9*C1; i++) W1f[i] = bf16_to_f32(W1[i]);
    for (i = 0; i < C1; i++)  b1f[i] = bf16_to_f32(b1[i]);
    for (i = 0; i < 9*C1*C2; i++) W2f[i] = bf16_to_f32(W2[i]);
    for (i = 0; i < C2; i++)  b2f[i] = bf16_to_f32(b2[i]);
    for (i = 0; i < N_FC_IN*N_H; i++) W3f[i] = bf16_to_f32(W3[i]);
    for (i = 0; i < N_H; i++) b3f[i] = bf16_to_f32(b3[i]);
    for (i = 0; i < N_H*N_OUT; i++) W4f[i] = bf16_to_f32(W4[i]);
    for (i = 0; i < N_OUT; i++) b4f[i] = bf16_to_f32(b4[i]);
}

/* conv1 tap activation: pixel at (oy+iy-1, ox+ix-1) as BF16, 0 if OOB. */
static inline uint16_t act1(int oy, int ox, int iy, int ix)
{
    int py = oy + iy - 1, px = ox + ix - 1;
    if (py < 0 || py >= 28 || px < 0 || px >= 28) return 0x0000u;
    return px_bf16[py * 28 + px];
}

/* conv2 tap activation: p1[ic][(oy+iy-1)*14 + (ox+ix-1)] as BF16, 0 if OOB. */
static inline uint16_t act2(int oy, int ox, int iy, int ix, int ic)
{
    int py = oy + iy - 1, px = ox + ix - 1;
    if (py < 0 || py >= 14 || px < 0 || px >= 14) return 0x0000u;
    return p1[ic][py * 14 + px];
}

static void forward(uint32_t out[N_OUT])
{
    int oy, ox, oc, iy, ix, i, j, k, c;
    fp32 acc;

    for (i = 0; i < 784; i++) px_bf16[i] = bf16_of_pixel((unsigned)px_bf16[i]);

    /* ---- conv1: per pixel (oy,ox), per oc: bias, taps 0..7, then tap 8 ---- */
    for (oy = 0; oy < 28; oy++)
        for (ox = 0; ox < 28; ox++) {
            for (oc = 0; oc < C1; oc++) {
                acc = b1f[oc];                                    /* bias first */
                for (c = 0; c < 8; c++) {                          /* pass A: taps 0..7 */
                    iy = c / 3; ix = c % 3;
                    acc = f32_add(acc, f32_mul(W1f[oc * 9 + c],
                                               bf16_to_f32(act1(oy, ox, iy, ix))));
                }
                for (c = 0; c < 8; c++) {                          /* pass B: tap 8 in col 0 */
                    fp32 w = (c == 0) ? W1f[oc * 9 + 8] : 0x00000000u;
                    iy = c / 3; ix = c % 3;
                    acc = f32_add(acc, f32_mul(w,
                                               bf16_to_f32((c == 0) ? act1(oy, ox, 2, 2)
                                                                     : act1(oy, ox, iy, ix))));
                }
                h1[(oc * 28 + oy) * 28 + ox] = bf16_round(relu_f32(acc));
            }
        }

    /* ---- pool1: 2x2 max -> p1[oc][oy*14+ox] ---- */
    for (oc = 0; oc < C1; oc++)
        for (oy = 0; oy < 14; oy++)
            for (ox = 0; ox < 14; ox++) {
                int16_t m = (int16_t)h1[(oc * 28 + 2 * oy) * 28 + 2 * ox];
                int16_t v;
                v = (int16_t)h1[(oc * 28 + 2 * oy) * 28 + 2 * ox + 1]; if (v > m) m = v;
                v = (int16_t)h1[(oc * 28 + 2 * oy + 1) * 28 + 2 * ox]; if (v > m) m = v;
                v = (int16_t)h1[(oc * 28 + 2 * oy + 1) * 28 + 2 * ox + 1]; if (v > m) m = v;
                p1[oc][oy * 14 + ox] = (uint16_t)m;
            }

    /* ---- conv2: per pixel, per oc: bias, then k=0..8 outer, ic c=0..7 inner ---- */
    for (oy = 0; oy < 14; oy++)
        for (ox = 0; ox < 14; ox++) {
            for (oc = 0; oc < C2; oc++) {
                acc = b2f[oc];                                    /* bias first */
                for (k = 0; k < 9; k++) {                          /* k = iy*3+ix */
                    iy = k / 3; ix = k % 3;
                    for (c = 0; c < 8; c++) {                      /* c = ic (wavefront col order) */
                        acc = f32_add(acc, f32_mul(W2f[oc * 72 + c * 9 + k],
                                                   bf16_to_f32(act2(oy, ox, iy, ix, c))));
                    }
                }
                h2[(oc * 14 + oy) * 14 + ox] = bf16_round(relu_f32(acc));
            }
        }

    /* ---- pool2: 2x2 max -> p2[oc*49 + oy*7 + ox] (channel-major flatten) ---- */
    for (oc = 0; oc < C2; oc++)
        for (oy = 0; oy < 7; oy++)
            for (ox = 0; ox < 7; ox++) {
                int16_t m = (int16_t)h2[(oc * 14 + 2 * oy) * 14 + 2 * ox];
                int16_t v;
                v = (int16_t)h2[(oc * 14 + 2 * oy) * 14 + 2 * ox + 1]; if (v > m) m = v;
                v = (int16_t)h2[(oc * 14 + 2 * oy + 1) * 14 + 2 * ox]; if (v > m) m = v;
                v = (int16_t)h2[(oc * 14 + 2 * oy + 1) * 14 + 2 * ox + 1]; if (v > m) m = v;
                p2[oc * 49 + oy * 7 + ox] = (uint16_t)m;
            }

    /* ---- FC1: per j: bias, i=0..783 ascending; sigmoid; BF16 store ---- */
    for (j = 0; j < N_H; j++) {
        acc = b3f[j];
        for (i = 0; i < N_FC_IN; i++)
            acc = f32_add(acc, f32_mul(W3f[i * N_H + j], bf16_to_f32(p2[i])));
        if (GM_DBG) z3dbg[j] = acc;               /* debug hook */
        h3[j] = bf16_round(sigmoid_piecewise(acc));
    }

    /* ---- FC2: per j: bias, i=0..31 ascending; sigmoid; sigma256 ---- */
    for (j = 0; j < N_OUT; j++) {
        acc = b4f[j];
        for (i = 0; i < N_H; i++)
            acc = f32_add(acc, f32_mul(W4f[i * N_OUT + j], bf16_to_f32(h3[i])));
        out[j] = sigma256_of(sigmoid_piecewise(acc));
    }
}

/* ----------------------------- vector self-test ------------------------- */

static int run_vectors(void)
{
    unsigned i;
    for (i = 0; i < GM_VECTOR_COUNT; i++) {
        const gm_vec_t *v = &gm_vectors[i];
        uint32_t dout = 0;
        switch (v->kind) {
        case 0: dout = bf16_round(v->a); break;
        case 1: dout = f32_add(v->a, v->b); break;
        case 2: dout = f32_mul(v->a, v->b); break;
        case 3: dout = sigmoid_piecewise(v->a); break;
        case 4: dout = sigma256_of(v->a); break;
        case 5: {
            uint32_t conf = (uint32_t)(((uint64_t)v->a * 100u) >> 8);
            uint32_t pred = (v->b >> 4) & 0xFu, label = v->b & 0xFu;
            uint32_t verdict = (conf < 50) ? 2u : (pred == label ? 0u : 1u);
            dout = (conf << 2) | verdict;
            break;
        }
        case 6: {
            uint32_t s0 = v->a & 0xFFu, s1 = (v->a >> 8) & 0xFFu;
            uint32_t s2 = (v->a >> 16) & 0xFFu, s3 = (v->a >> 24) & 0xFFu;
            uint32_t best = 0, val = s0;
            if (s1 > val) { val = s1; best = 1; }
            if (s2 > val) { val = s2; best = 2; }
            if (s3 > val) { val = s3; best = 3; }
            dout = (best << 8) | val;
            break;
        }
        default: fprintf(stderr, "bad vector kind %u\n", (unsigned)v->kind); return 1;
        }
        printf("VEC %03u k=%u din=0x%08X_%08X dout=0x%08X\n",
               i, (unsigned)v->kind, v->a, v->b, dout);
    }
    return 0;
}

/* --------------------------------- main -------------------------------- */

int main(int argc, char **argv)
{
    const char *root = ".";
    if (argc >= 2 && strcmp(argv[1], "--vectors") == 0)
        return run_vectors();
    if (argc >= 2) root = argv[1];
    size_t n = (argc >= 3) ? (size_t)strtoul(argv[2], NULL, 10) : 10000;
    if (n > 10000) n = 10000;

    char wpath[1024], ipath[1024], lpath[1024];
    snprintf(wpath, sizeof wpath, "%s/arch/golden_model/weights_bf16.hex", root);
    snprintf(ipath, sizeof ipath, "%s/../cnn/data/t10k_images.bin", root);
    snprintf(lpath, sizeof lpath, "%s/../cnn/data/t10k_labels.bin", root);
    if (load_weights(wpath)) return 1;
    expand_weights();

    FILE *fimg = fopen(ipath, "rb");
    FILE *flbl = fopen(lpath, "rb");
    if (!fimg || !flbl) { fprintf(stderr, "cannot open %s / %s\n", ipath, lpath); return 1; }

    unsigned char *imgs = malloc(n * 784);
    unsigned char *labels = malloc(n);
    if (!imgs || !labels) { fprintf(stderr, "oom\n"); return 1; }
    if (fread(imgs, 1, n * 784, fimg) != n * 784) { fprintf(stderr, "short image read\n"); return 1; }
    if (fread(labels, 1, n, flbl) != n) { fprintf(stderr, "short label read\n"); return 1; }
    fclose(fimg); fclose(flbl);

    char epath[1024], xpath[1024], spath[1024], lxpath[1024];
    snprintf(epath,  sizeof epath,  "%s/arch/golden_model/expected_outputs.txt", root);
    snprintf(xpath,  sizeof xpath,  "%s/arch/golden_model/expected.hex", root);
    snprintf(spath,  sizeof spath,  "%s/arch/golden_model/stimulus.hex", root);
    snprintf(lxpath, sizeof lxpath, "%s/arch/golden_model/labels.hex", root);
    FILE *fexp = fopen(epath, "w");
    FILE *fhx  = fopen(xpath, "w");
    FILE *fshx = fopen(spath, "w");
    FILE *flhx = fopen(lxpath, "w");
    if (!fexp || !fhx || !fshx || !flhx) { fprintf(stderr, "cannot write outputs\n"); return 1; }

    uint32_t out[N_OUT];
    int correct = 0, incorrect = 0, trash = 0;
    size_t k;
    for (k = 0; k < n; k++) {
        unsigned i;
        for (i = 0; i < 784; i++) px_bf16[i] = (uint16_t)imgs[k * 784 + i];  /* raw pixel for bf16_of_pixel */
        forward(out);

        uint32_t best = 0, j;
        for (j = 1; j < N_OUT; j++)
            if (out[j] > out[best]) best = j;                  /* lowest-index ties */
        uint32_t conf = (out[best] * 100u) >> 8;
        uint32_t exp  = labels[k];
        uint32_t verdict = (conf < 50) ? 2u : (best == exp ? 0u : 1u);

        if (verdict == 0) correct++;
        else if (verdict == 1) incorrect++;
        else trash++;

        if (k < 100) {
            fprintf(fhx, "%04x\n%04x\n%04x\n%04x\n", best, conf, exp, verdict);
            for (i = 0; i < 784; i++)
                fprintf(fshx, "%02x\n", imgs[k * 784 + i]);
            fprintf(flhx, "%02x\n", exp);
            if (verdict == 2)
                fprintf(fexp, "IMG %03zu: NOT A NUMBER | confidence %u%% | expected %u | TRASH\n",
                        k, conf, exp);
            else
                fprintf(fexp, "IMG %03zu: This is number %u | confidence %u%% | expected %u | %s\n",
                        k, best, conf, exp, verdict == 0 ? "CORRECT" : "INCORRECT");
        }

        if (GM_DBG && k < 3) {          /* internal-state hook (fe-rtl debug aid) */
            {   uint32_t p2max = 0, h2max = 0; uint64_t p2sum = 0; unsigned pi;
                for (pi = 0; pi < 784; pi++) { if (p2[pi] > p2max) p2max = p2[pi]; p2sum += p2[pi]; }
                for (pi = 0; pi < 3136; pi++) if (h2[pi] > h2max) h2max = h2[pi];
                printf("GM_DEBUG img%zu: h2 max=%04x h2[2693]=%04x p1@(10,5)=%04x %04x %04x %04x %04x %04x %04x %04x z3[0]=%08x | out",
                       k, h2max, h2[2693],
                       p1[0][145], p1[1][145], p1[2][145], p1[3][145],
                       p1[4][145], p1[5][145], p1[6][145], p1[7][145],
                       z3dbg[0]);
                for (i = 0; i < 10; i++) printf(" %u", out[i]);
                printf("\n");
            }
        }

        if (verdict == 2)
            printf("IMG %03zu: NOT A NUMBER | confidence %u%% | expected %u | TRASH\n",
                   k, conf, exp);
        else
            printf("IMG %03zu: This is number %u | confidence %u%% | expected %u | %s\n",
                   k, best, conf, exp, verdict == 0 ? "CORRECT" : "INCORRECT");
    }

    fclose(fexp); fclose(fhx); fclose(fshx); fclose(flhx);
    free(imgs); free(labels);

    printf("\nSUMMARY on %zu test images: correct %d, incorrect %d, trash %d,"
           " accuracy %.2f%%\n", n, correct, incorrect, trash, 100.0 * correct / n);
    printf("FTZ flush events: subnormal-results add %llu mul %llu | subnormal-inputs"
           " add/mul %llu bf16 %llu\n"
           "   (all 0 = FTZ never fires for this network, as predicted by range analysis)\n",
           (unsigned long long)g_ftz_add, (unsigned long long)g_ftz_mul,
           (unsigned long long)g_ftz_in, (unsigned long long)g_ftz_bf16);
    printf("vector set: first 100 images -> expected_outputs.txt, expected.hex,"
           " stimulus.hex, labels.hex\n");
    return 0;
}
