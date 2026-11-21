// Test numerici del motore DSP: misurano il segnale REALMENTE elaborato da aeq_process
// e lo confrontano con i valori mostrati dall'interfaccia (cursori e curva EQ).
//
// Compilazione (da ArmoniaEQ/):
//   cc -O2 -DAEQ_NO_SAFETY_CLAMP -I Sources/ArmoniaDSP/include Tests/dsp_test.c
//      Sources/ArmoniaDSP/dsp.c Sources/ArmoniaDSP/presets.c -lm -o build/dsp_test && build/dsp_test

#include "ArmoniaDSP.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define PI 3.14159265358979323846
#define BLOCK 512

static int failures = 0;
static int checks = 0;

static void check(int ok, const char *fmt, double a, double b) {
    checks++;
    if (!ok) {
        failures++;
        printf("  FALLITO: ");
        printf(fmt, a, b);
        printf("\n");
    }
}

static AEQEngine *make_engine(double sr) {
    AEQEngine *e = aeq_create(sr);
    aeq_set_limiter_enabled(e, 0);
    aeq_prepare(e, sr);
    return e;
}

static void apply_preset(AEQEngine *e, int p) {
    for (int b = 0; b < AEQ_NUM_BANDS; b++) aeq_set_band_gain(e, b, aeq_preset_gain(p, b));
    aeq_set_preamp(e, aeq_preset_preamp(p));
}

// Ampiezza di una sinusoide a frequenza f stimata con proiezione finestrata (Hann).
static double amplitude(const float *x, int n, double f, double sr) {
    double s = 0, c = 0, wsum = 0;
    for (int i = 0; i < n; i++) {
        double w = 0.5 - 0.5 * cos(2 * PI * i / (n - 1));
        double ph = 2 * PI * f * i / sr;
        s += w * x[i] * sin(ph);
        c += w * x[i] * cos(ph);
        wsum += w;
    }
    return 2.0 * sqrt(s * s + c * c) / wsum;
}

// Fa passare una sinusoide nel motore e restituisce il guadagno misurato in dB (regime).
static double measure_gain_db(AEQEngine *e, double f, double sr, double amp) {
    const int settle = (int)sr;     // 1 s per stabilizzare smoothing e filtri
    const int measure = (int)sr;    // 1 s di misura
    float *inL = malloc(sizeof(float) * measure), *outL = malloc(sizeof(float) * measure);
    float l[BLOCK], r[BLOCK];
    long idx = 0;
    for (int done = 0; done < settle + measure; done += BLOCK) {
        for (int i = 0; i < BLOCK; i++, idx++) {
            float v = (float)(amp * sin(2 * PI * f * idx / sr));
            l[i] = v;
            r[i] = v;
            int m = done + i - settle;
            if (m >= 0 && m < measure) inL[m] = v;
        }
        aeq_process(e, l, r, BLOCK);
        for (int i = 0; i < BLOCK; i++) {
            int m = done + i - settle;
            if (m >= 0 && m < measure) outL[m] = l[i];
        }
    }
    double g = 20 * log10(amplitude(outL, measure, f, sr) / amplitude(inL, measure, f, sr));
    free(inL);
    free(outL);
    return g;
}

static void test_single_band_values(double sr) {
    printf("\n[1] Valore del cursore = guadagno applicato alla frequenza della banda (%.0f Hz)\n", sr);
    const float values[] = {-12.0f, -6.0f, -2.5f, 3.0f, 6.0f, 12.0f};
    double worst = 0;
    for (int b = 0; b < AEQ_NUM_BANDS; b++) {
        for (size_t v = 0; v < sizeof(values) / sizeof(values[0]); v++) {
            AEQEngine *e = make_engine(sr);
            aeq_set_band_gain(e, b, values[v]);
            double g = measure_gain_db(e, aeq_band_frequency(b), sr, 0.05);
            double err = fabs(g - values[v]);
            if (err > worst) worst = err;
            check(err < 0.05, "banda %.0f Hz: errore %.3f dB", aeq_band_frequency(b), err);
            aeq_destroy(e);
        }
    }
    printf("  10 bande x 6 valori: errore massimo %.4f dB\n", worst);
}

static void test_presets(double sr) {
    printf("\n[2] Profili: guadagno misurato vs curva mostrata (%.0f Hz)\n", sr);
    printf("  %-11s %-8s", "profilo", "");
    for (int b = 0; b < AEQ_NUM_BANDS; b++) printf("%7.0f", aeq_band_frequency(b));
    printf("   picco curva+preamp\n");
    double probe[] = {20, 45, 90, 180, 350, 700, 1400, 2800, 5600, 11000, 19000};
    for (int p = 0; p < aeq_preset_count(); p++) {
        float gains[AEQ_NUM_BANDS];
        for (int b = 0; b < AEQ_NUM_BANDS; b++) gains[b] = aeq_preset_gain(p, b);
        float pre = aeq_preset_preamp(p);
        double meas[AEQ_NUM_BANDS], worst = 0;
        for (int b = 0; b < AEQ_NUM_BANDS; b++) {
            AEQEngine *e = make_engine(sr);
            apply_preset(e, p);
            meas[b] = measure_gain_db(e, aeq_band_frequency(b), sr, 0.05);
            double shown = aeq_response_db(gains, pre, sr, aeq_band_frequency(b));
            double err = fabs(meas[b] - shown);
            if (err > worst) worst = err;
            check(err < 0.05, "profilo, banda %.0f Hz: errore %.3f dB", aeq_band_frequency(b), err);
            aeq_destroy(e);
        }
        for (size_t k = 0; k < sizeof(probe) / sizeof(probe[0]); k++) {
            AEQEngine *e = make_engine(sr);
            apply_preset(e, p);
            double m = measure_gain_db(e, probe[k], sr, 0.05);
            double err = fabs(m - aeq_response_db(gains, pre, sr, probe[k]));
            if (err > worst) worst = err;
            check(err < 0.05, "profilo, %.0f Hz tra le bande: errore %.3f dB", probe[k], err);
            aeq_destroy(e);
        }
        double peak = -99;
        for (double f = 20; f < 20000; f *= 1.005) {
            double r = aeq_response_db(gains, pre, sr, f);
            if (r > peak) peak = r;
        }
        printf("  %-11s cursori ", aeq_preset_identifier(p));
        for (int b = 0; b < AEQ_NUM_BANDS; b++) printf("%+7.1f", gains[b]);
        printf("   preamp %+.1f\n  %-11s misurati", pre, "");
        for (int b = 0; b < AEQ_NUM_BANDS; b++) printf("%+7.2f", meas[b]);
        printf("   %+.2f dB  (errore max vs curva %.4f dB)\n", peak, worst);
        check(peak <= 1.5, "profilo: picco curva+preamp %.2f dB > %.1f dB", peak, 1.5);
        if (p > 0) {
            // Ogni profilo deve cambiare realmente il suono rispetto a Flat.
            double maxDiff = 0;
            for (int b = 0; b < AEQ_NUM_BANDS; b++) maxDiff = fmax(maxDiff, fabs(meas[b]));
            check(maxDiff > 1.0, "profilo identico a flat (%.2f dB, soglia %.1f)", maxDiff, 1.0);
        }
    }
}

static void test_bypass(void) {
    printf("\n[3] Interruttore EQ (bypass)\n");
    AEQEngine *e = make_engine(48000);
    apply_preset(e, 4);
    aeq_set_eq_enabled(e, 0);
    double worst = 0;
    for (int b = 0; b < AEQ_NUM_BANDS; b++) {
        double g = fabs(measure_gain_db(e, aeq_band_frequency(b), 48000, 0.05));
        if (g > worst) worst = g;
    }
    check(worst < 0.01, "bypass non neutro: %.3f dB (soglia %.2f)", worst, 0.01);
    aeq_set_eq_enabled(e, 1);
    double on = measure_gain_db(e, 64, 48000, 0.05);
    check(on < -8.0, "riattivazione EQ: 64 Hz = %.2f dB (atteso < %.0f)", on, -8.0);
    printf("  bypass: deviazione max %.4f dB; riattivato: 64 Hz = %.2f dB\n", worst, on);
    aeq_destroy(e);
}

static void test_volume_balance(void) {
    printf("\n[4] Volume e bilanciamento\n");
    AEQEngine *e = make_engine(48000);
    aeq_set_volume(e, 0.5f);
    aeq_set_balance(e, 0.5f);
    float l[BLOCK], r[BLOCK];
    long idx = 0;
    double pl = 0, pr = 0;
    for (int blk = 0; blk < 400; blk++) {
        for (int i = 0; i < BLOCK; i++, idx++) l[i] = r[i] = (float)(0.5 * sin(2 * PI * 1000 * idx / 48000.0));
        aeq_process(e, l, r, BLOCK);
        if (blk > 300)
            for (int i = 0; i < BLOCK; i++) { pl = fmax(pl, fabs(l[i])); pr = fmax(pr, fabs(r[i])); }
    }
    check(fabs(pl - 0.125) < 0.002, "canale sinistro %.4f (atteso %.3f)", pl, 0.125);
    check(fabs(pr - 0.25) < 0.002, "canale destro %.4f (atteso %.3f)", pr, 0.25);
    printf("  volume 0.5, bilanciamento +0.5: L=%.4f R=%.4f (attesi 0.125 / 0.250)\n", pl, pr);
    aeq_destroy(e);
}

static void test_smooth_switch(void) {
    printf("\n[5] Cambio profilo durante la riproduzione (assenza di discontinuità)\n");
    const double sr = 48000, f = 80, amp = 0.2;
    AEQEngine *e = make_engine(sr);
    float l[BLOCK], r[BLOCK];
    long idx = 0;
    float prev = 0;
    double maxStep = 0, maxStepSteady = 0;
    int nan = 0;
    for (int blk = 0; blk < 600; blk++) {
        if (blk == 200) apply_preset(e, 1);   // Flat -> Elettronica
        if (blk == 300) apply_preset(e, 4);   // -> Voce
        if (blk == 400) apply_preset(e, 0);   // -> Flat
        for (int i = 0; i < BLOCK; i++, idx++) l[i] = r[i] = (float)(amp * sin(2 * PI * f * idx / sr));
        aeq_process(e, l, r, BLOCK);
        for (int i = 0; i < BLOCK; i++) {
            if (isnan(l[i]) || isinf(l[i])) nan++;
            double step = fabs(l[i] - prev);
            prev = l[i];
            if (blk > 10) maxStep = fmax(maxStep, step);
            int inSteady = (blk > 150 && blk < 200) || (blk > 250 && blk < 300) ||
                           (blk > 350 && blk < 400) || (blk > 550);
            if (inSteady) maxStepSteady = fmax(maxStepSteady, step);
        }
    }
    // Con lo smoothing la massima variazione tra campioni non supera quella a regime
    // più ampia tra i profili attraversati (nessun gradino = nessun click).
    check(nan == 0, "campioni non validi: %.0f %.0f", nan, 0);
    check(maxStep <= maxStepSteady * 1.05, "salto max %.5f > regime %.5f", maxStep, maxStepSteady);
    printf("  salto max tra campioni durante i cambi %.5f, a regime %.5f, NaN %d\n", maxStep, maxStepSteady, nan);
    aeq_destroy(e);
}

static void test_limiter(void) {
    printf("\n[6] Limiter di picco (senza la rete di sicurezza: AEQ_NO_SAFETY_CLAMP)\n");
    const double sr = 48000;
    AEQEngine *e = aeq_create(sr);
    aeq_set_limiter_enabled(e, 1);
    aeq_set_limiter_ceiling(e, -1.0f);
    for (int b = 0; b < AEQ_NUM_BANDS; b++) aeq_set_band_gain(e, b, 12.0f);
    aeq_set_preamp(e, 6.0f);
    aeq_prepare(e, sr);
    const float ceiling = powf(10.0f, -1.0f / 20.0f);
    float l[BLOCK], r[BLOCK];
    srand(1);
    double maxOut = 0;
    long idx = 0;
    for (int blk = 0; blk < 2000; blk++) {
        for (int i = 0; i < BLOCK; i++, idx++) {
            double noise = ((double)rand() / RAND_MAX - 0.5);
            double burst = (blk % 50 < 3) ? 1.0 : 0.2; // transienti improvvisi
            l[i] = (float)(burst * (0.8 * sin(2 * PI * 60 * idx / sr) + noise));
            r[i] = (float)(burst * (0.8 * sin(2 * PI * 3000 * idx / sr) - noise));
        }
        aeq_process(e, l, r, BLOCK);
        for (int i = 0; i < BLOCK; i++) maxOut = fmax(maxOut, fmax(fabs(l[i]), fabs(r[i])));
    }
    float gr = aeq_read_gain_reduction_db(e);
    check(maxOut <= ceiling * 1.0001, "picco %.5f > ceiling %.5f", maxOut, ceiling);
    printf("  ingresso fino a ~+30 dBFS dopo EQ, picco in uscita %.5f (ceiling %.5f = -1 dBFS), riduzione max %.1f dB\n",
           maxOut, ceiling, gr);
    aeq_destroy(e);
}

static void test_performance(void) {
    printf("\n[7] Carico CPU\n");
    const double sr = 48000;
    AEQEngine *e = aeq_create(sr);
    apply_preset(e, 1);
    float l[256], r[256];
    const int blocks = (int)(60 * sr / 256); // 60 s di audio
    clock_t t0 = clock();
    for (int k = 0; k < blocks; k++) {
        for (int i = 0; i < 256; i++) l[i] = r[i] = (float)sin((k * 256 + i) * 0.1) * 0.3f;
        aeq_process(e, l, r, 256);
    }
    double secs = (double)(clock() - t0) / CLOCKS_PER_SEC;
    printf("  60 s di audio stereo elaborati in %.3f s (%.2f%% di un core)\n", secs, secs / 60 * 100);
    check(secs < 3.0, "troppo lento: %.2f s (limite %.0f)", secs, 3.0);
    aeq_destroy(e);
}


// Segnale di prova a banda larga, deterministico: rumore + 3 sinusoidi. Picco < -1 dBFS.
static void test_signal(float *l, float *r, long start, int n, double sr, double scale) {
    for (int i = 0; i < n; i++) {
        long k = start + i;
        unsigned int h = (unsigned int)(k * 2654435761u);
        double noise = ((h >> 8) & 0xFFFF) / 65535.0 - 0.5;
        double v = 0.12 * sin(2 * PI * 97 * k / sr) + 0.10 * sin(2 * PI * 1013 * k / sr)
                 + 0.08 * sin(2 * PI * 6007 * k / sr) + 0.25 * noise;
        l[i] = (float)(v * scale);
        r[i] = (float)(-v * 0.9 * scale);
    }
}

// Confronto RMS e picco ingresso/uscita con EQ Flat (volume 100 %, limiter attivo, bilanciamento 0).
// inputAtten simula l'attenuazione del controllo volume di BlackHole; compensate applica 1/g.
static void flat_level_check(const char *label, double inputAtten, int compensate) {
    const double sr = 48000;
    AEQEngine *e = aeq_create(sr); // Flat, preamp 0, volume 1, limiter ON a -1 dBFS
    if (compensate) aeq_set_input_gain(e, (float)(1.0 / inputAtten));
    aeq_prepare(e, sr);
    float l[BLOCK], r[BLOCK];
    double sumIn = 0, sumOut = 0, pkIn = 0, pkOut = 0;
    long n = 0;
    for (int blk = 0; blk < 1000; blk++) { // ~10,7 s
        test_signal(l, r, (long)blk * BLOCK, BLOCK, sr, 1.0);
        for (int i = 0; i < BLOCK; i++) {
            if (blk >= 20) { sumIn += (double)l[i] * l[i] + (double)r[i] * r[i]; }
            pkIn = fmax(pkIn, fmax(fabs(l[i]), fabs(r[i])));
            l[i] = (float)(l[i] * inputAtten); // stadio "BlackHole"
            r[i] = (float)(r[i] * inputAtten);
        }
        aeq_process(e, l, r, BLOCK);
        for (int i = 0; i < BLOCK; i++) {
            if (blk >= 20) { sumOut += (double)l[i] * l[i] + (double)r[i] * r[i]; n++; }
            pkOut = fmax(pkOut, fmax(fabs(l[i]), fabs(r[i])));
        }
    }
    double rmsIn = sqrt(sumIn / (2.0 * n)), rmsOut = sqrt(sumOut / (2.0 * n));
    double dRms = 20 * log10(rmsOut / rmsIn), dPk = 20 * log10(pkOut / pkIn);
    printf("  %-44s RMS in %.4f out %.4f (%+.3f dB)  picco in %.4f out %.4f (%+.3f dB)\n",
           label, rmsIn, rmsOut, dRms, pkIn, pkOut, dPk);
    check(fabs(dRms) < 0.05, "RMS alterato di %.3f dB (soglia %.2f)", dRms, 0.05);
    check(fabs(dPk) < 0.05, "picco alterato di %.3f dB (soglia %.2f)", dPk, 0.05);
    aeq_destroy(e);
}

static void test_flat_levels(void) {
    printf("\n[8] Livello RMS e picco con EQ Flat: ingresso = uscita\n");
    flat_level_check("Flat, volume 100 %", 1.0, 0);
    flat_level_check("Flat, BlackHole a -32 dB (50 %), compensato", pow(10, -32 / 20.0), 1);
    flat_level_check("Flat, BlackHole a -48 dB (25 %), compensato", pow(10, -48 / 20.0), 1);
    flat_level_check("Flat, BlackHole a -60 dB (6 %), compensato", pow(10, -60 / 20.0), 1);
}

// Rumore rosa deterministico (filtro di Paul Kellet su rumore bianco LCG), stereo identico.
typedef struct { unsigned int seed; double b0, b1, b2, b3, b4, b5, b6; } Pink;
static float pink_next(Pink *p) {
    p->seed = p->seed * 1664525u + 1013904223u;
    double w = ((p->seed >> 8) & 0xFFFFFF) / 16777215.0 * 2.0 - 1.0;
    p->b0 = 0.99886 * p->b0 + w * 0.0555179; p->b1 = 0.99332 * p->b1 + w * 0.0750759;
    p->b2 = 0.96900 * p->b2 + w * 0.1538520; p->b3 = 0.86650 * p->b3 + w * 0.3104856;
    p->b4 = 0.55000 * p->b4 + w * 0.5329522; p->b5 = -0.7616 * p->b5 - w * 0.0168980;
    double out = p->b0 + p->b1 + p->b2 + p->b3 + p->b4 + p->b5 + p->b6 + w * 0.5362;
    p->b6 = w * 0.115926;
    return (float)(out * 0.04);
}

// Rilevamento dei click: un click è una discontinuità, che produce energia a larga banda.
// Si suona un tono puro a frequenza f, si filtra l'uscita con un passa-alto Butterworth del
// 4° ordine a fc >> f (attenua il tono di oltre 80 dB) e si misura il residuo: durante i cambi
// di parametro deve restare sotto -60 dB rispetto al tono. Una variazione morbida del livello
// non produce residuo; un gradino sì.
typedef struct { double b0, b1, b2, a1, a2, z1, z2; } DBiquad;
static void dhp_init(DBiquad *f, double fc, double q, double sr) {
    double w0 = 2 * PI * fc / sr, al = sin(w0) / (2 * q), a0 = 1 + al, c = cos(w0);
    f->b0 = (1 + c) / 2 / a0; f->b1 = -(1 + c) / a0; f->b2 = f->b0;
    f->a1 = -2 * c / a0; f->a2 = (1 - al) / a0; f->z1 = f->z2 = 0;
}
static double dbq(DBiquad *f, double x) {
    double y = f->b0 * x + f->z1;
    f->z1 = f->b1 * x - f->a1 * y + f->z2;
    f->z2 = f->b2 * x - f->a2 * y;
    return y;
}
typedef void (*ParamChange)(AEQEngine *, int);
static void click_check(const char *label, ParamChange change, double f) {
    const double sr = 48000, amp = 0.2;
    const double fc = f < 150 ? 1000 : 2500;
    AEQEngine *e = make_engine(sr);
    DBiquad h1, h2;
    dhp_init(&h1, fc, 0.5412, sr);
    dhp_init(&h2, fc, 1.3066, sr);
    float l[BLOCK], r[BLOCK];
    long idx = 0;
    double residue = 0;
    int bad = 0;
    for (int blk = 0; blk < 700; blk++) {
        change(e, blk);
        for (int i = 0; i < BLOCK; i++, idx++) l[i] = r[i] = (float)(amp * sin(2 * PI * f * idx / sr));
        aeq_process(e, l, r, BLOCK);
        for (int i = 0; i < BLOCK; i++) {
            if (!isfinite(l[i])) bad++;
            double y = dbq(&h2, dbq(&h1, l[i]));
            if (blk > 20) residue = fmax(residue, fabs(y));
        }
    }
    double rel = 20 * log10(fmax(residue, 1e-12) / amp);
    printf("  %-44s residuo a larga banda %.1f dB rispetto al tono\n", label, rel);
    check(bad == 0, "campioni non validi: %.0f (%.0f)", bad, 0);
    check(rel < -60.0, "click: residuo %.1f dB (soglia %.0f dB)", rel, -60.0);
    aeq_destroy(e);
}

static void ch_bass(AEQEngine *e, int blk) { if (blk % 100 == 0) aeq_set_bass(e, (blk / 100) % 2 ? 12.0f : -12.0f); }
static void ch_treble(AEQEngine *e, int blk) { if (blk % 100 == 0) aeq_set_treble(e, (blk / 100) % 2 ? 12.0f : -12.0f); }
static void ch_ab(AEQEngine *e, int blk) {
    // A = Elettronica + bassi +6 / alti +3, B = Voce + bassi -4 / alti +2: passaggio ogni 100 blocchi.
    if (blk % 100 != 0) return;
    int useA = (blk / 100) % 2 == 0;
    int p = useA ? 1 : 4;
    for (int b = 0; b < AEQ_NUM_BANDS; b++) aeq_set_band_gain(e, b, aeq_preset_gain(p, b));
    aeq_set_preamp(e, aeq_preset_preamp(p));
    aeq_set_bass(e, useA ? 6.0f : -4.0f);
    aeq_set_treble(e, useA ? 3.0f : 2.0f);
}
static void ch_autogain(AEQEngine *e, int blk) { if (blk % 100 == 0) aeq_set_auto_gain(e, (blk / 100) % 2 ? 6.0f : -12.0f); }

static void test_tone(void) {
    printf("\n[9] Controlli BASSI (shelving %.0f Hz) e ALTI (shelving %.0f Hz), indipendenti dai 10 cursori\n",
           AEQ_BASS_FREQUENCY, AEQ_TREBLE_FREQUENCY);
    const double sr = 48000;
    const double probe[] = {25, 32, 50, 80, 120, 250, 500, 1000, 2000, 4000, 8000, 10000, 14000, 18000};
    const int np = sizeof(probe) / sizeof(probe[0]);

    // a) -12, 0, +12 dB per BASSI e ALTI: misura = curva; effetto pieno agli estremi, 0 dB al centro.
    const float values[] = {-12.0f, 0.0f, 12.0f};
    for (int which = 0; which < 2; which++) {
        for (int v = 0; v < 3; v++) {
            double worst = 0, low = 0, mid = 0, high = 0;
            for (int k = 0; k < np; k++) {
                AEQEngine *e = make_engine(sr);
                if (which == 0) aeq_set_bass(e, values[v]); else aeq_set_treble(e, values[v]);
                double m = measure_gain_db(e, probe[k], sr, 0.02);
                double shown = which == 0 ? aeq_bass_response_db(values[v], sr, probe[k])
                                          : aeq_treble_response_db(values[v], sr, probe[k]);
                worst = fmax(worst, fabs(m - shown));
                if (probe[k] == 25) low = m;
                if (probe[k] == 1000) mid = m;
                if (probe[k] == 18000) high = m;
                aeq_destroy(e);
            }
            const char *name = which == 0 ? "BASSI" : "ALTI";
            printf("  %-5s %+5.1f dB: 25 Hz %+6.2f, 1 kHz %+5.2f, 18 kHz %+6.2f dB (errore max vs curva %.4f dB)\n",
                   name, values[v], low, mid, high, worst);
            check(worst < 0.05, "tono: misura diversa dalla curva di %.3f dB (soglia %.2f)", worst, 0.05);
            double edge = which == 0 ? low : high, other = which == 0 ? high : low;
            check(fabs(edge - values[v]) < 0.8, "tono: estremo %.2f dB invece di %.1f", edge, values[v]);
            check(fabs(other) < 0.05 && fabs(mid) < 0.6, "tono: banda opposta/medi alterati (%.3f / %.3f dB)", other, mid);
        }
    }

    // b) Passi di 0,5 dB e limiti -12...+12 (anche NaN).
    {
        AEQEngine *e = aeq_create(sr);
        const float in[] = {0.2f, 0.26f, -1.74f, 7.24f, 11.9f, 30.0f, -40.0f, NAN};
        const float exp_[] = {0.0f, 0.5f, -1.5f, 7.0f, 12.0f, 12.0f, -12.0f, 0.0f};
        int ok = 1;
        for (int i = 0; i < 8; i++) {
            aeq_set_bass(e, in[i]);
            aeq_set_treble(e, in[i]);
            if (fabsf(aeq_get_bass_target(e) - exp_[i]) > 1e-6f || fabsf(aeq_get_treble_target(e) - exp_[i]) > 1e-6f) ok = 0;
        }
        check(ok, "quantizzazione a 0,5 dB / limiti errati (%.0f %.0f)", 0, 0);
        printf("  passi di 0,5 dB, limiti -12...+12, NaN -> 0: %s\n", ok ? "OK" : "ERRATI");
        aeq_destroy(e);
    }

    // c) Interazione BASSI + ALTI: l'effetto combinato è la somma esatta delle due curve.
    {
        const float combos[][2] = {{12, 12}, {-12, 12}, {12, -12}, {6.5f, -3.5f}};
        for (int c = 0; c < 4; c++) {
            double worst = 0;
            for (int k = 0; k < np; k++) {
                AEQEngine *e = make_engine(sr);
                aeq_set_bass(e, combos[c][0]);
                aeq_set_treble(e, combos[c][1]);
                double m = measure_gain_db(e, probe[k], sr, 0.02);
                double expect = aeq_bass_response_db(combos[c][0], sr, probe[k]) + aeq_treble_response_db(combos[c][1], sr, probe[k]);
                worst = fmax(worst, fabs(m - expect));
                aeq_destroy(e);
            }
            printf("  BASSI %+5.1f + ALTI %+5.1f: errore max vs somma delle curve %.4f dB\n", combos[c][0], combos[c][1], worst);
            check(worst < 0.05, "interazione bassi/alti: errore %.3f dB (soglia %.2f)", worst, 0.05);
        }
    }

    // d) Indipendenza dai 10 cursori: per ogni profilo, BASSI +12 / ALTI -12 = curva del profilo +
    //    curve dei toni; i cursori del profilo non cambiano.
    for (int p = 1; p < aeq_preset_count(); p++) {
        float gains[AEQ_NUM_BANDS];
        for (int b = 0; b < AEQ_NUM_BANDS; b++) gains[b] = aeq_preset_gain(p, b);
        float pre = aeq_preset_preamp(p);
        double worst = 0;
        for (int k = 0; k < np; k++) {
            AEQEngine *e = make_engine(sr);
            apply_preset(e, p);
            aeq_set_bass(e, 12.0f);
            aeq_set_treble(e, -12.0f);
            double m = measure_gain_db(e, probe[k], sr, 0.01);
            double expect = aeq_response_total_db(gains, pre, 12.0f, -12.0f, sr, probe[k]);
            worst = fmax(worst, fabs(m - expect));
            aeq_destroy(e);
        }
        int same = 1;
        for (int b = 0; b < AEQ_NUM_BANDS; b++) if (aeq_preset_gain(p, b) != gains[b]) same = 0;
        printf("  %-11s + BASSI +12 / ALTI -12: errore max vs curva totale %.4f dB; cursori invariati: %s\n",
               aeq_preset_identifier(p), worst, same ? "sì" : "NO");
        check(worst < 0.05, "indipendenza toni/EQ: errore %.3f dB (soglia %.2f)", worst, 0.05);
        check(same, "i cursori del profilo sono cambiati (%.0f %.0f)", 0, 0);
    }

    // e) Toni portati a ±12 e poi a 0: il suono torna quello del solo profilo (entro il residuo
    //    di arrotondamento float32 misurato senza toccare i toni).
    {
        double diffDuring = 0, diffAfter = 0, control = 0;
        for (int run = 0; run < 2; run++) {
            AEQEngine *a = make_engine(sr), *b = make_engine(sr);
            apply_preset(a, 2); apply_preset(b, 2);
            aeq_prepare(a, sr); aeq_prepare(b, sr);
            float la[BLOCK], ra[BLOCK], lb[BLOCK], rb[BLOCK];
            for (int blk = 0; blk < 600; blk++) {
                if (run == 0 && blk == 50) { aeq_set_bass(b, 12.0f); aeq_set_treble(b, -12.0f); }
                if (run == 0 && blk == 200) { aeq_set_bass(b, 0.0f); aeq_set_treble(b, 0.0f); }
                test_signal(la, ra, (long)blk * BLOCK, BLOCK, sr, 1.0);
                const double scale = (run == 1 && blk >= 50 && blk < 200) ? 1.5 : 1.0;
                for (int i = 0; i < BLOCK; i++) { lb[i] = (float)(la[i] * scale); rb[i] = (float)(ra[i] * scale); }
                aeq_process(a, la, ra, BLOCK);
                aeq_process(b, lb, rb, BLOCK);
                for (int i = 0; i < BLOCK; i++) {
                    double d = fabs(la[i] - lb[i]);
                    if (run == 0 && blk > 100 && blk < 200) diffDuring = fmax(diffDuring, d);
                    if (blk > 400) { if (run == 0) diffAfter = fmax(diffAfter, d); else control = fmax(control, d); }
                }
            }
            aeq_destroy(a); aeq_destroy(b);
        }
        printf("  toni ±12 poi 0: differenza durante %.3f; dopo %.1e vs controllo %.1e\n", diffDuring, diffAfter, control);
        check(diffDuring > 0.01, "i toni non cambiano il suono (%.4f, soglia %.2f)", diffDuring, 0.01);
        check(diffAfter <= 2.0 * control + 1e-6, "residuo dopo i toni %.3g oltre il riferimento %.3g", diffAfter, control);
    }

    // f) Bypass EQ: anche i toni vengono esclusi.
    {
        AEQEngine *e = make_engine(sr);
        aeq_set_bass(e, 12.0f);
        aeq_set_treble(e, 12.0f);
        aeq_set_eq_enabled(e, 0);
        double gl = measure_gain_db(e, 40, sr, 0.02), gh = measure_gain_db(e, 15000, sr, 0.02);
        printf("  bypass con BASSI/ALTI +12: 40 Hz %+.3f dB, 15 kHz %+.3f dB\n", gl, gh);
        check(fabs(gl) < 0.01 && fabs(gh) < 0.01, "bypass non neutro con i toni: %.3f / %.3f dB", gl, gh);
        aeq_destroy(e);
    }

    // g) Nessun click muovendo i toni da -12 a +12 durante la riproduzione.
    click_check("BASSI -12 <-> +12 in riproduzione (60 Hz)", ch_bass, 60);
    click_check("ALTI -12 <-> +12 in riproduzione (200 Hz)", ch_treble, 200);
}

// Loudness misurata con rumore rosa pesato K, come aeq_loudness_change_db ma sul segnale reale.
static double pink_loudness_db(AEQEngine *e, double sr) {
    Pink pk = {12345u, 0, 0, 0, 0, 0, 0, 0};
    // Filtri di pesatura K applicati all'uscita (biquad in doppia precisione).
    double hz1[2] = {0}, hz2[2] = {0};
    const double w0a = 2 * PI * 38.135 / sr, aa = sin(w0a) / (2 * 0.5003);
    const double hpb0 = (1 + cos(w0a)) / 2 / (1 + aa), hpb1 = -(1 + cos(w0a)) / (1 + aa), hpb2 = hpb0;
    const double hpa1 = -2 * cos(w0a) / (1 + aa), hpa2 = (1 - aa) / (1 + aa);
    const double A = pow(10, 4.0 / 40), w0b = 2 * PI * 1681.97 / sr, cw = cos(w0b), sa = 2 * sqrt(A) * sin(w0b) / 2 * sqrt(2.0);
    const double a0 = (A + 1) - (A - 1) * cw + sa;
    const double hsb0 = A * ((A + 1) + (A - 1) * cw + sa) / a0, hsb1 = -2 * A * ((A - 1) + (A + 1) * cw) / a0;
    const double hsb2 = A * ((A + 1) + (A - 1) * cw - sa) / a0, hsa1 = 2 * ((A - 1) - (A + 1) * cw) / a0;
    const double hsa2 = ((A + 1) - (A - 1) * cw - sa) / a0;
    // Passa-basso Butterworth del 4° ordine a 20 kHz.
    DBiquad lp1, lp2;
    for (int k = 0; k < 2; k++) {
        DBiquad *f = k ? &lp2 : &lp1;
        double q = k ? 1.3066 : 0.5412, w0 = 2 * PI * 20000 / sr, al = sin(w0) / (2 * q), a0 = 1 + al, c = cos(w0);
        f->b0 = (1 - c) / 2 / a0; f->b1 = (1 - c) / a0; f->b2 = f->b0; f->a1 = -2 * c / a0; f->a2 = (1 - al) / a0;
        f->z1 = f->z2 = 0;
    }
    float l[BLOCK], r[BLOCK];
    double sum = 0;
    long n = 0;
    for (int blk = 0; blk < 1200; blk++) {
        for (int i = 0; i < BLOCK; i++) l[i] = r[i] = pink_next(&pk);
        aeq_process(e, l, r, BLOCK);
        for (int i = 0; i < BLOCK; i++) {
            double x = l[i];
            double y = hpb0 * x + hz1[0]; hz1[0] = hpb1 * x - hpa1 * y + hz2[0]; hz2[0] = hpb2 * x - hpa2 * y;
            double z = hsb0 * y + hz1[1]; hz1[1] = hsb1 * y - hsa1 * z + hz2[1]; hz2[1] = hsb2 * y - hsa2 * z;
            z = dbq(&lp2, dbq(&lp1, z)); // banda udibile: fino a 20 kHz, come la stima
            if (blk > 100) { sum += z * z; n++; }
        }
    }
    return 10 * log10(sum / n);
}

static void test_autogain(void) {
    printf("\n[10] Auto Gain (compensazione di loudness dell'EQ)\n");
    const double sr = 48000;
    AEQEngine *flat = make_engine(sr);
    const double ref = pink_loudness_db(flat, sr);
    aeq_destroy(flat);
    struct { int preset; float bass, treble; const char *label; } cases[] = {
        {1, 0, 0, "electronic"}, {2, 0, 0, "pop"}, {3, 0, 0, "classical"}, {4, 0, 0, "voice"},
        {0, 12, 0, "flat + BASSI +12"}, {0, 0, 12, "flat + ALTI +12"}, {1, 8, 6, "electronic + toni +8/+6"},
    };
    for (size_t c = 0; c < sizeof(cases) / sizeof(cases[0]); c++) {
        float gains[AEQ_NUM_BANDS];
        for (int b = 0; b < AEQ_NUM_BANDS; b++) gains[b] = aeq_preset_gain(cases[c].preset, b);
        const float pre = aeq_preset_preamp(cases[c].preset);
        const float ag = aeq_auto_gain_db(gains, pre, cases[c].bass, cases[c].treble, sr);
        AEQEngine *off = make_engine(sr), *on = make_engine(sr);
        apply_preset(off, cases[c].preset); apply_preset(on, cases[c].preset);
        aeq_set_bass(off, cases[c].bass); aeq_set_bass(on, cases[c].bass);
        aeq_set_treble(off, cases[c].treble); aeq_set_treble(on, cases[c].treble);
        aeq_set_auto_gain(on, ag);
        aeq_prepare(off, sr); aeq_prepare(on, sr);
        const double lOff = pink_loudness_db(off, sr) - ref, lOn = pink_loudness_db(on, sr) - ref;
        const int clamped = ag <= AEQ_AUTOGAIN_MIN_DB + 1e-3f || ag >= AEQ_AUTOGAIN_MAX_DB - 1e-3f;
        printf("  %-24s loudness vs Flat: senza AGC %+6.2f dB, AGC %+6.2f dB -> con AGC %+5.2f dB\n",
               cases[c].label, lOff, ag, lOn);
        if (!clamped) check(fabs(lOn) < 0.5, "AGC: loudness residua %.2f dB (soglia %.1f)", lOn, 0.5);
        aeq_destroy(off); aeq_destroy(on);
    }

    // AGC spento = comportamento originale, campione per campione.
    {
        AEQEngine *a = make_engine(sr), *b = make_engine(sr);
        apply_preset(a, 1); apply_preset(b, 1);
        aeq_set_auto_gain(b, 0.0f);
        aeq_prepare(a, sr); aeq_prepare(b, sr);
        float la[BLOCK], ra[BLOCK], lb[BLOCK], rb[BLOCK];
        double maxDiff = 0;
        for (int blk = 0; blk < 300; blk++) {
            test_signal(la, ra, (long)blk * BLOCK, BLOCK, sr, 1.0);
            memcpy(lb, la, sizeof(la)); memcpy(rb, ra, sizeof(ra));
            aeq_process(a, la, ra, BLOCK);
            aeq_process(b, lb, rb, BLOCK);
            for (int i = 0; i < BLOCK; i++) maxDiff = fmax(maxDiff, fabs(la[i] - lb[i]));
        }
        printf("  AGC spento (0 dB): differenza dal motore senza AGC %.1e\n", maxDiff);
        check(maxDiff == 0.0, "AGC spento altera il suono (%.3g, soglia %.0f)", maxDiff, 0);
        aeq_destroy(a); aeq_destroy(b);
    }
    // Nessuna variazione improvvisa: il guadagno AGC cambia con rampa lenta.
    click_check("AGC -12 <-> +6 dB in riproduzione", ch_autogain, 80);
    {
        // Tempo per raggiungere il 90 % del salto: >= 150 ms (nessun "pompaggio").
        AEQEngine *e = make_engine(sr);
        float l[BLOCK], r[BLOCK];
        double target = pow(10, -12 / 20.0), t90 = -1;
        const int startBlk = 20; // regime raggiunto (anche il ritardo del limiter)
        for (int blk = 0; blk < 300 && t90 < 0; blk++) {
            if (blk == startBlk) aeq_set_auto_gain(e, -12.0f);
            for (int i = 0; i < BLOCK; i++) l[i] = r[i] = 0.5f;
            aeq_process(e, l, r, BLOCK);
            if (blk < startBlk) continue;
            for (int i = 0; i < BLOCK; i++) {
                double g = l[i] / 0.5;
                if (t90 < 0 && g <= 1 - 0.9 * (1 - target)) t90 = (double)((blk - startBlk) * BLOCK + i) / sr;
            }
        }
        printf("  AGC 0 -> -12 dB: 90 %% raggiunto in %.0f ms\n", t90 * 1000);
        check(t90 >= 0.15 && t90 < 1.5, "AGC troppo brusco o troppo lento: %.3f s (min %.2f)", t90, 0.15);
        aeq_destroy(e);
    }
}

static void test_meters(void) {
    printf("\n[11] Indicatori di picco e clipping\n");
    const double sr = 48000;
    struct { const char *label; double amp; int limiter; float boost; } cases[] = {
        {"livello normale (-6 dBFS)", 0.5, 1, 0},
        {"oltre 0 dBFS con limiter", 1.0, 1, 6},
        {"oltre 0 dBFS senza limiter", 1.0, 0, 6},
    };
    for (int c = 0; c < 3; c++) {
        AEQEngine *e = aeq_create(sr);
        aeq_set_limiter_enabled(e, cases[c].limiter);
        aeq_set_preamp(e, cases[c].boost);
        aeq_prepare(e, sr);
        float l[BLOCK], r[BLOCK];
        long idx = 0;
        for (int blk = 0; blk < 100; blk++) {
            for (int i = 0; i < BLOCK; i++, idx++) l[i] = r[i] = (float)(cases[c].amp * sin(2 * PI * 440 * idx / sr));
            aeq_process(e, l, r, BLOCK);
        }
        AEQMeters m;
        aeq_get_meters(e, &m);
        printf("  %-28s picco max %+6.2f dBFS, pre-limiter %+6.2f dBFS, oltre soglia %u, clipping %u\n",
               cases[c].label, 20 * log10(m.peakHold), 20 * log10(m.preLimiterPeakHold), m.overSamples, m.clipSamples);
        if (c == 0) check(m.overSamples == 0 && m.clipSamples == 0 && fabs(20 * log10(m.peakHold) + 6.02) < 0.1,
                          "livello normale segnalato come clipping (%.0f / %.0f)", m.overSamples, m.clipSamples);
        if (c == 1) check(m.overSamples > 0 && m.clipSamples == 0 && m.peakHold <= powf(10, -1.0f / 20) + 1e-4,
                          "limiter: oltre soglia %.0f, clipping %.0f (atteso >0 / 0)", m.overSamples, m.clipSamples);
        if (c == 2) check(m.clipSamples > 0 && m.peakHold > 1.0f, "clipping effettivo non rilevato (%.0f, picco %.3f)",
                          m.clipSamples, m.peakHold);
        aeq_reset_meters(e);
        aeq_get_meters(e, &m);
        if (c == 2) {
            printf("  dopo l'azzeramento: picco %.3f, oltre %u, clipping %u\n", m.peakHold, m.overSamples, m.clipSamples);
            check(m.peakHold == 0 && m.overSamples == 0 && m.clipSamples == 0, "azzeramento non riuscito (%.0f %.0f)", 0, 0);
        }
        aeq_destroy(e);
    }
}

static void test_invalid(void) {
    printf("\n[12] Protezione da valori non validi\n");
    const double sr = 48000;
    AEQEngine *e = make_engine(sr);
    aeq_set_band_gain(e, 3, NAN);
    aeq_set_preamp(e, INFINITY);
    aeq_set_bass(e, NAN);
    aeq_set_treble(e, -INFINITY);
    aeq_set_auto_gain(e, NAN);
    aeq_set_volume(e, NAN);
    aeq_set_input_gain(e, NAN);
    aeq_set_volume(e, 1.0f);
    float l[BLOCK], r[BLOCK];
    long idx = 0;
    int bad = 0;
    double after = 0;
    for (int blk = 0; blk < 300; blk++) {
        for (int i = 0; i < BLOCK; i++, idx++) l[i] = r[i] = (float)(0.3 * sin(2 * PI * 300 * idx / sr));
        if (blk == 100) { l[7] = NAN; r[9] = INFINITY; l[100] = -INFINITY; } // campioni corrotti in ingresso
        aeq_process(e, l, r, BLOCK);
        for (int i = 0; i < BLOCK; i++) {
            if (!isfinite(l[i]) || !isfinite(r[i])) bad++;
            if (blk > 200) after = fmax(after, fabs(l[i]));
        }
    }
    printf("  parametri NaN/Inf e campioni NaN/Inf in ingresso: uscite non valide %d, picco dopo %.3f\n", bad, after);
    check(bad == 0, "uscite non valide: %.0f (%.0f)", bad, 0);
    check(after > 0.1, "il motore non si è ripreso (picco %.3f, soglia %.1f)", after, 0.1);
    aeq_destroy(e);
}

static void test_ab(void) {
    printf("\n[13] Confronto A/B: passaggio tra due configurazioni complete\n");
    click_check("A (Elettronica, toni +6/+3) <-> B (Voce, -4/+2)", ch_ab, 70);
}

static void ch_bass_freq(AEQEngine *e, int blk) {
    if (blk == 0) aeq_set_bass(e, 12.0f);
    if (blk % 100 == 0) aeq_set_bass_frequency(e, (blk / 100) % 2 ? 120.0f : 60.0f);
}
static void ch_treble_freq(AEQEngine *e, int blk) {
    if (blk == 0) aeq_set_treble(e, 12.0f);
    if (blk % 100 == 0) aeq_set_treble_frequency(e, (blk / 100) % 2 ? 12000.0f : 8000.0f);
}

static void test_tone_frequencies(void) {
    printf("\n[14] Frequenza selezionabile per BASSI (60/80/100/120 Hz) e ALTI (8/10/12 kHz)\n");
    const double sr = 48000;
    const double probe[] = {25, 40, 60, 80, 100, 120, 160, 250, 1000, 4000, 6000, 8000, 10000, 12000, 16000, 19000};
    const int np = sizeof(probe) / sizeof(probe[0]);

    // a) Ogni opzione a -12 e +12 dB: misura = curva disegnata (stessa frequenza).
    for (int which = 0; which < 2; which++) {
        const int n = which == 0 ? aeq_bass_frequency_count() : aeq_treble_frequency_count();
        for (int o = 0; o < n; o++) {
            const float hz = which == 0 ? aeq_bass_frequency_option(o) : aeq_treble_frequency_option(o);
            for (int sgn = -1; sgn <= 1; sgn += 2) {
                const float g = 12.0f * sgn;
                double worst = 0, atF = 0;
                for (int k = 0; k < np; k++) {
                    AEQEngine *e = make_engine(sr);
                    if (which == 0) { aeq_set_bass(e, g); aeq_set_bass_frequency(e, hz); }
                    else { aeq_set_treble(e, g); aeq_set_treble_frequency(e, hz); }
                    aeq_prepare(e, sr);
                    double m = measure_gain_db(e, probe[k], sr, 0.02);
                    double shown = which == 0 ? aeq_bass_response_at_db(g, hz, sr, probe[k])
                                              : aeq_treble_response_at_db(g, hz, sr, probe[k]);
                    worst = fmax(worst, fabs(m - shown));
                    if (fabs(probe[k] - hz) < 1) atF = m;
                    aeq_destroy(e);
                }
                printf("  %-5s %6.0f Hz %+5.1f dB: alla frequenza %+6.2f dB (metà ≈ %+.1f), errore max vs curva %.4f dB\n",
                       which == 0 ? "BASSI" : "ALTI", hz, g, atF, g / 2, worst);
                check(worst < 0.05, "frequenza toni: misura diversa dalla curva di %.3f dB (soglia %.2f)", worst, 0.05);
                check(fabs(atF - g / 2) < 0.6, "frequenza toni: alla frequenza %.2f dB invece di ~%.1f", atF, g / 2);
            }
        }
    }

    // b) Valori non previsti portati all'opzione più vicina; NaN -> predefinita.
    {
        const float inB[] = {61, 85, 99, 500, 1, NAN}, expB[] = {60, 80, 100, 120, 60, 80};
        const float inT[] = {7000, 9500, 11500, 20000, NAN}, expT[] = {8000, 10000, 12000, 12000, 10000};
        int ok = 1;
        AEQEngine *e = aeq_create(sr);
        for (int i = 0; i < 6; i++) { aeq_set_bass_frequency(e, inB[i]); if (aeq_get_bass_frequency_target(e) != expB[i]) ok = 0; }
        for (int i = 0; i < 5; i++) { aeq_set_treble_frequency(e, inT[i]); if (aeq_get_treble_frequency_target(e) != expT[i]) ok = 0; }
        printf("  frequenze non previste -> opzione più vicina, NaN -> predefinita: %s\n", ok ? "OK" : "ERRATO");
        check(ok, "aggancio delle frequenze errato (%.0f %.0f)", 0, 0);
        aeq_destroy(e);
    }

    // c) Indipendenza: la frequenza non cambia il guadagno; con guadagno 0 cambiare frequenza
    //    non altera il suono (uscita identica campione per campione).
    {
        AEQEngine *e = aeq_create(sr);
        aeq_set_bass(e, 7.5f); aeq_set_treble(e, -4.5f);
        aeq_set_bass_frequency(e, 120); aeq_set_treble_frequency(e, 8000);
        int same = aeq_get_bass_target(e) == 7.5f && aeq_get_treble_target(e) == -4.5f;
        aeq_destroy(e);
        AEQEngine *a = make_engine(sr), *b = make_engine(sr);
        apply_preset(a, 2); apply_preset(b, 2);
        aeq_prepare(a, sr); aeq_prepare(b, sr);
        float la[BLOCK], ra[BLOCK], lb[BLOCK], rb[BLOCK];
        double maxDiff = 0;
        for (int blk = 0; blk < 300; blk++) {
            if (blk == 50) { aeq_set_bass_frequency(b, 60); aeq_set_treble_frequency(b, 12000); }
            if (blk == 150) { aeq_set_bass_frequency(b, 120); aeq_set_treble_frequency(b, 8000); }
            test_signal(la, ra, (long)blk * BLOCK, BLOCK, sr, 1.0);
            memcpy(lb, la, sizeof(la)); memcpy(rb, ra, sizeof(ra));
            aeq_process(a, la, ra, BLOCK);
            aeq_process(b, lb, rb, BLOCK);
            for (int i = 0; i < BLOCK; i++) maxDiff = fmax(maxDiff, fabs(la[i] - lb[i]));
        }
        printf("  la frequenza non cambia il guadagno: %s; con BASSI/ALTI a 0, cambiare frequenza: differenza %.1e\n",
               same ? "sì" : "NO", maxDiff);
        check(same, "il cambio di frequenza ha alterato il guadagno (%.0f %.0f)", 0, 0);
        check(maxDiff == 0.0, "con guadagno 0 il cambio di frequenza altera il suono (%.3g, soglia %.0f)", maxDiff, 0);
        aeq_destroy(a); aeq_destroy(b);
    }

    // d) Cambio di frequenza durante l'ascolto, con il controllo a +12 dB: nessun click.
    click_check("BASSI +12, frequenza 60 <-> 120 Hz (70 Hz)", ch_bass_freq, 70);
    click_check("ALTI +12, frequenza 8 <-> 12 kHz (200 Hz)", ch_treble_freq, 200);

    // e) Auto Gain con frequenze non predefinite: loudness pari a Flat.
    {
        AEQEngine *flat = make_engine(sr);
        const double ref = pink_loudness_db(flat, sr);
        aeq_destroy(flat);
        struct { float b, bhz, t, thz; } cs[] = {{12, 120, 0, 10000}, {12, 60, 0, 10000}, {0, 80, 12, 8000}, {6, 100, 9, 12000}};
        for (int c = 0; c < 4; c++) {
            float gains[AEQ_NUM_BANDS] = {0};
            float ag = aeq_auto_gain_full_db(gains, 0, cs[c].b, cs[c].bhz, cs[c].t, cs[c].thz, sr);
            AEQEngine *e = make_engine(sr);
            aeq_set_bass(e, cs[c].b); aeq_set_bass_frequency(e, cs[c].bhz);
            aeq_set_treble(e, cs[c].t); aeq_set_treble_frequency(e, cs[c].thz);
            aeq_set_auto_gain(e, ag);
            aeq_prepare(e, sr);
            double l = pink_loudness_db(e, sr) - ref;
            printf("  Auto Gain, BASSI %+.0f @ %.0f Hz / ALTI %+.0f @ %.0f Hz: AGC %+.2f dB -> loudness vs Flat %+.2f dB\n",
                   cs[c].b, cs[c].bhz, cs[c].t, cs[c].thz, ag, l);
            check(fabs(l) < 0.5, "AGC con frequenze toni: loudness residua %.2f dB (soglia %.1f)", l, 0.5);
            aeq_destroy(e);
        }
    }
}


// [15] Tasti volume. Simulazione del percorso completo a livello di campione:
//   BlackHole (guadagno g applicato a gradino all'ingresso) -> compensazione 1/g (in ritardo come il
//   listener: 0-25 ms) -> DSP (volume con rampa) -> volume hardware dell'uscita.
// Prima: ogni tacca = gradino di 4 dB in BlackHole + compensazione in ritardo + gradino hardware.
// Ora: il volume è applicato dal DSP; BlackHole si muove solo a micro-passi di 0,005 dB; hardware fisso.
static double bh_gain(double scalar) { return scalar <= 0 ? 0 : pow(10, -64.0 * (1 - scalar) / 20); }

// La compensazione legge sempre il valore ATTUALE di BlackHole (come il listener), ma i campioni
// con il nuovo guadagno arrivano al DSP con un ritardo diverso e ignoto: si simulano i due ritardi
// (blocchi da 1,5 ms) inDelay (BlackHole -> campioni) e compDelay (BlackHole -> compensazione).
static double volume_key_sim(int newDesign, int fastRepeat, int inDelay, int compDelay,
                             double *levelErrDb, double *mutedPeakDb) {
    const double sr = 48000, amp = 0.2, f = 200;
    enum { B = 72, H = 64 };
    AEQEngine *e = make_engine(sr);
    DBiquad h1, h2;
    dhp_init(&h1, 2500, 0.5412, sr);
    dhp_init(&h2, 2500, 1.3066, sr);
    float l[B], r[B];
    double hist[H];
    int hmuted[H];
    double user = 0.75, bhScalar = 0.75, bhTarget = 0.75, hw = newDesign ? 1.0 : 0.75;
    for (int k = 0; k < H; k++) { hist[k] = bhScalar; hmuted[k] = 0; }
    const double microStep = 0.005 / 64.0;
    int muted = 0, bhMuted = 0;
    long muteAt = -1, unmuteAt = -1, blk = 0;
    aeq_set_volume(e, newDesign ? (float)bh_gain(user) : 1.0f);
    aeq_set_input_gain(e, (float)(1 / bh_gain(bhScalar)));
    aeq_prepare(e, sr);
    double residue = 0, mutedPeak = 0;
    static double env[240];
    int envPos = 0;
    for (int k = 0; k < 240; k++) env[k] = amp * bh_gain(user);
    long idx = 0;
    const long total = (long)(sr * (fastRepeat ? 3.0 : 13.5));
    const long press = (long)(sr * (fastRepeat ? 0.03 : 0.25));
    int presses = 0;
    long microSteps = 0;
    long lastPress = -press * 4, hwAt = -1;
    double pendingHw = -1;
    while (idx < total) {
        // Tasto volume: 8 tacche giù e 8 su (passo 1/16), poi (design nuovo) muto e ripristino.
        // Poi (design nuovo, non rapido) 4 tacche giù a 1,5 s l'una dall'altra: tra una e l'altra
        // l'indicatore di macOS si allinea a micro-passi mentre il tono suona.
        const int maxPresses = (newDesign && !fastRepeat) ? 20 : 16;
        const long gap = presses >= 16 ? (long)(1.5 * sr) : press;
        if (idx >= (long)(0.3 * sr) && idx - lastPress >= gap && presses < maxPresses) {
            lastPress = idx;
            user += (presses < 8 || presses >= 16 ? -1.0 : 1.0) / 16;
            presses++;
            if (newDesign) {
                aeq_set_volume(e, (float)bh_gain(user)); // rampa del DSP
                bhTarget = user;                          // indicatore di macOS a micro-passi
            } else {
                bhScalar = bhTarget = user;               // macOS cambia BlackHole a gradino
                pendingHw = user; hwAt = idx + (long)(0.03 * sr); // copia sul volume hardware
            }
        }
        if (newDesign && !fastRepeat && presses == 20 && muteAt < 0 && idx - lastPress > (long)(1.5 * sr)) {
            muted = 1; muteAt = idx; aeq_set_volume(e, 0);        // muto: rampa verso 0…
        }
        if (muteAt >= 0 && muted && !bhMuted && idx - muteAt >= (long)(0.5 * sr)) bhMuted = 1; // …poi BlackHole
        if (muted && muteAt >= 0 && unmuteAt < 0 && idx - muteAt >= (long)(0.8 * sr)) {
            muted = 0; unmuteAt = idx; bhMuted = 0;              // sblocco: prima BlackHole…
        }
        if (unmuteAt >= 0 && idx - unmuteAt >= (long)(0.12 * sr) && idx - unmuteAt < (long)(0.12 * sr) + B)
            aeq_set_volume(e, (float)bh_gain(user));             // …poi la rampa
        // Micro-passi dell'indicatore di macOS: partono 0,3 s dopo l'ultimo tasto (rampa conclusa).
        if (newDesign && idx - lastPress > (long)(0.3 * sr) && fabs(bhTarget - bhScalar) > 1e-12) {
            double d = bhTarget - bhScalar;
            bhScalar += fabs(d) < microStep ? d : (d > 0 ? microStep : -microStep);
            microSteps++;
        }
        hist[blk % H] = bhScalar;
        hmuted[blk % H] = bhMuted;
        const int ci = (int)((blk - compDelay + H * 4) % H), ii = (int)((blk - inDelay + H * 4) % H);
        const double gc = hmuted[ci] ? 0 : bh_gain(hist[ci]);
        aeq_set_input_gain(e, (float)(gc > 1e-6 ? 1 / gc : 1));
        if (hwAt >= 0 && idx >= hwAt) { hw = pendingHw; hwAt = -1; }
        const double g = hmuted[ii] ? 0 : bh_gain(hist[ii]);
        const double hwGain = newDesign ? 1.0 : bh_gain(hw);
        for (int i = 0; i < B; i++) l[i] = r[i] = (float)(g * amp * sin(2 * PI * f * (idx + i) / sr));
        aeq_process(e, l, r, B);
        // Riferimento: livello effettivo del tono in uscita (picco sull'ultimo periodo, 240 campioni),
        // così una rampa lenta non viene confusa con un click. Durante il muto e la ripresa: livello pieno.
        for (int i = 0; i < B; i++) {
            const double y = l[i] * hwGain;
            const double hp = dbq(&h2, dbq(&h1, y));
            env[envPos] = fabs(y);
            envPos = (envPos + 1) % 240;
            double pk = 0;
            for (int k = 0; k < 240; k++) pk = fmax(pk, env[k]);
            if (idx > (long)(0.1 * sr)) {
                if (muteAt >= 0 && (muted || (unmuteAt >= 0 && idx - unmuteAt < (long)(0.8 * sr))))
                    residue = fmax(residue, fabs(hp) / (amp * bh_gain(user))); // rispetto al livello pieno
                else
                    residue = fmax(residue, fabs(hp) / fmax(pk, 1e-9));
            }
            if (muted && idx - muteAt > (long)(0.6 * sr)) mutedPeak = fmax(mutedPeak, fabs(y));
        }
        idx += B;
        blk++;
    }
    // Livello finale (a micro-passi conclusi): deve corrispondere alla curva del volume.
    if (levelErrDb) {
        bhScalar = bhTarget;
        aeq_set_input_gain(e, (float)(1 / bh_gain(bhScalar)));
        for (int k = 0; k < 200; k++) {
            for (int i = 0; i < B; i++) l[i] = r[i] = (float)(bh_gain(bhScalar) * amp * sin(2 * PI * f * (idx + i) / sr));
            aeq_process(e, l, r, B);
            idx += B;
        }
        static float buf[4800], rr[4800];
        for (int i = 0; i < 4800; i++) buf[i] = rr[i] = (float)(bh_gain(bhScalar) * amp * sin(2 * PI * f * (idx + i) / sr));
        aeq_process(e, buf, rr, 4800);
        *levelErrDb = 20 * log10(amplitude(buf, 4800, f, sr) / (amp * bh_gain(user)));
    }
    if (mutedPeakDb) *mutedPeakDb = 20 * log10(fmax(mutedPeak, 1e-12) / amp);
    if (newDesign && !fastRepeat) printf("    (micro-passi dell'indicatore di macOS durante la riproduzione: %ld)\n", microSteps);
    aeq_destroy(e);
    return 20 * log10(fmax(residue, 1e-12));
}

static void test_volume_keys(void) {
    printf("\n[15] Tasti volume: variazioni ripetute senza discontinuità\n");
    // Ritardi (blocchi da 1,5 ms): compensazione in ritardo di 21 ms, in anticipo di 21 ms, simultanea.
    const int delays[3][2] = {{0, 14}, {14, 0}, {7, 7}};
    const char *names[3] = {"compensazione in ritardo", "compensazione in anticipo", "simultanee"};
    for (int k = 0; k < 2; k++) {
        double before = volume_key_sim(0, 0, delays[k][0], delays[k][1], NULL, NULL);
        printf("  percorso precedente, %s: residuo %.1f dB\n", names[k], before);
        check(before > -40.0, "il test riproduce il click del percorso precedente: residuo %.1f dB (atteso > %.0f)", before, -40.0);
    }
    for (int k = 0; k < 3; k++) {
        double err = 0, mutedPk = 0;
        double after = volume_key_sim(1, 0, delays[k][0], delays[k][1], &err, &mutedPk);
        printf("  nuovo percorso, %s, 16 tacche + muto/ripristino: residuo %.1f dB, livello finale %+.3f dB, picco a muto %.1f dB\n",
               names[k], after, err, mutedPk);
        check(after < -60.0, "click con i tasti volume: residuo %.1f dB (soglia %.0f dB)", after, -60.0);
        check(fabs(err) < 0.05, "livello finale diverso dalla curva del volume: %.3f dB (%.2f)", err, 0.05);
        check(mutedPk < -100.0, "muto non silenzioso: %.1f dB (soglia %.0f dB)", mutedPk, -100.0);
        double fast = volume_key_sim(1, 1, delays[k][0], delays[k][1], &err, NULL);
        printf("  nuovo percorso, %s, una tacca ogni 30 ms: residuo %.1f dB, livello finale %+.3f dB\n", names[k], fast, err);
        check(fast < -60.0, "click con ripetizione rapida: residuo %.1f dB (soglia %.0f dB)", fast, -60.0);
        check(fabs(err) < 0.05, "livello finale (ripetizione rapida): %.3f dB (%.2f)", err, 0.05);
    }
}

int main(void) {
    printf("ArmoniaDSP – test numerici\n");
    test_single_band_values(48000);
    test_single_band_values(44100);
    test_presets(48000);
    test_presets(44100);
    test_bypass();
    test_volume_balance();
    test_smooth_switch();
    test_limiter();
    test_performance();
    test_flat_levels();
    test_tone();
    test_autogain();
    test_meters();
    test_invalid();
    test_ab();
    test_tone_frequencies();
    test_volume_keys();
    printf("\n%d verifiche, %d fallite\n", checks, failures);
    return failures ? 1 : 0;
}
