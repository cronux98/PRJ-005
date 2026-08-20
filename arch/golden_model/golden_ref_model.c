/* =====================================================================
 * golden_ref_model.c
 * Golden reference model for rinriAI.  Stage: fe-arch.
 *
 * Granularity: transaction-level (one function call per processed sample).
 *
 * Models: 2-layer MLP (FEATURES x HIDDEN x CLASSES), online SGD training.
 *   - Fixed point: Q8.8 (16-bit signed, 8 fractional bits; value = raw/256).
 *   - Activation: sigmoid via integer rational approximation
 *         sigma(z) = 0.5 + 0.5*z/(1+|z|)     (real)
 *         sigma_raw = 128 + trunc(128*z_raw/(256+|z_raw|))   (Q8.8)
 *     The backprop derivative uses the stored activation:
 *         d_sigma = a*(1-a)  (surrogate sigmoid derivative).
 *   - Cost: quadratic C = 0.5*sum_c (y_c - t_c)^2.
 *   - Backprop (Nielsen ch.1-2):
 *         delta_o[c] = (y_c - t_c) * y_c * (256 - y_c) / 2^16   (trunc)
 *         e16[h]     = sum_c w_o[c][h] * delta_o[c]             (Q16.16)
 *         delta_h[h] = e16[h] * a_h[h] * (256 - a_h[h]) / 2^24  (trunc)
 *   - Update (online SGD, eta = 2^-LR_SHIFT):
 *         w_o[c][h] -= trunc(delta_o[c]*a_h[h] / 2^(LR_SHIFT+8))
 *         b_o[c]    -= trunc(delta_o[c] / 2^LR_SHIFT)
 *         w_h[h][f] -= trunc(delta_h[h]*x[f] / 2^(LR_SHIFT+8))
 *         b_h[h]    -= trunc(delta_h[h] / 2^LR_SHIFT)
 *     All weights saturate at the 16-bit range after update.
 *   - Hidden z and output z: acc = bias<<8 + sum(a*w), 48-bit signed
 *     accumulation; z = sat16(trunc(acc / 256)).
 *   - argmax over outputs, lowest index wins on ties.
 *   - Counters saturate at 0xFFFFFFFF.
 *
 * Rounding/overflow rules (must match rtl/ exactly, see arch.md section 5):
 *   - trunc(x/2^n): toward zero  ->  (x>=0) ? (x>>n) : -((-x)>>n)
 *   - trunc(a/b):   toward zero  ->  C99 '/' semantics (RTL: sign-magnitude
 *     restoring divider, same result).
 *   - All intermediates in int64; final values masked to the RTL widths.
 *
 * Determinism: fixed-width integer arithmetic only; no float, no malloc,
 * no time/address/locale dependent output. Bit-identical on every run.
 *
 * Config: the default build below is the TINY config (FEATURES=4, HIDDEN=4,
 * CLASSES=2, LR_SHIFT=0) and matches golden_model_test_vectors.h +
 * stimulus.hex/expected.hex. To generate vectors for another config, change
 * the four defines and replace the vectors in the header accordingly.
 *
 * Build: gcc -std=c99 -O2 -Wall -Wextra -o gm golden_ref_model.c
 * Run  : ./gm > got.txt && diff -u expected_outputs.txt got.txt
 * ===================================================================== */
#include <stdint.h>
#include <stdio.h>
#include "golden_model_test_vectors.h"

/* ---- configuration (default = tiny config, matches shipped vectors) ---- */
#define FEATURES 4
#define HIDDEN   4
#define CLASSES  2
#define LR_SHIFT 0            /* eta = 2^-LR_SHIFT */
#define W_TOT    (FEATURES*HIDDEN + HIDDEN + HIDDEN*CLASSES + CLASSES)

/* ---- fixed-point helpers (identical semantics to rtl/) ---- */

/* trunc(x / 2^n), n >= 0, toward zero */
static int64_t trunc_pow2(int64_t x, int n)
{
    if (n <= 0) return x;
    if (x >= 0) return x >> n;
    return -((-x) >> n);
}

/* saturate to 16-bit signed */
static int32_t sat16(int64_t x)
{
    if (x >  32767) return  32767;
    if (x < -32768) return -32768;
    return (int32_t)x;
}

/* sigmoid, Q8.8 in -> Q8.8 out (range [1,255]):
 * sigma_raw = 128 + trunc(128*z / (256+|z|)) */
static int32_t sigmoid_q8(int32_t z)
{
    int32_t az = (z < 0) ? -z : z;
    int32_t q  = (128 * z) / (256 + az);   /* C99: trunc toward zero */
    return 128 + q;
}

/* ---- design state ---- */
static int16_t w[W_TOT];           /* weights + biases, Q8.8, address map
                                    * arch.md section 7: 0..F*H-1 hidden W,
                                    * F*H..F*H+H-1 hidden B, +H..+H+H*C-1
                                    * output W, +H+H*C..W_TOT-1 output B */
static uint16_t x[FEATURES];       /* input pixels 0..255 (Q8.8 raw = byte) */
static int32_t  label;             /* true class */

static uint32_t sample_cnt;
static uint32_t correct_cnt;
static uint32_t error_cnt;

/* ---- per-sample processing ---- */
static void gm_process_sample(void)
{
    int16_t a_h[HIDDEN];
    int16_t y[CLASSES];
    int16_t delta_o[CLASSES];
    int16_t delta_h[HIDDEN];
    int32_t pred = 0;
    int32_t f, h, c;
    int32_t correct;
    int64_t acc;

    /* --- forward: hidden layer --- */
    for (h = 0; h < HIDDEN; h++) {
        acc = (int64_t)w[FEATURES*HIDDEN + h] << 8;      /* bias, Q16.16 */
        for (f = 0; f < FEATURES; f++) {
            acc += (int64_t)w[h*FEATURES + f] * (int64_t)x[f];
        }
        a_h[h] = (int16_t)sigmoid_q8(sat16(trunc_pow2(acc, 8)));
    }

    /* --- forward: output layer + argmax (lowest index wins) --- */
    for (c = 0; c < CLASSES; c++) {
        acc = (int64_t)w[FEATURES*HIDDEN + HIDDEN + HIDDEN*CLASSES + c] << 8;
        for (h = 0; h < HIDDEN; h++) {
            acc += (int64_t)w[FEATURES*HIDDEN + HIDDEN + c*HIDDEN + h]
                   * (int64_t)a_h[h];
        }
        y[c] = (int16_t)sigmoid_q8(sat16(trunc_pow2(acc, 8)));
        if (y[c] > y[pred]) pred = c;                     /* strict > keeps
                                                            lowest index */
    }

    /* --- counters (update once per sample, before weight update) --- */
    correct = (pred == label) ? 1 : 0;
    if (sample_cnt < 0xFFFFFFFFu) sample_cnt++;
    if (correct) { if (correct_cnt < 0xFFFFFFFFu) correct_cnt++; }
    else         { if (error_cnt   < 0xFFFFFFFFu) error_cnt++;   }

    /* --- backpropagation --- */
    for (c = 0; c < CLASSES; c++) {
        int64_t t = (c == label) ? 256 : 0;               /* one-hot, Q8.8 */
        int64_t tmp = ((int64_t)y[c] - t) * (int64_t)y[c]
                    * (256 - (int64_t)y[c]);
        delta_o[c] = (int16_t)sat16(trunc_pow2(tmp, 16));
    }
    for (h = 0; h < HIDDEN; h++) {
        int64_t e16 = 0;
        for (c = 0; c < CLASSES; c++) {
            e16 += (int64_t)w[FEATURES*HIDDEN + HIDDEN + c*HIDDEN + h]
                   * (int64_t)delta_o[c];
        }
        delta_h[h] = (int16_t)sat16(trunc_pow2(
            e16 * (int64_t)a_h[h] * (256 - (int64_t)a_h[h]), 24));
    }

    /* --- online SGD weight update (eta = 2^-LR_SHIFT) --- */
    for (c = 0; c < CLASSES; c++) {
        for (h = 0; h < HIDDEN; h++) {
            int32_t addr = FEATURES*HIDDEN + HIDDEN + c*HIDDEN + h;
            int32_t upd = (int32_t)trunc_pow2(
                (int64_t)delta_o[c] * (int64_t)a_h[h], LR_SHIFT + 8);
            w[addr] = (int16_t)sat16((int64_t)w[addr] - upd);
        }
        {
            int32_t addr = FEATURES*HIDDEN + HIDDEN + HIDDEN*CLASSES + c;
            int32_t upd = (int32_t)trunc_pow2((int64_t)delta_o[c], LR_SHIFT);
            w[addr] = (int16_t)sat16((int64_t)w[addr] - upd);
        }
    }
    for (h = 0; h < HIDDEN; h++) {
        for (f = 0; f < FEATURES; f++) {
            int32_t addr = h*FEATURES + f;
            int32_t upd = (int32_t)trunc_pow2(
                (int64_t)delta_h[h] * (int64_t)x[f], LR_SHIFT + 8);
            w[addr] = (int16_t)sat16((int64_t)w[addr] - upd);
        }
        {
            int32_t addr = FEATURES*HIDDEN + h;
            int32_t upd = (int32_t)trunc_pow2((int64_t)delta_h[h], LR_SHIFT);
            w[addr] = (int16_t)sat16((int64_t)w[addr] - upd);
        }
    }

    /* --- report --- */
    printf("SAMPLE %03u label=0x%02X pred=0x%02X correct=0x%01X "
           "sample=0x%08X correct_cnt=0x%08X error_cnt=0x%08X\n",
           (unsigned)(sample_cnt - 1u), (unsigned)label, (unsigned)pred,
           (unsigned)correct, (unsigned)sample_cnt, (unsigned)correct_cnt,
           (unsigned)error_cnt);
}

int main(void)
{
    unsigned s;

    /* load initial weights (values identical to stimulus.hex first section) */
    for (s = 0u; s < (unsigned)GM_INIT_WORDS; s++) {
        w[s] = gm_init_weights[s];
    }

    for (s = 0u; s < GM_VECTOR_COUNT; s++) {
        unsigned f;
        for (f = 0u; f < (unsigned)GM_FEATURES; f++) {
            x[f] = gm_samples[s].pixels[f];
        }
        label = gm_samples[s].label;
        gm_process_sample();
    }

    /* final weight dump (values identical to expected.hex second section) */
    for (s = 0u; s < (unsigned)W_TOT; s++) {
        printf("WEIGHT 0x%04X=0x%04X\n", (unsigned)s,
               (unsigned)(uint16_t)w[s]);
    }
    return 0;
}
