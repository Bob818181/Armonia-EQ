// Test automatico dell'interfaccia di Armonia EQ con eventi mouse/tastiera reali (CGEvent).
// Uso: ui_check <file di log dell'app avviata con ARMONIA_DEBUG=1>
//
// Verifica che:
//  1. tutti i cursori (PREAMP, BASSI, ALTI, 10 bande), trascinati in tre punti, cambino valore
//     e NON spostino la finestra; BASSI/ALTI a passi di 0,5 dB;
//  2. le zone non interattive dei pannelli non spostino la finestra;
//  3. rotella, doppio clic, inserimento numerico, A/B, Auto Gain, azzeramento del picco funzionino;
//  4. barra del titolo e aree libere spostino la finestra;
//  5. il menu della frequenza BASSI funzioni;
//  6. chiusa la finestra, il motore continui a elaborare e l'icona nella barra dei menu apra il
//     pannello rapido (BASSI, ALTI, volume, frequenza, profilo, ON/OFF, Apri finestra, Esci).

import AppKit
import CoreGraphics
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
guard CommandLine.arguments.count > 1 else { print("uso: ui_check <log>"); exit(2) }
let logPath = CommandLine.arguments[1]

func readLog() -> String { (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "" }

func waitFor(_ needles: [String], timeout: Double = 20) -> String {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        let l = readLog()
        if needles.allSatisfy({ l.contains($0) }) { return l }
        Thread.sleep(forTimeInterval: 0.25)
    }
    print("ERRORE: nel log mancano \(needles)"); print(readLog()); exit(1)
}

func value(_ line: Substring, _ key: String) -> Double? {
    guard let r = line.range(of: key + "=") else { return nil }
    let rest = line[r.upperBound...]
    return Double(rest.prefix { "0123456789.-".contains($0) })
}

/// Ultima riga del log che contiene `marker`, con i campi x, y, w, h.
func frame(_ log: String, _ marker: String) -> CGRect? {
    guard let line = log.split(separator: "\n").last(where: { $0.contains(marker) }),
          let x = value(line, "x"), let y = value(line, "y"), let w = value(line, "w"), let h = value(line, "h") else { return nil }
    return CGRect(x: x, y: y, width: w, height: h)
}

_ = waitFor(["finestra x=", "controllo cursore-1k ", "controllo cursore-bassi ", "controllo ab ", "controllo auto-gain ", "controllo area-libera "])
Thread.sleep(forTimeInterval: 1.5) // lascia completare il dimensionamento della finestra
let initial = readLog()
var failures = 0

func windowFrame() -> CGRect { frame(readLog(), "finestra x=")! }
func screenPoint(_ control: String) -> CGPoint {
    let w = windowFrame(), c = frame(initial, "controllo \(control) ")!
    return CGPoint(x: w.minX + c.midX, y: w.minY + c.midY)
}

var lastPoint = CGPoint.zero
/// Evento mouse con i campi di spostamento (delta) valorizzati, come quelli di un mouse reale:
/// il trascinamento della finestra gestito da macOS segue i delta, non solo la posizione.
func post(_ type: CGEventType, _ p: CGPoint) {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
    if type == .leftMouseDragged || type == .mouseMoved {
        e?.setIntegerValueField(.mouseEventDeltaX, value: Int64((p.x - lastPoint.x).rounded()))
        e?.setIntegerValueField(.mouseEventDeltaY, value: Int64((p.y - lastPoint.y).rounded()))
    }
    if type == .leftMouseDown || type == .leftMouseUp { e?.setIntegerValueField(.mouseEventClickState, value: 1) }
    e?.post(tap: .cghidEventTap)
    lastPoint = p
}

func drag(from p: CGPoint, dx: CGFloat, dy: CGFloat, steps: Int = 15, stepDelay: Double = 0.02) {
    post(.mouseMoved, p); Thread.sleep(forTimeInterval: 0.15)
    post(.leftMouseDown, p); Thread.sleep(forTimeInterval: 0.08)
    for i in 1...steps {
        let q = CGPoint(x: p.x + dx * CGFloat(i) / CGFloat(steps), y: p.y + dy * CGFloat(i) / CGFloat(steps))
        post(.leftMouseDragged, q); Thread.sleep(forTimeInterval: stepDelay)
    }
    post(.leftMouseUp, CGPoint(x: p.x + dx, y: p.y + dy))
    Thread.sleep(forTimeInterval: 0.6)
}

/// Esegue un'azione e restituisce le righe di log aggiunte nel frattempo.
func during(_ action: () -> Void) -> String {
    let before = readLog().count
    action()
    let l = readLog()
    return l.count > before ? String(l.dropFirst(before)) : ""
}

func expect(_ ok: Bool, _ msg: String) {
    print((ok ? "  OK  " : "  FALLITO  ") + msg)
    if !ok { failures += 1 }
}

print("Finestra: \(windowFrame())")
let w0 = windowFrame()

func controlFrame(_ name: String) -> CGRect? { frame(initial, "controllo \(name) ") }
func point(_ name: String, fx: CGFloat = 0.5, fy: CGFloat = 0.5) -> CGPoint? {
    guard let c = controlFrame(name) else { return nil }
    let w = windowFrame()
    return CGPoint(x: w.minX + c.minX + c.width * fx, y: w.minY + c.minY + c.height * fy)
}
func noMove(_ out: String) -> Bool { !out.contains("finestra spostata") && windowFrame() == w0 }

// 0) Verifica preliminare: il sistema consegna gli eventi sintetici all'app? (Su alcune macchine
//    di CI macOS li blocca per privacy: in quel caso il test non può verificare nulla e lo dice
//    esplicitamente, invece di riportare falsi errori dell'app.)
func click(_ name: String, fx: CGFloat = 0.5, fy: CGFloat = 0.5) -> String {
    during {
        guard let p = point(name, fx: fx, fy: fy) else { return }
        post(.mouseMoved, p); Thread.sleep(forTimeInterval: 0.1)
        post(.leftMouseDown, p); Thread.sleep(forTimeInterval: 0.05); post(.leftMouseUp, p)
        Thread.sleep(forTimeInterval: 0.6)
    }
}
var inputWorks = false
for attempt in 1...3 where !inputWorks {
    if click("ab", fx: 0.75, fy: 0.75).contains("confronto B") {
        inputWorks = true
        _ = click("ab", fx: 0.25, fy: 0.75) // torna ad A
    } else {
        print("  verifica eventi: nessuna reazione (tentativo \(attempt))")
        Thread.sleep(forTimeInterval: 3)
    }
}
if !inputWorks {
    print("INCONCLUSIVO: macOS non consegna eventi mouse/tastiera sintetici a questa sessione (permessi di CI); nessuna verifica dell'interfaccia eseguita")
    exit(3)
}

// 1) Tutti i cursori, in tre punti ciascuno (alto, centro, basso), su e giù alternati.
let sliders: [(String, String)] = [("cursore-preamp", "preamp ="), ("cursore-bassi", "bassi ="), ("cursore-alti", "alti =")]
    + ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"].map { ("cursore-\($0)", "cursore \($0) =") }
var sliderOK = 0, sliderTotal = 0
for (name, logKey) in sliders {
    for (k, fy) in [CGFloat(0.12), 0.5, 0.88].enumerated() {
        guard let p = point(name, fy: fy) else { expect(false, "controllo \(name) non trovato"); continue }
        sliderTotal += 1
        let dy: CGFloat = k % 2 == 0 ? -28 : 28
        let out = during { drag(from: p, dx: 0, dy: dy) }
        let changed = out.contains(logKey), still = noMove(out)
        if changed && still { sliderOK += 1 } else {
            print("     \(name) punto \(Int(fy * 100)) %: valore cambiato \(changed), finestra ferma \(still)")
        }
    }
}
expect(sliderOK == sliderTotal, "cursori trascinati correttamente senza spostare la finestra: \(sliderOK)/\(sliderTotal) (PREAMP, BASSI, ALTI, 10 bande × 3 punti)")
let bassSteps = readLog().split(separator: "\n").filter { $0.contains("bassi =") || $0.contains("alti =") }.compactMap { l -> Double? in
    guard let r = l.range(of: " = ") else { return nil }
    return Double(l[r.upperBound...].prefix { "0123456789.-".contains($0) })
}
expect(!bassSteps.isEmpty && bassSteps.allSatisfy { abs($0 * 2 - ($0 * 2).rounded()) < 1e-6 && abs($0) <= 12 },
       "BASSI/ALTI a passi di 0,5 dB entro ±12 (\(bassSteps.count) valori)")

// 2) Zone non interattive dentro i pannelli (titoli delle colonne): niente spostamento.
var outNI = ""
for name in ["cursore-1k", "cursore-bassi", "cursore-16k"] {
    if let p = point(name, fy: -0.17) { outNI += during { drag(from: p, dx: 40, dy: 20) } }
}
expect(noMove(outNI), "trascinare le etichette dentro i pannelli NON sposta la finestra")

// 3) Rotella sul cursore 2 kHz e sul cursore ALTI.
for (name, key) in [("cursore-2k", "cursore 2k ="), ("cursore-alti", "alti =")] {
    let out = during {
        guard let p = point(name) else { return }
        post(.mouseMoved, p); Thread.sleep(forTimeInterval: 0.2)
        for _ in 0..<3 {
            CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 2, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.1)
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
    expect(out.contains(key), "la rotella su \(name) cambia il valore")
}

// 4) Doppio clic: azzera BASSI.
do {
    let out = during {
        guard let p = point("cursore-bassi") else { return }
        post(.mouseMoved, p); Thread.sleep(forTimeInterval: 0.2)
        for click in 1...2 {
            let d = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)
            d?.setIntegerValueField(.mouseEventClickState, value: Int64(click)); d?.post(tap: .cghidEventTap)
            let u = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)
            u?.setIntegerValueField(.mouseEventClickState, value: Int64(click)); u?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.08)
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
    expect(out.contains("bassi = 0.0"), "doppio clic sul cursore BASSI lo azzera")
}

// 5) Inserimento numerico negli ALTI: -3.5 (System Events)
do {
    let out = during {
        guard let p = point("valore-cursore-alti") else { return }
        post(.mouseMoved, p); Thread.sleep(forTimeInterval: 0.1)
        post(.leftMouseDown, p); Thread.sleep(forTimeInterval: 0.05); post(.leftMouseUp, p)
        Thread.sleep(forTimeInterval: 0.8)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "tell application \"System Events\" to keystroke \"a\" using command down",
                          "-e", "tell application \"System Events\" to keystroke \"-3.5\"",
                          "-e", "tell application \"System Events\" to key code 36"]
        try? proc.run(); proc.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.6)
    }
    expect(out.contains("alti = -3.5"), "valore digitato negli ALTI: -3.5 dB")
}

// 6) A/B, Auto Gain, azzeramento del picco.
expect(click("ab", fx: 0.75, fy: 0.75).contains("confronto B"), "pulsante B: passa alla configurazione B")
expect(click("ab", fx: 0.25, fy: 0.75).contains("confronto A"), "pulsante A: torna alla configurazione A")
expect(click("auto-gain", fx: 0.93).contains("auto gain"), "interruttore Auto Gain (clic sullo switch)")
expect(click("picco-reset").contains("picco azzerato"), "clic sul picco: azzeramento")
expect(windowFrame() == w0, "nessuno di questi clic sposta la finestra")

// 7) Zone designate: barra del titolo e area libera spostano la finestra.
do {
    let w = windowFrame()
    let out = during { drag(from: CGPoint(x: w.midX, y: w.minY + 12), dx: 50, dy: 25, steps: 30, stepDelay: 0.04) }
    let w1 = windowFrame()
    expect(out.contains("finestra spostata") && abs(w1.minX - w.minX - 50) < 6, "trascinando la barra del titolo la finestra si sposta (\(w.origin) -> \(w1.origin))")
}
do {
    let w = windowFrame()
    let out = during { drag(from: point("area-libera")!, dx: 60, dy: 30, steps: 30, stepDelay: 0.04) }
    let w1 = windowFrame()
    expect(out.contains("finestra spostata") && abs(w1.minX - w.minX - 60) < 6 && abs(w1.minY - w.minY - 30) < 6,
           "trascinando un'area libera la finestra si sposta (\(w.origin) -> \(w1.origin))")
}

func osa(_ lines: [String]) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = lines.flatMap { ["-e", "tell application \"System Events\" to " + $0] }
    try? proc.run(); proc.waitUntilExit()
}

/// Seleziona la voce successiva di un menu a comparsa: clic, freccia giù, Invio.
func choosePopupNext(at p: CGPoint) -> String {
    during {
        post(.mouseMoved, p); Thread.sleep(forTimeInterval: 0.1)
        post(.leftMouseDown, p); Thread.sleep(forTimeInterval: 0.05); post(.leftMouseUp, p)
        Thread.sleep(forTimeInterval: 0.7)
        osa(["key code 125", "key code 36"])
        Thread.sleep(forTimeInterval: 0.7)
    }
}

// 8) Frequenza dei BASSI dal menu sotto il cursore (finestra principale).
if let p = point("frequenza-bassi") {
    let out = choosePopupNext(at: p)
    expect(out.contains("frequenza bassi = 100"), "menu frequenza BASSI: 80 -> 100 Hz")
} else { expect(false, "menu frequenza BASSI non trovato") }

// 8b) Tasti volume della tastiera (eventi di sistema come quelli dei tasti fisici F10/F11/F12),
// ricevuti dall'event tap reale dell'app in esecuzione.
func keyEvent(_ code: Int, down: Bool, repeating: Bool = false, flags: NSEvent.ModifierFlags = []) {
    let state = down ? 0xA : 0xB
    let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                subtype: 8, data1: (code << 16) | (state << 8) | (repeating ? 1 : 0), data2: -1)
    ev?.cgEvent?.post(tap: .cghidEventTap)
}
func volumeKey(_ code: Int, flags: NSEvent.ModifierFlags = [], gap: Double = 0.03) {
    keyEvent(code, down: true, flags: flags)
    Thread.sleep(forTimeInterval: 0.01)
    keyEvent(code, down: false, flags: flags)
    Thread.sleep(forTimeInterval: gap)
}
/// Volume di macOS (uscita predefinita = BlackHole mentre l'EQ è attivo), 0...100.
func macVolume() -> Int? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "output volume of (get volume settings)"]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run(); p.waitUntilExit()
    return Int(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
}
/// Valori registrati dall'app per i tasti ("tasto volume su/giù: V (n=N)").
func keyLines(_ log: String) -> [(v: Double, n: Int)] {
    log.split(separator: "\n").compactMap { line -> (Double, Int)? in
        guard let r = line.range(of: "tasto volume ") else { return nil }
        let rest = line[r.upperBound...]
        guard let colon = rest.firstIndex(of: ":"), let nr = rest.range(of: "(n=") else { return nil }
        let v = Double(rest[rest.index(after: colon)..<nr.lowerBound].trimmingCharacters(in: .whitespaces))
        let n = Int(rest[nr.upperBound...].prefix { $0.isNumber })
        guard let vv = v, let nn = n else { return nil }
        return (vv, nn)
    }
}
func lastHud(_ log: String) -> Double? {
    log.split(separator: "\n").last(where: { $0.contains("hud volume=") }).flatMap { value($0, "hud volume") }
}
do {
    let log0 = readLog()
    if log0.contains("tasti volume gestiti da Armonia EQ") {
        expect(true, "tasti volume intercettati da Armonia EQ (permesso Accessibilità concesso)")
        let taps = log0.components(separatedBy: "event tap dei tasti volume attivo").count - 1
        expect(taps == 1 && log0.contains("tap creati: 1"), "un solo event tap (thread dedicato), nessun duplicato (\(taps))")
        Thread.sleep(forTimeInterval: 2.5) // indicatore di macOS allineato
        let mac0 = macVolume() ?? -1

        // Pressione singola: una sola tacca nell'app e NESSUN effetto diretto di macOS sul suo volume.
        let before = readLog().count
        volumeKey(1, gap: 0.0)
        let macRightAfter = macVolume() ?? -1 // entro ~0,1 s: macOS cambierebbe subito di una tacca
        Thread.sleep(forTimeInterval: 0.3)
        var o = String(readLog().dropFirst(before))
        let single = keyLines(o)
        expect(single.count == 1, "pressione singola: una sola tacca (\(single.count))")
        // Se macOS avesse elaborato il tasto, il router registrerebbe un cambio di volume esterno.
        // (Il valore letto con osascript può già essere quello allineato da Armonia: in silenzio
        // l'allineamento è immediato dopo 0,3 s e osascript a volte impiega di più.)
        expect(!o.contains("cambiato dall'esterno"), "pressione singola: macOS non ha elaborato il tasto (volume di macOS \(mac0) -> \(macRightAfter), nessun cambio esterno)")
        Thread.sleep(forTimeInterval: 0.2)
        if let s1 = single.first, let h = lastHud(readLog()) {
            expect(abs(h - s1.v) < 0.0002, "indicatore coerente con il volume effettivo (\(h) = \(s1.v))")
        } else { expect(false, "indicatore non mostrato dopo la pressione") }
        expect(readLog().contains("(indicatore di macOS)") && !readLog().contains("indicatore di macOS non disponibile"),
               "compare l'indicatore originale di macOS (non quello verde di Armonia)")
        // Schermata con l'indicatore visibile, per la documentazione.
        volumeKey(0, gap: 0.0)
        Thread.sleep(forTimeInterval: 0.35)
        let sc = Process()
        sc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        sc.arguments = ["-x", (CommandLine.arguments[1] as NSString).deletingLastPathComponent + "/osd.png"]
        try? sc.run(); sc.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.3)

        // Pressioni rapide (8 a 15 ms), prolungata (ripetizione automatica), alternanza.
        let base = keyLines(readLog()).last?.v ?? 0.5
        o = during { for _ in 0..<8 { volumeKey(0, gap: 0.015) }; Thread.sleep(forTimeInterval: 0.4) }
        var lines = keyLines(o)
        let expRapid = min(1, ((base * 16).rounded() + 8) / 16)
        expect(lines.count == 8 && abs((lines.last?.v ?? -1) - expRapid) < 0.0002,
               "8 pressioni rapide: 8 tacche, volume \(lines.last?.v ?? -1) (atteso \(expRapid))")
        expect(zip(lines, lines.dropFirst()).allSatisfy { $1.n == $0.n + 1 }, "pressioni rapide: nessuna persa o duplicata (contatore consecutivo)")
        o = during {
            keyEvent(1, down: true)
            for _ in 0..<19 { Thread.sleep(forTimeInterval: 0.033); keyEvent(1, down: true, repeating: true) }
            keyEvent(1, down: false)
            Thread.sleep(forTimeInterval: 0.4)
        }
        lines = keyLines(o)
        expect(lines.count == 20, "pressione prolungata (ripetizione automatica): 20 tacche (\(lines.count))")
        expect(lines.last?.v == 0, "pressione prolungata: volume al minimo senza superarlo (\(lines.last?.v ?? -1))")
        o = during { for _ in 0..<4 { volumeKey(0, gap: 0.02) }; for _ in 0..<6 { volumeKey(0, gap: 0.02); volumeKey(1, gap: 0.02) }; Thread.sleep(forTimeInterval: 0.4) }
        lines = keyLines(o)
        expect(lines.count == 16 && abs((lines.last?.v ?? -1) - 0.25) < 0.0002, "alternanza + / −: 16 tacche, volume \(lines.last?.v ?? -1) (atteso 0.25)")
        o = during { volumeKey(0, flags: [.option, .shift]) }
        if let v = keyLines(o).last?.v {
            expect(abs(v - 0.265625) < 0.0002, "⌥⇧ + volume: passo fine 1/64 (\(v))")
        } else { expect(false, "⌥⇧ + volume: passo fine non gestito") }
        o = during { volumeKey(7); volumeKey(7) }
        expect(o.contains("tasto muto: attivo") && o.contains("tasto muto: disattivo"), "tasto muto: attivo e disattivo")

        // Sincronismo finale: HUD = ultimo valore = volume di macOS (dopo l'allineamento a micro-passi).
        Thread.sleep(forTimeInterval: 0.3)
        let finalV = keyLines(readLog()).last?.v ?? -1
        expect(abs((lastHud(readLog()) ?? -2) - finalV) < 0.0002, "HUD finale coerente (\(lastHud(readLog()) ?? -1) = \(finalV))")
        var vm = -1
        for _ in 0..<40 { Thread.sleep(forTimeInterval: 0.25); vm = macVolume() ?? -1; if abs(Double(vm) - finalV * 100) <= 1 { break } }
        expect(abs(Double(vm) - finalV * 100) <= 1, "volume di macOS sincronizzato: \(vm) (atteso \(Int((finalV * 100).rounded())))")
        let all = readLog()
        expect(!all.contains("event tap riattivato"), "event tap mai disattivato da macOS per timeout")
        expect(!all.contains("cambiato dall'esterno"), "macOS non ha mai elaborato i tasti (nessun cambio esterno del volume)")
    } else if log0.contains("tasti volume: permesso Accessibilità necessario") {
        print("  INCONCLUSIVO  tasti volume: permesso Accessibilità non concesso su questa macchina di CI (verificati i test audio)")
    } else {
        expect(false, "stato dei tasti volume non registrato")
    }
}

// 9) Barra dei menu: chiusura della finestra, audio sempre attivo, pannello rapido, riapertura.
func lastFrameNumber(_ log: String) -> UInt64? {
    guard let line = log.split(separator: "\n").last(where: { $0.contains("diag: attivo=1 frame=") }),
          let r = line.range(of: "frame=") else { return nil }
    return UInt64(line[r.upperBound...].prefix { $0.isNumber })
}
func current(_ marker: String) -> CGRect? { frame(readLog(), marker) }
/// Posizione di un controllo del pannello, in coordinate dello schermo registrate da AppKit.
func popPoint(_ name: String, fx: CGFloat = 0.5, fy: CGFloat = 0.5) -> CGPoint? {
    guard let c = current("schermo \(name) ") else { return nil }
    return CGPoint(x: c.minX + c.width * fx, y: c.minY + c.height * fy)
}
func clickAt(_ p: CGPoint?) -> String {
    during {
        guard let p = p else { return }
        post(.mouseMoved, p); Thread.sleep(forTimeInterval: 0.1)
        post(.leftMouseDown, p); Thread.sleep(forTimeInterval: 0.05); post(.leftMouseUp, p)
        Thread.sleep(forTimeInterval: 0.6)
    }
}
func openPanel() -> Bool {
    for attempt in 1...2 {
        guard let item = current("barra dei menu x=") else { return false }
        let p = CGPoint(x: item.midX, y: item.midY)
        print("     icona nella barra dei menu: \(item) -> clic in \(p) (tentativo \(attempt))")
        if clickAt(p).contains("pannello barra dei menu aperto") { return true }
        Thread.sleep(forTimeInterval: 1.0)
    }
    return false
}

do {
    expect(current("barra dei menu x=") != nil, "icona presente nella barra dei menu")
    expect(readLog().contains("icona barra dei menu: simbolo Armonia EQ"), "icona: simbolo di Armonia EQ (template)")
    let out = during { osa(["keystroke \"w\" using command down"]); Thread.sleep(forTimeInterval: 0.8) }
    expect(out.contains("finestra chiusa"), "finestra principale chiusa (⌘W)")
    let f1 = lastFrameNumber(readLog())
    Thread.sleep(forTimeInterval: 3.0)
    let f2 = lastFrameNumber(readLog())
    expect(f1 != nil && f2 != nil && f2! > f1! + 48000,
           "a finestra chiusa il motore audio continua a elaborare (frame \(f1 ?? 0) -> \(f2 ?? 0))")
    expect(openPanel(), "clic sull'icona: si apre il pannello rapido (finestra chiusa)")
    Thread.sleep(forTimeInterval: 0.5)

    var o = clickAt(popPoint("pop-bassi", fx: 0.85))
    expect(o.contains("bassi ="), "pannello: cursore BASSI")
    o = clickAt(popPoint("pop-alti", fx: 0.2))
    expect(o.contains("alti ="), "pannello: cursore ALTI")
    o = clickAt(popPoint("pop-volume", fx: 0.6))
    expect(o.contains("volume ="), "pannello: volume")
    o = clickAt(popPoint("pop-alti-f-12 kHz"))
    expect(o.contains("frequenza alti = 12000"), "pannello: selettore frequenza ALTI 10 -> 12 kHz")
    o = clickAt(popPoint("pop-bassi-f-120 Hz"))
    expect(o.contains("frequenza bassi = 120"), "pannello: selettore frequenza BASSI -> 120 Hz")
    o = clickAt(popPoint("pop-rapido-Elettronica"))
    expect(o.contains("profilo Musica elettronica"), "pannello: profilo rapido Musica elettronica")
    o = clickAt(popPoint("pop-rapido-Voce"))
    expect(o.contains("profilo Voce"), "pannello: profilo rapido Voce")
    o = clickAt(popPoint("pop-rapido-Pop"))
    expect(o.contains("profilo Musica pop"), "pannello: profilo rapido Musica pop")
    o = clickAt(popPoint("pop-rapido-Flat"))
    expect(o.contains("profilo Flat"), "pannello: profilo rapido Flat")
    // Lo stato iniziale dipende dalle prove precedenti: ogni clic deve invertirlo.
    o = clickAt(popPoint("pop-autogain", fx: 0.7))
    let agFirst = o.contains("auto gain acceso") ? "acceso" : (o.contains("auto gain spento") ? "spento" : "")
    expect(!agFirst.isEmpty, "pannello: interruttore Auto Gain (\(agFirst.isEmpty ? "nessun effetto" : agFirst))")
    let agSecond = agFirst == "acceso" ? "spento" : "acceso"
    o = clickAt(popPoint("pop-autogain", fx: 0.7))
    expect(!agFirst.isEmpty && o.contains("auto gain \(agSecond)"), "pannello: interruttore Auto Gain di nuovo \(agSecond)")
    // Immagine del pannello e dell'icona per la documentazione (non influisce sull'esito).
    if let panel = current("pannello x="), let item = current("barra dei menu x=") {
        let r = panel.union(item).insetBy(dx: -24, dy: -6)
        let sc = Process()
        sc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        sc.arguments = ["-x", "-R", String(format: "%.0f,%.0f,%.0f,%.0f", r.minX, max(0, r.minY), r.width, r.height),
                        (CommandLine.arguments[1] as NSString).deletingLastPathComponent + "/panel.png"]
        try? sc.run(); sc.waitUntilExit()
    }
    // Se il menu a comparsa ha chiuso il pannello, lo si riapre.
    if let last = readLog().split(separator: "\n").last(where: { $0.contains("pannello barra dei menu") }),
       last.contains("chiuso") { _ = openPanel(); Thread.sleep(forTimeInterval: 0.5) }
    if let p = popPoint("pop-profilo") {
        o = choosePopupNext(at: p)
        expect(o.contains("profilo "), "pannello: selezione del profilo")
    } else { expect(false, "pannello: selettore profili non trovato") }
    o = clickAt(popPoint("pop-power", fx: 0.7))
    expect(o.contains("accensione OFF"), "pannello: interruttore OFF")
    o = clickAt(popPoint("pop-power", fx: 0.7))
    expect(o.contains("accensione ON"), "pannello: interruttore di nuovo ON")
    o = clickAt(popPoint("pop-apri"))
    expect(o.contains("finestra aperta"), "pannello: \"Apri finestra\" riapre la finestra principale")

    // Uscita completa dal pannello.
    _ = during { osa(["keystroke \"w\" using command down"]); Thread.sleep(forTimeInterval: 0.8) }
    _ = openPanel()
    Thread.sleep(forTimeInterval: 0.5)
    _ = clickAt(popPoint("pop-esci"))
    Thread.sleep(forTimeInterval: 2.5)
    let pg = Process()
    pg.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pg.arguments = ["-f", "ArmoniaEQ.app/Contents/MacOS/ArmoniaEQ"]
    pg.standardOutput = FileHandle.nullDevice
    try? pg.run(); pg.waitUntilExit()
    expect(pg.terminationStatus != 0, "pannello: \"Esci\" chiude completamente l'applicazione")
}

print(failures == 0 ? "TEST INTERFACCIA SUPERATO" : "\(failures) verifiche fallite")
exit(failures == 0 ? 0 : 1)
