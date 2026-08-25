/* golden_model_test_vectors.h
 * Input vectors for golden_ref_model.c — rinriAI, fe-arch.
 *
 * Tiny config: FEATURES=4, HIDDEN=4, CLASSES=2, lr_shift=0 (eta=1).
 * W_TOT = 4*4 + 4 + 4*2 + 2 = 30 words.
 *
 * These values are value-identical to arch/golden_model/stimulus.hex
 * (initial weights section + sample section) so the C diff flow and the
 * fe-rtl Verilog testbench read the same golden data.
 *
 * Initial weights: w[i] = ((i*7 + 3) mod 256) - 128   (deterministic
 * pseudo-random pattern in [-128,127], Q8.8).
 * Samples are MNIST-style abstract patterns (4-pixel images, 2 classes).
 */
#ifndef GOLDEN_MODEL_TEST_VECTORS_H
#define GOLDEN_MODEL_TEST_VECTORS_H

#include <stdint.h>

#define GM_VECTOR_COUNT 6
#define GM_FEATURES     4
#define GM_INIT_WORDS   30

/* initial weights, address order 0..29 (arch.md section 7 address map) */
static const int16_t gm_init_weights[GM_INIT_WORDS] = {
    -125, -118, -111, -104,     /* w_h[0][0..3] */
     -97,  -90,  -83,  -76,     /* w_h[1][0..3] */
     -69,  -62,  -55,  -48,     /* w_h[2][0..3] */
     -41,  -34,  -27,  -20,     /* w_h[3][0..3] */
     -13,   -6,    1,    8,     /* b_h[0..3] */
      15,   22,   29,   36,     /* w_o[0][0..3] */
      43,   50,   57,   64,     /* w_o[1][0..3] */
      71,   78                   /* b_o[0..1] */
};

typedef struct {
    uint16_t pixels[GM_FEATURES];   /* 0..255, Q8.8 raw = byte value */
    uint8_t  label;                 /* 0..CLASSES-1 */
} gm_sample_t;

static const gm_sample_t gm_samples[GM_VECTOR_COUNT] = {
    { {   0, 100, 100,   0 }, 0 },  /* S1: label 0 */
    { { 200,   0,   0, 200 }, 1 },  /* S2: label 1 */
    { {  50,  50,  50,  50 }, 0 },  /* S3: label 0 */
    { {   0,   0,   0,   0 }, 0 },  /* S4: all-zero, label 0 */
    { { 255, 255, 255, 255 }, 1 },  /* S5: all-max, label 1 */
    { {   0,   1,   2,   3 }, 5 }   /* S6: INVALID label 5 >= CLASSES (2):
                                     * REQ-018 rejection proof — must be
                                     * discarded, not counted, no update */
};

#endif /* GOLDEN_MODEL_TEST_VECTORS_H */
