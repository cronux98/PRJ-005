/*-------------------------------------------------------------------------
 * mnist_npu golden reference model (fe-arch, golden-first)
 *
 * Integer-only Q8.8 inference for the 784-32-10 MLP. This C model is the
 * BIT-EXACT CONTRACT for fe-rtl: the RTL must reproduce its predictions,
 * confidence, verdicts, and UART lines exactly.
 *
 * Fixed-point rules (document in arch.md; RTL must match):
 *   - input: pixel byte p (0..255) is the Q8.8 value p (i.e. p/256)
 *   - MAC: acc += x*w, accumulated in signed 64-bit long (no intermediate
 *     truncation); BIAS is added at Q16.16 alignment: acc = bias<<8
 *     (bias is Q8.8, products x*w are Q16.16). |w| <= 128 and x <= 255
 *     so acc fits easily.
 *   - z = acc >> 8  (arithmetic shift, floor)  [acc saturates to int16
 *     range before the shift: z = clamp(acc>>8, -32768, 32767)]
 *   - activation: sigma = 128 + trunc(128*z / (256+|z|))   (C99 division
 *     truncates toward zero -- identical to learn_accel/rtl/div_seq.v)
 *   - argmax over the 10 output sigmas; lowest index wins ties
 *   - confidence = (best_sigma * 100) >> 8   (0..100)
 *   - verdict: TRASH if confidence < 50; else CORRECT/INCORRECT vs the
 *     expected label from memory (label_rom)
 *
 * Inputs : arch/golden_model/weights.hex  (25,450 Q8.8 words: W1|b1|W2|b2)
 *          data/t10k_images.bin (raw 784-byte images), data/t10k_labels.bin
 * Outputs: stdout report (UART-format lines) + expected.hex, images.hex,
 *          labels.hex for the first 100 images (RTL vector set)
 *-------------------------------------------------------------------------*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define N_IN    784
#define N_H     32
#define N_OUT   10
#define N_WORDS (N_IN * N_H + N_H + N_H * N_OUT + N_OUT)  /* 25,450 */
#define VEC_N   100          /* demo vector set size (RTL ROMs) */
#define CONF_TRASH 50        /* confidence < 50% => trash */

static int16_t W1[N_IN * N_H], b1[N_H], W2[N_H * N_OUT], b2[N_OUT];
static unsigned char img[N_IN];

/* int16 with wrap -> signed */
static int s16(uint32_t u) { return (int)(int16_t)(u & 0xFFFF); }

static int load_weights(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return 1; }
    unsigned v;
    int i = 0;
    while (fscanf(f, "%x", &v) == 1) {
        if (i >= N_WORDS) { fprintf(stderr, "too many words\n"); fclose(f); return 1; }
        if (i < N_IN * N_H)      W1[i] = (int16_t)s16(v);
        else if (i < N_IN*N_H + N_H)                     b1[i - N_IN * N_H] = (int16_t)s16(v);
        else if (i < N_IN*N_H + N_H + N_H*N_OUT)         W2[i - N_IN*N_H - N_H] = (int16_t)s16(v);
        else                                             b2[i - N_IN*N_H - N_H - N_H*N_OUT] = (int16_t)s16(v);
        i++;
    }
    fclose(f);
    if (i != N_WORDS) { fprintf(stderr, "expected %d words, got %d\n", N_WORDS, i); return 1; }
    return 0;
}

static int load_images(const char *path, unsigned char *imgs, size_t n)
{
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return 1; }
    size_t got = fread(imgs, 1, n * N_IN, f);
    fclose(f);
    if (got != n * N_IN) { fprintf(stderr, "short read %zu/%zu\n", got, n * N_IN); return 1; }
    return 0;
}

static int load_labels(const char *path, unsigned char *labels, size_t n)
{
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return 1; }
    size_t got = fread(labels, 1, n, f);
    fclose(f);
    if (got != n) { fprintf(stderr, "short read %zu/%zu\n", got, n); return 1; }
    return 0;
}

/* rational sigmoid: sigma = 128 + trunc(128*z/(256+|z|)), z Q8.8 */
static int sigmoid(int z)
{
    long num = 128L * z;                 /* fits int32 far beyond z range */
    long den = 256L + (z < 0 ? - (long)z : (long)z);
    return 128 + (int)(num / den);       /* C99: trunc toward zero */
}

/* forward pass on img[] -> out[10] sigmas (0..256) */
static void forward(int out[N_OUT])
{
    long acc;
    int h[N_H];
    int i, j, c, z;
    for (j = 0; j < N_H; j++) {
        acc = (long)b1[j] << 8;             /* bias at Q16.16 alignment */
        for (i = 0; i < N_IN; i++)
            acc += (int)img[i] * W1[i * N_H + j];   /* x=p (Q8.8), w Q8.8 */
        z = (int)(acc >> 8);
        if (z >  32767) z =  32767;
        if (z < -32768) z = -32768;
        h[j] = sigmoid(z);                          /* 0..256 */
    }
    for (c = 0; c < N_OUT; c++) {
        acc = (long)b2[c] << 8;             /* bias at Q16.16 alignment */
        for (j = 0; j < N_H; j++)
            acc += (long)h[j] * W2[j * N_OUT + c];
        z = (int)(acc >> 8);
        if (z >  32767) z =  32767;
        if (z < -32768) z = -32768;
        out[c] = sigmoid(z);
    }
}

int main(int argc, char **argv)
{
    const char *root = argc > 1 ? argv[1] : ".";
    char wpath[1024], ipath[1024], lpath[1024];
    snprintf(wpath, sizeof wpath, "%s/arch/golden_model/weights.hex", root);
    snprintf(ipath, sizeof ipath, "%s/data/t10k_images.bin", root);
    snprintf(lpath, sizeof lpath, "%s/data/t10k_labels.bin", root);
    if (load_weights(wpath)) return 1;

    static unsigned char *imgs;   /* 10,000 x 784 */
    static unsigned char *labels; /* 10,000 */
    size_t n = 10000;
    imgs   = malloc(n * N_IN);
    labels = malloc(n);
    if (!imgs || !labels) { fprintf(stderr, "oom\n"); return 1; }
    if (load_images(ipath, imgs, n)) return 1;
    if (load_labels(lpath, labels, n)) return 1;

    FILE *exp = fopen("arch/golden_model/expected.hex", "w");
    FILE *ihx = fopen("arch/golden_model/images.hex", "w");
    FILE *lhx = fopen("arch/golden_model/labels.hex", "w");
    if (!exp || !ihx || !lhx) { fprintf(stderr, "cannot write outputs\n"); return 1; }

    int out[N_OUT];
    int correct = 0, incorrect = 0, trash = 0;
    size_t k, i;
    int best, conf, verdict;

    for (k = 0; k < n; k++) {
        memcpy(img, imgs + k * N_IN, N_IN);
        forward(out);

        best = 0;
        for (i = 1; i < N_OUT; i++)
            if (out[i] > out[best]) best = (int)i;      /* lowest-index ties */
        conf = (out[best] * 100) >> 8;                  /* 0..100 */

        if (conf < CONF_TRASH)      verdict = 2;        /* TRASH */
        else if (best != labels[k]) verdict = 1;        /* INCORRECT */
        else                        verdict = 0;        /* CORRECT */
        if (verdict == 0) correct++;
        else if (verdict == 1) incorrect++;
        else trash++;

        if (k < VEC_N) {                               /* RTL vector set */
            fprintf(exp, "%04x\n%04x\n%04x\n%04x\n", best, conf, labels[k], verdict);
            for (i = 0; i < N_IN; i++)
                fprintf(ihx, "%02x\n", img[i]);
            fprintf(lhx, "%02x\n", labels[k]);
        }

        /* UART-format report line (RTL must emit identical bytes) */
        if (verdict == 2)
            printf("IMG %03zu: NOT A NUMBER | confidence %d%% | expected %u | TRASH\n",
                   k, conf, labels[k]);
        else
            printf("IMG %03zu: This is number %d | confidence %d%% | expected %u | %s\n",
                   k, best, conf, labels[k],
                   verdict == 0 ? "CORRECT" : "INCORRECT");
    }

    fclose(exp); fclose(ihx); fclose(lhx);
    printf("\nSUMMARY on %zu test images: correct %d, incorrect %d, trash %d,"
           " accuracy %.2f%%\n",
           n, correct, incorrect, trash, 100.0 * correct / n);
    printf("vector set: first %d images -> expected.hex, images.hex, labels.hex\n", VEC_N);
    return 0;
}
