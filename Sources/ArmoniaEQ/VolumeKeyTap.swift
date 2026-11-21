import AppKit
import ApplicationServices

enum VolumeKeysState: Equatable {
    /// Motore spento: i tasti volume agiscono direttamente sul dispositivo (comportamento di macOS).
    case inactive
    /// Tasti gestiti da Armonia EQ: volume applicato dal DSP con rampa, nessun click.
    case active
    /// Serve il permesso Accessibilità; nel frattempo i tasti cambiano il volume di BlackHole.
    case needsPermission
}

/// Intercetta i tasti volume della tastiera (eventi di sistema NX_SYSDEFINED, sottotipo 8) con un
/// event tap di Core Graphics (macOS 12+, permesso Accessibilità).
///
/// Il tap vive su un THREAD DEDICATO ad alta priorità, con il proprio run loop. Prima era sul main
/// thread: quando l'interfaccia era occupata (spettro, ridisegno, HUD) la callback rispondeva in
/// ritardo, macOS disattivava il tap per timeout e lasciava passare i tasti a sé stesso. Effetti:
/// indicatore di Apple insieme a quello di Armonia, salto del volume di BlackHole, comandi in ritardo
/// o persi. Ora la callback fa solo: decodifica -> handler (stato autoritativo nel router, sotto lock,
/// pochi microsecondi) -> decisione consuma/inoltra. Nessun accesso all'interfaccia.
final class VolumeKeyTap {
    /// Chiamato sul thread del tap. true = tasto gestito (l'evento NON prosegue verso macOS).
    /// Deve essere impostato prima di start() e non modificato dopo.
    var handler: ((VolumeKey, Bool) -> Bool)?
    /// Registro diagnostico (thread qualsiasi).
    var log: ((String) -> Void)?
    private var tap: CFMachPort?
    private var thread: Thread?
    /// Tasti il cui "giù" è stato gestito: anche il rilascio non deve arrivare a macOS (solo thread del tap).
    private var consumedKeys: Set<Int> = []
    private let statsLock = NSLock()
    private var _timeouts = 0
    private var _passedThrough = 0
    private var _consumed = 0

    /// Numero di event tap creati da tutte le istanze (diagnostica: deve restare 1).
    private(set) static var tapsCreated = 0

    var isActive: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    /// Diagnostica: riattivazioni dopo timeout, eventi lasciati a macOS, eventi consumati.
    var stats: (timeouts: Int, passed: Int, consumed: Int) {
        statsLock.lock(); defer { statsLock.unlock() }
        return (_timeouts, _passedThrough, _consumed)
    }

    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Installa il tap (idempotente: un solo tap e un solo thread per tutta la vita dell'app).
    /// false se macOS lo rifiuta (permesso mancante).
    @discardableResult
    func start() -> Bool {
        if let t = tap {
            if !CGEvent.tapIsEnabled(tap: t) { CGEvent.tapEnable(tap: t, enable: true) }
            return true
        }
        let mask = CGEventMask(1) << 14 // NX_SYSDEFINED
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: VolumeKeyTap.callback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = t
        VolumeKeyTap.tapsCreated += 1
        let ready = DispatchSemaphore(value: 0)
        let th = Thread {
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        th.name = "it.armoniaeq.tasti-volume"
        th.qualityOfService = .userInteractive
        thread = th
        th.start()
        ready.wait()
        log?("event tap dei tasti volume attivo (thread dedicato, tap creati: \(VolumeKeyTap.tapsCreated))")
        return true
    }

    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
        let me = Unmanaged<VolumeKeyTap>.fromOpaque(refcon).takeUnretainedValue()
        return me.handle(type: type, event: event)
    }

    private func count(_ body: () -> Void) { statsLock.lock(); body(); statsLock.unlock() }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disattiva un tap che non risponde in tempo: lo si riattiva e lo si registra.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            count { _timeouts += 1 }
            log?("event tap riattivato (\(type == .tapDisabledByTimeout ? "timeout" : "utente"))")
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let code = (ns.data1 & 0xFFFF0000) >> 16
        let state = (ns.data1 & 0xFF00) >> 8
        let key: VolumeKey
        switch code {
        case 0: key = .up    // NX_KEYTYPE_SOUND_UP
        case 1: key = .down  // NX_KEYTYPE_SOUND_DOWN
        case 7: key = .mute  // NX_KEYTYPE_MUTE
        default: return Unmanaged.passUnretained(event)
        }
        let f = event.flags
        let option = f.contains(.maskAlternate), shift = f.contains(.maskShift)
        let other = f.contains(.maskCommand) || f.contains(.maskControl)
        // ⌥ da solo + tasto volume apre le Impostazioni Suono: lo lascia a macOS.
        if option && !shift && !other {
            count { _passedThrough += 1 }
            return Unmanaged.passUnretained(event)
        }
        if state == 0xA { // tasto premuto (anche ripetizione automatica): una pressione = una tacca
            if handler?(key, option && shift) == true {
                consumedKeys.insert(code)
                count { _consumed += 1 }
                return nil
            }
            consumedKeys.remove(code)
            count { _passedThrough += 1 }
            return Unmanaged.passUnretained(event)
        }
        if state == 0xB, consumedKeys.remove(code) != nil { return nil } // rilascio di un tasto gestito
        return Unmanaged.passUnretained(event)
    }
}
