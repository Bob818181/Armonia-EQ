import Foundation

/// Gestione dei profili personali: nomi univoci, rinomina, duplicazione, eliminazione,
/// importazione ed esportazione. Logica pura (senza interfaccia), verificata da Tests/ModelCheck.
/// I profili predefiniti non passano mai di qui: non possono essere modificati o sovrascritti.
struct PresetLibrary {
    private(set) var profiles: [CustomProfile]

    init(_ profiles: [CustomProfile] = []) { self.profiles = profiles }

    static func clean(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func index(named name: String, excluding id: UUID? = nil) -> Int? {
        let n = PresetLibrary.clean(name)
        return profiles.firstIndex { $0.id != id && $0.name.caseInsensitiveCompare(n) == .orderedSame }
    }

    func contains(name: String, excluding id: UUID? = nil) -> Bool { index(named: name, excluding: id) != nil }

    /// "Nome", "Nome (2)", "Nome (3)"... senza collisioni (maiuscole/minuscole ignorate).
    func uniqueName(_ base: String) -> String {
        let b = PresetLibrary.clean(base).isEmpty ? "Profilo" : PresetLibrary.clean(base)
        if !contains(name: b) { return b }
        var i = 2
        while contains(name: "\(b) (\(i))") { i += 1 }
        return "\(b) (\(i))"
    }

    /// Salva con nome: se esiste già un profilo con lo stesso nome viene aggiornato, altrimenti
    /// se ne crea uno nuovo. Restituisce l'id del profilo salvato.
    @discardableResult
    mutating func save(name: String, settings: EQSettings, limiter: LimiterSettings?) -> UUID? {
        let n = PresetLibrary.clean(name)
        guard !n.isEmpty else { return nil }
        if let i = index(named: n) {
            profiles[i].settings = settings.normalized()
            profiles[i].limiter = limiter?.normalized()
            return profiles[i].id
        }
        let p = CustomProfile(id: UUID(), name: n, settings: settings.normalized(), limiter: limiter?.normalized())
        profiles.append(p)
        return p.id
    }

    mutating func update(_ id: UUID, settings: EQSettings, limiter: LimiterSettings?) -> Bool {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return false }
        profiles[i].settings = settings.normalized()
        profiles[i].limiter = limiter?.normalized()
        return true
    }

    /// Rinomina: rifiuta nomi vuoti o già usati da un altro profilo.
    mutating func rename(_ id: UUID, to name: String) -> Bool {
        let n = PresetLibrary.clean(name)
        guard !n.isEmpty, !contains(name: n, excluding: id),
              let i = profiles.firstIndex(where: { $0.id == id }) else { return false }
        profiles[i].name = n
        return true
    }

    /// Duplica un profilo: stessa curva e limiter, nuovo id, nome "… copia" univoco.
    mutating func duplicate(_ id: UUID) -> CustomProfile? {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = profiles[i]
        copy.id = UUID()
        copy.name = uniqueName("\(profiles[i].name) copia")
        profiles.insert(copy, at: i + 1)
        return copy
    }

    @discardableResult
    mutating func delete(_ id: UUID) -> Bool {
        let before = profiles.count
        profiles.removeAll { $0.id == id }
        return profiles.count != before
    }

    // MARK: Importazione / esportazione

    static let fileFormat = "ArmoniaEQ-presets"

    struct ExportedPreset: Codable {
        var name: String
        var gains: [Float]
        var preamp: Float
        var bass: Float?
        var treble: Float?
        var bassFrequency: Float?
        var trebleFrequency: Float?
        var limiterEnabled: Bool?
        var limiterCeiling: Float?
    }

    struct PresetFile: Codable {
        var format: String
        var version: Int
        var presets: [ExportedPreset]
    }

    func exportData(_ ids: [UUID]? = nil) throws -> Data {
        let selected = ids.map { set in profiles.filter { set.contains($0.id) } } ?? profiles
        let file = PresetFile(format: PresetLibrary.fileFormat, version: 2, presets: selected.map {
            ExportedPreset(name: $0.name, gains: $0.settings.gains, preamp: $0.settings.preamp,
                           bass: $0.settings.bass, treble: $0.settings.treble,
                           bassFrequency: $0.settings.bassFrequency, trebleFrequency: $0.settings.trebleFrequency,
                           limiterEnabled: $0.limiter?.enabled, limiterCeiling: $0.limiter?.ceiling)
        })
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(file)
    }

    struct ImportResult: Equatable {
        var imported: [String] = []
        var skipped = 0
    }

    enum ImportError: LocalizedError {
        case notAPresetFile
        var errorDescription: String? { "Il file non contiene profili di Armonia EQ." }
    }

    /// Importa i profili da un file esportato. I valori fuori intervallo vengono limitati, le voci
    /// non valide (es. 10 bande mancanti) saltate, i nomi già esistenti resi univoci: nessun
    /// profilo esistente viene sovrascritto.
    mutating func importData(_ data: Data) throws -> ImportResult {
        guard let file = try? JSONDecoder().decode(PresetFile.self, from: data),
              file.format == PresetLibrary.fileFormat else { throw ImportError.notAPresetFile }
        var result = ImportResult()
        for p in file.presets {
            guard p.gains.count == bandCount, !PresetLibrary.clean(p.name).isEmpty else { result.skipped += 1; continue }
            let settings = EQSettings(gains: p.gains, preamp: p.preamp, bass: p.bass ?? 0, treble: p.treble ?? 0,
                                      bassFrequency: p.bassFrequency ?? defaultBassFrequency,
                                      trebleFrequency: p.trebleFrequency ?? defaultTrebleFrequency).normalized()
            var limiter: LimiterSettings?
            if let en = p.limiterEnabled {
                limiter = LimiterSettings(enabled: en, ceiling: p.limiterCeiling ?? -1).normalized()
            }
            let name = uniqueName(p.name)
            profiles.append(CustomProfile(id: UUID(), name: name, settings: settings, limiter: limiter))
            result.imported.append(name)
        }
        return result
    }
}
