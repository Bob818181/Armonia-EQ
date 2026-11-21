// Test del modello: salvataggio/ripristino, compatibilità con i file delle versioni precedenti,
// gestione dei profili (rinomina, duplicazione, eliminazione, import/export) e confronto A/B.
// Compilato in CI insieme a Profiles.swift, PresetLibrary.swift e ABCompare.swift.

import ArmoniaDSP
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
var failures = 0, checks = 0
func expect(_ ok: Bool, _ msg: String) {
    checks += 1
    print((ok ? "  OK  " : "  FALLITO  ") + msg)
    if !ok { failures += 1 }
}

func settings(_ seed: Float, bass: Float = 0, treble: Float = 0) -> EQSettings {
    EQSettings(gains: (0..<bandCount).map { Float($0) * 0.5 - seed }, preamp: -seed, bass: bass, treble: treble)
}

print("[1] Compatibilità con lo stato salvato dalle versioni precedenti")
do {
    // state.json della versione 1 (prima di BASSI/ALTI, Auto Gain e limiter nei profili).
    let v1 = """
    {"version":1,"selection":{"custom":{"_0":"6F1C2D3E-4A5B-4C6D-8E9F-0A1B2C3D4E5F"}},
     "current":{"gains":[-4,-3,-2,-1,-1,1,2.5,3,0.5,0],"preamp":-3},
     "manual":{"gains":[0,0,0,0,0,0,0,0,0,0],"preamp":0},
     "customProfiles":[
       {"id":"6F1C2D3E-4A5B-4C6D-8E9F-0A1B2C3D4E5F","name":"M60 – Voci limpide","settings":{"gains":[-4,-3,-2,-1,-1,1,2.5,3,0.5,0],"preamp":-3}},
       {"id":"broken","name":42},
       {"id":"7F1C2D3E-4A5B-4C6D-8E9F-0A1B2C3D4E5F","name":"M60 – Bassi","settings":{"gains":[2,2,1,0,0,0,0,0,0,0],"preamp":-2,"bass":3}}
     ],
     "volume":0.7,"balance":0.1,"powerOn":true,"eqEnabled":true,"limiterEnabled":false,"limiterCeiling":-2}
    """
    let s = try JSONDecoder().decode(PersistedState.self, from: Data(v1.utf8))
    expect(s.customProfiles.count == 2, "profili validi conservati, quello danneggiato scartato (\(s.customProfiles.count) su 2)")
    expect(s.customProfiles.first?.name == "M60 – Voci limpide" && s.customProfiles.first?.settings.treble == 0,
           "profilo v1 senza ALTI: ALTI = 0 dB")
    expect(s.customProfiles.last?.settings.bass == 3, "BASSI del profilo conservati (3 dB)")
    expect(s.customProfiles.allSatisfy { $0.settings.bassFrequency == 80 && $0.settings.trebleFrequency == 10000 },
           "profili senza frequenze dei toni: 80 Hz / 10 kHz (comportamento delle versioni precedenti)")
    expect(s.customProfiles.first?.limiter == nil, "profilo v1 senza limiter: nessun limiter salvato")
    expect(s.autoGain == false && s.spectrumZoom == "full", "nuovi campi ai valori predefiniti (Auto Gain spento, spettro completo)")
    expect(s.volume == 0.7 && s.limiterEnabled == false && s.limiterCeiling == -2, "impostazioni esistenti conservate")
    let empty = try JSONDecoder().decode(PersistedState.self, from: Data("{}".utf8))
    expect(empty.customProfiles.isEmpty && empty.selection == .factory("flat"), "file vuoto: valori predefiniti, nessun errore")
} catch {
    expect(false, "decodifica dello stato v1: \(error)")
}

print("\n[2] Salvataggio e ripristino di tutti i parametri (file reale)")
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("armonia-modelcheck-\(UUID().uuidString)")
    StateStore.overrideDirectory = dir
    var st = PersistedState()
    var full = settings(1, bass: 6.5, treble: -3.5)
    full.bassFrequency = 120
    full.trebleFrequency = 8000
    let p = CustomProfile(id: UUID(), name: "Prova completa", settings: full,
                          limiter: LimiterSettings(enabled: false, ceiling: -2.5))
    st.customProfiles = [p]
    st.selection = .custom(p.id)
    st.current = settings(2, bass: -12, treble: 12)
    st.autoGain = true
    st.limiterEnabled = false
    st.limiterCeiling = -3
    st.spectrumZoom = "bass"
    StateStore.save(st)
    let back = StateStore.load()
    expect(back.customProfiles == st.customProfiles, "profilo con BASSI, ALTI, preamp e limiter identico dopo il riavvio")
    expect(back.customProfiles.first?.settings.bassFrequency == 120 && back.customProfiles.first?.settings.trebleFrequency == 8000,
           "frequenze dei toni (120 Hz / 8 kHz) conservate dopo il riavvio")
    expect(back.current == st.current && back.selection == st.selection, "curva corrente e profilo selezionato ripristinati")
    expect(back.autoGain && back.limiterEnabled == false && back.limiterCeiling == -3 && back.spectrumZoom == "bass",
           "Auto Gain, limiter e zoom dello spettro ripristinati")
    try? FileManager.default.removeItem(at: dir)
}

print("\n[3] Gestione dei profili personali")
do {
    var lib = PresetLibrary()
    let a = lib.save(name: "  M60 – Musica  ", settings: settings(1, bass: 4), limiter: LimiterSettings(enabled: true, ceiling: -1))!
    expect(lib.profiles.first?.name == "M60 – Musica", "nome ripulito dagli spazi")
    expect(lib.save(name: "", settings: settings(1), limiter: nil) == nil, "nome vuoto rifiutato")
    let again = lib.save(name: "m60 – musica", settings: settings(3), limiter: nil)
    expect(again == a && lib.profiles.count == 1 && lib.profiles[0].settings.preamp == -3,
           "salvataggio con nome esistente aggiorna quel profilo (nessun duplicato)")
    var film = settings(2, treble: 2)
    film.trebleFrequency = 12000
    film.bassFrequency = 60
    let b = lib.save(name: "M60 – Film", settings: film, limiter: nil)!
    expect(!lib.rename(b, to: "M60 – MUSICA"), "rinomina verso un nome già usato rifiutata")
    expect(!lib.rename(b, to: "   "), "rinomina con nome vuoto rifiutata")
    expect(lib.rename(b, to: "M60 – Film notturno") && lib.profiles[1].name == "M60 – Film notturno", "rinomina riuscita")
    let copy = lib.duplicate(b)
    expect(copy != nil && copy!.id != b && copy!.name == "M60 – Film notturno copia"
           && copy!.settings == lib.profiles.first { $0.id == b }!.settings, "duplicazione: nuova voce con la stessa curva")
    let copy2 = lib.duplicate(b)
    expect(copy2?.name == "M60 – Film notturno copia (2)", "duplicazione ripetuta: nome univoco (\(copy2?.name ?? "-"))")
    expect(lib.delete(copy!.id) && !lib.profiles.contains { $0.id == copy!.id }, "eliminazione")
    expect(!lib.delete(UUID()), "eliminazione di un profilo inesistente: nessun effetto")
    // Valori non validi limitati al salvataggio
    let w = lib.save(name: "Estremo", settings: EQSettings(gains: Array(repeating: 40, count: bandCount), preamp: .nan,
                                                            bass: 13.26, treble: -99), limiter: nil)!
    let ws = lib.profiles.first { $0.id == w }!.settings
    expect(ws.gains.allSatisfy { $0 == 12 } && ws.preamp == 0 && ws.bass == 12 && ws.treble == -12,
           "valori fuori intervallo/NaN limitati (bande 12, preamp 0, BASSI 12, ALTI -12)")
    expect(quantizeTone(3.26) == 3.5 && quantizeTone(-0.2) == 0 && quantizeTone(.nan) == 0, "BASSI/ALTI a passi di 0,5 dB")
    expect(bassFrequencyOptions == [60, 80, 100, 120] && trebleFrequencyOptions == [8000, 10000, 12000],
           "opzioni di frequenza: BASSI 60/80/100/120 Hz, ALTI 8/10/12 kHz")
    let odd = EQSettings(gains: Array(repeating: 0, count: bandCount), preamp: 0, bassFrequency: 97, trebleFrequency: .nan).normalized()
    expect(odd.bassFrequency == 100 && odd.trebleFrequency == 10000, "frequenze non valide portate all'opzione più vicina / predefinita")
    var f1 = settings(1), f2 = settings(1)
    f2.bassFrequency = 60
    expect(!f1.isClose(to: f2), "cambiare solo la frequenza rende il profilo \"modificato\"")
    f1.bassFrequency = 60
    expect(f1.isClose(to: f2), "stessa curva e stesse frequenze: profilo non modificato")

    // Esportazione e importazione
    let data = try lib.exportData()
    var other = PresetLibrary()
    _ = other.save(name: "M60 – Musica", settings: settings(9), limiter: nil)
    let res = try other.importData(data)
    expect(res.imported.count == lib.profiles.count && res.skipped == 0, "importati \(res.imported.count) profili su \(lib.profiles.count)")
    expect(other.profiles.first?.settings == settings(9), "il profilo esistente con lo stesso nome NON viene sovrascritto")
    expect(res.imported.contains("M60 – Musica (2)"), "conflitto di nome risolto con nome univoco")
    let orig = lib.profiles.first { $0.name == "M60 – Musica" }!
    let imp = other.profiles.first { $0.name == "M60 – Musica (2)" }!
    expect(imp.settings == orig.settings && imp.limiter == orig.limiter, "curva, BASSI, ALTI, preamp e limiter identici dopo export/import")
    let filmBack = other.profiles.first { $0.name.hasPrefix("M60 – Film notturno") }
    expect(filmBack?.settings.bassFrequency == 60 && filmBack?.settings.trebleFrequency == 12000,
           "frequenze dei toni conservate da export/import (60 Hz / 12 kHz)")
    // File non validi
    var lib3 = PresetLibrary()
    expect((try? lib3.importData(Data("ciao".utf8))) == nil, "file non JSON rifiutato")
    expect((try? lib3.importData(Data(#"{"format":"altro","version":1,"presets":[]}"#.utf8))) == nil, "formato estraneo rifiutato")
    let partial = #"{"format":"ArmoniaEQ-presets","version":2,"presets":[{"name":"Corto","gains":[1,2],"preamp":0},{"name":"Buono","gains":[1,1,1,1,1,1,1,1,1,1],"preamp":-1,"bass":50}]}"#
    let r3 = try lib3.importData(Data(partial.utf8))
    expect(r3.imported == ["Buono"] && r3.skipped == 1 && lib3.profiles[0].settings.bass == 12,
           "voce incompleta saltata, valori limitati nella voce valida")
} catch {
    expect(false, "gestione profili: \(error)")
}

print("\n[4] Confronto A/B")
do {
    var ab = ABCompare()
    let x = settings(1, bass: 3), y = settings(5, treble: -4)
    expect(!ab.isInUse && ab.active == .a, "stato iniziale: A, nessuna configurazione memorizzata")
    var cur = ab.switchTo(.b, current: x)
    expect(ab.active == .b && cur == x, "primo passaggio a B: B parte come copia di A (il suono non cambia)")
    cur = y // l'utente modifica B
    cur = ab.switchTo(.a, current: cur)
    expect(ab.active == .a && cur == x, "ritorno ad A: A è esattamente com'era")
    cur = ab.switchTo(.b, current: cur)
    expect(cur == y, "di nuovo B: le modifiche fatte in B sono conservate")
    cur = ab.toggle(current: cur)
    expect(ab.active == .a && cur == x, "alternanza A/B ripetuta stabile")
    ab.copyActiveToOther(current: cur)
    expect(ab.settings(for: .b, current: cur) == x, "copia A -> B")
    ab.reset()
    expect(!ab.isInUse && ab.active == .a, "azzeramento del confronto")
}

print("\n[5] Avvio automatico all'accesso (LaunchAgent dell'utente)")
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("armonia-login-\(UUID().uuidString)")
    LoginItem.overrideDirectory = dir
    expect(!LoginItem.isEnabled && LoginItem.configuredAppPath() == nil, "inizialmente disattivato")
    try LoginItem.setEnabled(true, appPath: "/Applications/ArmoniaEQ.app")
    expect(LoginItem.isEnabled, "attivazione: file creato in LaunchAgents")
    let lint = Process()
    lint.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
    lint.arguments = ["-lint", LoginItem.plistURL.path]
    lint.standardOutput = FileHandle.nullDevice
    try lint.run(); lint.waitUntilExit()
    expect(lint.terminationStatus == 0, "plist valido per macOS (plutil -lint)")
    let obj = try PropertyListSerialization.propertyList(from: Data(contentsOf: LoginItem.plistURL), format: nil) as? [String: Any]
    let args = obj?["ProgramArguments"] as? [String] ?? []
    expect(obj?["Label"] as? String == LoginItem.label && obj?["RunAtLoad"] as? Bool == true,
           "etichetta e avvio al login (RunAtLoad)")
    expect(args == ["/usr/bin/open", "-g", "-a", "/Applications/ArmoniaEQ.app", "--args", "--avvio-automatico"],
           "avvia l'app in secondo piano con --avvio-automatico (solo barra dei menu)")
    expect(LoginItem.refreshIfNeeded(appPath: "/Users/test/Desktop/ArmoniaEQ.app")
           && LoginItem.configuredAppPath() == "/Users/test/Desktop/ArmoniaEQ.app", "app spostata: percorso aggiornato")
    expect(!LoginItem.refreshIfNeeded(appPath: "/Users/test/Desktop/ArmoniaEQ.app"), "percorso invariato: nessuna riscrittura")
    try LoginItem.setEnabled(false, appPath: "")
    expect(!LoginItem.isEnabled && !FileManager.default.fileExists(atPath: LoginItem.plistURL.path), "disattivazione: file rimosso")
    expect(!LoginItem.refreshIfNeeded(appPath: "/x.app") && !LoginItem.isEnabled, "disattivato: non viene ricreato")
    try? FileManager.default.removeItem(at: dir)
} catch {
    expect(false, "avvio automatico: \(error)")
}

print("\n\(checks) verifiche, \(failures) fallite")
exit(failures == 0 ? 0 : 1)
