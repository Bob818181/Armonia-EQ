import ArmoniaDSP
import AudioToolbox
import CoreAudio
import Foundation

/// Instradamento dell'audio di sistema:
///
///   App (Safari, Music, YouTube…) ──> uscita predefinita = driver loopback (BlackHole)
///        ──> [aggregate device privato: uscita reale (clock) + loopback (drift compensation)]
///        ──> AUHAL ──> ArmoniaDSP (preamp, EQ 10 bande, volume, bilanciamento, limiter)
///        ──> dispositivo di uscita reale (altoparlanti interni, USB, …)
///
/// Su macOS 12 non esiste un'API pubblica per catturare l'audio di sistema (ScreenCaptureKit audio
/// richiede macOS 13, i "process tap" macOS 14.2): l'unica strada affidabile è un driver HAL di
/// loopback, la stessa architettura usata da eqMac con il suo driver.
/// Tasti volume della tastiera (vedi VolumeKeyTap e AudioRouter.handleKey).
enum VolumeKey { case up, down, mute }

final class AudioRouter {
    static let aggregateUIDPrefix = "it.armoniaeq.engine"

    struct RunningInfo: Equatable {
        let outputName: String
        let sampleRate: Double
        let bufferFrames: UInt32
        let latencyMs: Double
        /// true: i tasti volume di macOS regolano il volume hardware del dispositivo di uscita.
        var hardwareVolume = false
        /// Dispositivo reale che riceve l'audio (UID Core Audio) e descrizione per l'interfaccia.
        var outputUID = ""
        var outputDetail = ""
    }

    /// UID dei sotto-dispositivi attivi dell'aggregate in uso (uscita reale + loopback). Vuoto a motore spento.
    var activeSubdeviceUIDs: [String] {
        guard aggregateID != 0 else { return [] }
        return CA.getArray(aggregateID, CA.address(kAudioAggregateDevicePropertyActiveSubDeviceList),
                           of: AudioObjectID.self, zero: 0).compactMap { CA.getString($0, kAudioDevicePropertyDeviceUID) }
    }

    let dsp: OpaquePointer
    private(set) var running: RunningInfo?
    private(set) var outputDevice: AudioDevice?
    private(set) var loopbackDevice: AudioDevice?

    private var aggregateID: AudioObjectID = 0
    private var unit: AudioUnit?
    private var renderContext: OpaquePointer?
    private var sampleRateListenerActive = false
    private var sampleRateListenerDevice: AudioObjectID = 0

    // Ponte volume: BlackHole moltiplica l'audio catturato per il proprio volume (legge in dB
    // lineare -64...0: 50 % = -32 dB, 25 % = -48 dB). Mentre l'EQ è attivo quel guadagno viene
    // annullato all'ingresso del DSP e il volume dell'utente è applicato dal DSP (vedi "Ponte volume").
    private struct SavedVolume { let scalar: Float32?; let muted: Bool? }
    private var savedLoopbackVolume: SavedVolume?
    // Listener con l'API a puntatore di funzione C: la rimozione è deterministica (stessa funzione
    // + stesso contesto). Con l'API a blocchi, da Swift la rimozione può fallire in silenzio e il
    // ponte resterebbe attivo anche a EQ spento.
    private var volumeListeners: [(AudioObjectID, AudioObjectPropertyAddress)] = []
    private var bridgeLoopback: AudioDeviceID = 0
    private var bridgeOutput: AudioDeviceID = 0
    private var bridgeHardware = false
    /// Solo per i test: false riproduce il comportamento precedente (volume di BlackHole applicato).
    var volumeBridgeEnabled = true

    /// Guadagno di cattura attuale del loopback in dB (per diagnostica). nil se non attivo.
    var loopbackCaptureGainDb: Float? {
        guard bridgeLoopback != 0 else { return nil }
        let g = CA.loopbackCaptureGain(bridgeLoopback)
        return g > 0 ? 20 * log10(g) : -.infinity
    }

    /// Chiamato (sul main thread) quando la frequenza di campionamento dell'uscita cambia.
    var onConfigurationChange: (() -> Void)?

    /// 512 campioni (≈10,7 ms a 48 kHz): margine contro i dropout con picchi di CPU,
    /// latenza totale ≈25 ms (sotto la soglia percepibile per il sincronismo audio/video).
    var preferredBufferFrames: UInt32 = 512

    init() {
        guard let engine = aeq_create(48000) else { fatalError("Impossibile creare il motore DSP") }
        dsp = engine
    }

    deinit {
        stop(restoreDefaultOutput: true)
        aeq_destroy(dsp)
    }

    var renderErrors: Int {
        renderContext.map { Int(aeq_render_error_count($0)) } ?? 0
    }

    // MARK: Avvio

    /// Volume hardware dell'uscita nei vari passi dell'avvio (diagnostica).
    private(set) var startTrace = ""

    /// `initialVolume`: volume dell'utente da usare (es. dopo una chiusura anomala, quando il volume
    /// hardware è rimasto al 100 %); nil = volume attuale del dispositivo di uscita.
    func start(output: AudioDevice, loopback: AudioDevice, initialVolume: Float32? = nil) throws {
        teardown()
        // Con il ponte volume il DSP parte da guadagno 0 e sale con la rampa quando tutto è pronto
        // (fino ad allora i tasti aggiornano lo stato ma non il DSP).
        if volumeBridgeEnabled {
            locked { _fadedOut = true }
            aeq_set_volume(dsp, 0)
        }
        // Volume del dispositivo reale PRIMA di qualsiasi modifica: è il volume scelto dall'utente.
        let originalOutputVolume = CA.volumeScalar(output.id, scope: .output)
        var trace: [String] = []
        func mark(_ step: String) {
            let v = CA.volumeScalar(output.id, scope: .output).map { String(format: "%.3f", $0) } ?? "-"
            let l = CA.volumeScalar(loopback.id, scope: .output).map { String(format: "%.3f", $0) } ?? "-"
            trace.append("\(step): uscita \(v), loopback \(l)")
        }
        mark("inizio")

        let sampleRate = CA.nominalSampleRate(output.id) ?? 48000
        // Porta il loopback alla stessa frequenza dell'uscita: la compensazione di deriva dell'aggregate
        // corregge solo la piccola differenza di clock, non una conversione di frequenza.
        if let loopRate = CA.nominalSampleRate(loopback.id), abs(loopRate - sampleRate) > 0.5,
           CA.supportsSampleRate(loopback.id, sampleRate) {
            CA.setNominalSampleRate(loopback.id, sampleRate)
        }

        // 1) Aggregate device privato (invisibile alle altre app, distrutto all'uscita del processo).
        let aggregateUID = "\(AudioRouter.aggregateUIDPrefix).\(UUID().uuidString)"
        let description: [String: Any] = [
            "name": "ArmoniaEQ Engine",
            "uid": aggregateUID,
            "private": 1,
            "stacked": 0,
            "master": output.uid,
            "clock": output.uid,
            "subdevices": [
                ["uid": output.uid, "drift": 0],
                ["uid": loopback.uid, "drift": 1, "drift quality": 0x7F],
            ],
        ]
        var agg: AudioObjectID = 0
        var status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &agg)
        guard status == noErr, agg != 0 else {
            throw CoreAudioError("Impossibile creare il dispositivo aggregato", status)
        }
        aggregateID = agg
        mark("aggregate creato")

        do {
            try configureAndStart(aggregate: agg, output: output, loopback: loopback, sampleRate: sampleRate)
        } catch {
            teardown()
            throw error
        }

        // 2) Il volume del loopback non deve attenuare il segnale (vedi ponte volume).
        mark("AUHAL avviata")

        // 3) Tutto l'audio di sistema va nel loopback.
        status = CA.setDefaultOutputDevice(loopback.id)
        if status != noErr {
            teardown()
            throw CoreAudioError("Impossibile impostare \(loopback.name) come uscita di sistema", status)
        }
        mark("uscita di sistema = loopback")
        // Il volume del loopback non deve attenuare il segnale e il volume del dispositivo reale
        // non deve cambiare (vedi ponte volume).
        if volumeBridgeEnabled {
            installVolumeBridge(output: output, loopback: loopback, originalOutputVolume: originalOutputVolume,
                                initialVolume: initialVolume)
            mark("ponte volume attivo")
            // I cambi di volume di BlackHole e dell'hardware sono avvenuti a guadagno zero; quando sono
            // sicuramente effettivi, il volume sale con la rampa del DSP (dissolvenza d'avvio).
            Thread.sleep(forTimeInterval: 0.08)
            locked {
                _fadedOut = false
                applyDSPLocked()
            }
        }
        startTrace = trace.joined(separator: " → ")
        outputDevice = output
        loopbackDevice = loopback
        installSampleRateListener(on: output.id)
    }

    private func configureAndStart(aggregate agg: AudioObjectID, output: AudioDevice, loopback: AudioDevice,
                                   sampleRate: Double) throws {
        let outputIn = CA.channelCount(output.id, scope: .input)
        let outputOut = CA.channelCount(output.id, scope: .output)
        let loopIn = CA.channelCount(loopback.id, scope: .input)
        guard loopIn >= 1 else { throw CoreAudioError("\(loopback.name) non ha canali di ingresso") }
        guard outputOut >= 1 else { throw CoreAudioError("\(output.name) non ha canali di uscita") }

        // L'aggregate pubblica i sotto-dispositivi in modo asincrono: attende che i canali compaiano.
        var aggIn = 0, aggOut = 0
        for _ in 0..<40 {
            aggIn = CA.channelCount(agg, scope: .input)
            aggOut = CA.channelCount(agg, scope: .output)
            if aggIn >= outputIn + loopIn && aggOut >= outputOut { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard aggIn >= outputIn + loopIn, aggOut >= outputOut else {
            throw CoreAudioError("Il dispositivo aggregato non è pronto (ingressi \(aggIn), uscite \(aggOut))")
        }
        // L'aggregate deve contenere ESATTAMENTE il dispositivo reale scelto (driver nativo) e il loopback:
        // l'audio va direttamente al dispositivo selezionato, nessun altro dispositivo lo riceve.
        let subs = activeSubdeviceUIDs
        guard subs.count == 2, subs.contains(output.uid), subs.contains(loopback.uid) else {
            throw CoreAudioError("Composizione del dispositivo aggregato inattesa: \(subs)")
        }
        if abs((CA.nominalSampleRate(agg) ?? sampleRate) - sampleRate) > 0.5 {
            CA.setNominalSampleRate(agg, sampleRate)
        }
        CA.setBufferFrameSize(agg, preferredBufferFrames)

        // I canali dell'aggregate sono concatenati nell'ordine dei sotto-dispositivi:
        // ingressi = [ingressi dell'uscita reale (es. microfono USB)] + [loopback]
        // uscite   = [uscite reali] + [uscite del loopback (lasciate a zero: niente feedback)]
        let loopLeft = UInt32(outputIn)
        let loopRight = UInt32(loopIn >= 2 ? outputIn + 1 : outputIn)
        var (outL, outR) = CA.preferredStereoChannels(output.id) ?? (0, 1)
        if outL >= outputOut { outL = 0 }
        if outR >= outputOut { outR = min(1, outputOut - 1) }
        let mono: Int32 = outputOut == 1 ? 1 : 0

        // AUHAL con ingresso e uscita sullo stesso dispositivo (un solo clock, nessun ring buffer).
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw CoreAudioError("Componente AUHAL non trovato")
        }
        var newUnit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &newUnit)
        guard status == noErr, let au = newUnit else { throw CoreAudioError("AudioComponentInstanceNew", status) }
        unit = au

        func set<T>(_ prop: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement,
                    _ value: T, _ what: String) throws {
            var v = value
            let st = withUnsafeBytes(of: &v) { raw in
                AudioUnitSetProperty(au, prop, scope, element, raw.baseAddress, UInt32(raw.count))
            }
            if st != noErr { throw CoreAudioError(what, st) }
        }

        try set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1), "Abilitazione ingresso")
        try set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(1), "Abilitazione uscita")
        try set(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, agg, "Selezione dispositivo")

        func format(_ channels: Int) -> AudioStreamBasicDescription {
            AudioStreamBasicDescription(mSampleRate: sampleRate,
                                        mFormatID: kAudioFormatLinearPCM,
                                        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                                            | kAudioFormatFlagIsNonInterleaved,
                                        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                        mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        }
        try set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, format(aggIn), "Formato ingresso")
        try set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, format(aggOut), "Formato uscita")
        let maxFrames: UInt32 = 4096
        try set(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, maxFrames, "Dimensione massima buffer")

        guard let ctx = aeq_render_create(dsp, UInt32(aggIn), loopLeft, loopRight, UInt32(outL), UInt32(outR),
                                          mono, maxFrames) else {
            throw CoreAudioError("Memoria insufficiente per il rendering")
        }
        renderContext = ctx
        aeq_render_set_unit(ctx, au)
        try set(kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                AURenderCallbackStruct(inputProc: aeq_render_callback, inputProcRefCon: UnsafeMutableRawPointer(ctx)),
                "Callback di rendering")

        aeq_prepare(dsp, sampleRate)

        status = AudioUnitInitialize(au)
        guard status == noErr else { throw CoreAudioError("AudioUnitInitialize", status) }
        status = AudioOutputUnitStart(au)
        guard status == noErr else { throw CoreAudioError("Avvio dell'unità audio", status) }

        let frames = CA.bufferFrameSize(agg) ?? preferredBufferFrames
        let latencyFrames = Double(frames) * 2
            + Double(CA.latencyFrames(output.id, scope: .output))
            + Double(CA.latencyFrames(loopback.id, scope: .input))
        let fresh = CA.device(output.id) ?? output
        running = RunningInfo(outputName: fresh.displayName, sampleRate: sampleRate, bufferFrames: frames,
                              latencyMs: latencyFrames / sampleRate * 1000,
                              hardwareVolume: CA.hasSettableVolume(output.id, scope: .output),
                              outputUID: output.uid,
                              outputDetail: "\(fresh.displayName) · \(fresh.transportLabel) · \(fresh.driverLabel) · UID \(output.uid)")
    }

    // MARK: Arresto

    /// Ferma il motore. Con `restoreDefaultOutput` riporta l'uscita di sistema sul dispositivo reale
    /// PRIMA di fermare l'elaborazione, così le app continuano a suonare senza interruzioni.
    func stop(restoreDefaultOutput: Bool) {
        // Dissolvenza, poi volume hardware dell'uscita = volume dell'utente, POI cambio di uscita:
        // le app riprendono direttamente sul dispositivo allo stesso volume, senza sbalzi.
        fadeOutIfRunning()
        restoreOutputHardwareVolume()
        if restoreDefaultOutput, let out = outputDevice, CA.isAlive(out.id) {
            CA.setDefaultOutputDevice(out.id)
        }
        teardown()
    }

    private func teardown() {
        fadeOutIfRunning()
        removeSampleRateListener()
        removeVolumeBridge()
        if let au = unit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            unit = nil
        }
        if let ctx = renderContext {
            aeq_render_destroy(ctx)
            renderContext = nil
        }
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        running = nil
        outputDevice = nil
        loopbackDevice = nil
    }

    // MARK: Ponte volume
    //
    // Perché i tasti volume producevano un click a ogni tacca (misurato: impulso di 4 dB e residuo a
    // banda larga a -16,5 dB): macOS cambiava il volume di BlackHole, che lo applica ISTANTANEAMENTE ai
    // campioni catturati; la compensazione 1/g arrivava dal listener 8-25 ms dopo (in modo variabile) e il
    // volume veniva poi copiato sul volume hardware dell'uscita: tre gradini non sincronizzati per tacca.
    //
    // Ora il volume dell'utente è applicato in UN solo punto: il guadagno del DSP, con rampa (~40 ms).
    // - Il volume hardware dell'uscita resta fisso (100 %) mentre l'EQ è attivo e torna al volume
    //   dell'utente allo spegnimento: nessun gradino nel dispositivo.
    // - I tasti volume sono gestiti dall'app (VolumeKeyTap): il guadagno di BlackHole non cambia a scatti.
    // - Il volume di macOS (BlackHole, mostrato da Centro di Controllo) segue il volume dell'utente con
    //   micro-passi di 0,005 dB, compensati: inudibili.
    // - Cambi esterni (Centro di Controllo, Impostazioni, tasti senza permesso Accessibilità) sono
    //   ancora possibili: diventano il nuovo volume (applicato con rampa); il gradino di BlackHole viene
    //   compensato come prima (lì un piccolo click resta inevitabile, è il driver a produrlo).

    // Architettura degli eventi (tasti volume):
    // - VolumeKeyTap riceve i tasti su un thread dedicato e chiama handleKey(): il nuovo volume è
    //   calcolato dallo stato AUTORITATIVO (sotto lock) e il guadagno del DSP è aggiornato subito
    //   (scrittura atomica). Nessuna coda, nessun main thread: niente ritardi, pressioni mai perse.
    // - L'interfaccia (cursore, HUD) riceve notifiche coalescenti: vale sempre l'ultimo valore.
    // - L'allineamento del volume di macOS (micro-passi) e i listener di BlackHole lavorano su una
    //   coda separata (displayQueue) e non possono rallentare i tasti; le notifiche dei listener sono
    //   coalescenti (al massimo un controllo in coda).

    enum VolumeSource { case keys, app, system }

    /// Curva volume -> guadagno: quella del dispositivo di uscita (stessa sonorità di prima a ogni
    /// tacca), altrimenti una curva percettiva.
    struct VolumeCurve {
        private let table: [Float32] // 0...1 in 256 passi (dB relativi al massimo)
        let source: String
        /// Curva percettiva (dispositivi senza controllo volume).
        init() {
            table = (0...256).map { i in let x = Float32(i) / 256; return x > 0 ? 40 * log10(x) : -200 }
            source = "percettiva"
        }
        /// Curva da punti (scalare, dB) misurati sul dispositivo, interpolata linearmente in dB.
        init?(points: [(Float32, Float32)], source: String) {
            let p = points.sorted { $0.0 < $1.0 }
            guard p.count >= 2, let top = p.last?.1, p.first!.0 <= 0.001, p.last!.0 >= 0.999 else { return nil }
            var t: [Float32] = []
            var k = 0
            for i in 0...256 {
                let x = Float32(i) / 256
                while k + 1 < p.count - 1 && p[k + 1].0 < x { k += 1 }
                let (x0, d0) = p[k], (x1, d1) = p[k + 1]
                let f = x1 > x0 ? (x - x0) / (x1 - x0) : 0
                t.append(d0 + (d1 - d0) * min(max(f, 0), 1) - top)
            }
            table = t
            self.source = source
        }
        func db(_ v: Float32) -> Float32 {
            let x = min(max(v, 0), 1) * 256
            let i = min(Int(x), 255), f = x - Float32(i)
            return table[i] + (table[i + 1] - table[i]) * f
        }
        func gain(_ v: Float32) -> Float32 { v <= 0 ? 0 : min(1, powf(10, db(v) / 20)) }
    }

    // MARK: Stato autoritativo del volume (protetto da stateLock, accessibile da qualsiasi thread)

    private let stateLock = NSLock()
    private var _userVolume: Float32 = 1
    private var _userMuted = false
    private var _externalMute = false      // BlackHole silenziato dall'esterno (Impostazioni)
    private var _bridgeActive = false
    private var _fadedOut = false
    private var _curve = VolumeCurve()
    private var _keyEvents = 0
    private var _lastAppliedGain: Float32 = 1
    // Notifiche all'interfaccia, coalescenti.
    private var _notifyScheduled = false
    private var _notifyFromKeys = false
    private var _notifySource: VolumeSource = .app

    private func locked<T>(_ body: () -> T) -> T {
        stateLock.lock(); defer { stateLock.unlock() }
        return body()
    }

    /// Volume dell'utente (0...1, come il volume di macOS) e mute.
    var userVolume: Float32 { locked { _userVolume } }
    var userMuted: Bool { locked { _userMuted } }
    var volumeCurve: VolumeCurve { locked { _curve } }
    /// true se il volume è gestito dal DSP (motore attivo con ponte volume).
    var volumeControlActive: Bool { locked { _bridgeActive } }
    /// Diagnostica (test): tasti gestiti, guadagno del DSP richiesto, micro-passi, cambi esterni, listener.
    var keyEventsHandled: Int { locked { _keyEvents } }
    var lastAppliedGain: Float32 { locked { _lastAppliedGain } }
    var walkerSteps: Int { displayQueue.sync { _walkerSteps } }
    var externalVolumeChanges: Int { displayQueue.sync { _externalChanges } }
    /// Diagnostica: allineamenti istantanei in silenzio e costo medio di una scrittura del volume (ms).
    var walkerJumps: Int { displayQueue.sync { _walkerJumps } }
    var walkerWriteCostMs: Double { displayQueue.sync { _walkerSteps > 0 ? _setTimeNs / Double(_walkerSteps + _walkerJumps) / 1e6 : 0 } }
    var volumeListenerCount: Int { volumeListeners.count }
    /// Chiamato sul main thread quando il volume dell'utente cambia. `fromKeys`: almeno un tasto volume
    /// dall'ultima notifica (l'app mostra l'HUD). Il valore è sempre quello più recente.
    var onUserVolumeChange: ((Float32, Bool, VolumeSource, Bool) -> Void)?
    /// Registro diagnostico (thread qualsiasi).
    var log: ((String) -> Void)?
    /// true se il volume hardware dell'uscita è stato portato al 100 % (da ripristinare).
    private(set) var hardwareVolumeRaised = false
    /// Passo dei micro-passi del volume di macOS (dB) e intervallo (s).
    /// 0,005 dB = discontinuità dello 0,06 %: sotto la soglia di click dei test (-60 dB; test [15]: -68 dB).
    static let displayStepDb: Float32 = 0.005
    static let displayStepInterval = 0.0015

    /// Applica al DSP il guadagno corrispondente allo stato (chiamare con stateLock acquisito).
    private func applyDSPLocked() {
        guard _bridgeActive, !_fadedOut else { return }
        let g = (_userMuted || _externalMute) ? 0 : _curve.gain(_userVolume)
        _lastAppliedGain = g
        aeq_set_volume(dsp, g) // scrittura atomica: il thread audio la vede al buffer successivo
    }

    /// Tasto volume (thread del tap). Restituisce false se il ponte non è attivo: il tasto prosegue
    /// verso macOS. Ogni chiamata produce esattamente una tacca.
    func handleKey(_ key: VolumeKey, fine: Bool) -> Bool {
        stateLock.lock()
        guard _bridgeActive else { stateLock.unlock(); return false }
        switch key {
        case .up, .down:
            let step: Float32 = fine ? 1.0 / 64 : 1.0 / 16
            _userVolume = min(max(((_userVolume / step).rounded() + (key == .up ? 1 : -1)) * step, 0), 1)
            _userMuted = false // come macOS: cambiare il volume toglie il muto
        case .mute:
            _userMuted.toggle()
        }
        _keyEvents += 1
        let v = _userVolume, m = _userMuted, n = _keyEvents
        applyDSPLocked()
        scheduleNotifyLocked(.keys)
        stateLock.unlock()
        retargetDisplay(v)
        if let log = log {
            switch key {
            case .up: log(String(format: "tasto volume su: %.4f (n=%d)", v, n))
            case .down: log(String(format: "tasto volume giù: %.4f (n=%d)", v, n))
            case .mute: log("tasto muto: \(m ? "attivo" : "disattivo") (n=\(n))")
            }
        }
        return true
    }

    /// Imposta il volume dell'utente (cursore dell'app o test). Sincrono e thread-safe.
    func setUserVolume(_ value: Float32, source: VolumeSource) {
        let v = min(max(value.isFinite ? value : 0, 0), 1)
        stateLock.lock()
        guard _bridgeActive else { stateLock.unlock(); return }
        _userVolume = v
        applyDSPLocked()
        scheduleNotifyLocked(source)
        stateLock.unlock()
        retargetDisplay(v)
    }

    /// Mute dell'utente: rampa del DSP verso il silenzio e ritorno immediato. Il mute di BlackHole
    /// non viene toccato (cambierebbe a gradino il segnale catturato).
    func setUserMuted(_ muted: Bool, source: VolumeSource) {
        stateLock.lock()
        guard _bridgeActive, muted != _userMuted else { stateLock.unlock(); return }
        _userMuted = muted
        applyDSPLocked()
        scheduleNotifyLocked(source)
        stateLock.unlock()
    }

    /// Guadagno (dB) corrispondente a un valore di volume, secondo la curva in uso.
    func volumeDb(_ v: Float32) -> Float32 { locked { _curve.db(v) } }

    /// Notifica coalescente all'interfaccia (chiamare con stateLock acquisito): una sola consegna in
    /// coda; la consegna legge lo stato più recente, quindi l'HUD mostra sempre il volume effettivo.
    private func scheduleNotifyLocked(_ source: VolumeSource) {
        _notifySource = source
        if source == .keys { _notifyFromKeys = true }
        guard !_notifyScheduled else { return }
        _notifyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let (v, m, src, keys) = self.locked { () -> (Float32, Bool, VolumeSource, Bool) in
                self._notifyScheduled = false
                let r = (self._userVolume, self._userMuted || self._externalMute, self._notifySource, self._notifyFromKeys)
                self._notifyFromKeys = false
                return r
            }
            self.onUserVolumeChange?(v, m, src, keys)
        }
    }

    // MARK: Volume di macOS (BlackHole): micro-passi e cambi esterni, solo su displayQueue

    // Priorità alta: con QoS "utility" macOS raggruppa i timer e i micro-passi rallentano (misurato
    // in CI: ~12 ms per passo invece di 1,5 ms). Il lavoro per passo è minimo (una scrittura).
    private let displayQueue = DispatchQueue(label: "it.armoniaeq.volume-macos", qos: .userInteractive)
    private var displayCurrent: Float32 = 1   // ultimo valore scritto da noi su BlackHole
    private var displayTarget: Float32 = 1
    private var displayStepScalar: Float32 = 0.005 / 64
    private var displayLoopback: AudioDeviceID = 0
    private var expectedMute = false
    private var walker: DispatchSourceTimer?
    private var walkerStart: DispatchWorkItem?
    private var _walkerSteps = 0
    private var _walkerJumps = 0
    private var _setTimeNs: Double = 0
    private var _externalChanges = 0
    /// Curva del volume del loopback (dB a 65 posizioni, misurata all'avvio a guadagno zero) e indirizzi
    /// della proprietà volume: ogni micro-passo costa una sola scrittura a Core Audio.
    private var loopCurveDb: [Float32] = []
    private var loopVolumeAddrs: [AudioObjectPropertyAddress] = []
    /// Controllo dei listener già in coda (coalescenza): protetto da stateLock.
    private var _listenerCheckPending = false

    /// I micro-passi partono quando la rampa del volume è conclusa (0,3 s dopo l'ultimo cambio):
    /// i due movimenti non si sovrappongono mai. Un nuovo tasto sospende i micro-passi in corso.
    private func retargetDisplay(_ v: Float32) {
        displayQueue.async { [self] in
            guard displayLoopback != 0 else { return }
            displayTarget = v
            walker?.cancel()
            walker = nil
            walkerStart?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.startWalker() }
            walkerStart = work
            displayQueue.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    private func startWalker() {
        guard walker == nil, displayLoopback != 0 else { return }
        let t = DispatchSource.makeTimerSource(queue: displayQueue)
        t.schedule(deadline: .now(), repeating: AudioRouter.displayStepInterval, leeway: .microseconds(500))
        t.setEventHandler { [weak self] in self?.walkStep() }
        walker = t
        t.resume()
    }

    private func walkStep() {
        let loop = displayLoopback
        let diff = displayTarget - displayCurrent
        guard loop != 0, abs(diff) > 1e-6 else {
            walker?.cancel()
            walker = nil
            return
        }
        // Prima di scrivere: se qualcuno ha cambiato il volume di macOS (Centro di Controllo,
        // Impostazioni…) mentre ci stavamo allineando, quel valore vince e non va sovrascritto.
        if let addr = loopVolumeAddrs.first, let now = CA.getValue(loop, addr, default: Float32(0)),
           abs(now - displayCurrent) > max(1e-5, 1.5 * displayStepScalar) {
            acceptExternalChange(volume: now, muted: CA.isMuted(loop, scope: .output) ?? expectedMute)
            return
        }
        // In silenzio (nessun audio in ingresso da ~0,5 s) un gradino non è udibile: allineamento
        // immediato. Con l'audio presente: micro-passi da 0,005 dB.
        let silent = aeq_input_envelope(dsp) < 1e-4
        if silent {
            displayCurrent = displayTarget
            _walkerJumps += 1
        } else {
            let step = min(abs(diff), displayStepScalar)
            displayCurrent += diff > 0 ? step : -step
            _walkerSteps += 1
        }
        var value = displayCurrent
        let t0 = DispatchTime.now().uptimeNanoseconds
        for addr in loopVolumeAddrs {
            var a = addr
            AudioObjectSetPropertyData(loop, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
        _setTimeNs += Double(DispatchTime.now().uptimeNanoseconds - t0)
        // Compensazione dalla curva misurata (nessuna lettura da Core Audio); senza curva, lettura diretta.
        if let g = loopGain(displayCurrent), !expectedMute {
            aeq_set_input_gain(dsp, g > 1e-6 ? 1 / g : 1)
        } else {
            updateCompensation(loop)
        }
    }

    /// Guadagno di cattura del loopback per uno scalare, dalla curva misurata all'avvio.
    private func loopGain(_ scalar: Float32) -> Float32? {
        guard loopCurveDb.count == 65 else { return nil }
        if scalar <= 0 { return 0 }
        let x = min(scalar, 1) * 64
        let i = min(Int(x), 63), f = x - Float32(i)
        return powf(10, (loopCurveDb[i] + (loopCurveDb[i + 1] - loopCurveDb[i]) * f) / 20)
    }

    /// Annulla esattamente il guadagno che il loopback applica in cattura (1/g, senza smoothing).
    private func updateCompensation(_ loop: AudioDeviceID) {
        guard loop != 0 else { return }
        let g = CA.loopbackCaptureGain(loop)
        // g = 0 (volume al minimo o mute): il segnale è già zero, non c'è nulla da compensare.
        aeq_set_input_gain(dsp, g > 1e-6 ? 1 / g : 1)
    }

    private static let volumeListenerProc: AudioObjectPropertyListenerProc = { _, _, _, context in
        guard let context = context else { return noErr }
        let router = Unmanaged<AudioRouter>.fromOpaque(context).takeUnretainedValue()
        // Coalescenza: le notifiche dei nostri micro-passi sono centinaia; basta un controllo in coda.
        let schedule: Bool = router.locked {
            if router._listenerCheckPending { return false }
            router._listenerCheckPending = true
            return true
        }
        if schedule { router.displayQueue.async { router.loopbackVolumeChanged() } }
        return noErr
    }

    /// Il volume del loopback è cambiato: se non l'abbiamo cambiato noi (micro-passi), è un cambio
    /// esterno (Centro di Controllo, Impostazioni, tasti non intercettati) e diventa il volume dell'utente.
    private func loopbackVolumeChanged() {
        locked { _listenerCheckPending = false }
        let loopID = displayLoopback
        guard loopID != 0 else { return } // ponte non attivo: callback tardiva, ignorata
        var current: Float32?
        if let addr = loopVolumeAddrs.first { current = CA.getValue(loopID, addr, default: Float32(0)) }
        let muted = CA.isMuted(loopID, scope: .output) ?? false
        // Tolleranza: 1,5 micro-passi (un driver può arrotondare il valore impostato).
        let volumeChanged = current.map { abs($0 - displayCurrent) > max(1e-5, 1.5 * displayStepScalar) } ?? false
        if volumeChanged || muted != expectedMute || current == nil {
            acceptExternalChange(volume: volumeChanged ? current : nil, muted: muted)
        }
    }

    /// Cambio esterno del volume di macOS (Centro di Controllo, Impostazioni, tasti non intercettati):
    /// diventa il volume dell'utente; i micro-passi in corso si fermano (solo su displayQueue).
    private func acceptExternalChange(volume v: Float32?, muted: Bool) {
        let loopID = displayLoopback
        if let v = v {
            _externalChanges += 1
            log?(String(format: "volume di sistema cambiato dall'esterno: %.4f (indicatore %.4f)", v, displayCurrent))
            displayCurrent = v
            displayTarget = v
            walker?.cancel()
            walker = nil
            walkerStart?.cancel()
        }
        expectedMute = muted
        updateCompensation(loopID) // guadagno letto direttamente dal driver
        stateLock.lock()
        if let v = v { _userVolume = v }
        _externalMute = muted
        applyDSPLocked()
        scheduleNotifyLocked(.system)
        stateLock.unlock()
    }

    /// Curva del controllo volume del dispositivo: dalla proprietà di traduzione di Core Audio se
    /// disponibile, altrimenti misurata leggendo i dB a 33 posizioni del volume hardware. La misura
    /// avviene durante la dissolvenza d'avvio (DSP a guadagno 0): non è udibile. Il volume hardware
    /// viene poi portato al 100 % dal ponte.
    static func measureCurve(_ dev: AudioDeviceID, hardware: Bool) -> VolumeCurve {
        guard hardware else { return VolumeCurve() }
        let xs = (0...32).map { Float32($0) / 32 }
        let translated = xs.compactMap { x in CA.volumeScalarToDecibels(dev, scope: .output, x).map { (x, $0) } }
        if translated.count == xs.count, let c = VolumeCurve(points: translated, source: "dispositivo (traduzione)") { return c }
        var measured: [(Float32, Float32)] = []
        for x in xs {
            CA.setVolumeScalar(dev, scope: .output, x)
            if let db = CA.volumeDecibels(dev, scope: .output) { measured.append((x, db)) }
        }
        if measured.count == xs.count, let c = VolumeCurve(points: measured, source: "dispositivo (misurata)") { return c }
        return VolumeCurve()
    }

    private func installVolumeBridge(output: AudioDevice, loopback: AudioDevice, originalOutputVolume: Float32?,
                                     initialVolume: Float32?) {
        removeVolumeBridge()
        bridgeLoopback = loopback.id
        bridgeOutput = output.id
        bridgeHardware = CA.hasSettableVolume(output.id, scope: .output)
        savedLoopbackVolume = SavedVolume(scalar: CA.volumeScalar(loopback.id, scope: .output),
                                          muted: CA.isMuted(loopback.id, scope: .output))
        let curve = AudioRouter.measureCurve(output.id, hardware: bridgeHardware)
        // Volume dell'utente: quello del dispositivo reale prima dell'avvio (era il volume di macOS).
        let v = min(max(initialVolume ?? (bridgeHardware ? (originalOutputVolume ?? 1) : 1), 0), 1)
        let range = CA.volumeDecibelRange(loopback.id, scope: .output)
        let span = max(1, (range?.max ?? 0) - (range?.min ?? -64))
        // Il DSP è a guadagno 0 (dissolvenza d'avvio): questi gradini non sono udibili.
        if bridgeHardware {
            CA.setVolumeScalar(output.id, scope: .output, 1)
            CA.setMuted(output.id, scope: .output, false)
            hardwareVolumeRaised = true
        }
        // Curva del loopback misurata ora, con il DSP a guadagno zero (inudibile).
        let addrs = CA.volumeElements(loopback.id, scope: .output).map {
            CA.address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput, element: $0)
        }
        var loopCurve = (0...64).compactMap { i -> Float32? in
            CA.setVolumeScalar(loopback.id, scope: .output, Float32(i) / 64)
            return CA.volumeDecibels(loopback.id, scope: .output)
        }
        if loopCurve.count != 65 { loopCurve = [] }
        CA.setVolumeScalar(loopback.id, scope: .output, v)
        CA.setMuted(loopback.id, scope: .output, false)
        updateCompensation(loopback.id)
        displayQueue.sync {
            displayLoopback = loopback.id
            displayCurrent = v
            displayTarget = v
            displayStepScalar = AudioRouter.displayStepDb / span
            expectedMute = false
            loopCurveDb = loopCurve
            loopVolumeAddrs = addrs
        }
        locked {
            _curve = curve
            _userVolume = v
            _userMuted = false
            _externalMute = false
            _listenerCheckPending = false
            _bridgeActive = true // il DSP resta a 0 finché start() non conclude la dissolvenza (_fadedOut)
        }

        let loopID = loopback.id
        var selectors: [(AudioObjectPropertySelector, AudioObjectPropertyScope, AudioObjectPropertyElement)] = [
            (kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain),
        ]
        for scope in [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeInput] {
            for el in [kAudioObjectPropertyElementMain, 1, 2] as [AudioObjectPropertyElement] {
                selectors.append((kAudioDevicePropertyVolumeScalar, scope, el))
            }
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for (sel, scope, el) in selectors {
            var addr = CA.address(sel, scope: scope, element: el)
            guard CA.hasProperty(loopID, addr) else { continue }
            if AudioObjectAddPropertyListener(loopID, &addr, AudioRouter.volumeListenerProc, context) == noErr {
                volumeListeners.append((loopID, addr))
            }
        }
    }

    /// Dissolvenza in uscita prima di modificare volumi hardware o instradamento (~70 ms).
    private func fadeOutIfRunning() {
        let doFade: Bool = locked {
            guard unit != nil, _bridgeActive, !_fadedOut else { return false }
            _fadedOut = true
            aeq_set_volume(dsp, 0)
            return true
        }
        if doFade { Thread.sleep(forTimeInterval: 0.07) }
    }

    /// Riporta il volume hardware dell'uscita al volume dell'utente (come era prima dell'EQ).
    private func restoreOutputHardwareVolume() {
        guard hardwareVolumeRaised else { return }
        hardwareVolumeRaised = false
        let out = bridgeOutput
        guard out != 0, CA.isAlive(out) else { return }
        let (v, m) = locked { (_userVolume, _userMuted) }
        CA.setVolumeScalar(out, scope: .output, v)
        if m { CA.setMuted(out, scope: .output, true) }
    }

    private func removeVolumeBridge() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        for (obj, addr) in volumeListeners {
            var a = addr
            let st = AudioObjectRemovePropertyListener(obj, &a, AudioRouter.volumeListenerProc, context)
            if st != noErr { NSLog("ArmoniaEQ: rimozione listener volume non riuscita (%d)", st) }
        }
        volumeListeners.removeAll()
        restoreOutputHardwareVolume()
        let loop = bridgeLoopback
        // Disattiva il ponte PRIMA di ripristinare: tasti e callback tardive non fanno nulla.
        locked { _bridgeActive = false }
        displayQueue.sync {
            walker?.cancel()
            walker = nil
            walkerStart?.cancel()
            walkerStart = nil
            displayLoopback = 0
        }
        bridgeLoopback = 0
        bridgeOutput = 0
        if let saved = savedLoopbackVolume, loop != 0 {
            if let v = saved.scalar { CA.setVolumeScalar(loop, scope: .output, v) }
            if let m = saved.muted { CA.setMuted(loop, scope: .output, m) }
        }
        savedLoopbackVolume = nil
        aeq_set_input_gain(dsp, 1)
    }

    // MARK: Cambio frequenza di campionamento

    private func installSampleRateListener(on device: AudioObjectID) {
        removeSampleRateListener()
        var addr = CA.address(kAudioDevicePropertyNominalSampleRate)
        if AudioObjectAddPropertyListener(device, &addr, AudioRouter.sampleRateListenerProc,
                                          Unmanaged.passUnretained(self).toOpaque()) == noErr {
            sampleRateListenerActive = true
            sampleRateListenerDevice = device
        }
    }

    private static let sampleRateListenerProc: AudioObjectPropertyListenerProc = { _, _, _, context in
        guard let context = context else { return noErr }
        let router = Unmanaged<AudioRouter>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async {
            guard let info = router.running, let out = router.outputDevice,
                  let rate = CA.nominalSampleRate(out.id), abs(rate - info.sampleRate) > 0.5 else { return }
            router.onConfigurationChange?()
        }
        return noErr
    }

    private func removeSampleRateListener() {
        guard sampleRateListenerActive else { return }
        var addr = CA.address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectRemovePropertyListener(sampleRateListenerDevice, &addr, AudioRouter.sampleRateListenerProc,
                                          Unmanaged.passUnretained(self).toOpaque())
        sampleRateListenerActive = false
        sampleRateListenerDevice = 0
    }
}
