// Verifica end-to-end del motore audio REALE (stesso codice dell'app: AudioRouter + ArmoniaDSP).
//
// Configurazione di prova (usata in CI su un Mac senza altoparlanti):
//   - BlackHole 2ch  = driver loopback (uscita di sistema durante l'EQ)
//   - BlackHole 16ch = "dispositivo di uscita reale" (al posto di altoparlanti/USB), da cui registriamo
//
//   toni di prova -> uscita di sistema (BlackHole 2ch) -> aggregate + AUHAL + DSP -> BlackHole 16ch -> registrazione
//
// Per ogni profilo si suonano 10 toni (alle frequenze delle bande) e si misura il guadagno
// rispetto a Flat. Il risultato deve coincidere con la curva mostrata dall'app (aeq_response_db).

import ArmoniaDSP
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ msg: String) -> Never {
    print("ERRORE: \(msg)")
    exit(1)
}

let sampleRate = 48000.0
let toneSeconds = 0.4
let leadSeconds = 0.6
let toneAmplitude: Float = 0.1 // -20 dBFS
let freqs = bandFrequencies.map(Double.init)

// MARK: Dispositivi

let devices = CA.allDevices()
for d in devices {
    print("dispositivo: \(d.name) [\(d.uid)] in=\(d.inputChannels) out=\(d.outputChannels) \(d.transportLabel)")
}
guard let loopback = devices.first(where: { $0.name.contains("BlackHole 2ch") }) else { fail("BlackHole 2ch non trovato") }
guard let fakeOutput = devices.first(where: { $0.name.contains("BlackHole 16ch") }) else { fail("BlackHole 16ch non trovato") }
CA.setNominalSampleRate(loopback.id, sampleRate)
CA.setNominalSampleRate(fakeOutput.id, sampleRate)
print("Autorizzazione ingresso audio: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (3 = autorizzato)")

let originalDefault = CA.defaultOutputDevice()

// MARK: Avvio motore

let router = AudioRouter()
aeq_set_volume(router.dsp, 1)
aeq_set_balance(router.dsp, 0)
aeq_set_limiter_enabled(router.dsp, 1)
do {
    try router.start(output: fakeOutput, loopback: loopback)
} catch {
    fail("avvio motore: \(error.localizedDescription)")
}
guard let info = router.running else { fail("motore non in esecuzione") }
print(String(format: "Motore attivo: uscita=%@ %.0f Hz buffer=%u latenza≈%.1f ms", info.outputName, info.sampleRate,
             info.bufferFrames, info.latencyMs))
guard CA.defaultOutputDevice() == loopback.id else { fail("l'uscita di sistema non è stata impostata sul loopback") }
print("OK: uscita di sistema = \(loopback.name)")

// MARK: Riproduzione + registrazione

var format = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                         mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                         mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                         mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)

final class Session {
    var playIndex = 0
    var recorded: [Float] = []
    let totalFrames: Int
    let generator: ((Int) -> Float)?
    init(generator: ((Int) -> Float)? = nil, seconds: Double? = nil) {
        self.generator = generator
        totalFrames = Int((seconds ?? (leadSeconds + toneSeconds * Double(freqs.count) + 0.6)) * sampleRate)
        recorded.reserveCapacity(totalFrames + 48000)
    }
    func sample(_ i: Int) -> Float {
        if let g = generator { return g(i) }
        let t = Double(i) / sampleRate - leadSeconds
        guard t >= 0 else { return 0 }
        let k = Int(t / toneSeconds)
        guard k < freqs.count else { return 0 }
        return toneAmplitude * Float(sin(2 * Double.pi * freqs[k] * Double(i) / sampleRate))
    }
}

let queue = DispatchQueue(label: "engine-check")
var failures = 0

func runSequence(generator: ((Int) -> Float)? = nil, seconds: Double? = nil) -> [Float] {
    let s = Session(generator: generator, seconds: seconds)
    var outQ: AudioQueueRef?
    var inQ: AudioQueueRef?
    var st = AudioQueueNewOutputWithDispatchQueue(&outQ, &format, 0, queue) { q, buf in
        let n = Int(buf.pointee.mAudioDataBytesCapacity) / 8
        let p = buf.pointee.mAudioData.assumingMemoryBound(to: Float.self)
        for i in 0..<n {
            let v = s.sample(s.playIndex)
            p[2 * i] = v
            p[2 * i + 1] = v
            s.playIndex += 1
        }
        buf.pointee.mAudioDataByteSize = UInt32(n * 8)
        AudioQueueEnqueueBuffer(q, buf, 0, nil)
    }
    guard st == noErr, let oq = outQ else { fail("AudioQueue uscita \(st)") }
    st = AudioQueueNewInputWithDispatchQueue(&inQ, &format, 0, queue) { q, buf, _, _, _ in
        let n = Int(buf.pointee.mAudioDataByteSize) / 8
        let p = buf.pointee.mAudioData.assumingMemoryBound(to: Float.self)
        for i in 0..<n { s.recorded.append(p[2 * i]) }
        AudioQueueEnqueueBuffer(q, buf, 0, nil)
    }
    guard st == noErr, let iq = inQ else { fail("AudioQueue ingresso \(st)") }
    var uid: Unmanaged<CFString>? = Unmanaged.passRetained(fakeOutput.uid as CFString)
    st = AudioQueueSetProperty(iq, kAudioQueueProperty_CurrentDevice, &uid, UInt32(MemoryLayout<Unmanaged<CFString>?>.size))
    uid?.release()
    guard st == noErr else { fail("selezione dispositivo di registrazione \(st)") }

    for q in [oq, iq] {
        for _ in 0..<3 {
            var b: AudioQueueBufferRef?
            AudioQueueAllocateBuffer(q, 4096 * 8, &b)
            guard let buf = b else { fail("buffer") }
            if q == oq {
                memset(buf.pointee.mAudioData, 0, 4096 * 8)
                buf.pointee.mAudioDataByteSize = 4096 * 8
            }
            AudioQueueEnqueueBuffer(q, buf, 0, nil)
        }
    }
    AudioQueueStart(iq, nil)
    AudioQueueStart(oq, nil)
    Thread.sleep(forTimeInterval: Double(s.totalFrames) / sampleRate + 0.5)
    AudioQueueStop(oq, true)
    AudioQueueStop(iq, true)
    AudioQueueDispose(oq, true)
    AudioQueueDispose(iq, true)
    return queue.sync { s.recorded }
}

func amplitude(_ x: ArraySlice<Float>, _ f: Double) -> Double {
    let n = x.count
    var s = 0.0, c = 0.0, w = 0.0
    for (i, v) in x.enumerated() {
        let win = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1))
        let ph = 2 * Double.pi * f * Double(i) / sampleRate
        s += win * Double(v) * sin(ph)
        c += win * Double(v) * cos(ph)
        w += win
    }
    return 2 * sqrt(s * s + c * c) / w
}

/// Livelli (ampiezza) dei 10 toni nella registrazione + rilevamento dei dropout:
/// ogni tono è misurato su due metà; se differiscono di oltre 0,5 dB c'è stata un'interruzione.
func measureTones(_ rec: [Float]) -> (levels: [Double], dropouts: [Int]) {
    guard let onset = rec.firstIndex(where: { abs($0) > 0.0015 }) else {
        fail("registrazione silenziosa: l'audio non attraversa il motore (permesso ingresso audio negato?)")
    }
    let seg = Int(toneSeconds * sampleRate)
    var levels: [Double] = [], dropouts: [Int] = []
    for k in freqs.indices {
        let a = onset + k * seg + Int(0.12 * sampleRate)
        let b = onset + (k + 1) * seg - Int(0.04 * sampleRate)
        guard b <= rec.count else { fail("registrazione troppo corta") }
        let mid = (a + b) / 2
        let h1 = amplitude(rec[a..<mid], freqs[k]), h2 = amplitude(rec[mid..<b], freqs[k])
        if abs(20 * log10(h1 / h2)) > 0.5 { dropouts.append(k) }
        levels.append(amplitude(rec[a..<b], freqs[k]))
    }
    return (levels, dropouts)
}

var dropoutCount = 0
/// Esegue la sequenza di toni; se si rileva un dropout la ripete (max 3 tentativi) e lo conteggia.
func measureClean(_ label: String) -> [Double] {
    for attempt in 1...3 {
        let r = measureTones(runSequence())
        if r.dropouts.isEmpty { return r.levels }
        dropoutCount += 1
        print("  ATTENZIONE: dropout audio durante \(label) (bande \(r.dropouts.map { bandLabel(Float(freqs[$0])) })), tentativo \(attempt)")
    }
    print("FALLITO: dropout ripetuti durante \(label)")
    failures += 1
    return measureTones(runSequence()).levels
}

func apply(_ s: EQSettings, eq: Bool = true) {
    for (i, g) in s.gains.enumerated() { aeq_set_band_gain(router.dsp, Int32(i), g) }
    aeq_set_preamp(router.dsp, s.preamp)
    aeq_set_bass(router.dsp, s.bass)
    aeq_set_treble(router.dsp, s.treble)
    aeq_set_bass_frequency(router.dsp, s.bassFrequency)
    aeq_set_treble_frequency(router.dsp, s.trebleFrequency)
    aeq_set_auto_gain(router.dsp, 0)
    aeq_set_eq_enabled(router.dsp, eq ? 1 : 0)
    Thread.sleep(forTimeInterval: 0.3) // smoothing
}

// MARK: Misure

apply(.flat)
let flat = measureClean("Flat")
let flatDb = flat.map { 20 * log10($0 / Double(toneAmplitude)) }
print("\nFlat: livello attraverso il motore (atteso 0 dB) ->",
      flatDb.map { String(format: "%+.2f", $0) }.joined(separator: " "))
if flatDb.contains(where: { abs($0) > 0.5 }) {
    print("FALLITO: il percorso Flat non è trasparente"); failures += 1
}

print("\nProfilo                     ", freqs.map { bandLabel(Float($0)).padding(toLength: 7, withPad: " ", startingAt: 0) }.joined())
for profile in FactoryProfiles.all where profile.id != "flat" {
    apply(profile.settings)
    let expected: [Double] = profile.settings.gains.withUnsafeBufferPointer { g in
        freqs.map { aeq_response_db(g.baseAddress, profile.settings.preamp, sampleRate, $0) }
    }
    var measured: [Double] = []
    var worst = 0.0
    // Un'interruzione dell'audio della macchina di CI durante un solo tono (non sempre rilevata
    // dal confronto tra le due metà) si ripete la misura una volta, come per i dropout.
    for attempt in 1...2 {
        let m = measureClean(profile.name)
        measured = zip(m, flat).map { 20 * log10($0 / $1) }
        worst = zip(measured, expected).map { abs($0 - $1) }.max() ?? 0
        if worst <= 0.3 { break }
        if attempt == 1 { dropoutCount += 1; print("  ATTENZIONE: misura anomala per \(profile.name) (scarto \(String(format: "%.2f", worst)) dB), ripetuta") }
    }
    print(String(format: "%-20@ cursori", profile.name as NSString),
          profile.settings.gains.map { String(format: "%+7.1f", $0) }.joined(), String(format: "  preamp %+.1f", profile.settings.preamp))
    print(String(format: "%-20@ curva  ", "" as NSString), expected.map { String(format: "%+7.2f", $0) }.joined())
    print(String(format: "%-20@ misura ", "" as NSString), measured.map { String(format: "%+7.2f", $0) }.joined(),
          String(format: "  scarto max %.2f dB", worst))
    if worst > 0.3 { print("FALLITO: \(profile.name) non corrisponde alla curva"); failures += 1 }
    if (measured.map { abs($0) }.max() ?? 0) < 1 { print("FALLITO: \(profile.name) non cambia il suono"); failures += 1 }
}

// Fase 5a: BASSI e ALTI sul percorso audio reale (misura vs curva mostrata).
print("\nFase 5: BASSI/ALTI, confronto A/B, Auto Gain e clipping sul percorso reale")
func curveRow(_ s: EQSettings) -> [Double] {
    s.gains.withUnsafeBufferPointer { g in
        freqs.map { aeq_response_full_db(g.baseAddress, s.preamp, s.bass, s.bassFrequency, s.treble, s.trebleFrequency, sampleRate, $0) }
    }
}
func measureRelative(_ label: String) -> [Double] { zip(measureClean(label), flat).map { 20 * log10($0 / $1) } }

for (label, b, t) in [("BASSI -12", Float(-12), Float(0)), ("BASSI +12", 12, 0), ("ALTI -12", 0, -12),
                      ("ALTI +12", 0, 12), ("BASSI +12 / ALTI +12", 12, 12), ("Pop + BASSI +6 / ALTI -6", 6, -6),
                      ("BASSI +12 @ 60 Hz", 12, 0), ("BASSI +12 @ 120 Hz", 12, 0), ("ALTI +12 @ 8 kHz", 0, 12),
                      ("ALTI -12 @ 12 kHz", 0, -12)] {
    var st = EQSettings(gains: Array(repeating: 0, count: bandCount), preamp: 0, bass: b, treble: t)
    if label.hasSuffix("@ 60 Hz") { st.bassFrequency = 60 }
    if label.hasSuffix("@ 120 Hz") { st.bassFrequency = 120 }
    if label.hasSuffix("@ 8 kHz") { st.trebleFrequency = 8000 }
    if label.hasSuffix("@ 12 kHz") { st.trebleFrequency = 12000 }
    if label.hasPrefix("Pop") { st.gains = FactoryProfiles.profile("pop")!.settings.gains; st.preamp = FactoryProfiles.profile("pop")!.settings.preamp }
    apply(st)
    let measured = measureRelative(label)
    let expected = curveRow(st)
    let worst = zip(measured, expected).map { abs($0 - $1) }.max() ?? 0
    print(String(format: "%-26@ curva  ", label as NSString), expected.map { String(format: "%+7.2f", $0) }.joined())
    print(String(format: "%-26@ misura ", "" as NSString), measured.map { String(format: "%+7.2f", $0) }.joined(),
          String(format: "  scarto max %.2f dB", worst))
    if worst > 0.3 { print("FALLITO: \(label) non corrisponde alla curva"); failures += 1 }
}

// Fase 5b: confronto A/B con cambi reali durante la riproduzione continua.
do {
    var abState = ABCompare()
    let A = EQSettings(gains: FactoryProfiles.profile("electronic")!.settings.gains, preamp: -5, bass: 4, treble: 2)
    let B = EQSettings(gains: FactoryProfiles.profile("voice")!.settings.gains, preamp: -4, bass: -6, treble: 3)
    apply(A)
    let mA1 = measureRelative("A")
    var cur = abState.switchTo(.b, current: A)   // B parte come copia di A…
    cur = B                                       // …poi viene modificata
    apply(cur)
    let mB = measureRelative("B")
    cur = abState.switchTo(.a, current: cur)
    apply(cur)
    let mA2 = measureRelative("A di nuovo")
    let errA = zip(mA1, curveRow(A)).map { abs($0 - $1) }.max() ?? 0
    let errB = zip(mB, curveRow(B)).map { abs($0 - $1) }.max() ?? 0
    let rep = zip(mA1, mA2).map { abs($0 - $1) }.max() ?? 0
    print(String(format: "  A/B: A vs curva %.2f dB, B vs curva %.2f dB, A ripetuta vs A %.3f dB, A e B diverse di %.1f dB",
                 errA, errB, rep, zip(mA1, mB).map { abs($0 - $1) }.max() ?? 0))
    if errA > 0.3 || errB > 0.3 || rep > 0.1 || cur != A { print("FALLITO: confronto A/B"); failures += 1 }
}

// Fase 5c: Auto Gain applicato realmente dal motore (livello a 1 kHz con AGC acceso/spento).
do {
    let st = FactoryProfiles.profile("electronic")!.settings
    let ag: Float = st.gains.withUnsafeBufferPointer { aeq_auto_gain_db($0.baseAddress, st.preamp, st.bass, st.treble, sampleRate) }
    apply(st)
    let off = measureClean("AGC spento")
    aeq_set_auto_gain(router.dsp, ag)
    Thread.sleep(forTimeInterval: 1.0) // rampa lenta dell'AGC
    let on = measureClean("AGC acceso")
    let delta = zip(on, off).map { 20 * log10($0 / $1) }
    let worst = delta.map { abs($0 - Double(ag)) }.max() ?? 0
    print(String(format: "  Auto Gain Elettronica: calcolato %+.2f dB, applicato %+.2f…%+.2f dB (scarto max %.3f dB)",
                 ag, delta.min() ?? 0, delta.max() ?? 0, worst))
    if worst > 0.1 { print("FALLITO: Auto Gain non applicato correttamente"); failures += 1 }
    aeq_set_auto_gain(router.dsp, 0)
}

// Fase 5d: clipping e limiter sul percorso reale (segnale +6 dB oltre 0 dBFS).
do {
    func hotRun(limiter: Bool) -> (AEQMeters, Double) {
        apply(EQSettings(gains: Array(repeating: 0, count: bandCount), preamp: 12, bass: 0, treble: 0))
        aeq_set_limiter_enabled(router.dsp, limiter ? 1 : 0)
        aeq_set_limiter_ceiling(router.dsp, -1)
        Thread.sleep(forTimeInterval: 0.2)
        aeq_reset_meters(router.dsp)
        let rec = runSequence(generator: { i in Float(0.5 * sin(2 * Double.pi * 1000 * Double(i) / sampleRate)) }, seconds: 1.0)
        var m = AEQMeters()
        aeq_get_meters(router.dsp, &m)
        let peak = rec.dropFirst(4800).map { Double(abs($0)) }.max() ?? 0
        return (m, peak)
    }
    let (mOff, pOff) = hotRun(limiter: false)
    let (mOn, pOn) = hotRun(limiter: true)
    print(String(format: "  senza limiter: clipping %u campioni, picco registrato %.3f | con limiter: oltre soglia %u, clipping %u, picco registrato %.3f (soglia %.3f)",
                 mOff.clipSamples, pOff, mOn.overSamples, mOn.clipSamples, pOn, pow(10, -1.0 / 20)))
    if mOff.clipSamples == 0 { print("FALLITO: clipping effettivo non rilevato"); failures += 1 }
    if mOn.clipSamples != 0 || mOn.overSamples == 0 || pOn > pow(10, -1.0 / 20) + 0.002 {
        print("FALLITO: limiter/indicatori sul percorso reale"); failures += 1
    }
    aeq_set_limiter_enabled(router.dsp, 1)
    apply(.flat)
}

// MARK: Fase 6 – tasti volume durante la riproduzione

/// Riproduzione continua con registrazione marcata nel tempo (host time di ogni buffer registrato)
/// e un'azione eseguita in parallelo (es. tasti volume simulati).
struct TimedRecording {
    var samples: [Float]
    var stamps: [(index: Int, host: UInt64)]
    /// Host time (in ns) del campione `index` della registrazione.
    func hostNs(at index: Int) -> Double? {
        guard let k = stamps.lastIndex(where: { $0.index <= index }) else { return nil }
        return Double(stamps[k].host) * hostTicksToNs + Double(index - stamps[k].index) / sampleRate * 1e9
    }
    /// Indice della registrazione corrispondente all'host time `ns`.
    func index(atNs ns: Double) -> Int? {
        guard let k = stamps.lastIndex(where: { Double($0.host) * hostTicksToNs <= ns }) else { return nil }
        return stamps[k].index + Int((ns - Double(stamps[k].host) * hostTicksToNs) * 1e-9 * sampleRate)
    }
}
let hostTicksToNs: Double = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return Double(tb.numer) / Double(tb.denom)
}()
func nowNs() -> Double { Double(mach_absolute_time()) * hostTicksToNs }

final class TimedSession {
    var playIndex = 0
    var recorded: [Float] = []
    var stamps: [(Int, UInt64)] = []
}

func runTimed(seconds: Double, generator: @escaping (Int) -> Float, during action: @escaping () -> Void) -> TimedRecording {
    let s = TimedSession()
    s.recorded.reserveCapacity(Int((seconds + 1) * sampleRate))
    var outQ: AudioQueueRef?
    var inQ: AudioQueueRef?
    var st = AudioQueueNewOutputWithDispatchQueue(&outQ, &format, 0, queue) { q, buf in
        let n = Int(buf.pointee.mAudioDataBytesCapacity) / 8
        let p = buf.pointee.mAudioData.assumingMemoryBound(to: Float.self)
        for i in 0..<n {
            let v = generator(s.playIndex)
            p[2 * i] = v
            p[2 * i + 1] = v
            s.playIndex += 1
        }
        buf.pointee.mAudioDataByteSize = UInt32(n * 8)
        AudioQueueEnqueueBuffer(q, buf, 0, nil)
    }
    guard st == noErr, let oq = outQ else { fail("AudioQueue uscita \(st)") }
    st = AudioQueueNewInputWithDispatchQueue(&inQ, &format, 0, queue) { q, buf, ts, _, _ in
        let n = Int(buf.pointee.mAudioDataByteSize) / 8
        let p = buf.pointee.mAudioData.assumingMemoryBound(to: Float.self)
        if ts.pointee.mFlags.contains(.hostTimeValid) { s.stamps.append((s.recorded.count, ts.pointee.mHostTime)) }
        for i in 0..<n { s.recorded.append(p[2 * i]) }
        AudioQueueEnqueueBuffer(q, buf, 0, nil)
    }
    guard st == noErr, let iq = inQ else { fail("AudioQueue ingresso \(st)") }
    var uid: Unmanaged<CFString>? = Unmanaged.passRetained(fakeOutput.uid as CFString)
    st = AudioQueueSetProperty(iq, kAudioQueueProperty_CurrentDevice, &uid, UInt32(MemoryLayout<Unmanaged<CFString>?>.size))
    uid?.release()
    guard st == noErr else { fail("selezione dispositivo di registrazione \(st)") }
    for q in [oq, iq] {
        for _ in 0..<3 {
            var b: AudioQueueBufferRef?
            AudioQueueAllocateBuffer(q, 2048 * 8, &b)
            guard let buf = b else { fail("buffer") }
            if q == oq {
                memset(buf.pointee.mAudioData, 0, 2048 * 8)
                buf.pointee.mAudioDataByteSize = 2048 * 8
            }
            AudioQueueEnqueueBuffer(q, buf, 0, nil)
        }
    }
    AudioQueueStart(iq, nil)
    AudioQueueStart(oq, nil)
    let t0 = Date()
    action()
    let rest = seconds - Date().timeIntervalSince(t0)
    if rest > 0 { Thread.sleep(forTimeInterval: rest) }
    AudioQueueStop(oq, true)
    AudioQueueStop(iq, true)
    AudioQueueDispose(oq, true)
    AudioQueueDispose(iq, true)
    return queue.sync { TimedRecording(samples: s.recorded, stamps: s.stamps.map { (index: $0.0, host: $0.1) }) }
}

/// Inviluppo di un tono di frequenza f (ampiezza) su una finestra di esattamente un periodo.
func toneEnvelope(_ x: [Float], f: Double) -> [Float] {
    let period = Int((sampleRate / f).rounded())
    var env = [Float](repeating: 0, count: x.count)
    guard x.count > period else { return env }
    var sc = 0.0, cc = 0.0
    for i in 0..<x.count {
        let ph = 2 * Double.pi * f * Double(i) / sampleRate
        sc += Double(x[i]) * sin(ph); cc += Double(x[i]) * cos(ph)
        if i >= period {
            let j = i - period
            let pj = 2 * Double.pi * f * Double(j) / sampleRate
            sc -= Double(x[j]) * sin(pj); cc -= Double(x[j]) * cos(pj)
        }
        if i >= period - 1 { env[i - period / 2] = Float(2 * sqrt(sc * sc + cc * cc) / Double(period)) }
    }
    return env
}

/// Residuo a banda larga (passa-alto 4° ordine Butterworth a `hp` Hz): misura click e discontinuità.
/// Restituisce il massimo RMS su finestre di 2 ms.
func broadbandResidue(_ x: ArraySlice<Float>, hp: Double) -> Double {
    func biquadHP(_ input: [Double], q: Double) -> [Double] {
        let w0 = 2 * Double.pi * hp / sampleRate, cw = cos(w0), alpha = sin(w0) / (2 * q)
        let b0 = (1 + cw) / 2, b1 = -(1 + cw), b2 = (1 + cw) / 2, a0 = 1 + alpha, a1 = -2 * cw, a2 = 1 - alpha
        var y = [Double](repeating: 0, count: input.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in input.indices {
            let v = (b0 * input[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
            x2 = x1; x1 = input[i]; y2 = y1; y1 = v; y[i] = v
        }
        return y
    }
    let y = biquadHP(biquadHP(x.map(Double.init), q: 0.5412), q: 1.3066)
    let w = Int(0.002 * sampleRate)
    var worst = 0.0
    var i = Int(0.02 * sampleRate) // salta il transitorio iniziale dei filtri
    while i + w <= y.count {
        var e = 0.0
        for k in i..<(i + w) { e += y[k] * y[k] }
        worst = max(worst, sqrt(e / Double(w)))
        i += w / 2
    }
    return worst
}

/// Residuo a banda larga (passa-alto 4° ordine a 2,5 kHz) rispetto al livello EFFETTIVO del tono
/// (picco sull'ultimo periodo): una rampa di volume non è un click, un gradino sì.
var lastResidueAt = 0.0
func relativeResidueDb(_ x: ArraySlice<Float>, periodSamples: Int) -> Double {
    func biquadHP(_ input: [Double], q: Double) -> [Double] {
        let w0 = 2 * Double.pi * 2500 / sampleRate, cw = cos(w0), alpha = sin(w0) / (2 * q)
        let b0 = (1 + cw) / 2, b1 = -(1 + cw), b2 = (1 + cw) / 2, a0 = 1 + alpha, a1 = -2 * cw, a2 = 1 - alpha
        var y = [Double](repeating: 0, count: input.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in input.indices {
            let v = (b0 * input[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
            x2 = x1; x1 = input[i]; y2 = y1; y1 = v; y[i] = v
        }
        return y
    }
    let xs = x.map(Double.init)
    let y = biquadHP(biquadHP(xs, q: 0.5412), q: 1.3066)
    var worst = 0.0, at = 0
    var pk = 0.0
    for i in xs.indices {
        if i % periodSamples == 0 { pk = 0; for k in max(0, i - periodSamples)..<i { pk = max(pk, abs(xs[k])) } }
        if i > 1000, pk > 1e-6, abs(y[i]) / pk > worst { worst = abs(y[i]) / pk; at = i }
    }
    lastResidueAt = Double(at) / sampleRate
    return 20 * log10(max(worst, 1e-12))
}

/// Interruzione dell'audio della macchina di CI (non del motore): un blocco di 5 ms il cui picco
/// crolla sotto il 10 % dei blocchi precedenti. Una tacca di volume (4 dB, con rampa) non lo fa mai.
func hasDropout(_ x: ArraySlice<Float>) -> Bool {
    let blocks = stride(from: x.startIndex, to: x.endIndex - 240, by: 240).map { i in x[i..<(i + 240)].map { abs($0) }.max() ?? 0 }
    guard blocks.count > 20 else { return false }
    for k in 4..<(blocks.count - 4) {
        let ref = blocks[(k - 4)..<k].max() ?? 0
        if ref > 1e-3, blocks[k] < 0.1 * ref { return true }
    }
    return false
}

/// Registra con `record` e misura il residuo; se il residuo supera la soglia per un'interruzione
/// dell'audio della CI, ripete la misura (max 3 tentativi), come per le misure dei toni.
func residueWithRetry(_ label: String, _ record: () -> [Float]) -> Double {
    var r = 0.0
    for attempt in 1...3 {
        let x = record()
        let pk = x.map { abs($0) }.max() ?? 0
        guard pk > 1e-3, let on = x.firstIndex(where: { abs($0) > pk * 0.5 }), on + 9600 < x.count else {
            print("  ATTENZIONE: \(label): registrazione silenziosa, tentativo \(attempt)"); continue
        }
        let body = x[(on + 4800)..<(x.count - 2400)]
        r = relativeResidueDb(body, periodSamples: 240)
        if r <= -60 || !hasDropout(body) { return r }
        dropoutCount += 1
        print(String(format: "  ATTENZIONE: interruzione dell'audio della CI durante %@ (residuo %.1f dB), tentativo %d", label, r, attempt))
    }
    return r
}

print("\nFase 6: tasti volume durante la riproduzione (click, livelli, sincronismo con macOS)")
do {
    // Configurazione realistica: profilo Pop, Auto Gain acceso, limiter acceso.
    let pop = FactoryProfiles.profile("pop")!.settings
    apply(pop)
    let ag: Float = pop.gains.withUnsafeBufferPointer { aeq_auto_gain_db($0.baseAddress, pop.preamp, pop.bass, pop.treble, sampleRate) }
    aeq_set_auto_gain(router.dsp, ag)
    aeq_set_limiter_enabled(router.dsp, 1)
    router.setUserVolume(0.75, source: .app)
    Thread.sleep(forTimeInterval: 3.0) // rampa + allineamento dell'indicatore di macOS
    let toneF = 200.0, amp: Float = 0.25
    let tone: (Int) -> Float = { i in amp * Float(sin(2 * Double.pi * toneF * Double(i) / sampleRate)) }
    let framesBefore = aeq_frames_processed(router.dsp)
    let errorsBefore = router.renderErrors
    let runningBefore = router.running
    var hwSeen: Set<Int> = []
    func sampleHw() { hwSeen.insert(Int(((CA.volumeScalar(fakeOutput.id, scope: .output) ?? -1) * 1000).rounded())) }

    // 6a) 16 tacche (8 giù, 8 su) ogni 250 ms, come tenere premuti/rilasciare i tasti volume.
    var marks: [(ns: Double, v: Float)] = []
    var rec = TimedRecording(samples: [], stamps: [])
    let res = residueWithRetry("6a") {
    marks = []
    router.setUserVolume(0.75, source: .app)
    Thread.sleep(forTimeInterval: 0.5)
    rec = runTimed(seconds: 6.5, generator: tone) {
        Thread.sleep(forTimeInterval: 1.0)
        var v: Float = 0.75
        for k in 0..<16 {
            v += (k < 8 ? -1 : 1) / 16
            marks.append((nowNs(), v))
            router.setUserVolume(v, source: .keys)
            sampleHw()
            Thread.sleep(forTimeInterval: 0.25)
        }
    }
    return rec.samples
    }
    let x = rec.samples
    guard let onset = x.firstIndex(where: { abs($0) > 1e-4 }) else { fail("fase 6a: registrazione silenziosa") }
    // Livello a fine tacca rispetto al livello iniziale (attesi -4 dB per tacca con la curva di BlackHole 16ch).
    let env = toneEnvelope(x, f: toneF)
    let refIdx = rec.index(atNs: marks[0].ns).map { $0 - 4800 } ?? onset + 24000
    let ref = Double(env[max(onset + 2400, refIdx)])
    var worstLevel = 0.0
    for (k, m) in marks.enumerated() {
        let endNs = k + 1 < marks.count ? marks[k + 1].ns : m.ns + 0.25e9
        guard let i = rec.index(atNs: endNs - 0.02e9), i < env.count else { continue }
        let measured = 20 * log10(Double(env[i]) / ref)
        let expected = Double(router.volumeDb(m.v) - router.volumeDb(0.75))
        worstLevel = max(worstLevel, abs(measured - expected))
    }
    print(String(format: "  6a) 16 tacche ogni 250 ms (Pop + Auto Gain + limiter): residuo a banda larga %.1f dB rispetto al tono, scarto livello/curva max %.2f dB",
                 res, worstLevel))
    if res > -60 { print("FALLITO: click con i tasti volume (soglia -60 dB)"); failures += 1 }
    if worstLevel > 0.3 { print("FALLITO: livello diverso dalla curva del volume"); failures += 1 }

    // 6b) Ripetizione rapida (una tacca ogni 30 ms, la velocità massima di ripetizione dei tasti).
    let res2 = residueWithRetry("6b") {
        runTimed(seconds: 3.5, generator: tone) {
            Thread.sleep(forTimeInterval: 0.8)
            var v: Float = 0.75
            for k in 0..<16 {
                v += (k < 8 ? -1 : 1) / 16
                router.setUserVolume(v, source: .keys)
                sampleHw()
                Thread.sleep(forTimeInterval: 0.03)
            }
        }.samples
    }
    print(String(format: "  6b) ripetizione rapida (una tacca ogni 30 ms): residuo %.1f dB", res2))
    if res2 > -60 { print("FALLITO: click con ripetizione rapida (soglia -60 dB)"); failures += 1 }

    // 6c) Muto e ripristino dai tasti.
    var mutedLevel = 0.0
    let rec3 = runTimed(seconds: 3.6, generator: tone) {
        Thread.sleep(forTimeInterval: 0.8)
        router.setUserMuted(true, source: .keys)
        Thread.sleep(forTimeInterval: 1.4)
        router.setUserMuted(false, source: .keys)
    }
    let s3 = rec3.samples
    let peak3 = s3.map { abs($0) }.max() ?? 0
    guard peak3 > 1e-3, let on3 = s3.firstIndex(where: { abs($0) > peak3 * 0.5 }) else { fail("fase 6c: registrazione silenziosa") }
    let full = Double(toneEnvelope(s3, f: toneF)[on3 + 9600])
    // Residuo rispetto al livello pieno (durante muto e ripresa il livello effettivo tende a zero).
    func absResidue(_ v: ArraySlice<Float>) -> Double { broadbandResidue(v, hp: 2500) * sqrt(2) }
    let res3 = 20 * log10(max(absResidue(s3[(on3 + 4800)...]), 1e-12) / full)
    let midMute = on3 + Int(1.0 * sampleRate) + 9600
    if midMute + 4800 < s3.count { mutedLevel = Double(s3[midMute..<(midMute + 4800)].map { abs($0) }.max() ?? 0) }
    print(String(format: "  6c) muto/ripristino: residuo %.1f dB rispetto al tono, livello a muto %.1f dB", res3,
                 20 * log10(max(mutedLevel, 1e-9) / full)))
    if res3 > -60 { print("FALLITO: click con muto/ripristino (soglia -60 dB)"); failures += 1 }
    if mutedLevel / full > 1e-4 { print("FALLITO: il muto non è silenzioso"); failures += 1 }

    // Nessun riavvio del motore, nessun errore, volume hardware dell'uscita mai toccato.
    let frames = aeq_frames_processed(router.dsp) - framesBefore
    print("      volume hardware dell'uscita durante le prove: \(hwSeen.sorted().map { String(format: "%.3f", Double($0) / 1000) }) | frame elaborati \(frames) | errori \(router.renderErrors - errorsBefore)")
    if hwSeen != [1000] { print("FALLITO: il volume hardware dell'uscita è cambiato"); failures += 1 }
    if router.running != runningBefore || router.renderErrors != errorsBefore {
        print("FALLITO: il motore è stato riavviato o ha avuto errori"); failures += 1
    }

    // Livello di fondo del percorso reale (nessun cambio di volume): riferimento per i residui.
    let recFloor = runTimed(seconds: 2.0, generator: tone) {}
    let peakF = recFloor.samples.map { abs($0) }.max() ?? 0
    if let onF = recFloor.samples.firstIndex(where: { abs($0) > peakF * 0.5 }), onF + 9600 < recFloor.samples.count {
        print(String(format: "      riferimento: residuo senza alcun cambio di volume %.1f dB", relativeResidueDb(recFloor.samples[(onF + 4800)...], periodSamples: 240)))
    }

    // 6d) Sincronismo con il volume di macOS (BlackHole) dopo i tasti: a micro-passi, entro pochi secondi.
    print("      curva del volume: \(router.volumeCurve.source); BlackHole: 0.70000 -> \(String(format: "%.5f", { CA.setVolumeScalar(loopback.id, scope: .output, 0.7); return CA.volumeScalar(loopback.id, scope: .output) ?? -1 }())), 0.70008 -> \(String(format: "%.5f", { CA.setVolumeScalar(loopback.id, scope: .output, 0.70008); return CA.volumeScalar(loopback.id, scope: .output) ?? -1 }()))")
    Thread.sleep(forTimeInterval: 0.5)
    let steps0 = router.walkerSteps, ext0 = router.externalVolumeChanges
    router.setUserVolume(0.5, source: .keys)
    var synced = false
    for _ in 0..<60 {
        Thread.sleep(forTimeInterval: 0.25)
        if abs((CA.volumeScalar(loopback.id, scope: .output) ?? -1) - 0.5) < 0.001 { synced = true; break }
    }
    print(String(format: "  6d) volume di macOS dopo i tasti (-> 0.50): %.3f, utente %.3f, micro-passi %d (costo medio di una scrittura %.2f ms), cambi esterni %d",
                 CA.volumeScalar(loopback.id, scope: .output) ?? -1, router.userVolume, router.walkerSteps - steps0,
                 router.walkerWriteCostMs, router.externalVolumeChanges - ext0))
    if !synced { print("FALLITO: il volume di macOS non si è allineato al volume dell'utente"); failures += 1 }

    // 6e) Cambio esterno (Centro di Controllo / Impostazioni) MENTRE l'indicatore si sta allineando
    //     (con l'audio presente, quindi a micro-passi): diventa il volume dell'utente e non viene sovrascritto.
    let bg = DispatchQueue(label: "tono-6e")
    var tonePlaying = true
    bg.async { _ = runTimed(seconds: 3.0, generator: tone) {}; tonePlaying = false }
    Thread.sleep(forTimeInterval: 0.6)
    router.setUserVolume(0.25, source: .keys)
    Thread.sleep(forTimeInterval: 0.8) // micro-passi in corso
    // Trascinamento nel Centro di Controllo: scritture da un ALTRO processo (osascript, come il Centro
    // di Controllo e le Impostazioni), che finiscono a 62 %. Dallo stesso processo Core Audio può
    // restituire alla nostra lettura un valore in cache non aggiornato: non rappresenterebbe l'uso reale.
    router.log = { print("      [router] \($0)") }
    let st6e = router.walkerSteps, ex6e = router.externalVolumeChanges
    for pct in [59, 60, 61, 62] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "set volume output volume \(pct)"]
        try? p.run(); p.waitUntilExit()
    }
    Thread.sleep(forTimeInterval: 0.5)
    print("      durante il trascinamento: micro-passi \(router.walkerSteps - st6e), cambi esterni rilevati \(router.externalVolumeChanges - ex6e), utente \(router.userVolume)")
    let bhAfter = CA.volumeScalar(loopback.id, scope: .output) ?? -1
    let hwAfter = CA.volumeScalar(fakeOutput.id, scope: .output) ?? -1
    while tonePlaying { Thread.sleep(forTimeInterval: 0.1) }
    router.log = nil
    if abs(bhAfter - 0.62) > 0.006 { print(String(format: "FALLITO: il volume di macOS impostato dall'esterno è stato sovrascritto (%.4f)", bhAfter)); failures += 1 }
    print(String(format: "  6e) volume cambiato da un altro processo (59→62 %%) durante l'allineamento: volume utente %.3f, volume di macOS %.4f, volume hardware uscita %.3f",
                 router.userVolume, bhAfter, hwAfter))
    if abs(router.userVolume - bhAfter) > 0.001 || abs(bhAfter - 0.62) > 0.006 { print("FALLITO: cambio di volume esterno non recepito"); failures += 1 }
    if abs(hwAfter - 1) > 0.001 { print("FALLITO: il cambio esterno ha modificato il volume hardware"); failures += 1 }
    // 6f) Senza audio l'indicatore di macOS si allinea subito (nessun gradino udibile possibile).
    Thread.sleep(forTimeInterval: 1.0) // nessun audio: l'inviluppo d'ingresso decade
    let jumps0 = router.walkerJumps
    let t6f = Date()
    router.setUserVolume(0.3125, source: .keys)
    var syncedSilent = false
    for _ in 0..<40 {
        Thread.sleep(forTimeInterval: 0.05)
        if abs((CA.volumeScalar(loopback.id, scope: .output) ?? -1) - 0.3125) < 0.0005 { syncedSilent = true; break }
    }
    print(String(format: "  6f) in silenzio: volume di macOS allineato in %.2f s (allineamenti istantanei %d)",
                 Date().timeIntervalSince(t6f), router.walkerJumps - jumps0))
    if !syncedSilent { print("FALLITO: in silenzio il volume di macOS non si è allineato subito"); failures += 1 }
    router.setUserVolume(1.0, source: .app)
    aeq_set_auto_gain(router.dsp, 0)
    Thread.sleep(forTimeInterval: 0.5)
}

// MARK: Fase 7 – gestione degli eventi dei tasti volume (stessa funzione chiamata dall'event tap)
print("\nFase 7: tasti volume – pressioni singole, rapide, prolungate, alternate, sincronismo, duplicati")
do {
    // Notifiche all'interfaccia (coalescenti) consegnate sul main thread, come nell'app.
    var delivered: [(v: Float, keys: Bool)] = []
    router.onUserVolumeChange = { v, _, _, keys in delivered.append((v, keys)) }
    func drainMain(_ t: Double = 0.2) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }
    func dspMatches() -> Bool {
        abs(aeq_get_volume_target(router.dsp) - router.volumeCurve.gain(router.userVolume)) < 1e-6
    }
    var worstCallUs = 0.0
    func press(_ k: VolumeKey, fine: Bool = false) -> Bool {
        let t0 = nowNs()
        let ok = router.handleKey(k, fine: fine)
        worstCallUs = max(worstCallUs, (nowNs() - t0) / 1000)
        return ok
    }
    router.setUserVolume(0.5, source: .app)
    drainMain(0.5)

    // 7a) Pressione singola: una tacca, DSP aggiornato prima del ritorno della funzione.
    let n0 = router.keyEventsHandled
    _ = press(.down)
    let single = router.userVolume
    let okSingle = abs(single - 0.4375) < 1e-6 && router.keyEventsHandled == n0 + 1 && dspMatches()
    print(String(format: "  7a) pressione singola: 0.5000 -> %.4f, DSP aggiornato: %@", single, dspMatches() ? "sì" : "no"))
    if !okSingle { print("FALLITO: la pressione singola non ha prodotto esattamente una tacca"); failures += 1 }

    // 7b) Pressioni rapide (2 ms) MENTRE l'indicatore di macOS si sta allineando a micro-passi
    //     (situazione che prima ritardava o faceva perdere i comandi).
    router.setUserVolume(0.0625, source: .app)
    Thread.sleep(forTimeInterval: 0.45) // micro-passi in corso, listener di BlackHole attivi
    let stepsBefore = router.walkerSteps
    let nb = router.keyEventsHandled
    for _ in 0..<12 { _ = press(.up); Thread.sleep(forTimeInterval: 0.002) }
    let rapid = router.userVolume
    print(String(format: "  7b) 12 pressioni a 2 ms durante i micro-passi (%d già eseguiti): %.4f (atteso 0.8125), tasti contati %d",
                 stepsBefore, rapid, router.keyEventsHandled - nb))
    if abs(rapid - 0.8125) > 1e-6 || router.keyEventsHandled - nb != 12 || !dspMatches() {
        print("FALLITO: pressioni rapide perse o duplicate"); failures += 1
    }

    // 7c) Pressione prolungata (ripetizione automatica ogni 33 ms): limiti 0 e 1 rispettati.
    for _ in 0..<20 { _ = press(.down); Thread.sleep(forTimeInterval: 0.033) }
    let held0 = router.userVolume
    for _ in 0..<20 { _ = press(.up); Thread.sleep(forTimeInterval: 0.033) }
    let held1 = router.userVolume
    print(String(format: "  7c) pressione prolungata: 20 giù -> %.4f, 20 su -> %.4f", held0, held1))
    if held0 != 0 || held1 != 1 || !dspMatches() { print("FALLITO: pressione prolungata"); failures += 1 }

    // 7d) Alternanza + / − (20 coppie a 10 ms) e passo fine ⌥⇧.
    router.setUserVolume(0.5, source: .app)
    for _ in 0..<20 { _ = press(.up); Thread.sleep(forTimeInterval: 0.01); _ = press(.down); Thread.sleep(forTimeInterval: 0.01) }
    let alt = router.userVolume
    _ = press(.up, fine: true)
    let fine = router.userVolume
    print(String(format: "  7d) alternanza 20 × (+, −): %.4f (atteso 0.5000); ⌥⇧ +: %.4f (atteso 0.5156)", alt, fine))
    if abs(alt - 0.5) > 1e-6 || abs(fine - 0.515625) > 1e-6 { print("FALLITO: alternanza o passo fine"); failures += 1 }

    // 7e) Due thread contemporanei (es. ripetizione + nuovo tasto): nessuna pressione persa.
    router.setUserVolume(0.5, source: .app)
    let group = DispatchGroup()
    for dir in [VolumeKey.up, .down] {
        DispatchQueue.global(qos: .userInteractive).async(group: group) {
            for _ in 0..<50 { _ = router.handleKey(dir, fine: true); usleep(200) }
        }
    }
    group.wait()
    let conc = router.userVolume
    print(String(format: "  7e) 50 + e 50 − da due thread contemporanei: %.4f (atteso 0.5000)", conc))
    if abs(conc - 0.5) > 1e-6 || !dspMatches() { print("FALLITO: aggiornamenti concorrenti persi"); failures += 1 }

    // 7f) Muto dai tasti e ritorno: un tasto volume toglie il muto (come macOS).
    _ = press(.mute)
    let mutedOK = router.userMuted && aeq_get_volume_target(router.dsp) == 0
    _ = press(.up)
    let unmutedOK = !router.userMuted && dspMatches()
    print("  7f) muto: \(mutedOK ? "DSP a 0" : "ERRORE"), volume su dopo il muto: \(unmutedOK ? "muto tolto, DSP corretto" : "ERRORE")")
    if !mutedOK || !unmutedOK { print("FALLITO: muto dai tasti"); failures += 1 }

    // 7g) Sincronismo: ultima notifica all'interfaccia = volume interno = DSP; indicatore di macOS allineato.
    drainMain(0.5)
    let last = delivered.last
    print(String(format: "  7g) notifiche all'interfaccia %d (coalescenti, per %d tasti), ultima %.4f, volume interno %.4f; durata max di handleKey %.0f µs",
                 delivered.count, router.keyEventsHandled - n0, last?.v ?? -1, router.userVolume, worstCallUs))
    if last == nil || abs(last!.v - router.userVolume) > 1e-6 { print("FALLITO: HUD/cursore non coerenti con il volume effettivo"); failures += 1 }
    if worstCallUs > 2000 { print("FALLITO: gestione del tasto troppo lenta"); failures += 1 }
    let target = router.userVolume
    var synced = false
    let tSync = Date()
    for _ in 0..<80 {
        Thread.sleep(forTimeInterval: 0.25)
        if abs((CA.volumeScalar(loopback.id, scope: .output) ?? -1) - target) < 0.001 { synced = true; break }
    }
    print(String(format: "      volume di macOS allineato a %.4f in %.1f s; cambi esterni rilevati durante i tasti: %d",
                 target, Date().timeIntervalSince(tSync), router.externalVolumeChanges))
    if !synced { print("FALLITO: volume di macOS non allineato"); failures += 1 }

    // 7h) Audio durante pressioni rapide e alternate: nessun click.
    router.setUserVolume(0.75, source: .app)
    Thread.sleep(forTimeInterval: 0.5)
    let toneF = 200.0
    let steps7 = router.walkerSteps, jumps7 = router.walkerJumps
    let r7 = residueWithRetry("7h") {
        router.setUserVolume(0.75, source: .app)
        Thread.sleep(forTimeInterval: 0.4)
        return runTimed(seconds: 3.5, generator: { i in 0.25 * Float(sin(2 * Double.pi * toneF * Double(i) / sampleRate)) }) {
            Thread.sleep(forTimeInterval: 0.8)
            for k in 0..<24 { _ = router.handleKey(k % 3 == 2 ? .up : .down, fine: false); Thread.sleep(forTimeInterval: 0.04) }
        }.samples
    }
    print(String(format: "  7h) 24 pressioni miste ogni 40 ms durante la riproduzione: residuo %.1f dB (massimo a %.3f s dall'inizio della misura; micro-passi %d, allineamenti istantanei %d)",
                 r7, lastResidueAt, router.walkerSteps - steps7, router.walkerJumps - jumps7))
    if r7 > -60 { print("FALLITO: click durante le pressioni (soglia -60 dB)"); failures += 1 }

    // 7i) Nessun listener duplicato dopo riavvii del motore; nessuno a motore spento.
    let listeners0 = router.volumeListenerCount
    var counts: [Int] = []
    for _ in 0..<3 {
        router.stop(restoreDefaultOutput: true)
        counts.append(router.volumeListenerCount)
        try router.start(output: fakeOutput, loopback: loopback)
        counts.append(router.volumeListenerCount)
    }
    let keysWhenStopped: Bool = {
        router.stop(restoreDefaultOutput: true)
        let r = router.handleKey(.up, fine: false)
        return r
    }()
    try router.start(output: fakeOutput, loopback: loopback)
    print("  7i) listener del volume: \(listeners0) all'inizio, dopo 3 riavvii (spento/acceso) \(counts); tasto a motore spento \(keysWhenStopped ? "GESTITO (errore)" : "lasciato a macOS")")
    if counts != [0, listeners0, 0, listeners0, 0, listeners0] || listeners0 == 0 || keysWhenStopped {
        print("FALLITO: listener duplicati o tasti gestiti a motore spento"); failures += 1
    }
    router.onUserVolumeChange = nil
    router.setUserVolume(1.0, source: .app)
    Thread.sleep(forTimeInterval: 0.3)
} catch {
    print("FALLITO: fase 7: \(error.localizedDescription)"); failures += 1
}

// Bypass: con un profilo attivo ma EQ disattivato il suono deve tornare neutro.
apply(FactoryProfiles.profile("voice")!.settings, eq: false)
let byp = zip(measureClean("bypass"), flat).map { 20 * log10($0 / $1) }
let bypWorst = byp.map { abs($0) }.max() ?? 0
print(String(format: "\nBypass EQ (profilo Voce caricato): scarto max da Flat %.2f dB", bypWorst))
if bypWorst > 0.3 { print("FALLITO: bypass non neutro"); failures += 1 }

// Arresto: l'uscita di sistema torna sul dispositivo "reale".
router.stop(restoreDefaultOutput: true)
let restored = CA.defaultOutputDevice()
print("Dopo l'arresto l'uscita di sistema è: \(restored.flatMap { CA.device($0)?.name } ?? "?")")
if restored != fakeOutput.id { print("FALLITO: uscita di sistema non ripristinata"); failures += 1 }

// Fase 2: uscita reale non-BlackHole (es. dispositivo integrato del Mac) come clock dell'aggregate.
// Non possiamo registrarne l'uscita, ma verifichiamo che l'audio di sistema arrivi al DSP.
if let builtIn = CA.allDevices().first(where: { $0.isSelectableOutput }) {
    print("\nFase 2: uscita \(builtIn.name) (\(builtIn.transportLabel))")
    apply(.flat)
    // Il volume dell'utente è quello del dispositivo prima dell'avvio: per misurare il livello a
    // guadagno unitario lo si porta al 100 % (come fa la fase 4 per l'uscita di prova).
    let found = CA.volumeScalar(builtIn.id, scope: .output)
    if CA.hasSettableVolume(builtIn.id, scope: .output) { CA.setVolumeScalar(builtIn.id, scope: .output, 1) }
    print("  volume del dispositivo trovato: \(found.map { String(format: "%.3f", $0) } ?? "nessun controllo") -> 1.000 per la misura")
    do {
        try router.start(output: builtIn, loopback: loopback)
        _ = aeq_read_peak(router.dsp, 0)
        let before = aeq_frames_processed(router.dsp)
        _ = runSequence() // suona i toni sull'uscita di sistema (= loopback)
        let frames = aeq_frames_processed(router.dsp) - before
        let peak = aeq_read_peak(router.dsp, 0)
        print(String(format: "  frame elaborati %llu, picco in uscita dal DSP %.4f (atteso ~%.2f), errori di render %d",
                     frames, peak, toneAmplitude, router.renderErrors))
        if frames < 48000 { print("FALLITO: il motore non elabora audio con \(builtIn.name)"); failures += 1 }
        if peak < toneAmplitude * 0.8 { print("FALLITO: l'audio di sistema non arriva al DSP con \(builtIn.name)"); failures += 1 }

        // Fase 3: audio prodotto da un ALTRO processo (afplay), come Safari/Musica/YouTube.
        _ = aeq_read_peak(router.dsp, 0)
        let sound = ["/System/Library/Sounds/Glass.aiff", "/System/Library/Sounds/Ping.aiff"]
            .first { FileManager.default.fileExists(atPath: $0) }
        if let sound = sound {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            p.arguments = [sound]
            try? p.run()
            var maxPeak: Float = 0
            for _ in 0..<30 {
                Thread.sleep(forTimeInterval: 0.05)
                maxPeak = max(maxPeak, aeq_read_peak(router.dsp, 0))
            }
            p.waitUntilExit()
            print(String(format: "Fase 3: suono di sistema da afplay (processo esterno) -> picco nel DSP %.4f", maxPeak))
            if maxPeak < 0.01 { print("FALLITO: l'audio di un'altra app non arriva al motore"); failures += 1 }
        }
        router.stop(restoreDefaultOutput: true)
    } catch {
        print("FALLITO: avvio con \(builtIn.name): \(error.localizedDescription)"); failures += 1
    }
}
if let o = originalDefault { CA.setDefaultOutputDevice(o) }


// Fase 4: livello RMS e picco con EQ Flat, nello scenario segnalato dall'utente:
// volume di sistema (= volume di BlackHole) basso all'avvio, uscita reale al 100 %.
// Prima della correzione BlackHole attenuava il segnale catturato di -48 dB.
do {
    print("\nFase 4: livello RMS/picco con EQ Flat (volume BlackHole al 25 % = -48 dB all'avvio)")
    let levelLead = 0.6, levelSeconds = 2.6
    func multitone(_ x: Double) -> Double {
        let a: Double = 0.2 * sin(2.0 * Double.pi * 100.0 * x)
        let b: Double = 0.15 * sin(2.0 * Double.pi * 1000.0 * x + 0.3)
        let c: Double = 0.1 * sin(2.0 * Double.pi * 5000.0 * x + 1.1)
        return a + b + c
    }
    let signal: (Int) -> Float = { (i: Int) -> Float in
        let t: Double = Double(i) / sampleRate - levelLead
        if t < 0 || t >= 2.0 { return 0 }
        return Float(multitone(Double(i) / sampleRate))
    }
    // Statistiche del segnale di ingresso (periodo 10 ms = 480 campioni, armoniche di 100 Hz).
    var refSum = 0.0, refPeak = 0.0
    for i in 0..<48000 {
        let v: Double = multitone(Double(i) / sampleRate)
        refSum += v * v
        refPeak = max(refPeak, abs(v))
    }
    let refRms = sqrt(refSum / 48000)

    func measureLevel() -> (rms: Double, peak: Double) {
        let rec = runSequence(generator: signal, seconds: levelSeconds)
        guard let onset = rec.firstIndex(where: { abs($0) > 1e-7 }) else { return (0, 0) }
        let a = onset + Int(0.3 * sampleRate), b = min(onset + Int(1.6 * sampleRate), rec.count)
        guard b > a else { return (0, 0) }
        var sum = 0.0, pk = 0.0
        for v in rec[a..<b] { sum += Double(v) * Double(v); pk = max(pk, Double(abs(v))) }
        return (sqrt(sum / Double(b - a)), pk)
    }
    func db(_ x: Double) -> Double { 20 * log10(max(x, 1e-12)) }
    func state(_ tag: String) {
        print(String(format: "     [%@] %@: scalar %.3f (%.1f dB, mute %@) | %@: scalar %.3f (%.1f dB) | compensazione %@",
                     tag, loopback.name, CA.volumeScalar(loopback.id, scope: .output) ?? -1,
                     CA.volumeDecibels(loopback.id, scope: .output) ?? 99,
                     (CA.isMuted(loopback.id, scope: .output) ?? false) ? "sì" : "no",
                     fakeOutput.name, CA.volumeScalar(fakeOutput.id, scope: .output) ?? -1,
                     CA.volumeDecibels(fakeOutput.id, scope: .output) ?? 99,
                     router.loopbackCaptureGainDb.map { String(format: "%+.1f dB", -$0) } ?? "nessuna"))
    }

    CA.setVolumeScalar(fakeOutput.id, scope: .output, 1.0)
    CA.setVolumeScalar(loopback.id, scope: .output, 0.25)
    print(String(format: "  stato iniziale: %@ volume %.2f (%.1f dB), %@ volume %.2f",
                 loopback.name, CA.volumeScalar(loopback.id, scope: .output) ?? -1,
                 CA.volumeDecibels(loopback.id, scope: .output) ?? 0,
                 fakeOutput.name, CA.volumeScalar(fakeOutput.id, scope: .output) ?? -1))
    apply(.flat)
    aeq_set_volume(router.dsp, 1)

    // 0) Riproduzione del difetto: senza ponte volume (comportamento della versione precedente).
    router.volumeBridgeEnabled = false
    state("0 prima dell'avvio")
    try router.start(output: fakeOutput, loopback: loopback)
    Thread.sleep(forTimeInterval: 0.3)
    state("0 avviato")
    print("     traccia avvio: \(router.startTrace)")
    let m0 = measureLevel()
    let bhDb = Double(CA.volumeDecibels(loopback.id, scope: .output) ?? 0)
    print(String(format: "  0) versione precedente: RMS uscita %+.2f dB, picco %+.2f dB  <- perdita = volume di BlackHole (%.1f dB)",
                 db(m0.rms / refRms), db(m0.peak / refPeak), bhDb))
    if abs(db(m0.rms / refRms) - bhDb) > 0.5 {
        print("NOTA: la perdita misurata senza correzione non coincide con il volume di BlackHole")
    }
    router.stop(restoreDefaultOutput: true)
    router.volumeBridgeEnabled = true
    CA.setVolumeScalar(fakeOutput.id, scope: .output, 1.0)
    CA.setVolumeScalar(loopback.id, scope: .output, 0.25)
    Thread.sleep(forTimeInterval: 0.2)

    // A) Con la correzione.
    state("A prima")
    try router.start(output: fakeOutput, loopback: loopback)
    Thread.sleep(forTimeInterval: 0.3)
    state("A avviato")
    print("     traccia avvio: \(router.startTrace)")
    let outAfterStart = CA.volumeScalar(fakeOutput.id, scope: .output) ?? -1
    if abs(outAfterStart - 1.0) > 0.01 {
        print(String(format: "FALLITO: l'avvio ha cambiato il volume del dispositivo di uscita (1.00 -> %.2f)", outAfterStart)); failures += 1
    }

    let m1 = measureLevel()
    let dR1 = db(m1.rms / refRms), dP1 = db(m1.peak / refPeak)
    print(String(format: "  A) RMS ingresso %.4f uscita %.4f (%+.2f dB) | picco ingresso %.4f uscita %.4f (%+.2f dB)",
                 refRms, m1.rms, dR1, refPeak, m1.peak, dP1))
    if abs(dR1) > 0.2 || abs(dP1) > 0.2 { print("FALLITO: con EQ Flat il livello in uscita non corrisponde all'ingresso"); failures += 1 }

    // Simula i tasti volume: l'utente porta il volume di sistema al 50 %.
    CA.setVolumeScalar(loopback.id, scope: .output, 0.5)
    Thread.sleep(forTimeInterval: 0.3)
    state("B")
    let mirrored = CA.volumeScalar(fakeOutput.id, scope: .output) ?? -1
    let outDb = Double(CA.volumeDecibels(fakeOutput.id, scope: .output) ?? 0)
    _ = aeq_read_input_peak(router.dsp)
    let m2 = measureLevel()
    let inPeakDsp = Double(aeq_read_input_peak(router.dsp))
    let dR2 = db(m2.rms / refRms)
    print(String(format: "  B) volume di sistema -> 50 %%: volume hardware uscita %.2f (%.1f dB, invariato); RMS uscita %+.2f dB (curva %+.1f dB); picco all'ingresso del DSP %.4f (%+.2f dB)",
                 mirrored, outDb, dR2, router.volumeDb(0.5), inPeakDsp, db(inPeakDsp / refPeak)))
    // Il volume dell'utente è applicato dal DSP con la curva del dispositivo di uscita; il volume
    // hardware resta fisso (nessun gradino nel dispositivo).
    let curveDb = Double(router.volumeDb(0.5))
    if abs(mirrored - 1.0) > 0.01 { print("FALLITO: il volume hardware dell'uscita è cambiato"); failures += 1 }
    if abs(router.userVolume - 0.5) > 0.001 { print("FALLITO: il volume di sistema non è diventato il volume dell'utente"); failures += 1 }
    if abs(dR2 - curveDb) > 0.3 { print("FALLITO: attenuazione diversa dalla curva del volume (\(curveDb) dB)"); failures += 1 }
    if abs(db(inPeakDsp / refPeak)) > 0.2 { print("FALLITO: il segnale catturato non arriva al DSP a guadagno unitario"); failures += 1 }

    router.stop(restoreDefaultOutput: true)
    let restoredScalar = CA.volumeScalar(loopback.id, scope: .output) ?? -1
    print(String(format: "  dopo lo spegnimento: volume %@ ripristinato a %.2f", loopback.name, restoredScalar))
    if abs(restoredScalar - 0.25) > 0.01 { print("FALLITO: volume del loopback non ripristinato"); failures += 1 }
    // A motore spento il volume del loopback non deve più influire sul dispositivo di uscita.
    let outBefore = CA.volumeScalar(fakeOutput.id, scope: .output) ?? -1
    CA.setVolumeScalar(loopback.id, scope: .output, 0.8)
    Thread.sleep(forTimeInterval: 0.4)
    let outAfter = CA.volumeScalar(fakeOutput.id, scope: .output) ?? -1
    print(String(format: "  motore spento, volume loopback -> 0.80: volume uscita %.2f -> %.2f", outBefore, outAfter))
    if abs(outAfter - outBefore) > 0.01 { print("FALLITO: il ponte volume è rimasto attivo dopo lo spegnimento"); failures += 1 }
    CA.setVolumeScalar(fakeOutput.id, scope: .output, 1.0)
    CA.setVolumeScalar(loopback.id, scope: .output, 1.0)
} catch {
    print("FALLITO: fase 4: \(error.localizedDescription)"); failures += 1
}
if let o = originalDefault { CA.setDefaultOutputDevice(o) }
print("\nDropout rilevati (e misure ripetute): \(dropoutCount)")
print(failures == 0 ? "\nTEST END-TO-END SUPERATO" : "\n\(failures) verifiche fallite")
exit(failures == 0 ? 0 : 1)
