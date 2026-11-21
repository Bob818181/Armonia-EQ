#include "ArmoniaDSP.h"

// Profili predefiniti. Bande: 32, 64, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz.
//
// Note di progetto (i filtri peaking sono larghi ~1 ottava e si sommano tra bande vicine:
// il preamp è scelto in base al picco REALE della curva, verificato da Tests/dsp_test.c,
// così che la curva + preamp resti attorno a 0 dB e il limiter intervenga solo raramente):
//
// - Flat: neutro.
// - Musica elettronica: sub-bassi (32–64 Hz) in evidenza ma con 125 Hz moderato e taglio
//   a 250–500 Hz per evitare il "fango" che rende i bassi gonfi; 1 kHz leggermente
//   ridotto, alti (8–16 kHz) aperti per hi-hat e dettaglio.
// - Musica pop: leggero rinforzo dei bassi (64–125 Hz) per il corpo, 500 Hz appena ridotto
//   (scatolosità), presenza a 2–4 kHz per le voci, aria moderata in alto.
// - Musica classica: curva quasi neutra, nessuna enfasi dei bassi; piccola riduzione a
//   250–500 Hz per pulizia degli strumenti a corda e dell'ambiente, leggero aumento
//   di 4–16 kHz per dettaglio e spazialità della sala.
// - Voce / YouTube: forte riduzione sotto i 125 Hz (rimbombo, rumori di manipolazione,
//   effetto prossimità), riduzione a 250–500 Hz (suono ovattato/nasale), enfasi della
//   zona di intelligibilità 1–4 kHz, 8 kHz neutro e 16 kHz ridotto per contenere
//   sibilanti e fruscio.

typedef struct {
    const char *identifier;
    float gains[AEQ_NUM_BANDS];
    float preamp;
} AEQPreset;

static const AEQPreset kPresets[] = {
    {"flat",       { 0.0f,  0.0f,  0.0f,  0.0f,  0.0f,  0.0f, 0.0f, 0.0f, 0.0f,  0.0f},  0.0f},
    {"electronic", { 3.5f,  4.0f,  2.0f, -1.0f, -2.0f, -1.0f, 0.0f, 1.0f, 2.5f,  2.5f}, -5.0f},
    {"pop",        { 1.0f,  2.5f,  2.0f,  0.0f, -1.0f,  0.0f, 1.5f, 2.5f, 2.0f,  1.5f}, -3.0f},
    {"classical",  { 0.0f,  0.0f,  0.0f, -0.5f, -1.0f,  0.0f, 0.0f, 1.0f, 2.0f,  2.5f}, -2.5f},
    {"voice",      {-6.0f, -5.0f, -3.0f, -2.0f, -1.5f,  1.0f, 3.0f, 3.5f, 0.0f, -1.0f}, -4.0f},
};

int aeq_preset_count(void) { return (int)(sizeof(kPresets) / sizeof(kPresets[0])); }

const char *aeq_preset_identifier(int index) {
    if (index < 0 || index >= aeq_preset_count()) return "";
    return kPresets[index].identifier;
}

float aeq_preset_gain(int index, int band) {
    if (index < 0 || index >= aeq_preset_count() || band < 0 || band >= AEQ_NUM_BANDS) return 0.0f;
    return kPresets[index].gains[band];
}

float aeq_preset_preamp(int index) {
    if (index < 0 || index >= aeq_preset_count()) return 0.0f;
    return kPresets[index].preamp;
}
