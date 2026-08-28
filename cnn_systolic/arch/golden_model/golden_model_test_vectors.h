/*-------------------------------------------------------------------------
 * golden_model_test_vectors.h — directed vector set for the cnn_systolic FP
 * golden model (REQ-029, G7).  Inputs only; expected outputs live in
 * expected_vectors.txt (hand-derived, exact dyadic arithmetic — every value
 * in that file was computed by hand from the pinned FP semantics of
 * arch/piecewise_sigmoid.md + arch/systolic_dataflow.md, NOT by running this
 * model; the golden's --vectors run must reproduce them 1:1).
 *
 * Kinds:
 *   0 bf16_round : dout = BF16(a)            (RN-even, FTZ; arch.md §5.1)
 *   1 f32_add    : dout = fadd(a, b)         (RN-even, FTZ)
 *   2 f32_mul    : dout = fmul(a, b)         (RN-even, FTZ)
 *   3 sigmoid    : dout = piecewise_sigmoid(a)  (pinned dyadic coefficients)
 *   4 sigma256   : dout = trunc(fadd(fmul(a,256.0),0.5))
 *   5 conf_ver   : a = sigma256_best, b = (pred<<4)|label ->
 *                  dout = (conf<<2)|verdict, conf=(a*100)>>8,
 *                  verdict = conf<50 ? 2 : (pred==label ? 0 : 1)
 *   6 argmax4    : a = {s3,s2,s1,s0} (8b each, s0 = bits 7:0) ->
 *                  dout = (best_idx<<8)|best_val, strict >, lowest-index ties
 *-------------------------------------------------------------------------*/
#ifndef GOLDEN_MODEL_TEST_VECTORS_H
#define GOLDEN_MODEL_TEST_VECTORS_H

#include <stdint.h>

typedef struct {
    uint8_t  kind;
    uint32_t a;
    uint32_t b;
} gm_vec_t;

#define GM_VECTOR_COUNT 70

static const gm_vec_t gm_vectors[GM_VECTOR_COUNT] = {
    /* kind 0 — BF16 conversion (RN-even, FTZ) */
    {0, 0x3F800000u, 0x00000000u},   /*  1.0            -> 0x3F80 exact   */
    {0, 0x3F000000u, 0x00000000u},   /*  0.5            -> 0x3F00 exact   */
    {0, 0x3E800000u, 0x00000000u},   /*  0.25           -> 0x3E80 exact   */
    {0, 0x3F810000u, 0x00000000u},   /*  1+2^-7 (8-bit significand, exact) -> 0x3F81 */
    {0, 0x3F808080u, 0x00000000u},   /*  round-up (r+S) -> 0x3F81         */
    {0, 0x3F818000u, 0x00000000u},   /*  tie, odd keep  -> 0x3F82 (half-even up) */
    {0, 0x3F848000u, 0x00000000u},   /*  tie, even keep -> 0x3F84 (half-even down) */
    {0, 0x3F858000u, 0x00000000u},   /*  tie, odd keep  -> 0x3F86 (half-even up) */
    {0, 0xBFC00000u, 0x00000000u},   /* -1.5            -> 0xBFC0         */
    {0, 0x00001000u, 0x00000000u},   /*  subnormal      -> 0x0000 (FTZ)   */
    {0, 0x80000000u, 0x00000000u},   /* -0.0            -> 0x8000 (sign kept) */
    {0, 0x00800000u, 0x00000000u},   /*  2^-126         -> 0x0001 (min normal) */
    {0, 0x437F0000u, 0x00000000u},   /*  255.0          -> 0x437F exact   */
    {0, 0x3F7FFFFFu, 0x00000000u},   /*  1-2^-24        -> 0x3F80 (round up, mantissa overflow) */
    {0, 0x00000000u, 0x00000000u},   /*  +0.0           -> 0x0000         */

    /* kind 1 — FP32 add (RN-even, FTZ) */
    {1, 0x3F800000u, 0x3E800000u},   /*  1 + 0.25   = 1.25        -> 0x3FA00000 */
    {1, 0x3F800000u, 0xBF800000u},   /*  1 + (-1)   = +0 (RN)     -> 0x00000000 */
    {1, 0x3F800000u, 0x33800001u},   /*  1 + 2^-24 + 2^-47 -> 1+2^-23 (round up) -> 0x3F800001 */
    {1, 0x3F800000u, 0x33800000u},   /*  1 + 2^-24  -> 1.0 (tie, even) -> 0x3F800000 */
    {1, 0x3F800000u, 0xBF7FFFFFu},   /*  1 - (1-2^-24) = 2^-24   -> 0x33800000 */
    {1, 0x3F800000u, 0x3F800000u},   /*  1 + 1      = 2          -> 0x40000000 */
    {1, 0x00C00000u, 0x80800000u},   /*  1.5*2^-126 - 2^-126 = 2^-127 (subnormal -> FTZ +0) -> 0x00000000 */
    {1, 0x3FC00000u, 0x3F000000u},   /*  1.5 + 0.5  = 2          -> 0x40000000 */
    {1, 0x3F800000u, 0x3F000000u},   /*  1 + 0.5    = 1.5        -> 0x3FC00000 */
    {1, 0x3F800000u, 0x40000000u},   /*  1 + 2      = 3          -> 0x40400000 */

    /* kind 2 — FP32 mul (RN-even, FTZ) */
    {2, 0x3FC00000u, 0x3F000000u},   /*  1.5 * 0.5 = 0.75        -> 0x3F400000 */
    {2, 0x40000000u, 0x40400000u},   /*  2 * 3     = 6           -> 0x40C00000 */
    {2, 0xC0000000u, 0x40400000u},   /* -2 * 3     = -6          -> 0xC0C00000 */
    {2, 0x1B800000u, 0x1B800000u},   /*  2^-100 * 2^-100 = 2^-200 (subnormal -> FTZ +0) -> 0x00000000 */
    {2, 0x3FA00000u, 0x3FA00000u},   /*  1.25^2    = 1.5625      -> 0x3FC80000 */
    {2, 0x3F800000u, 0x3F800000u},   /*  1 * 1     = 1           -> 0x3F800000 */

    /* kind 3 — piecewise sigmoid (pinned dyadic coefficients) */
    {3, 0x00000000u, 0x00000000u},   /*  z=0    -> 0.5 (act_float)  -> 0x3F000000 */
    {3, 0x3E800000u, 0x00000000u},   /*  z=1/4  -> 77/128         -> 0x3F1A0000 */
    {3, 0x3F000000u, 0x00000000u},   /*  z=1/2  -> 85/128         -> 0x3F2A0000 */
    {3, 0x3F800000u, 0x00000000u},   /*  z=1    -> 3/4            -> 0x3F400000 */
    {3, 0x3FC00000u, 0x00000000u},   /*  z=3/2  -> 205/256        -> 0x3F4D0000 */
    {3, 0x40000000u, 0x00000000u},   /*  z=2    -> 107/128        -> 0x3F560000 */
    {3, 0x40800000u, 0x00000000u},   /*  z=4    -> 115/128        -> 0x3F660000 */
    {3, 0x41000000u, 0x00000000u},   /*  z=8    -> 121/128        -> 0x3F720000 */
    {3, 0xBF000000u, 0x00000000u},   /*  z=-1/2 -> 1-85/128 = 43/128 -> 0x3EAC0000 */
    {3, 0xC1000000u, 0x00000000u},   /*  z=-8   -> 1-121/128 = 7/128 -> 0x3D600000 */
    {3, 0x40C00000u, 0x00000000u},   /*  z=6    -> 119/128        -> 0x3F6E0000 */
    {3, 0x3E000000u, 0x00000000u},   /*  z=1/8  -> 141/256        -> 0x3F0D0000 */
    {3, 0x3E400000u, 0x00000000u},   /*  z=3/16 -> 295/512        -> 0x3F138000 */
    {3, 0x3F400000u, 0x00000000u},   /*  z=3/4  -> 183/256        -> 0x3F370000 */
    {3, 0x3FA00000u, 0x00000000u},   /*  z=5/4  -> 397/512        -> 0x3F468000 */

    /* kind 4 — sigma256 quantization (trunc(sigma*256 + 0.5)) */
    {4, 0x3F000000u, 0x00000000u},   /*  0.5      -> 128         -> 0x00000080 */
    {4, 0x3F200000u, 0x00000000u},   /*  5/8      -> 160         -> 0x000000A0 */
    {4, 0x3F7D6000u, 0x00000000u},   /*  2027/2048 -> 253        -> 0x000000FD */
    {4, 0x3F800000u, 0x00000000u},   /*  1.0      -> 256         -> 0x00000100 */
    {4, 0x3D800000u, 0x00000000u},   /*  1/16 (=2^-4, 0x3D800000) -> 16         -> 0x00000010 */
    {4, 0x3F7B0000u, 0x00000000u},   /*  251/256  -> 251         -> 0x000000FB */
    {4, 0x00000000u, 0x00000000u},   /*  0.0      -> 0           -> 0x00000000 */

    /* kind 5 — confidence + verdict (conf=(a*100)>>8, verdict) */
    {5, 0x000000C8u, 0x00000012u},   /*  s=200 pred1 lab2: conf78 -> 0x00000139 */
    {5, 0x0000007Fu, 0x00000012u},   /*  s=127 -> conf49 TRASH   -> 0x000000C6 */
    {5, 0x00000080u, 0x00000012u},   /*  s=128 -> conf50, pred!=lab -> 0x000000C9 */
    {5, 0x00000100u, 0x00000055u},   /*  s=256 -> conf100 CORRECT-> 0x00000190 */
    {5, 0x00000000u, 0x00000000u},   /*  s=0   -> conf0 TRASH    -> 0x00000002 */
    {5, 0x00000064u, 0x00000021u},   /*  s=100 -> conf39 TRASH   -> 0x0000009E */

    {3, 0x40600000u, 0x00000000u},   /*  z=7/2  -> 227/256        -> 0x3F630000 */
    {3, 0x41600000u, 0x00000000u},   /*  z=14   -> 495/512        -> 0x3F770000 */
    {3, 0x41A00000u, 0x00000000u},   /*  z=20   -> 125/128        -> 0x3F7A0000 */
    {3, 0x42000000u, 0x00000000u},   /*  z=32   -> 251/256 (sat)  -> 0x3F7B0000 */

    /* kind 1 — SIGN coverage (the two classes the original set missed: the
     * sign of an opposite-sign add is the LARGER-MAGNITUDE operand's sign;
     * same-sign negative adds keep the negative sign) */
    {1, 0x3F000000u, 0xBFC00000u},   /*  0.5 + (-1.5) = -1.0      -> 0xBF800000 */
    {1, 0xBFC00000u, 0xBF000000u},   /* -1.5 + (-0.5) = -2.0      -> 0xC0000000 */

    /* kind 6 — argmax4 (strict >, lowest-index ties) */
    {6, 0x0A000064u, 0x00000000u},   /*  {10,0,10,100} -> best0 v100 -> 0x00000064 */
    {6, 0x000A0A64u, 0x00000000u},   /*  {0,10,10,100} -> best0 v100 -> 0x00000064 */
    {6, 0x64646463u, 0x00000000u},   /*  {100,100,100,99} -> best1 v100 (ties) -> 0x00000164 */
    {6, 0x00000000u, 0x00000000u},   /*  {0,0,0,0}    -> best0 v0    -> 0x00000000 */
    {6, 0x64640100u, 0x00000000u},   /*  {100,100,1,0}-> best2 v100  -> 0x00000264 */
};

#endif /* GOLDEN_MODEL_TEST_VECTORS_H */
