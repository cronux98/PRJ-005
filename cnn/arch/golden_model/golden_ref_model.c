/*-------------------------------------------------------------------------
 * cnn golden reference model (fe-arch, golden-first) — mnist_npu v2 CNN
 *
 * Integer-only Q8.8 inference for the tiny CNN (the BIT-EXACT CONTRACT the
 * RTL must reproduce, including UART bytes):
 *
 *   Input   28x28 pixels, byte p = Q8.8 value p (i.e. p/256)
 *   Conv1   3x3, 1->8 ch, pad=1, stride=1, ReLU        -> 28x28x8
 *   Pool1   2x2 max, stride=2                           -> 14x14x8
 *   Conv2   3x3, 8->16 ch, pad=1, stride=1, ReLU        -> 14x14x16
 *   Pool2   2x2 max, stride=2                           -> 7x7x16 = 784
 *   FC1     784->32, sigmoid (LUT contract)             -> 32
 *   FC2     32->10, sigmoid (LUT contract)              -> 10
 *
 * Fixed-point rules (RTL must match):
 *   - acc64 = (bias<<8) + SUM x*w   (bias Q8.8 at Q16.16 alignment; all
 *     accumulation in signed 64-bit)
 *   - z = clamp(acc64 >> 8, -32768, 32767)  (arithmetic floor shift)
 *   - conv/pool hidden: h = max(z, 0)        (ReLU)
 *   - FC activation: sigma = 128 + trunc(128*z/(256+|z|))  (C99 trunc
 *     toward zero — the sigmoid LUT's contents)
 *   - argmax over 10 output sigmas, LOWEST index wins ties
 *   - confidence = (best_sigma * 100) >> 8 ; TRASH if < 50
 *   - verdict: 0 CORRECT / 1 INCORRECT / 2 TRASH
 *
 * Weight layout (weights.hex, 26,698 Q8.8 words, one 4-hex-digit word/line):
 *   conv1_w[8*9] | conv1_b[8] | conv2_w[16*72] | conv2_b[16]
 *   | fc1_w[784*32] | fc1_b[32] | fc2_w[32*10] | fc2_b[10]
 *   conv tap order: oc*IC*9 + ic*9 + iy*3 + ix   (iy/ix in 0..2)
 *   fc1 row-major: fc1_w[i*32+j] = weight input i -> hidden j
 *   Feature-map flatten (fc1 input): f[oc*49 + oy*7 + ox] (channel-major)
 *
 * Inputs : arch/golden_model/weights.hex ; data/t10k_images.bin ;
 *          data/t10k_labels.bin
 * Outputs: stdout (UART-format lines + summary) + expected.hex,
 *          images.hex, labels.hex (first 100 test images = RTL vector set)
 *-------------------------------------------------------------------------*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define C1      8
#define C2      16
#define N_FC_IN (7*7*C2)      /* 784 */
#define N_H     32
#define N_OUT   10
#define N_WORDS (9*C1 + C1 + 9*C1*C2 + C2 + N_FC_IN*N_H + N_H + N_H*N_OUT + N_OUT)  /* 26,698 */
#define VEC_N   100
#define CONF_TRASH 50

static int16_t W1[9 * C1], b1[C1];
static int16_t W2[9 * C1 * C2], b2[C2];
static int16_t W3[N_FC_IN * N_H], b3[N_H];
static int16_t W4[N_H * N_OUT], b4[N_OUT];
static unsigned char img[784];

static int h1[28 * 28 * C1];   /* conv1 out, ReLU'd  */
static int p1[14 * 14 * C1];   /* pool1 out          */
static int h2[14 * 14 * C2];   /* conv2 out, ReLU'd  */
static int p2[7 * 7 * C2];     /* pool2 out          */
static int h3[N_H];            /* fc1 out, sigmoid   */

static int load_weights(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return 1; }
    unsigned v; int i = 0;
    const int n1 = 9 * C1, n2 = 9 * C1 * C2, n3 = N_FC_IN * N_H, n4 = N_H * N_OUT;
    while (fscanf(f, "%x", &v) == 1) {
        if (i >= N_WORDS) { fprintf(stderr, "too many words\n"); fclose(f); return 1; }
        int16_t s = (int16_t)(v & 0xFFFF);
        if (i < n1)                       W1[i] = s;
        else if (i < n1 + C1)             b1[i - n1] = s;
        else if (i < n1 + C1 + n2)        W2[i - n1 - C1] = s;
        else if (i < n1 + C1 + n2 + C2)   b2[i - n1 - C1 - n2] = s;
        else if (i < n1 + C1 + n2 + C2 + n3)        W3[i - n1 - C1 - n2 - C2] = s;
        else if (i < n1 + C1 + n2 + C2 + n3 + N_H)  b3[i - n1 - C1 - n2 - C2 - n3] = s;
        else if (i < n1 + C1 + n2 + C2 + n3 + N_H + n4)  W4[i - n1 - C1 - n2 - C2 - n3 - N_H] = s;
        else                                        b4[i - n1 - C1 - n2 - C2 - n3 - N_H - n4] = s;
        i++;
    }
    fclose(f);
    if (i != N_WORDS) { fprintf(stderr, "expected %d words, got %d\n", N_WORDS, i); return 1; }
    return 0;
}

static int load_bin(const char *path, unsigned char *buf, size_t n)
{
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return 1; }
    size_t got = fread(buf, 1, n, f);
    fclose(f);
    if (got != n) { fprintf(stderr, "short read %zu/%zu\n", got, n); return 1; }
    return 0;
}

static int sat(int64_t x) { return x > 32767 ? 32767 : x < -32768 ? -32768 : (int)x; }

static int sigmoid(int z)          /* 128 + trunc(128z/(256+|z|)), C99 trunc */
{
    int64_t num = 128LL * z;
    int64_t den = 256LL + (z < 0 ? -(int64_t)z : (int64_t)z);
    return 128 + (int)(num / den);
}

static void forward(int out[N_OUT])
{
    int oc, oy, ox, ic, iy, ix, j, z, i;
    int64_t acc;
    memset(h1, 0, sizeof h1); memset(p1, 0, sizeof p1);
    memset(h2, 0, sizeof h2); memset(p2, 0, sizeof p2);
    memset(h3, 0, sizeof h3);

    /* Conv1: 3x3, 1->8, pad=1, ReLU -> 28x28x8 */
    for (oc = 0; oc < C1; oc++)
        for (oy = 0; oy < 28; oy++)
            for (ox = 0; ox < 28; ox++) {
                acc = (int64_t)b1[oc] << 8;
                for (iy = 0; iy < 3; iy++)
                    for (ix = 0; ix < 3; ix++) {
                        int py = oy + iy - 1, px = ox + ix - 1;
                        if (py >= 0 && py < 28 && px >= 0 && px < 28)
                            acc += (int64_t)img[py * 28 + px] * W1[oc * 9 + iy * 3 + ix];
                    }
                z = sat(acc >> 8);
                h1[(oc * 28 + oy) * 28 + ox] = z > 0 ? z : 0;
            }

    /* Pool1: 2x2 max -> 14x14x8 */
    for (oc = 0; oc < C1; oc++)
        for (oy = 0; oy < 14; oy++)
            for (ox = 0; ox < 14; ox++) {
                int a = h1[(oc * 28 + 2 * oy) * 28 + 2 * ox];
                int b = h1[(oc * 28 + 2 * oy) * 28 + 2 * ox + 1];
                int c = h1[(oc * 28 + 2 * oy + 1) * 28 + 2 * ox];
                int d = h1[(oc * 28 + 2 * oy + 1) * 28 + 2 * ox + 1];
                int m = a; if (b > m) m = b; if (c > m) m = c; if (d > m) m = d;
                p1[(oc * 14 + oy) * 14 + ox] = m;
            }

    /* Conv2: 3x3, 8->16, pad=1, ReLU -> 14x14x16 */
    for (oc = 0; oc < C2; oc++)
        for (oy = 0; oy < 14; oy++)
            for (ox = 0; ox < 14; ox++) {
                acc = (int64_t)b2[oc] << 8;
                for (ic = 0; ic < C1; ic++)
                    for (iy = 0; iy < 3; iy++)
                        for (ix = 0; ix < 3; ix++) {
                            int py = oy + iy - 1, px = ox + ix - 1;
                            if (py >= 0 && py < 14 && px >= 0 && px < 14)
                                acc += (int64_t)p1[(ic * 14 + py) * 14 + px]
                                     * W2[(oc * C1 + ic) * 9 + iy * 3 + ix];
                        }
                z = sat(acc >> 8);
                h2[(oc * 14 + oy) * 14 + ox] = z > 0 ? z : 0;
            }

    /* Pool2: 2x2 max -> 7x7x16 (channel-major flatten = FC1 input) */
    for (oc = 0; oc < C2; oc++)
        for (oy = 0; oy < 7; oy++)
            for (ox = 0; ox < 7; ox++) {
                int a = h2[(oc * 14 + 2 * oy) * 14 + 2 * ox];
                int b = h2[(oc * 14 + 2 * oy) * 14 + 2 * ox + 1];
                int c = h2[(oc * 14 + 2 * oy + 1) * 14 + 2 * ox];
                int d = h2[(oc * 14 + 2 * oy + 1) * 14 + 2 * ox + 1];
                int m = a; if (b > m) m = b; if (c > m) m = c; if (d > m) m = d;
                p2[(oc * 7 + oy) * 7 + ox] = m;
            }

    /* FC1: 784->32, sigmoid */
    for (j = 0; j < N_H; j++) {
        acc = (int64_t)b3[j] << 8;
        for (i = 0; i < N_FC_IN; i++)
            acc += (int64_t)p2[i] * W3[i * N_H + j];
        z = sat(acc >> 8);
        h3[j] = sigmoid(z);
    }

    /* FC2: 32->10, sigmoid */
    for (j = 0; j < N_OUT; j++) {
        acc = (int64_t)b4[j] << 8;
        for (i = 0; i < N_H; i++)
            acc += (int64_t)h3[i] * W4[i * N_OUT + j];
        z = sat(acc >> 8);
        out[j] = sigmoid(z);
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

    size_t n = 10000;
    unsigned char *imgs = malloc(n * 784);
    unsigned char *labels = malloc(n);
    if (!imgs || !labels) { fprintf(stderr, "oom\n"); return 1; }
    if (load_bin(ipath, imgs, n * 784)) return 1;
    if (load_bin(lpath, labels, n)) return 1;

    FILE *exp = fopen("arch/golden_model/expected.hex", "w");
    FILE *ihx = fopen("arch/golden_model/images.hex", "w");
    FILE *lhx = fopen("arch/golden_model/labels.hex", "w");
    if (!exp || !ihx || !lhx) { fprintf(stderr, "cannot write outputs\n"); return 1; }

    int out[N_OUT];
    int correct = 0, incorrect = 0, trash = 0;
    size_t k;
    int best, conf, verdict, i;

    for (k = 0; k < n; k++) {
        memcpy(img, imgs + k * 784, 784);
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

        if (k < VEC_N) {
            fprintf(exp, "%04x\n%04x\n%04x\n%04x\n", best, conf, labels[k], verdict);
            for (i = 0; i < 784; i++)
                fprintf(ihx, "%02x\n", img[i]);
            fprintf(lhx, "%02x\n", labels[k]);
        }

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
