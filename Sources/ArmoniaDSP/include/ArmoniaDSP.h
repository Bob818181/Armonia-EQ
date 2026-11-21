// ArmoniaDSP – motore DSP in tempo reale (C puro, nessuna allocazione nel thread audio).
//
// Catena per ogni campione stereo:
//   preamp -> 10 filtri peaking (EQ grafico) -> volume/bilanciamento -> limiter look-ahead
//
// Tutti i parametri vengono scritti dal thread UI con operazioni atomiche e
// raggiunti dal thread audio con uno smoothing di ~30 ms: cambiare profilo
// o muovere un cursore non produce click o interruzioni.

#ifndef ARMONIA_DSP_H
#define ARMONIA_DSP_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define AEQ_NUM_BANDS 10
#define AEQ_GAIN_MIN_DB (-12.0f)
#define AEQ_GAIN_MAX_DB (12.0f)
#define AEQ_ANALYSIS_SIZE 8192
// Controlli di tono indipendenti dai 10 cursori: BASSI (shelving basso) e ALTI (shelving alto).
#define AEQ_TONE_MIN_DB (-12.0f)
#define AEQ_TONE_MAX_DB (12.0f)
#define AEQ_TONE_STEP_DB (0.5f)
// Frequenze di intervento predefinite (selezionabili: vedi aeq_*_frequency_option).
#define AEQ_BASS_FREQUENCY (80.0f)
#define AEQ_TREBLE_FREQUENCY (10000.0f)
// Auto Gain: limiti della compensazione automatica di loudness.
#define AEQ_AUTOGAIN_MIN_DB (-12.0f)
#define AEQ_AUTOGAIN_MAX_DB (6.0f)

typedef struct AEQEngine AEQEngine;

/// Frequenza centrale (Hz) della banda `band` (0...9): 32, 64, 125, 250, 500, 1k, 2k, 4k, 8k, 16k.
float aeq_band_frequency(int band);
/// Q dei filtri peaking (larghezza ~1 ottava).
float aeq_band_q(void);

AEQEngine *aeq_create(double sampleRate);
void aeq_destroy(AEQEngine *engine);

/// Da chiamare SOLO quando il thread audio non sta processando (motore fermo).
/// Azzera gli stati dei filtri e porta i parametri correnti al valore di destinazione.
void aeq_prepare(AEQEngine *engine, double sampleRate);

// ---- Parametri (thread-safe, chiamabili dal thread UI) ----
void aeq_set_band_gain(AEQEngine *engine, int band, float gainDb);
void aeq_set_preamp(AEQEngine *engine, float gainDb);
void aeq_set_volume(AEQEngine *engine, float linearGain);   // 0...1 (lineare)
/// Volume di destinazione attualmente impostato (diagnostica/test).
float aeq_get_volume_target(AEQEngine *engine);
void aeq_set_balance(AEQEngine *engine, float balance);     // -1 (sinistra) ... +1 (destra)
void aeq_set_eq_enabled(AEQEngine *engine, int enabled);    // 0 = bypass EQ + preamp
void aeq_set_limiter_enabled(AEQEngine *engine, int enabled);
void aeq_set_limiter_ceiling(AEQEngine *engine, float ceilingDb); // es. -1.0 dBFS
/// Guadagno lineare applicato all'ingresso, SENZA smoothing (deve seguire a gradino il guadagno
/// del driver loopback). Serve ad annullare esattamente l'attenuazione introdotta dal controllo
/// volume di BlackHole: se BlackHole moltiplica per g, qui si imposta 1/g. Intervallo 0...10000.
void aeq_set_input_gain(AEQEngine *engine, float linearGain);
/// BASSI: shelving basso a AEQ_BASS_FREQUENCY Hz. ALTI: shelving alto a AEQ_TREBLE_FREQUENCY Hz.
/// Intervallo -12...+12 dB, quantizzato a passi di 0,5 dB, indipendenti dai 10 cursori.
/// Esclusi dal bypass come l'EQ. Smoothing di ~30 ms: nessun click.
void aeq_set_bass(AEQEngine *engine, float gainDb);
void aeq_set_treble(AEQEngine *engine, float gainDb);
/// Valori effettivamente impostati (dopo limitazione e quantizzazione), per i test.
float aeq_get_bass_target(AEQEngine *engine);
float aeq_get_treble_target(AEQEngine *engine);

/// Frequenza di intervento dei controlli di tono, indipendente dal guadagno.
/// BASSI: 60, 80, 100, 120 Hz. ALTI: 8, 10, 12 kHz. Un valore diverso viene portato all'opzione
/// più vicina (NaN -> predefinita). Il cambio è graduale (~30 ms, scala logaritmica): niente click.
int aeq_bass_frequency_count(void);
float aeq_bass_frequency_option(int index);
int aeq_treble_frequency_count(void);
float aeq_treble_frequency_option(int index);
float aeq_snap_bass_frequency(float hz);
float aeq_snap_treble_frequency(float hz);
void aeq_set_bass_frequency(AEQEngine *engine, float hz);
void aeq_set_treble_frequency(AEQEngine *engine, float hz);
float aeq_get_bass_frequency_target(AEQEngine *engine);
float aeq_get_treble_frequency_target(AEQEngine *engine);
/// Auto Gain: guadagno di compensazione (dB) applicato dopo l'EQ con rampa lenta (~250 ms),
/// escluso dal bypass. 0 dB = nessun effetto (guadagno esattamente 1). Il valore si calcola con
/// aeq_auto_gain_db() dalla curva impostata.
void aeq_set_auto_gain(AEQEngine *engine, float gainDb);

// ---- Elaborazione (thread audio) ----
/// Elabora in place due canali non interleaved.
void aeq_process(AEQEngine *engine, float *left, float *right, uint32_t frames);

// ---- Misure (thread UI) ----
/// Picco di uscita dall'ultima lettura (lineare). Azzera il valore.
float aeq_read_peak(AEQEngine *engine, int channel);
/// Misuratori di picco e clipping (dall'ultimo azzeramento).
typedef struct {
    float peakHold;            ///< picco massimo in uscita (lineare)
    float preLimiterPeakHold;  ///< picco massimo prima del limiter (lineare)
    uint32_t overSamples;      ///< campioni oltre 0 dBFS prima del limiter (gestiti dal limiter)
    uint32_t clipSamples;      ///< campioni in uscita >= 0 dBFS: clipping effettivo
} AEQMeters;
void aeq_get_meters(AEQEngine *engine, AEQMeters *meters);
void aeq_reset_meters(AEQEngine *engine);
/// Picco in ingresso (dopo la compensazione, prima di preamp/EQ) dall'ultima lettura. Azzera il valore.
float aeq_read_input_peak(AEQEngine *engine);
/// Livello d'ingresso recente (lineare, dopo la compensazione): picco che decade di 60 dB in 0,5 s.
/// Non viene azzerato dalla lettura (serve a sapere se in questo momento c'è audio).
float aeq_input_envelope(AEQEngine *engine);
/// Massima riduzione di guadagno del limiter dall'ultima lettura (dB, >= 0). Azzera il valore.
float aeq_read_gain_reduction_db(AEQEngine *engine);
/// Copia gli ultimi `count` campioni mono (post-elaborazione) per l'analizzatore di spettro.
void aeq_copy_analysis(AEQEngine *engine, float *destination, uint32_t count);
/// Numero totale di frame elaborati (per sapere se l'audio sta scorrendo).
uint64_t aeq_frames_processed(AEQEngine *engine);

// ---- Risposta in frequenza ----
/// Risposta in dB (EQ + preamp) alla frequenza `frequency`, calcolata con gli
/// STESSI coefficienti usati nell'elaborazione. `gainsDb` deve avere 10 elementi.
double aeq_response_db(const float *gainsDb, float preampDb, double sampleRate, double frequency);
/// Risposta totale (EQ + preamp + BASSI + ALTI) con gli stessi coefficienti dell'elaborazione.
double aeq_response_total_db(const float *gainsDb, float preampDb, float bassDb, float trebleDb,
                             double sampleRate, double frequency);
/// Contributo dei soli controlli BASSI / ALTI (dB).
double aeq_bass_response_db(float bassDb, double sampleRate, double frequency);
double aeq_treble_response_db(float trebleDb, double sampleRate, double frequency);
/// Varianti con frequenza di intervento dei toni esplicita (le funzioni sopra usano le predefinite).
double aeq_bass_response_at_db(float bassDb, float bassHz, double sampleRate, double frequency);
double aeq_treble_response_at_db(float trebleDb, float trebleHz, double sampleRate, double frequency);
double aeq_response_full_db(const float *gainsDb, float preampDb, float bassDb, float bassHz,
                            float trebleDb, float trebleHz, double sampleRate, double frequency);
double aeq_loudness_change_full_db(const float *gainsDb, float preampDb, float bassDb, float bassHz,
                                   float trebleDb, float trebleHz, double sampleRate);
float aeq_auto_gain_full_db(const float *gainsDb, float preampDb, float bassDb, float bassHz,
                            float trebleDb, float trebleHz, double sampleRate);
/// Variazione di loudness percepita (dB) prodotta dalla curva completa rispetto a Flat:
/// media di potenza su spettro rosa (energia uguale per ottava) pesata K (ITU-R BS.1770).
double aeq_loudness_change_db(const float *gainsDb, float preampDb, float bassDb, float trebleDb, double sampleRate);
/// Guadagno Auto Gain che riporta la loudness al livello di Flat, limitato a
/// AEQ_AUTOGAIN_MIN_DB...AEQ_AUTOGAIN_MAX_DB.
float aeq_auto_gain_db(const float *gainsDb, float preampDb, float bassDb, float trebleDb, double sampleRate);

// ---- Profili predefiniti (unica fonte di verità, usata dall'app e dai test) ----
int aeq_preset_count(void);
const char *aeq_preset_identifier(int index); // "flat", "electronic", "pop", "classical", "voice"
float aeq_preset_gain(int index, int band);
float aeq_preset_preamp(int index);

#ifdef __cplusplus
}
#endif

#endif
