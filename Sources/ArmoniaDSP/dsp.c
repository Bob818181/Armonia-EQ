#include "ArmoniaDSP.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#ifndef AEQ_SUBBLOCK
#define AEQ_SUBBLOCK 32
#endif
// Smoothing dei parametri a due stadi (secondo ordine, smorzamento critico): la variazione parte
// con pendenza nulla, quindi senza "spigoli" udibili. Tempo totale ~ 2 x costante di stadio.
#define AEQ_SMOOTH_SECONDS 0.015
// Volume e bilanciamento: rampa più lenta (~150 ms al 95 %), come un controllo volume hardware.
// Con 15 ms una tacca dei tasti volume (4 dB) lasciava un residuo a banda larga di -58 dB; con
// 40 ms resta sotto -70 dB (test [15]).
#define AEQ_VOLUME_SMOOTH_SECONDS 0.04
#define AEQ_AUTOGAIN_SMOOTH_SECONDS 0.125
#define AEQ_LIMITER_LOOKAHEAD_SECONDS 0.0015
#define AEQ_LIMITER_RELEASE_SECONDS 0.080
#define AEQ_MAX_LOOKAHEAD 192
#define AEQ_PI 3.14159265358979323846

static const float kBandFrequencies[AEQ_NUM_BANDS] = {
    32.0f, 64.0f, 125.0f, 250.0f, 500.0f, 1000.0f, 2000.0f, 4000.0f, 8000.0f, 16000.0f
};
static const float kBandQ = 1.41421356f; // ~1 ottava

typedef struct {
    float b0, b1, b2, a1, a2;
} Coefficients;

typedef struct {
    float z1[2];
    float z2[2];
} BiquadState;

// Filtro a variabili di stato, forma "linear trapezoidal" di A. Simper (Cytomic). Stessa risposta
// in frequenza del biquad RBJ (stesso prototipo analogico, stessa trasformata bilineare con
// pre-warping), ma gli stati sono quelli degli integratori: variare i coefficienti durante
// l'ascolto non produce discontinuità ("zipper noise"/click).
typedef struct {
    float a1, a2, a3;   // integratori
    float m0, m1, m2;   // miscelazione: y = m0*x + m1*v1 + m2*v2
} SvfCoef;

typedef struct {
    float ic1[2];
    float ic2[2];
} SvfState;

struct AEQEngine {
    double sampleRate;

    // Destinazioni scritte dal thread UI
    _Atomic float targetGainDb[AEQ_NUM_BANDS];
    _Atomic float targetPreampDb;
    _Atomic float targetVolume;
    _Atomic float targetBalance;
    _Atomic int eqEnabled;
    _Atomic int limiterEnabled;
    _Atomic float limiterCeilingDb;
    _Atomic float inputGain;
    _Atomic float targetBassDb;
    _Atomic float targetTrebleDb;
    _Atomic float targetBassHz;
    _Atomic float targetTrebleHz;
    _Atomic float targetAutoGainDb;

    // Stato del thread audio
    float currentGainDb[AEQ_NUM_BANDS];
    float midGainDb[AEQ_NUM_BANDS];      // stadio intermedio dello smoothing
    float midBassDb, midTrebleDb, midPreamp, midGainL, midGainR, midAutoGain;
    float curBassLog2, midBassLog2, curTrebleLog2, midTrebleLog2; // frequenze in log2(Hz)
    SvfCoef coeffs[AEQ_NUM_BANDS];
    SvfState state[AEQ_NUM_BANDS];
    float currentBassDb;
    SvfCoef bassCoeffs;
    SvfState bassState;
    float currentTrebleDb;
    SvfCoef trebleCoeffs;
    SvfState trebleState;
    float currentAutoGain;   // lineare
    float autoGainAlpha;
    float currentPreamp;   // lineare
    float currentGainL;    // volume * bilanciamento (lineare)
    float currentGainR;
    float smoothAlpha;
    float volumeAlpha;

    // Limiter look-ahead
    int lookahead;               // D campioni
    float delayL[AEQ_MAX_LOOKAHEAD + 1];
    float delayR[AEQ_MAX_LOOKAHEAD + 1];
    float holdWindow[AEQ_MAX_LOOKAHEAD + 2]; // lunghezza W+1 (W = ritardo)
    float avgWindow[AEQ_MAX_LOOKAHEAD + 1];  // lunghezza W
    int windowPos;
    int holdPos;
    float holdMin;  // minimo corrente della finestra di hold
    int holdAge;    // campioni trascorsi da quando holdMin è entrato nella finestra
    double avgSum;
    float envelope;
    float releaseCoef;

    // Misure
    _Atomic float peak[2];
    _Atomic float inputPeak;
    _Atomic float minLimiterGain;
    _Atomic float peakHold;
    _Atomic float preLimiterPeakHold;
    _Atomic uint32_t overSamples;
    _Atomic uint32_t clipSamples;
    _Atomic uint64_t framesProcessed;

    // Buffer per l'analizzatore
    float analysis[AEQ_ANALYSIS_SIZE];
    _Atomic uint32_t analysisWrite;
};

float aeq_band_frequency(int band) {
    if (band < 0 || band >= AEQ_NUM_BANDS) return 0.0f;
    return kBandFrequencies[band];
}

float aeq_band_q(void) { return kBandQ; }

static float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }
/// Valore non finito (NaN, ±Inf) -> fallback, poi limitazione.
static float sanitize(float v, float lo, float hi, float fallback) {
    if (!isfinite(v)) v = fallback;
    return clampf(v, lo, hi);
}
static float db_to_lin(float db) { return powf(10.0f, db / 20.0f); }

// Filtro peaking (RBJ Audio EQ Cookbook). Usato sia per l'elaborazione che per la curva mostrata.
static Coefficients peaking(double sampleRate, double freq, double q, double gainDb) {
    Coefficients c = {1.0f, 0.0f, 0.0f, 0.0f, 0.0f};
    if (sampleRate <= 0.0 || freq >= sampleRate * 0.49 || fabs(gainDb) < 1e-6) return c;
    double A = pow(10.0, gainDb / 40.0);
    double w0 = 2.0 * AEQ_PI * freq / sampleRate;
    double cw = cos(w0), sw = sin(w0);
    double alpha = sw / (2.0 * q);
    double a0 = 1.0 + alpha / A;
    c.b0 = (float)((1.0 + alpha * A) / a0);
    c.b1 = (float)((-2.0 * cw) / a0);
    c.b2 = (float)((1.0 - alpha * A) / a0);
    c.a1 = (float)((-2.0 * cw) / a0);
    c.a2 = (float)((1.0 - alpha / A) / a0);
    return c;
}

// Shelving basso (RBJ Audio EQ Cookbook, pendenza S = 1).
static Coefficients low_shelf(double sampleRate, double freq, double gainDb) {
    Coefficients c = {1.0f, 0.0f, 0.0f, 0.0f, 0.0f};
    if (sampleRate <= 0.0 || freq >= sampleRate * 0.49 || fabs(gainDb) < 1e-6) return c;
    double A = pow(10.0, gainDb / 40.0);
    double w0 = 2.0 * AEQ_PI * freq / sampleRate;
    double cw = cos(w0), sw = sin(w0);
    double alpha = sw / 2.0 * sqrt(2.0); // pendenza S = 1: sqrt((A + 1/A)(1/S - 1) + 2) = sqrt(2)
    double sa = 2.0 * sqrt(A) * alpha;
    double a0 = (A + 1.0) + (A - 1.0) * cw + sa;
    c.b0 = (float)(A * ((A + 1.0) - (A - 1.0) * cw + sa) / a0);
    c.b1 = (float)(2.0 * A * ((A - 1.0) - (A + 1.0) * cw) / a0);
    c.b2 = (float)(A * ((A + 1.0) - (A - 1.0) * cw - sa) / a0);
    c.a1 = (float)(-2.0 * ((A - 1.0) + (A + 1.0) * cw) / a0);
    c.a2 = (float)(((A + 1.0) + (A - 1.0) * cw - sa) / a0);
    return c;
}

// Shelving alto (RBJ Audio EQ Cookbook, pendenza S = 1).
static Coefficients high_shelf(double sampleRate, double freq, double gainDb) {
    Coefficients c = {1.0f, 0.0f, 0.0f, 0.0f, 0.0f};
    if (sampleRate <= 0.0 || freq >= sampleRate * 0.49 || fabs(gainDb) < 1e-6) return c;
    double A = pow(10.0, gainDb / 40.0);
    double w0 = 2.0 * AEQ_PI * freq / sampleRate;
    double cw = cos(w0), sw = sin(w0);
    double alpha = sw / 2.0 * sqrt(2.0);
    double sa = 2.0 * sqrt(A) * alpha;
    double a0 = (A + 1.0) - (A - 1.0) * cw + sa;
    c.b0 = (float)(A * ((A + 1.0) + (A - 1.0) * cw + sa) / a0);
    c.b1 = (float)(-2.0 * A * ((A - 1.0) + (A + 1.0) * cw) / a0);
    c.b2 = (float)(A * ((A + 1.0) + (A - 1.0) * cw - sa) / a0);
    c.a1 = (float)(2.0 * ((A - 1.0) - (A + 1.0) * cw) / a0);
    c.a2 = (float)(((A + 1.0) - (A - 1.0) * cw - sa) / a0);
    return c;
}

// Passa-alto del secondo ordine (solo per la pesatura K della loudness, non per l'audio).
static Coefficients high_pass(double sampleRate, double freq, double q) {
    Coefficients c = {1.0f, 0.0f, 0.0f, 0.0f, 0.0f};
    double w0 = 2.0 * AEQ_PI * freq / sampleRate;
    double cw = cos(w0), sw = sin(w0);
    double alpha = sw / (2.0 * q);
    double a0 = 1.0 + alpha;
    c.b0 = (float)(((1.0 + cw) / 2.0) / a0);
    c.b1 = (float)(-(1.0 + cw) / a0);
    c.b2 = (float)(((1.0 + cw) / 2.0) / a0);
    c.a1 = (float)((-2.0 * cw) / a0);
    c.a2 = (float)((1.0 - alpha) / a0);
    return c;
}

static float quantize_tone(float db) {
    if (!isfinite(db)) db = 0.0f;
    db = clampf(db, AEQ_TONE_MIN_DB, AEQ_TONE_MAX_DB);
    return roundf(db / AEQ_TONE_STEP_DB) * AEQ_TONE_STEP_DB;
}

static void svf_integrators(SvfCoef *c, double g, double k) {
    double a1 = 1.0 / (1.0 + g * (g + k));
    c->a1 = (float)a1;
    c->a2 = (float)(g * a1);
    c->a3 = (float)(g * g * a1);
}

static double svf_g(double sampleRate, double freq) {
    double f = freq < sampleRate * 0.49 ? freq : sampleRate * 0.49;
    return tan(AEQ_PI * f / sampleRate);
}

/// Campana (peaking) con lo stesso Q del biquad RBJ.
static SvfCoef svf_bell(double sampleRate, double freq, double q, double gainDb) {
    SvfCoef c;
    double A = pow(10.0, gainDb / 40.0);
    double k = 1.0 / (q * A);
    svf_integrators(&c, svf_g(sampleRate, freq), k);
    c.m0 = 1.0f;
    c.m1 = (float)(k * (A * A - 1.0));
    c.m2 = 0.0f;
    if (freq >= sampleRate * 0.49) { c.m1 = 0.0f; }
    return c;
}

/// Shelving basso, Q = 1/sqrt(2) (pendenza S = 1 come il biquad RBJ).
static SvfCoef svf_low_shelf(double sampleRate, double freq, double gainDb) {
    SvfCoef c;
    double A = pow(10.0, gainDb / 40.0);
    double k = sqrt(2.0);
    svf_integrators(&c, svf_g(sampleRate, freq) / sqrt(A), k);
    c.m0 = 1.0f;
    c.m1 = (float)(k * (A - 1.0));
    c.m2 = (float)(A * A - 1.0);
    return c;
}

/// Shelving alto, Q = 1/sqrt(2).
static SvfCoef svf_high_shelf(double sampleRate, double freq, double gainDb) {
    SvfCoef c;
    double A = pow(10.0, gainDb / 40.0);
    double k = sqrt(2.0);
    svf_integrators(&c, svf_g(sampleRate, freq) * sqrt(A), k);
    c.m0 = (float)(A * A);
    c.m1 = (float)(k * (1.0 - A) * A);
    c.m2 = (float)(1.0 - A * A);
    if (freq >= sampleRate * 0.49) { c.m0 = 1.0f; c.m1 = 0.0f; c.m2 = 0.0f; }
    return c;
}

static const float kBassOptions[] = {60.0f, 80.0f, 100.0f, 120.0f};
static const float kTrebleOptions[] = {8000.0f, 10000.0f, 12000.0f};
#define AEQ_COUNT(a) ((int)(sizeof(a) / sizeof((a)[0])))

static float snap_option(float hz, const float *opts, int n, float fallback) {
    if (!isfinite(hz) || hz <= 0.0f) return fallback;
    float best = opts[0];
    float bestDist = fabsf(log2f(hz / opts[0]));
    for (int i = 1; i < n; i++) {
        float d = fabsf(log2f(hz / opts[i]));
        if (d < bestDist) { bestDist = d; best = opts[i]; }
    }
    return best;
}

int aeq_bass_frequency_count(void) { return AEQ_COUNT(kBassOptions); }
float aeq_bass_frequency_option(int i) { return (i >= 0 && i < AEQ_COUNT(kBassOptions)) ? kBassOptions[i] : AEQ_BASS_FREQUENCY; }
int aeq_treble_frequency_count(void) { return AEQ_COUNT(kTrebleOptions); }
float aeq_treble_frequency_option(int i) { return (i >= 0 && i < AEQ_COUNT(kTrebleOptions)) ? kTrebleOptions[i] : AEQ_TREBLE_FREQUENCY; }
float aeq_snap_bass_frequency(float hz) { return snap_option(hz, kBassOptions, AEQ_COUNT(kBassOptions), AEQ_BASS_FREQUENCY); }
float aeq_snap_treble_frequency(float hz) { return snap_option(hz, kTrebleOptions, AEQ_COUNT(kTrebleOptions), AEQ_TREBLE_FREQUENCY); }

static double magnitude_db(const Coefficients *c, double sampleRate, double freq) {
    double w = 2.0 * AEQ_PI * freq / sampleRate;
    double cw = cos(w), sw = sin(w), c2 = cos(2.0 * w), s2 = sin(2.0 * w);
    double nr = c->b0 + c->b1 * cw + c->b2 * c2;
    double ni = -(c->b1 * sw + c->b2 * s2);
    double dr = 1.0 + c->a1 * cw + c->a2 * c2;
    double di = -(c->a1 * sw + c->a2 * s2);
    double num = nr * nr + ni * ni;
    double den = dr * dr + di * di;
    if (den <= 0.0 || num <= 0.0) return -200.0;
    return 10.0 * log10(num / den);
}

double aeq_response_db(const float *gainsDb, float preampDb, double sampleRate, double frequency) {
    double total = preampDb;
    for (int b = 0; b < AEQ_NUM_BANDS; b++) {
        float g = clampf(gainsDb[b], AEQ_GAIN_MIN_DB, AEQ_GAIN_MAX_DB);
        Coefficients c = peaking(sampleRate, kBandFrequencies[b], kBandQ, g);
        total += magnitude_db(&c, sampleRate, frequency);
    }
    return total;
}

double aeq_bass_response_at_db(float bassDb, float bassHz, double sampleRate, double frequency) {
    Coefficients c = low_shelf(sampleRate, aeq_snap_bass_frequency(bassHz), quantize_tone(bassDb));
    return magnitude_db(&c, sampleRate, frequency);
}

double aeq_treble_response_at_db(float trebleDb, float trebleHz, double sampleRate, double frequency) {
    Coefficients c = high_shelf(sampleRate, aeq_snap_treble_frequency(trebleHz), quantize_tone(trebleDb));
    return magnitude_db(&c, sampleRate, frequency);
}

double aeq_bass_response_db(float bassDb, double sampleRate, double frequency) {
    return aeq_bass_response_at_db(bassDb, AEQ_BASS_FREQUENCY, sampleRate, frequency);
}

double aeq_treble_response_db(float trebleDb, double sampleRate, double frequency) {
    return aeq_treble_response_at_db(trebleDb, AEQ_TREBLE_FREQUENCY, sampleRate, frequency);
}

double aeq_response_full_db(const float *gainsDb, float preampDb, float bassDb, float bassHz,
                            float trebleDb, float trebleHz, double sampleRate, double frequency) {
    return aeq_response_db(gainsDb, preampDb, sampleRate, frequency)
         + aeq_bass_response_at_db(bassDb, bassHz, sampleRate, frequency)
         + aeq_treble_response_at_db(trebleDb, trebleHz, sampleRate, frequency);
}

double aeq_response_total_db(const float *gainsDb, float preampDb, float bassDb, float trebleDb,
                             double sampleRate, double frequency) {
    return aeq_response_full_db(gainsDb, preampDb, bassDb, AEQ_BASS_FREQUENCY, trebleDb, AEQ_TREBLE_FREQUENCY,
                                sampleRate, frequency);
}

double aeq_loudness_change_full_db(const float *gainsDb, float preampDb, float bassDb, float bassHz,
                                   float trebleDb, float trebleHz, double sampleRate) {
    if (sampleRate < 8000.0) sampleRate = 48000.0;
    // Pesatura K (ITU-R BS.1770): passa-alto ~38 Hz + shelving alto +4 dB ~1,68 kHz.
    Coefficients hp = high_pass(sampleRate, 38.135, 0.5003);
    Coefficients hs = high_shelf(sampleRate, 1681.97, 4.0);
    double num = 0.0, den = 0.0;
    // Spettro rosa: punti equispaziati in scala logaritmica (1/24 di ottava), 20 Hz - 20 kHz.
    const double fmax = fmin(20000.0, sampleRate * 0.45);
    for (double f = 20.0; f <= fmax; f *= 1.0293022366) {
        double w = pow(10.0, (magnitude_db(&hp, sampleRate, f) + magnitude_db(&hs, sampleRate, f)) / 10.0);
        double h = aeq_response_full_db(gainsDb, preampDb, bassDb, bassHz, trebleDb, trebleHz, sampleRate, f);
        num += w * pow(10.0, h / 10.0);
        den += w;
    }
    return den > 0.0 ? 10.0 * log10(num / den) : 0.0;
}

double aeq_loudness_change_db(const float *gainsDb, float preampDb, float bassDb, float trebleDb, double sampleRate) {
    return aeq_loudness_change_full_db(gainsDb, preampDb, bassDb, AEQ_BASS_FREQUENCY, trebleDb, AEQ_TREBLE_FREQUENCY, sampleRate);
}

float aeq_auto_gain_full_db(const float *gainsDb, float preampDb, float bassDb, float bassHz,
                            float trebleDb, float trebleHz, double sampleRate) {
    double g = -aeq_loudness_change_full_db(gainsDb, preampDb, bassDb, bassHz, trebleDb, trebleHz, sampleRate);
    if (!isfinite(g)) g = 0.0;
    return clampf((float)g, AEQ_AUTOGAIN_MIN_DB, AEQ_AUTOGAIN_MAX_DB);
}

float aeq_auto_gain_db(const float *gainsDb, float preampDb, float bassDb, float trebleDb, double sampleRate) {
    return aeq_auto_gain_full_db(gainsDb, preampDb, bassDb, AEQ_BASS_FREQUENCY, trebleDb, AEQ_TREBLE_FREQUENCY, sampleRate);
}

static void compute_balance_gains(float volume, float balance, float *gl, float *gr) {
    volume = clampf(volume, 0.0f, 1.0f);
    balance = clampf(balance, -1.0f, 1.0f);
    *gl = volume * (balance > 0.0f ? 1.0f - balance : 1.0f);
    *gr = volume * (balance < 0.0f ? 1.0f + balance : 1.0f);
}

static void reset_limiter(AEQEngine *e) {
    memset(e->delayL, 0, sizeof(e->delayL));
    memset(e->delayR, 0, sizeof(e->delayR));
    for (int i = 0; i <= AEQ_MAX_LOOKAHEAD + 1; i++) e->holdWindow[i] = 1.0f;
    for (int i = 0; i <= AEQ_MAX_LOOKAHEAD; i++) e->avgWindow[i] = 1.0f;
    e->windowPos = 0;
    e->holdPos = 0;
    e->holdMin = 1.0f;
    e->holdAge = 0;
    e->avgSum = (double)(e->lookahead + 1);
    e->envelope = 1.0f;
}

AEQEngine *aeq_create(double sampleRate) {
    AEQEngine *e = (AEQEngine *)calloc(1, sizeof(AEQEngine));
    if (!e) return NULL;
    for (int b = 0; b < AEQ_NUM_BANDS; b++) atomic_store(&e->targetGainDb[b], 0.0f);
    atomic_store(&e->targetPreampDb, 0.0f);
    atomic_store(&e->targetVolume, 1.0f);
    atomic_store(&e->targetBalance, 0.0f);
    atomic_store(&e->eqEnabled, 1);
    atomic_store(&e->limiterEnabled, 1);
    atomic_store(&e->limiterCeilingDb, -1.0f);
    atomic_store(&e->inputGain, 1.0f);
    atomic_store(&e->targetBassHz, AEQ_BASS_FREQUENCY);
    atomic_store(&e->targetTrebleHz, AEQ_TREBLE_FREQUENCY);
    atomic_store(&e->minLimiterGain, 1.0f);
    aeq_prepare(e, sampleRate);
    return e;
}

void aeq_destroy(AEQEngine *e) { free(e); }

void aeq_prepare(AEQEngine *e, double sampleRate) {
    if (!e) return;
    if (sampleRate < 8000.0) sampleRate = 48000.0;
    e->sampleRate = sampleRate;
    e->smoothAlpha = (float)(1.0 - exp(-(double)AEQ_SUBBLOCK / (AEQ_SMOOTH_SECONDS * sampleRate)));
    // Volume: smoothing a due stadi campione per campione (nessun "ginocchio" ogni sotto-blocco).
    e->volumeAlpha = (float)(1.0 - exp(-1.0 / (AEQ_VOLUME_SMOOTH_SECONDS * sampleRate)));
    int eqOn = atomic_load(&e->eqEnabled);
    for (int b = 0; b < AEQ_NUM_BANDS; b++) {
        float g = eqOn ? atomic_load(&e->targetGainDb[b]) : 0.0f;
        e->currentGainDb[b] = g;
        e->coeffs[b] = svf_bell(sampleRate, kBandFrequencies[b], kBandQ, g);
    }
    memset(e->state, 0, sizeof(e->state));
    e->currentBassDb = eqOn ? atomic_load(&e->targetBassDb) : 0.0f;
    e->curBassLog2 = e->midBassLog2 = log2f(atomic_load(&e->targetBassHz));
    e->curTrebleLog2 = e->midTrebleLog2 = log2f(atomic_load(&e->targetTrebleHz));
    e->bassCoeffs = svf_low_shelf(sampleRate, exp2f(e->curBassLog2), e->currentBassDb);
    memset(&e->bassState, 0, sizeof(e->bassState));
    e->currentTrebleDb = eqOn ? atomic_load(&e->targetTrebleDb) : 0.0f;
    e->trebleCoeffs = svf_high_shelf(sampleRate, exp2f(e->curTrebleLog2), e->currentTrebleDb);
    memset(&e->trebleState, 0, sizeof(e->trebleState));
    e->currentAutoGain = eqOn ? db_to_lin(atomic_load(&e->targetAutoGainDb)) : 1.0f;
    for (int b = 0; b < AEQ_NUM_BANDS; b++) e->midGainDb[b] = e->currentGainDb[b];
    e->midBassDb = e->currentBassDb;
    e->midTrebleDb = e->currentTrebleDb;
    e->midAutoGain = e->currentAutoGain;
    e->autoGainAlpha = (float)(1.0 - exp(-(double)AEQ_SUBBLOCK / (AEQ_AUTOGAIN_SMOOTH_SECONDS * sampleRate)));
    e->currentPreamp = eqOn ? db_to_lin(atomic_load(&e->targetPreampDb)) : 1.0f;
    compute_balance_gains(atomic_load(&e->targetVolume), atomic_load(&e->targetBalance),
                          &e->currentGainL, &e->currentGainR);
    e->midPreamp = e->currentPreamp;
    e->midGainL = e->currentGainL;
    e->midGainR = e->currentGainR;
    int la = (int)lround(AEQ_LIMITER_LOOKAHEAD_SECONDS * sampleRate);
    e->lookahead = la < 1 ? 1 : (la > AEQ_MAX_LOOKAHEAD ? AEQ_MAX_LOOKAHEAD : la);
    e->releaseCoef = (float)exp(-1.0 / (AEQ_LIMITER_RELEASE_SECONDS * sampleRate));
    reset_limiter(e);
}

void aeq_set_band_gain(AEQEngine *e, int band, float gainDb) {
    if (!e || band < 0 || band >= AEQ_NUM_BANDS) return;
    atomic_store(&e->targetGainDb[band], sanitize(gainDb, AEQ_GAIN_MIN_DB, AEQ_GAIN_MAX_DB, 0.0f));
}
void aeq_set_preamp(AEQEngine *e, float gainDb) { if (e) atomic_store(&e->targetPreampDb, sanitize(gainDb, -24.0f, 12.0f, 0.0f)); }
void aeq_set_volume(AEQEngine *e, float v) { if (e) atomic_store(&e->targetVolume, sanitize(v, 0.0f, 1.0f, 0.0f)); }
float aeq_get_volume_target(AEQEngine *e) { return e ? atomic_load(&e->targetVolume) : 0.0f; }
void aeq_set_balance(AEQEngine *e, float b) { if (e) atomic_store(&e->targetBalance, sanitize(b, -1.0f, 1.0f, 0.0f)); }
void aeq_set_eq_enabled(AEQEngine *e, int en) { if (e) atomic_store(&e->eqEnabled, en ? 1 : 0); }
void aeq_set_limiter_enabled(AEQEngine *e, int en) { if (e) atomic_store(&e->limiterEnabled, en ? 1 : 0); }
void aeq_set_input_gain(AEQEngine *e, float g) { if (e) atomic_store(&e->inputGain, sanitize(g, 0.0f, 10000.0f, 1.0f)); }
void aeq_set_bass(AEQEngine *e, float db) { if (e) atomic_store(&e->targetBassDb, quantize_tone(db)); }
void aeq_set_treble(AEQEngine *e, float db) { if (e) atomic_store(&e->targetTrebleDb, quantize_tone(db)); }
void aeq_set_bass_frequency(AEQEngine *e, float hz) { if (e) atomic_store(&e->targetBassHz, aeq_snap_bass_frequency(hz)); }
void aeq_set_treble_frequency(AEQEngine *e, float hz) { if (e) atomic_store(&e->targetTrebleHz, aeq_snap_treble_frequency(hz)); }
float aeq_get_bass_frequency_target(AEQEngine *e) { return e ? atomic_load(&e->targetBassHz) : AEQ_BASS_FREQUENCY; }
float aeq_get_treble_frequency_target(AEQEngine *e) { return e ? atomic_load(&e->targetTrebleHz) : AEQ_TREBLE_FREQUENCY; }
float aeq_get_bass_target(AEQEngine *e) { return e ? atomic_load(&e->targetBassDb) : 0.0f; }
float aeq_get_treble_target(AEQEngine *e) { return e ? atomic_load(&e->targetTrebleDb) : 0.0f; }
void aeq_set_auto_gain(AEQEngine *e, float db) {
    if (e) atomic_store(&e->targetAutoGainDb, sanitize(db, AEQ_AUTOGAIN_MIN_DB, AEQ_AUTOGAIN_MAX_DB, 0.0f));
}
void aeq_set_limiter_ceiling(AEQEngine *e, float db) { if (e) atomic_store(&e->limiterCeilingDb, sanitize(db, -12.0f, 0.0f, -1.0f)); }

static inline float flush_denormal(float v) { return fabsf(v) < 1e-15f ? 0.0f : v; }

/// Smoothing a due stadi verso `target`. Restituisce 1 se il valore è cambiato.
static inline int smooth2(float target, float *mid, float *cur, float a, float eps) {
    if (*cur == target && *mid == target) return 0;
    *mid += (target - *mid) * a;
    *cur += (*mid - *cur) * a;
    if (fabsf(target - *cur) < eps && fabsf(target - *mid) < eps) { *mid = target; *cur = target; }
    return 1;
}

/// Stato del filtro corrotto (NaN/Inf, es. da un ingresso non valido): azzera.
static inline void guard_state(SvfState *s) {
    for (int ch = 0; ch < 2; ch++) {
        if (!isfinite(s->ic1[ch]) || !isfinite(s->ic2[ch])) { s->ic1[ch] = 0.0f; s->ic2[ch] = 0.0f; }
        s->ic1[ch] = flush_denormal(s->ic1[ch]);
        s->ic2[ch] = flush_denormal(s->ic2[ch]);
    }
}

static inline float svf_tick(const SvfCoef *c, float *ic1, float *ic2, float x) {
    const float v3 = x - *ic2;
    const float v1 = c->a1 * *ic1 + c->a2 * v3;
    const float v2 = *ic2 + c->a2 * *ic1 + c->a3 * v3;
    *ic1 = 2.0f * v1 - *ic1;
    *ic2 = 2.0f * v2 - *ic2;
    return c->m0 * x + c->m1 * v1 + c->m2 * v2;
}

static inline void svf_stereo(const SvfCoef *c, SvfState *s, float *l, float *r) {
    *l = svf_tick(c, &s->ic1[0], &s->ic2[0], *l);
    *r = svf_tick(c, &s->ic1[1], &s->ic2[1], *r);
}

/// Interpolazione lineare dei coefficienti all'interno del sotto-blocco.
static inline void svf_lerp(SvfCoef *out, const SvfCoef *a, const SvfCoef *b, float t) {
    out->a1 = a->a1 + (b->a1 - a->a1) * t;
    out->a2 = a->a2 + (b->a2 - a->a2) * t;
    out->a3 = a->a3 + (b->a3 - a->a3) * t;
    out->m0 = a->m0 + (b->m0 - a->m0) * t;
    out->m1 = a->m1 + (b->m1 - a->m1) * t;
    out->m2 = a->m2 + (b->m2 - a->m2) * t;
}

#define AEQ_NUM_FILTERS (AEQ_NUM_BANDS + 2)

void aeq_process(AEQEngine *e, float *left, float *right, uint32_t frames) {
    if (!e || !left || !right) return;

    const int eqOn = atomic_load_explicit(&e->eqEnabled, memory_order_relaxed);
    const int limOn = atomic_load_explicit(&e->limiterEnabled, memory_order_relaxed);
    const float ceiling = db_to_lin(atomic_load_explicit(&e->limiterCeilingDb, memory_order_relaxed));
    const float alpha = e->smoothAlpha;
    const float inGain = atomic_load_explicit(&e->inputGain, memory_order_relaxed);
    float blockInPeak = 0.0f;

    float targetGain[AEQ_NUM_BANDS];
    for (int b = 0; b < AEQ_NUM_BANDS; b++)
        targetGain[b] = eqOn ? atomic_load_explicit(&e->targetGainDb[b], memory_order_relaxed) : 0.0f;
    const float targetBass = eqOn ? atomic_load_explicit(&e->targetBassDb, memory_order_relaxed) : 0.0f;
    const float targetTreble = eqOn ? atomic_load_explicit(&e->targetTrebleDb, memory_order_relaxed) : 0.0f;
    const float targetBassLog2 = log2f(atomic_load_explicit(&e->targetBassHz, memory_order_relaxed));
    const float targetTrebleLog2 = log2f(atomic_load_explicit(&e->targetTrebleHz, memory_order_relaxed));
    const float targetAuto = eqOn ? db_to_lin(atomic_load_explicit(&e->targetAutoGainDb, memory_order_relaxed)) : 1.0f;
    float blockPrePeak = 0.0f;
    uint32_t blockOvers = 0, blockClips = 0;
    const float targetPre = eqOn ? db_to_lin(atomic_load_explicit(&e->targetPreampDb, memory_order_relaxed)) : 1.0f;
    float targetL, targetR;
    compute_balance_gains(atomic_load_explicit(&e->targetVolume, memory_order_relaxed),
                          atomic_load_explicit(&e->targetBalance, memory_order_relaxed), &targetL, &targetR);

    float blockPeakL = 0.0f, blockPeakR = 0.0f, blockMinGain = 1.0f;
    const int D = e->lookahead;
    const int W = D + 1;
    uint32_t aw = atomic_load_explicit(&e->analysisWrite, memory_order_relaxed);

    uint32_t done = 0;
    while (done < frames) {
        uint32_t n = frames - done;
        if (n > AEQ_SUBBLOCK) n = AEQ_SUBBLOCK;

        // 1) Smoothing dei guadagni (10 bande + BASSI + ALTI): coefficienti a inizio e fine
        //    sotto-blocco, interpolati campione per campione (nessun gradino).
        SvfCoef startC[AEQ_NUM_FILTERS], endC[AEQ_NUM_FILTERS];
        int moving[AEQ_NUM_FILTERS];
        for (int b = 0; b < AEQ_NUM_BANDS; b++) {
            startC[b] = e->coeffs[b];
            moving[b] = 0;
            if (smooth2(targetGain[b], &e->midGainDb[b], &e->currentGainDb[b], alpha, 0.002f)) {
                e->coeffs[b] = svf_bell(e->sampleRate, kBandFrequencies[b], kBandQ, e->currentGainDb[b]);
                moving[b] = 1;
            }
            endC[b] = e->coeffs[b];
        }
        {
            const int bi = AEQ_NUM_BANDS, ti = AEQ_NUM_BANDS + 1;
            startC[bi] = e->bassCoeffs;
            startC[ti] = e->trebleCoeffs;
            moving[bi] = moving[ti] = 0;
            // Guadagno e frequenza dei toni: smoothing indipendente (frequenza in scala log2).
            const int bg = smooth2(targetBass, &e->midBassDb, &e->currentBassDb, alpha, 0.002f);
            const int bf = smooth2(targetBassLog2, &e->midBassLog2, &e->curBassLog2, alpha, 0.0005f);
            if (bg || bf) {
                e->bassCoeffs = svf_low_shelf(e->sampleRate, exp2f(e->curBassLog2), e->currentBassDb);
                moving[bi] = 1;
            }
            const int tg = smooth2(targetTreble, &e->midTrebleDb, &e->currentTrebleDb, alpha, 0.002f);
            const int tf = smooth2(targetTrebleLog2, &e->midTrebleLog2, &e->curTrebleLog2, alpha, 0.0005f);
            if (tg || tf) {
                e->trebleCoeffs = svf_high_shelf(e->sampleRate, exp2f(e->curTrebleLog2), e->currentTrebleDb);
                moving[ti] = 1;
            }
            endC[bi] = e->bassCoeffs;
            endC[ti] = e->trebleCoeffs;
        }
        SvfState *states[AEQ_NUM_FILTERS];
        for (int b = 0; b < AEQ_NUM_BANDS; b++) states[b] = &e->state[b];
        states[AEQ_NUM_BANDS] = &e->bassState;
        states[AEQ_NUM_BANDS + 1] = &e->trebleState;
        // Ordine di elaborazione: BASSI, ALTI, poi le 10 bande (come prima).
        static const int order[AEQ_NUM_FILTERS] = {AEQ_NUM_BANDS, AEQ_NUM_BANDS + 1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9};

        // 1c) Auto Gain: rampa lenta (~250 ms) per non produrre variazioni udibili.
        const float agStart = e->currentAutoGain;
        smooth2(targetAuto, &e->midAutoGain, &e->currentAutoGain, e->autoGainAlpha, 1e-6f);
        const float agEnd = e->currentAutoGain;

        // 2) Rampe lineari per preamp e volume/bilanciamento all'interno del sotto-blocco.
        const float preStart = e->currentPreamp;
        smooth2(targetPre, &e->midPreamp, &e->currentPreamp, alpha, 1e-6f);
        const float preEnd = e->currentPreamp;
        const float va = e->volumeAlpha;
        float mL = e->midGainL, cL = e->currentGainL, mR = e->midGainR, cR = e->currentGainR;
        const float inv = 1.0f / (float)n;

        for (uint32_t i = 0; i < n; i++) {
            const float t = (float)(i + 1) * inv;
            const float pre = preStart + (preEnd - preStart) * t;
            float xl = left[done + i], xr = right[done + i];
            if (!isfinite(xl)) xl = 0.0f; // campione non valido dal dispositivo: silenzio
            if (!isfinite(xr)) xr = 0.0f;
            const float il = xl * inGain;
            const float ir = xr * inGain;
            const float ip = fmaxf(fabsf(il), fabsf(ir));
            if (ip > blockInPeak) blockInPeak = ip;
            float l = il * pre;
            float r = ir * pre;

            for (int k = 0; k < AEQ_NUM_FILTERS; k++) {
                const int f = order[k];
                if (moving[f]) {
                    SvfCoef c;
                    svf_lerp(&c, &startC[f], &endC[f], t);
                    svf_stereo(&c, states[f], &l, &r);
                } else {
                    svf_stereo(&endC[f], states[f], &l, &r);
                }
            }

            const float ag = agStart + (agEnd - agStart) * t;
            mL += va * (targetL - mL); cL += va * (mL - cL);
            mR += va * (targetR - mR); cR += va * (mR - cR);
            l *= ag * cL;
            r *= ag * cR;

            // Misura prima del limiter: oltre 0 dBFS il segnale clipperebbe senza protezione.
            {
                const float pp = fmaxf(fabsf(l), fabsf(r));
                if (pp > blockPrePeak) blockPrePeak = pp;
                if (pp > 1.0f) blockOvers++;
            }

            // 3) Limiter con look-ahead. Il segnale è ritardato di W campioni; il guadagno richiesto
            //    passa per: minimo su W+1 campioni -> release esponenziale -> media mobile su W
            //    campioni. Ogni valore mediato è <= al guadagno richiesto dal campione in uscita,
            //    quindi |out| <= ceiling senza clipping duro e con attacco morbido.
            {
                const int pos = e->windowPos;
                const float pk = fmaxf(fabsf(l), fabsf(r));
                const float req = (limOn && pk > ceiling) ? ceiling / pk : 1.0f;
                e->holdWindow[e->holdPos] = req;
                e->holdPos = (e->holdPos + 1 == W + 1) ? 0 : e->holdPos + 1;
                // Minimo scorrevole O(1) ammortizzato: si riscansiona solo quando il
                // minimo corrente esce dalla finestra (raro).
                if (req <= e->holdMin) {
                    e->holdMin = req;
                    e->holdAge = 0;
                } else if (++e->holdAge > W) {
                    float m = 1.0f;
                    int age = 0;
                    for (int k = 0; k <= W; k++) {
                        // età del campione k rispetto all'ultimo scritto
                        int a = e->holdPos - 1 - k;
                        if (a < 0) a += W + 1;
                        if (e->holdWindow[k] < m || (e->holdWindow[k] == m && a < age)) {
                            m = e->holdWindow[k];
                            age = a;
                        }
                    }
                    e->holdMin = m;
                    e->holdAge = age;
                }
                const float hold = e->holdMin;
                float env = e->envelope;
                env = hold < env ? hold : hold + (env - hold) * e->releaseCoef;
                e->envelope = env;
                e->avgSum += (double)env - (double)e->avgWindow[pos];
                e->avgWindow[pos] = env;
                float g = (float)(e->avgSum / (double)W);
                if (g > 1.0f) g = 1.0f;

                const float dl = e->delayL[pos];
                const float dr = e->delayR[pos];
                e->delayL[pos] = l;
                e->delayR[pos] = r;
                e->windowPos = (pos + 1 == W) ? 0 : pos + 1;

                l = dl * g;
                r = dr * g;
#ifndef AEQ_NO_SAFETY_CLAMP
                if (limOn) {
                    l = clampf(l, -ceiling, ceiling); // rete di sicurezza (non dovrebbe intervenire)
                    r = clampf(r, -ceiling, ceiling);
                }
#endif
                if (g < blockMinGain) blockMinGain = g;
            }

            left[done + i] = l;
            right[done + i] = r;
            const float al = fabsf(l), ar = fabsf(r);
            if (al >= 1.0f || ar >= 1.0f) blockClips++; // clipping effettivo all'uscita
            if (al > blockPeakL) blockPeakL = al;
            if (ar > blockPeakR) blockPeakR = ar;
            e->analysis[aw & (AEQ_ANALYSIS_SIZE - 1)] = 0.5f * (l + r);
            aw++;
        }
        e->midGainL = mL; e->currentGainL = cL;
        e->midGainR = mR; e->currentGainR = cR;

        guard_state(&e->bassState);
        guard_state(&e->trebleState);
        for (int b = 0; b < AEQ_NUM_BANDS; b++) guard_state(&e->state[b]);
        done += n;
    }

    // Ricalibra periodicamente la somma della media mobile (evita deriva numerica).
    {
        double s = 0.0;
        for (int k = 0; k < W; k++) s += e->avgWindow[k];
        e->avgSum = s;
    }

    atomic_store_explicit(&e->analysisWrite, aw, memory_order_release);
    if (blockPeakL > atomic_load_explicit(&e->peak[0], memory_order_relaxed))
        atomic_store_explicit(&e->peak[0], blockPeakL, memory_order_relaxed);
    if (blockPeakR > atomic_load_explicit(&e->peak[1], memory_order_relaxed))
        atomic_store_explicit(&e->peak[1], blockPeakR, memory_order_relaxed);
    if (blockInPeak > atomic_load_explicit(&e->inputPeak, memory_order_relaxed))
        atomic_store_explicit(&e->inputPeak, blockInPeak, memory_order_relaxed);
    {
        const float blockPeak = fmaxf(blockPeakL, blockPeakR);
        if (blockPeak > atomic_load_explicit(&e->peakHold, memory_order_relaxed))
            atomic_store_explicit(&e->peakHold, blockPeak, memory_order_relaxed);
        if (blockPrePeak > atomic_load_explicit(&e->preLimiterPeakHold, memory_order_relaxed))
            atomic_store_explicit(&e->preLimiterPeakHold, blockPrePeak, memory_order_relaxed);
        if (blockOvers) atomic_fetch_add_explicit(&e->overSamples, blockOvers, memory_order_relaxed);
        if (blockClips) atomic_fetch_add_explicit(&e->clipSamples, blockClips, memory_order_relaxed);
    }
    if (blockMinGain < atomic_load_explicit(&e->minLimiterGain, memory_order_relaxed))
        atomic_store_explicit(&e->minLimiterGain, blockMinGain, memory_order_relaxed);
    atomic_fetch_add_explicit(&e->framesProcessed, frames, memory_order_relaxed);
}

float aeq_read_peak(AEQEngine *e, int channel) {
    if (!e || channel < 0 || channel > 1) return 0.0f;
    return atomic_exchange(&e->peak[channel], 0.0f);
}

void aeq_get_meters(AEQEngine *e, AEQMeters *m) {
    if (!e || !m) return;
    m->peakHold = atomic_load(&e->peakHold);
    m->preLimiterPeakHold = atomic_load(&e->preLimiterPeakHold);
    m->overSamples = atomic_load(&e->overSamples);
    m->clipSamples = atomic_load(&e->clipSamples);
}

void aeq_reset_meters(AEQEngine *e) {
    if (!e) return;
    atomic_store(&e->peakHold, 0.0f);
    atomic_store(&e->preLimiterPeakHold, 0.0f);
    atomic_store(&e->overSamples, 0);
    atomic_store(&e->clipSamples, 0);
}

float aeq_read_input_peak(AEQEngine *e) {
    return e ? atomic_exchange(&e->inputPeak, 0.0f) : 0.0f;
}

float aeq_read_gain_reduction_db(AEQEngine *e) {
    if (!e) return 0.0f;
    float g = atomic_exchange(&e->minLimiterGain, 1.0f);
    if (g >= 1.0f || g <= 0.0f) return 0.0f;
    return -20.0f * log10f(g);
}

void aeq_copy_analysis(AEQEngine *e, float *dst, uint32_t count) {
    if (!e || !dst) return;
    if (count > AEQ_ANALYSIS_SIZE) count = AEQ_ANALYSIS_SIZE;
    uint32_t w = atomic_load_explicit(&e->analysisWrite, memory_order_acquire);
    uint32_t start = w - count;
    for (uint32_t i = 0; i < count; i++) dst[i] = e->analysis[(start + i) & (AEQ_ANALYSIS_SIZE - 1)];
}

uint64_t aeq_frames_processed(AEQEngine *e) {
    return e ? atomic_load_explicit(&e->framesProcessed, memory_order_relaxed) : 0;
}
