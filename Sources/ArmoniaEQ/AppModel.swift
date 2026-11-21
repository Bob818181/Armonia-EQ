import ArmoniaDSP
import AVFoundation
import CoreAudio
import Foundation

enum EngineStatus: Equatable {
    case off
    case starting
    case running(AudioRouter.RunningInfo)
    case needsDriver
    case needsPermission
    case error(String)
}

final class AppModel: ObservableObject {
    // MARK: Stato pubblicato

    @Published private(set) var settings: EQSettings
    @Published private(set) var selection: ProfileSelection
    /// Profili personali (rinomina, duplicazione, eliminazione, import/export: vedi PresetLibrary).
    @Published private(set) var library: PresetLibrary
    var customProfiles: [CustomProfile] { library.profiles }
    /// Confronto A/B (temporaneo, non tocca i profili salvati).
    @Published private(set) var ab = ABCompare()
    /// Guadagno calcolato dall'Auto Gain per la curva corrente (dB), mostrato nell'interfaccia.
    @Published private(set) var autoGainDb: Float = 0
    @Published private(set) var outputDevices: [AudioDevice] = []
    @Published private(set) var loopbackDevice: AudioDevice?
    @Published private(set) var status: EngineStatus = .off
    @Published private(set) var selectedOutputUID: String?

    /// Volume dell'utente = volume di macOS (0...1). Con l'EQ attivo è applicato dal DSP con una
    /// rampa (vedi AudioRouter, "Ponte volume"); a motore spento è il volume del dispositivo di uscita.
    /// Tasti volume, volume di macOS e cursore dell'app restano sincronizzati.
    @Published var volume: Float {
        didSet {
            guard !applyingExternalVolume else { return }
            UIDebug.log(String(format: "volume = %.2f", volume))
            if router.volumeControlActive {
                router.setUserVolume(volume, source: .app)
            } else if let out = selectedOutput, CA.hasSettableVolume(out.id, scope: .output) {
                CA.setVolumeScalar(out.id, scope: .output, volume)
            }
            scheduleSave()
        }
    }
    @Published private(set) var muted = false
    /// Stato della gestione dei tasti volume (vedi VolumeKeyTap).
    @Published private(set) var volumeKeys: VolumeKeysState = .inactive
    @Published var balance: Float { didSet { aeq_set_balance(router.dsp, balance); scheduleSave() } }
    @Published var eqEnabled: Bool { didSet { aeq_set_eq_enabled(router.dsp, eqEnabled ? 1 : 0); scheduleSave() } }
    @Published var limiterEnabled: Bool { didSet { aeq_set_limiter_enabled(router.dsp, limiterEnabled ? 1 : 0); scheduleSave() } }
    @Published var limiterCeiling: Float { didSet { aeq_set_limiter_ceiling(router.dsp, limiterCeiling); scheduleSave() } }
    @Published private(set) var powerOn: Bool
    /// Auto Gain: compensa la variazione di loudness prodotta dalla curva (disattivabile).
    @Published var autoGain: Bool { didSet { UIDebug.log("auto gain \(autoGain ? "acceso" : "spento")"); pushAutoGain(); scheduleSave() } }
    @Published var spectrumZoom: String { didSet { scheduleSave() } }
    /// Avvio automatico all'accesso a macOS (LaunchAgent dell'utente, vedi LoginItem).
    @Published private(set) var launchAtLogin = LoginItem.isEnabled
    @Published private(set) var loginItemError: String?

    let router = AudioRouter()
    private var manualSettings: EQSettings
    private var restoreOutputUID: String?
    /// Volume dell'utente da ripristinare sul dispositivo di uscita se l'app si chiude in modo anomalo
    /// mentre l'EQ è attivo (il volume hardware è al 100 % durante l'elaborazione).
    private var restoreOutputVolume: Float?
    private var applyingExternalVolume = false
    private var accessibilityPromptShown = false
    let volumeKeyTap = VolumeKeyTap()
    private var accessibilityPoll: Timer?
    private var saveWork: DispatchWorkItem?
    private var restartWork: DispatchWorkItem?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var defaultListener: AudioObjectPropertyListenerBlock?

    var dsp: OpaquePointer { router.dsp }

    init() {
        let state = StateStore.load()
        settings = state.current.normalized()
        selection = state.selection
        library = PresetLibrary(state.customProfiles)
        manualSettings = state.manual.normalized()
        volume = state.volume
        balance = state.balance
        eqEnabled = state.eqEnabled
        limiterEnabled = state.limiterEnabled
        limiterCeiling = state.limiterCeiling
        powerOn = state.powerOn
        autoGain = state.autoGain
        spectrumZoom = state.spectrumZoom
        selectedOutputUID = state.outputUID
        restoreOutputUID = state.restoreOutputUID
        restoreOutputVolume = state.restoreOutputVolume
        accessibilityPromptShown = state.accessibilityPromptShown

        if case .custom(let id) = selection, !customProfiles.contains(where: { $0.id == id }) { selection = .manual }
        if case .factory(let id) = selection, FactoryProfiles.profile(id) == nil { selection = .factory("flat") }

        pushAllParameters()
        refreshDevices()
        recoverFromUncleanExit()
        // A motore spento il cursore mostra il volume del dispositivo di uscita (= volume di macOS).
        if !powerOn, let out = selectedOutput, let v = CA.volumeScalar(out.id, scope: .output) { volume = v }
        installSystemListeners()
        router.onConfigurationChange = { [weak self] in self?.scheduleRestart(after: 0.3) }
        router.onUserVolumeChange = { [weak self] v, m, source, keys in
            self?.userVolumeChanged(v, muted: m, source: source, fromKeys: keys)
        }
        // I tasti vanno direttamente al router (thread del tap, stato sotto lock): nessun passaggio dal
        // main thread, quindi nessun ritardo dovuto all'interfaccia.
        let engine = router
        volumeKeyTap.handler = { key, fine in engine.handleKey(key, fine: fine) }
        if UIDebug.enabled {
            router.log = { UIDebug.log($0) }
            volumeKeyTap.log = { UIDebug.log($0) }
        }
        VolumeHUD.shared.prepare()

        if powerOn { startEngine() }
    }

    // MARK: Profili

    var factoryProfiles: [FactoryProfile] { FactoryProfiles.all }

    /// Curva memorizzata del profilo selezionato (nil per Manuale, che non ha riferimento fisso).
    var referenceSettings: EQSettings? {
        switch selection {
        case .factory(let id): return FactoryProfiles.profile(id)?.settings
        case .custom(let id): return customProfiles.first { $0.id == id }?.settings
        case .manual: return nil
        }
    }

    var isModified: Bool {
        guard let ref = referenceSettings else { return false }
        return !settings.isClose(to: ref)
    }

    var selectionName: String {
        switch selection {
        case .factory(let id): return FactoryProfiles.profile(id)?.name ?? id
        case .custom(let id): return customProfiles.first { $0.id == id }?.name ?? "Profilo personale"
        case .manual: return "Manuale / Personalizzato"
        }
    }

    var selectionSummary: String {
        switch selection {
        case .factory(let id): return FactoryProfiles.profile(id)?.summary ?? ""
        case .custom: return "Profilo personale"
        case .manual: return "Equalizzazione libera, salvata automaticamente"
        }
    }

    var selectedCustomProfile: CustomProfile? {
        if case .custom(let id) = selection { return customProfiles.first { $0.id == id } }
        return nil
    }

    func select(_ newSelection: ProfileSelection) {
        selection = newSelection
        UIDebug.log("profilo \(selectionName)")
        switch newSelection {
        case .factory(let id): apply(FactoryProfiles.profile(id)?.settings ?? .flat)
        case .custom(let id):
            let p = customProfiles.first { $0.id == id }
            apply(p?.settings ?? settings)
            if let lim = p?.limiter {
                // Il limiter salvato con il profilo personale viene ripristinato.
                limiterEnabled = lim.enabled
                limiterCeiling = lim.ceiling
            }
        case .manual: apply(manualSettings)
        }
    }

    func setGain(band: Int, _ value: Float) {
        guard band >= 0 && band < bandCount, value.isFinite else { return }
        var s = settings
        s.gains[band] = round1(min(max(value, gainRange.lowerBound), gainRange.upperBound))
        UIDebug.log(String(format: "cursore %@ = %.1f", bandLabel(bandFrequencies[band]), s.gains[band]))
        apply(s)
    }

    /// BASSI (shelving 80 Hz): indipendente dai 10 cursori. Passi di 0,5 dB, -12...+12.
    func setBass(_ value: Float) {
        var s = settings
        s.bass = quantizeTone(value)
        guard s.bass != settings.bass else { return }
        UIDebug.log(String(format: "bassi = %.1f", s.bass))
        apply(s)
    }

    /// ALTI (shelving 10 kHz): indipendente dai 10 cursori. Passi di 0,5 dB, -12...+12.
    func setTreble(_ value: Float) {
        var s = settings
        s.treble = quantizeTone(value)
        guard s.treble != settings.treble else { return }
        UIDebug.log(String(format: "alti = %.1f", s.treble))
        apply(s)
    }

    /// Frequenza di intervento dei BASSI (60/80/100/120 Hz): indipendente dal guadagno.
    func setBassFrequency(_ hz: Float) {
        var s = settings
        s.bassFrequency = aeq_snap_bass_frequency(hz)
        guard s.bassFrequency != settings.bassFrequency else { return }
        UIDebug.log(String(format: "frequenza bassi = %.0f", s.bassFrequency))
        apply(s)
    }

    /// Frequenza di intervento degli ALTI (8/10/12 kHz): indipendente dal guadagno.
    func setTrebleFrequency(_ hz: Float) {
        var s = settings
        s.trebleFrequency = aeq_snap_treble_frequency(hz)
        guard s.trebleFrequency != settings.trebleFrequency else { return }
        UIDebug.log(String(format: "frequenza alti = %.0f", s.trebleFrequency))
        apply(s)
    }

    func setPreamp(_ value: Float) {
        guard value.isFinite else { return }
        var s = settings
        s.preamp = round1(min(max(value, preampRange.lowerBound), preampRange.upperBound))
        UIDebug.log(String(format: "preamp = %.1f", s.preamp))
        apply(s)
    }

    /// Reset immediato: torna al profilo Flat (bande, preamp, BASSI e ALTI a 0 dB).
    func resetToFlat() { select(.factory("flat")) }

    /// Annulla le modifiche e torna alla curva memorizzata del profilo selezionato.
    func revertToProfile() {
        if let ref = referenceSettings { apply(ref) }
    }

    /// Imposta automaticamente il preamp in modo che il picco della curva sia 0 dB.
    func autoPreamp() {
        var maxDb = -100.0
        var f = 20.0
        let zeroPre: Float = 0
        settings.gains.withUnsafeBufferPointer { g in
            while f <= 20000 {
                maxDb = max(maxDb, aeq_response_full_db(g.baseAddress, zeroPre, settings.bass, settings.bassFrequency,
                                                        settings.treble, settings.trebleFrequency, currentSampleRate, f))
                f *= 1.02
            }
        }
        setPreamp(Float(-max(0, maxDb)))
    }

    // MARK: Profili personali

    private var currentLimiter: LimiterSettings { LimiterSettings(enabled: limiterEnabled, ceiling: limiterCeiling) }

    /// Salva la curva corrente (bande, preamp, BASSI, ALTI) e il limiter come profilo personale.
    /// I profili predefiniti non vengono mai modificati.
    @discardableResult
    func saveAsNewProfile(named rawName: String) -> Bool {
        guard let id = library.save(name: rawName, settings: settings, limiter: currentLimiter) else { return false }
        selection = .custom(id)
        saveNow()
        return true
    }

    func profileNameExists(_ name: String, excluding id: UUID? = nil) -> Bool {
        library.contains(name: name, excluding: id)
    }

    /// Sovrascrive il profilo personale selezionato con la curva e il limiter correnti.
    func updateSelectedCustomProfile() {
        guard case .custom(let id) = selection else { return }
        _ = library.update(id, settings: settings, limiter: currentLimiter)
        saveNow()
    }

    @discardableResult
    func renameProfile(_ id: UUID, to rawName: String) -> Bool {
        let ok = library.rename(id, to: rawName)
        if ok { saveNow() }
        return ok
    }

    @discardableResult
    func duplicateProfile(_ id: UUID) -> CustomProfile? {
        let copy = library.duplicate(id)
        if copy != nil { saveNow() }
        return copy
    }

    func deleteProfile(_ id: UUID) {
        library.delete(id)
        if selection == .custom(id) {
            // Il suono non cambia: la curva corrente diventa la curva manuale.
            manualSettings = settings
            selection = .manual
        }
        saveNow()
    }

    func exportProfiles(to url: URL, ids: [UUID]? = nil) throws {
        try library.exportData(ids).write(to: url, options: .atomic)
    }

    func importProfiles(from url: URL) throws -> PresetLibrary.ImportResult {
        let result = try library.importData(Data(contentsOf: url))
        saveNow()
        return result
    }

    // MARK: Confronto A/B

    /// Passa alla configurazione A o B senza toccare i profili salvati. Il cambio usa lo smoothing
    /// del motore (nessun click).
    func abSwitch(to slot: ABCompare.Slot) {
        guard slot != ab.active else { return }
        let next = ab.switchTo(slot, current: settings)
        UIDebug.log("confronto \(slot.rawValue)")
        apply(next)
    }

    func abToggle() { abSwitch(to: ab.active == .a ? .b : .a) }

    func abCopyToOther() { ab.copyActiveToOther(current: settings) }

    func abReset() { ab.reset() }

    // MARK: Misuratori

    func resetMeters() { aeq_reset_meters(dsp) }

    private func apply(_ newSettings: EQSettings) {
        settings = newSettings.normalized()
        if selection == .manual { manualSettings = settings }
        pushEQ()
        scheduleSave()
    }

    // MARK: Parametri DSP

    var currentSampleRate: Double {
        if case .running(let info) = status { return info.sampleRate }
        return 48000
    }

    private func pushEQ() {
        for (i, g) in settings.gains.enumerated() { aeq_set_band_gain(dsp, Int32(i), g) }
        aeq_set_preamp(dsp, settings.preamp)
        aeq_set_bass(dsp, settings.bass)
        aeq_set_treble(dsp, settings.treble)
        aeq_set_bass_frequency(dsp, settings.bassFrequency)
        aeq_set_treble_frequency(dsp, settings.trebleFrequency)
        pushAutoGain()
    }

    /// Calcola la compensazione Auto Gain per la curva corrente e la invia al motore
    /// (0 dB quando l'Auto Gain è spento: comportamento originale).
    private func pushAutoGain() {
        let g: Float = settings.gains.withUnsafeBufferPointer { buf in
            aeq_auto_gain_full_db(buf.baseAddress, settings.preamp, settings.bass, settings.bassFrequency,
                                  settings.treble, settings.trebleFrequency, currentSampleRate)
        }
        if g != autoGainDb { autoGainDb = g }
        aeq_set_auto_gain(dsp, autoGain ? g : 0)
    }

    private func pushAllParameters() {
        pushEQ()
        aeq_set_balance(dsp, balance)
        aeq_set_eq_enabled(dsp, eqEnabled ? 1 : 0)
        aeq_set_limiter_enabled(dsp, limiterEnabled ? 1 : 0)
        aeq_set_limiter_ceiling(dsp, limiterCeiling)
    }

    var volumeDbText: String {
        if muted { return "muto" }
        let db = router.volumeDb(volume)
        return volume <= 0 || db < -150 ? "-∞ dB" : String(format: "%.1f dB", db)
    }

    // MARK: Volume (tasti, sistema, cursore)

    private func setVolumeSilently(_ v: Float) {
        applyingExternalVolume = true
        volume = v
        applyingExternalVolume = false
    }

    /// Il volume dell'utente è cambiato nel motore (tasti, Centro di Controllo, Impostazioni…).
    /// Notifica coalescente: `v`/`m` sono sempre lo stato più recente del motore, quindi cursore e HUD
    /// mostrano il volume effettivo anche con pressioni rapidissime.
    private func userVolumeChanged(_ v: Float, muted m: Bool, source: AudioRouter.VolumeSource, fromKeys: Bool) {
        if abs(v - volume) > 0.0001 { setVolumeSilently(v) }
        if m != muted { muted = m }
        if source == .system && !fromKeys {
            UIDebug.log(String(format: "volume di sistema = %.3f%@", v, m ? " (muto)" : ""))
        }
        // L'HUD di Armonia compare SOLO per i tasti gestiti dall'app (macOS non li ha ricevuti).
        if fromKeys { VolumeHUD.shared.show(volume: v, muted: m, device: router.outputDevice?.name ?? "") }
        if restoreOutputVolume != nil { restoreOutputVolume = v }
        scheduleSave()
    }

    /// Attiva l'intercettazione dei tasti volume quando il motore è attivo e il permesso
    /// Accessibilità è concesso; altrimenti i tasti restano a macOS (con possibile click).
    func updateVolumeKeys(prompt: Bool = false) {
        guard router.volumeControlActive else {
            volumeKeys = .inactive
            accessibilityPoll?.invalidate()
            accessibilityPoll = nil
            return
        }
        if VolumeKeyTap.isTrusted(prompt: prompt) && volumeKeyTap.start() {
            if volumeKeys != .active { UIDebug.log("tasti volume gestiti da Armonia EQ") }
            volumeKeys = .active
            accessibilityPoll?.invalidate()
            accessibilityPoll = nil
        } else {
            if volumeKeys != .needsPermission { UIDebug.log("tasti volume: permesso Accessibilità necessario") }
            volumeKeys = .needsPermission
            if accessibilityPoll == nil {
                accessibilityPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    self?.updateVolumeKeys()
                }
            }
        }
    }

    /// Chiede il permesso Accessibilità (finestra di sistema) e apre le Impostazioni.
    func requestVolumeKeyPermission() {
        updateVolumeKeys(prompt: true)
        if volumeKeys == .needsPermission { VolumeKeyTap.openAccessibilitySettings() }
    }

    // MARK: Dispositivi

    func refreshDevices() {
        let all = CA.allDevices()
        outputDevices = all.filter { $0.isSelectableOutput }
        loopbackDevice = all.first { $0.isLoopback && $0.inputChannels >= 1 && $0.outputChannels >= 1 }
        if selectedOutputUID == nil || !outputDevices.contains(where: { $0.uid == selectedOutputUID }) {
            if let def = CA.defaultOutputDevice(), let d = outputDevices.first(where: { $0.id == def }) {
                selectedOutputUID = d.uid
            } else if selectedOutputUID == nil {
                selectedOutputUID = (outputDevices.first { $0.transportType == kAudioDeviceTransportTypeBuiltIn }
                    ?? outputDevices.first)?.uid
            }
        }
        if case .needsDriver = status, loopbackDevice != nil { status = .off }
    }

    var selectedOutput: AudioDevice? { outputDevices.first { $0.uid == selectedOutputUID } }

    func selectOutput(uid: String) {
        guard uid != selectedOutputUID else { return }
        selectedOutputUID = uid
        scheduleSave()
        if powerOn { startEngine() }
    }

    private func installSystemListeners() {
        var devAddr = CA.address(kAudioHardwarePropertyDevices)
        let devBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.devicesChanged() }
        if AudioObjectAddPropertyListenerBlock(CA.systemObject, &devAddr, DispatchQueue.main, devBlock) == noErr {
            deviceListener = devBlock
        }
        var defAddr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        let defBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.defaultOutputChanged() }
        if AudioObjectAddPropertyListenerBlock(CA.systemObject, &defAddr, DispatchQueue.main, defBlock) == noErr {
            defaultListener = defBlock
        }
    }

    private func devicesChanged() {
        let previousUID = selectedOutputUID
        refreshDevices()
        guard powerOn else { return }
        if loopbackDevice == nil {
            stopEngine(restore: true)
            status = .needsDriver
            return
        }
        let current = router.outputDevice
        if let current = current, !CA.isAlive(current.id) || !outputDevices.contains(where: { $0.uid == current.uid }) {
            // Il dispositivo in uso è stato scollegato (es. DAC USB): ripiega sugli altoparlanti interni.
            selectedOutputUID = (outputDevices.first { $0.transportType == kAudioDeviceTransportTypeBuiltIn }
                ?? outputDevices.first)?.uid
            scheduleRestart(after: 0.2)
        } else if case .running = status {
            // niente da fare
        } else if previousUID != selectedOutputUID || current == nil {
            scheduleRestart(after: 0.2)
        }
    }

    /// Se l'utente sceglie un'uscita dalle Impostazioni di sistema o dalla barra dei menu mentre
    /// l'EQ è attivo, la adottiamo come nuova uscita e rimettiamo il loopback come predefinito.
    private func defaultOutputChanged() {
        guard powerOn, case .running = status, let def = CA.defaultOutputDevice(),
              def != router.loopbackDevice?.id,
              let device = CA.device(def), device.isSelectableOutput else { return }
        refreshDevices()
        selectedOutputUID = device.uid
        scheduleSave()
        scheduleRestart(after: 0.1)
    }

    // MARK: Motore audio

    func setLaunchAtLogin(_ on: Bool) {
        do {
            try LoginItem.setEnabled(on, appPath: Bundle.main.bundlePath)
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        launchAtLogin = LoginItem.isEnabled
        UIDebug.log("avvio all'accesso \(launchAtLogin ? "attivo" : "disattivo")")
    }

    /// Stato sintetico per la finestra e il pannello della barra dei menu.
    var statusSummary: String {
        switch status {
        case .off: return "Spento · audio di sistema non elaborato"
        case .starting: return "Avvio…"
        case .running(let info): return String(format: "Attivo · %.1f kHz · latenza %.0f ms", info.sampleRate / 1000, info.latencyMs)
        case .needsDriver: return "Driver loopback non installato"
        case .needsPermission: return "Serve l'autorizzazione all'ingresso audio"
        case .error(let msg): return "Errore: \(msg)"
        }
    }

    var isRunning: Bool { if case .running = status { return true } else { return false } }

    func setPower(_ on: Bool) {
        UIDebug.log("accensione \(on ? "ON" : "OFF")")
        powerOn = on
        scheduleSave()
        if on { startEngine() } else { stopEngine(restore: true) }
    }

    func startEngine() {
        restartWork?.cancel()
        refreshDevices()
        guard let loopback = loopbackDevice else {
            router.stop(restoreDefaultOutput: true)
            status = .needsDriver
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            status = .starting
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self = self, self.powerOn else { return }
                    if granted { self.startEngine() } else { self.status = .needsPermission }
                }
            }
            return
        default:
            status = .needsPermission
            return
        }
        guard let output = selectedOutput else {
            status = .error("Nessun dispositivo di uscita disponibile")
            return
        }
        status = .starting
        do {
            restoreOutputUID = output.uid
            // Volume iniziale: dopo una chiusura anomala quello salvato (l'hardware è rimasto al 100 %);
            // senza volume hardware quello dell'app; altrimenti il volume attuale del dispositivo.
            let initial: Float? = restoreOutputVolume ?? (CA.hasSettableVolume(output.id, scope: .output) ? nil : volume)
            try router.start(output: output, loopback: loopback, initialVolume: initial)
            if let info = router.running {
                status = .running(info)
                pushAutoGain() // la compensazione dipende dalla frequenza di campionamento
                setVolumeSilently(router.userVolume)
                muted = router.userMuted
                restoreOutputVolume = router.hardwareVolumeRaised ? router.userVolume : nil
            }
            saveNow()
            updateVolumeKeys(prompt: !UIDebug.enabled && !accessibilityPromptShown)
            accessibilityPromptShown = true
        } catch {
            router.stop(restoreDefaultOutput: false)
            if CA.defaultOutputDevice() == loopback.id { CA.setDefaultOutputDevice(output.id) }
            status = .error(error.localizedDescription)
        }
    }

    func stopEngine(restore: Bool) {
        restartWork?.cancel()
        let wasOutput = router.outputDevice
        router.stop(restoreDefaultOutput: restore)
        restoreOutputVolume = nil
        updateVolumeKeys()
        if let out = wasOutput { muted = CA.isMuted(out.id, scope: .output) ?? false }
        saveNow()
        // Se il motore non era attivo ma il loopback è rimasto predefinito, ripristina comunque.
        if restore, let loop = loopbackDevice, CA.defaultOutputDevice() == loop.id {
            let target = wasOutput ?? selectedOutput
            if let t = target { CA.setDefaultOutputDevice(t.id) }
        }
        status = loopbackDevice == nil ? .needsDriver : .off
    }

    private func scheduleRestart(after seconds: Double) {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.powerOn else { return }
            self.startEngine()
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Se l'app si era chiusa in modo anomalo lasciando il loopback come uscita di sistema,
    /// riporta l'audio sul dispositivo reale (altrimenti non si sentirebbe nulla).
    private func recoverFromUncleanExit() {
        guard !powerOn else { return } // con l'EQ acceso il volume salvato è usato all'avvio del motore
        let target = outputDevices.first { $0.uid == restoreOutputUID } ?? selectedOutput
        // Volume hardware lasciato al 100 % durante l'elaborazione: torna al volume dell'utente.
        if let v = restoreOutputVolume, let t = target {
            CA.setVolumeScalar(t.id, scope: .output, v)
            restoreOutputVolume = nil
            saveNow()
        }
        guard let loop = loopbackDevice, CA.defaultOutputDevice() == loop.id else { return }
        if let t = target { CA.setDefaultOutputDevice(t.id) }
    }

    func applicationWillTerminate() {
        stopEngine(restore: true)
        saveNow()
    }

    // MARK: Salvataggio

    private func makeState() -> PersistedState {
        var s = PersistedState()
        s.selection = selection
        s.current = settings
        s.manual = manualSettings
        s.customProfiles = library.profiles
        s.autoGain = autoGain
        s.spectrumZoom = spectrumZoom
        s.volume = volume
        s.balance = balance
        s.powerOn = powerOn
        s.eqEnabled = eqEnabled
        s.limiterEnabled = limiterEnabled
        s.limiterCeiling = limiterCeiling
        s.outputUID = selectedOutputUID
        s.restoreOutputUID = restoreOutputUID
        s.restoreOutputVolume = restoreOutputVolume
        s.accessibilityPromptShown = accessibilityPromptShown
        return s
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        StateStore.save(makeState())
    }
}

private func round1(_ v: Float) -> Float { (v * 10).rounded() / 10 }
