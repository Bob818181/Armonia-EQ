import ArmoniaDSP
import Foundation

let bandCount = Int(AEQ_NUM_BANDS)
let gainRange: ClosedRange<Float> = -12...12 // = AEQ_GAIN_MIN_DB...AEQ_GAIN_MAX_DB
let preampRange: ClosedRange<Float> = -12...12

/// Frequenze delle bande lette dal motore DSP (unica fonte di verità).
let bandFrequencies: [Float] = (0..<bandCount).map { aeq_band_frequency(Int32($0)) }

func bandLabel(_ f: Float) -> String {
    f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))"
}

/// Controlli BASSI (shelving 80 Hz) e ALTI (shelving 10 kHz): -12...+12 dB a passi di 0,5 dB.
let toneRange: ClosedRange<Float> = -12...12   // = AEQ_TONE_MIN_DB...AEQ_TONE_MAX_DB
let toneStep: Float = 0.5

/// Arrotonda al passo dei controlli di tono (0,5 dB) entro -12...+12. NaN -> 0.
func quantizeTone(_ v: Float) -> Float {
    guard v.isFinite else { return 0 }
    let c = min(max(v, toneRange.lowerBound), toneRange.upperBound)
    return (c / toneStep).rounded() * toneStep
}

/// Frequenze di intervento selezionabili (dal motore DSP, unica fonte di verità).
let bassFrequencyOptions: [Float] = (0..<Int(aeq_bass_frequency_count())).map { aeq_bass_frequency_option(Int32($0)) }
let trebleFrequencyOptions: [Float] = (0..<Int(aeq_treble_frequency_count())).map { aeq_treble_frequency_option(Int32($0)) }
let defaultBassFrequency: Float = 80     // = AEQ_BASS_FREQUENCY
let defaultTrebleFrequency: Float = 10000 // = AEQ_TREBLE_FREQUENCY

func frequencyLabel(_ hz: Float) -> String {
    hz >= 1000 ? "\(Int(hz / 1000)) kHz" : "\(Int(hz)) Hz"
}

private func finiteClamp(_ v: Float, _ r: ClosedRange<Float>) -> Float {
    guard v.isFinite else { return 0 }
    return min(max(v, r.lowerBound), r.upperBound)
}

/// Curva completa: 10 guadagni + preamp + BASSI + ALTI (guadagno e frequenza di intervento).
struct EQSettings: Codable, Equatable {
    var gains: [Float]
    var preamp: Float
    var bass: Float = 0
    var treble: Float = 0
    var bassFrequency: Float = defaultBassFrequency
    var trebleFrequency: Float = defaultTrebleFrequency

    static let flat = EQSettings(gains: Array(repeating: 0, count: bandCount), preamp: 0)

    init(gains: [Float], preamp: Float, bass: Float = 0, treble: Float = 0,
         bassFrequency: Float = defaultBassFrequency, trebleFrequency: Float = defaultTrebleFrequency) {
        self.gains = gains
        self.preamp = preamp
        self.bass = bass
        self.treble = treble
        self.bassFrequency = bassFrequency
        self.trebleFrequency = trebleFrequency
    }

    // I file delle versioni precedenti non hanno "bass"/"treble" (0 dB) né le frequenze
    // (80 Hz / 10 kHz, cioè il comportamento che avevano).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gains = try c.decode([Float].self, forKey: .gains)
        preamp = try c.decode(Float.self, forKey: .preamp)
        bass = try c.decodeIfPresent(Float.self, forKey: .bass) ?? 0
        treble = try c.decodeIfPresent(Float.self, forKey: .treble) ?? 0
        bassFrequency = (try? c.decodeIfPresent(Float.self, forKey: .bassFrequency)) ?? defaultBassFrequency
        trebleFrequency = (try? c.decodeIfPresent(Float.self, forKey: .trebleFrequency)) ?? defaultTrebleFrequency
    }

    func normalized() -> EQSettings {
        var g = Array(gains.prefix(bandCount))
        while g.count < bandCount { g.append(0) }
        return EQSettings(gains: g.map { finiteClamp($0, gainRange) },
                          preamp: finiteClamp(preamp, preampRange),
                          bass: quantizeTone(bass),
                          treble: quantizeTone(treble),
                          bassFrequency: aeq_snap_bass_frequency(bassFrequency),
                          trebleFrequency: aeq_snap_treble_frequency(trebleFrequency))
    }

    /// Confronto con tolleranza (i valori sono arrotondati a 0,1 dB).
    func isClose(to other: EQSettings) -> Bool {
        abs(preamp - other.preamp) < 0.05 && abs(bass - other.bass) < 0.05 && abs(treble - other.treble) < 0.05
            && bassFrequency == other.bassFrequency && trebleFrequency == other.trebleFrequency
            && gains.count == other.gains.count
            && zip(gains, other.gains).allSatisfy { abs($0 - $1) < 0.05 }
    }
}

/// Impostazioni del limiter salvate con un profilo personale.
struct LimiterSettings: Codable, Equatable {
    var enabled: Bool
    var ceiling: Float   // dBFS, -6...0

    func normalized() -> LimiterSettings {
        LimiterSettings(enabled: enabled, ceiling: ceiling.isFinite ? min(max((ceiling * 10).rounded() / 10, -6), 0) : -1)
    }
}

struct FactoryProfile: Identifiable {
    let id: String
    let name: String
    let summary: String
    let settings: EQSettings
}

/// Profili predefiniti: i valori numerici vengono dal C (Sources/ArmoniaDSP/presets.c),
/// gli stessi verificati da Tests/dsp_test.c.
enum FactoryProfiles {
    private static let texts: [String: (String, String)] = [
        "flat": ("Flat", "Audio neutro, senza equalizzazione"),
        "electronic": ("Musica elettronica", "Bassi profondi e controllati, alti dettagliati"),
        "pop": ("Musica pop", "Suono equilibrato, voci presenti, buona dinamica"),
        "classical": ("Musica classica", "Equilibrio naturale, dettaglio e spazialità"),
        "voice": ("Voce / YouTube", "Parlato chiaro e naturale, meno rimbombo e meno effetto ovattato"),
    ]

    static let all: [FactoryProfile] = (0..<Int(aeq_preset_count())).map { i in
        let id = String(cString: aeq_preset_identifier(Int32(i)))
        let gains = (0..<bandCount).map { aeq_preset_gain(Int32(i), Int32($0)) }
        let (name, summary) = texts[id] ?? (id, "")
        return FactoryProfile(id: id, name: name, summary: summary,
                              settings: EQSettings(gains: gains, preamp: aeq_preset_preamp(Int32(i))))
    }

    static func profile(_ id: String) -> FactoryProfile? { all.first { $0.id == id } }
}

struct CustomProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var settings: EQSettings
    /// Limiter salvato con il profilo (assente nei profili delle versioni precedenti).
    var limiter: LimiterSettings?
}

enum ProfileSelection: Codable, Hashable {
    case factory(String)
    case manual
    case custom(UUID)
}

/// Stato salvato su disco: ~/Library/Application Support/ArmoniaEQ/state.json
/// Decodifica tollerante: ogni campo mancante (file di versioni precedenti) prende il valore
/// predefinito, così profili e impostazioni non vanno mai persi con un aggiornamento.
struct PersistedState: Codable {
    var version = 2
    var selection: ProfileSelection = .factory("flat")
    var current: EQSettings = .flat
    var manual: EQSettings = .flat
    var customProfiles: [CustomProfile] = []
    var volume: Float = 0.8
    var balance: Float = 0
    var powerOn = false
    var eqEnabled = true
    var limiterEnabled = true
    var limiterCeiling: Float = -1
    var autoGain = false
    var spectrumZoom = "full"
    var outputUID: String?
    /// Uscita reale da ripristinare se l'app si chiude in modo anomalo lasciando il loopback come predefinito.
    var restoreOutputUID: String?
    /// Volume dell'utente da ripristinare sull'uscita dopo una chiusura anomala con l'EQ attivo.
    var restoreOutputVolume: Float?
    /// La richiesta del permesso Accessibilità (tasti volume) è già stata mostrata.
    var accessibilityPromptShown = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PersistedState()
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? d.version
        selection = (try? c.decodeIfPresent(ProfileSelection.self, forKey: .selection)) ?? d.selection
        current = (try? c.decodeIfPresent(EQSettings.self, forKey: .current)) ?? d.current
        manual = (try? c.decodeIfPresent(EQSettings.self, forKey: .manual)) ?? d.manual
        // I profili personali si decodificano uno per uno: uno danneggiato non fa perdere gli altri.
        if var list = try? c.nestedUnkeyedContainer(forKey: .customProfiles) {
            var profiles: [CustomProfile] = []
            while !list.isAtEnd {
                if let p = try? list.decode(CustomProfile.self) { profiles.append(p) }
                else { _ = try? list.decode(DiscardedValue.self) }
            }
            customProfiles = profiles
        }
        volume = (try? c.decodeIfPresent(Float.self, forKey: .volume)) ?? d.volume
        balance = (try? c.decodeIfPresent(Float.self, forKey: .balance)) ?? d.balance
        powerOn = (try? c.decodeIfPresent(Bool.self, forKey: .powerOn)) ?? d.powerOn
        eqEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .eqEnabled)) ?? d.eqEnabled
        limiterEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .limiterEnabled)) ?? d.limiterEnabled
        limiterCeiling = (try? c.decodeIfPresent(Float.self, forKey: .limiterCeiling)) ?? d.limiterCeiling
        autoGain = (try? c.decodeIfPresent(Bool.self, forKey: .autoGain)) ?? d.autoGain
        spectrumZoom = (try? c.decodeIfPresent(String.self, forKey: .spectrumZoom)) ?? d.spectrumZoom
        outputUID = try? c.decodeIfPresent(String.self, forKey: .outputUID)
        restoreOutputUID = try? c.decodeIfPresent(String.self, forKey: .restoreOutputUID)
        restoreOutputVolume = try? c.decodeIfPresent(Float.self, forKey: .restoreOutputVolume)
        accessibilityPromptShown = (try? c.decodeIfPresent(Bool.self, forKey: .accessibilityPromptShown)) ?? false
    }
}

/// Consuma un elemento JSON qualsiasi (per saltare voci non valide).
private struct DiscardedValue: Decodable {
    init(from decoder: Decoder) throws {}
}

enum StateStore {
    /// Solo per i test: cartella alternativa.
    static var overrideDirectory: URL?

    static var directory: URL {
        if let d = overrideDirectory { return d }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ArmoniaEQ", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("state.json") }

    static func load() -> PersistedState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else { return PersistedState() }
        return state
    }

    static func save(_ state: PersistedState) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("ArmoniaEQ: salvataggio non riuscito: \(error.localizedDescription)")
        }
    }
}
