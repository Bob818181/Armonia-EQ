import Accelerate
import ArmoniaDSP
import AVFoundation
import Foundation

/// Gamme di frequenza dell'analizzatore (ingrandimento).
enum SpectrumZoom: String, CaseIterable, Identifiable {
    case full, bass, high
    var id: String { rawValue }
    var label: String {
        switch self {
        case .full: return "Completo"
        case .bass: return "Bassi"
        case .high: return "Medi/Alti"
        }
    }
    var range: (Double, Double) {
        switch self {
        case .full: return (20, 20000)
        case .bass: return (20, 500)
        case .high: return (500, 20000)
        }
    }
}

/// Analizzatore di spettro e misuratori. Legge dal motore DSP i campioni GIÀ elaborati
/// (dopo EQ, volume e limiter) da un buffer circolare senza lock: il thread audio non attende mai.
/// FFT a 8192 punti (risoluzione ~5,9 Hz a 48 kHz) per rendere leggibili i bassi, 60 fotogrammi
/// al secondo; si ferma quando la finestra non è visibile.
final class SpectrumModel: ObservableObject {
    static let barCount = 96
    static let floorDb: Float = -90

    @Published private(set) var bars: [Float] = Array(repeating: SpectrumModel.floorDb, count: SpectrumModel.barCount)
    @Published private(set) var peakL: Float = 0
    @Published private(set) var peakR: Float = 0
    @Published private(set) var gainReduction: Float = 0
    @Published private(set) var hasSignal = false
    /// Picco massimo in uscita dall'ultimo azzeramento (dBFS).
    @Published private(set) var peakHoldDb: Float = -.infinity
    /// Campioni oltre 0 dBFS gestiti dal limiter / clipping effettivo in uscita.
    @Published private(set) var overSamples: UInt32 = 0
    @Published private(set) var clipSamples: UInt32 = 0

    var zoom: SpectrumZoom = .full {
        didSet { if zoom != oldValue { bars = Array(repeating: SpectrumModel.floorDb, count: SpectrumModel.barCount) } }
    }

    private let dsp: OpaquePointer
    private let fftSize = 8192
    private let log2n: vDSP_Length = 13
    private let setup: FFTSetup
    private var window: [Float]
    private var samples: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var mags: [Float]
    private var timer: Timer?
    private var lastFrames: UInt64 = 0
    private var tickCount = 0
    var sampleRate: Double = 48000
    var isActive = false
    /// false quando la finestra è nascosta o coperta: niente FFT né aggiornamenti.
    var isVisible = true
    var renderErrors: () -> Int = { 0 }
    var diagExtra: () -> String = { "" }
    /// Diagnostica su stderr/Console: avviare con ARMONIA_DEBUG=1.
    static let debug = ProcessInfo.processInfo.environment["ARMONIA_DEBUG"] == "1"

    init(dsp: OpaquePointer) {
        self.dsp = dsp
        guard let s = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { fatalError("vDSP FFT setup") }
        setup = s
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        samples = [Float](repeating: 0, count: fftSize)
        windowed = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imag = [Float](repeating: 0, count: fftSize / 2)
        mags = [Float](repeating: 0, count: fftSize / 2)
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.002
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit {
        timer?.invalidate()
        vDSP_destroy_fftsetup(setup)
    }

    /// Frequenza centrale (Hz) di ogni barra, distribuite logaritmicamente nella gamma attiva.
    func barFrequency(_ i: Int) -> Double {
        let (lo, hi) = zoom.range
        return lo * pow(hi / lo, (Double(i) + 0.5) / Double(SpectrumModel.barCount))
    }

    func resetMeters() {
        UIDebug.log("picco azzerato")
        aeq_reset_meters(dsp)
        peakHoldDb = -.infinity
        overSamples = 0
        clipSamples = 0
    }

    private func tick() {
        tickCount += 1
        let frames = aeq_frames_processed(dsp)
        let flowing = isActive && frames != lastFrames
        lastFrames = frames

        // Misuratori: letti a 30 Hz anche a finestra coperta (servono al clipping e alla diagnostica).
        if tickCount % 2 == 0 {
            let pl = aeq_read_peak(dsp, 0), pr = aeq_read_peak(dsp, 1)
            let gr = aeq_read_gain_reduction_db(dsp)
            var m = AEQMeters()
            aeq_get_meters(dsp, &m)
            if SpectrumModel.debug && tickCount % 60 == 0 {
                let inPk = aeq_read_input_peak(dsp)
                NSLog("ArmoniaEQ diag: attivo=%d frame=%llu ingresso=%.4f uscitaL=%.4f uscitaR=%.4f GR=%.1f dB picco=%.2f dBFS oltre=%u clip=%u permesso=%d errori=%d %@",
                      isActive ? 1 : 0, frames, inPk, pl, pr, gr, 20 * log10(max(m.peakHold, 1e-9)),
                      m.overSamples, m.clipSamples,
                      AVCaptureDevice.authorizationStatus(for: .audio).rawValue, renderErrors(), diagExtra())
            }
            if isVisible {
                peakL = flowing ? max(pl, peakL * 0.82) : peakL * 0.7
                peakR = flowing ? max(pr, peakR * 0.82) : peakR * 0.7
                gainReduction = flowing ? max(gr, gainReduction * 0.85) : 0
                hasSignal = flowing && max(pl, pr) > 0.0001
                let hold: Float = m.peakHold > 0 ? 20 * log10(m.peakHold) : -.infinity
                if hold != peakHoldDb { peakHoldDb = hold }
                if m.overSamples != overSamples { overSamples = m.overSamples }
                if m.clipSamples != clipSamples { clipSamples = m.clipSamples }
            }
        }

        guard isVisible else { return }
        var newBars = bars
        if flowing {
            computeSpectrum(into: &newBars)
        } else {
            for i in newBars.indices { newBars[i] = max(SpectrumModel.floorDb, newBars[i] - 2) }
        }
        if newBars != bars { bars = newBars }
    }

    private func computeSpectrum(into out: inout [Float]) {
        let n = fftSize
        samples.withUnsafeMutableBufferPointer { aeq_copy_analysis(dsp, $0.baseAddress, UInt32(n)) }
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }
        // Normalizzazione: una sinusoide a fondo scala (ampiezza 1) = 0 dB.
        let norm = Float(n / 2) * Float(n / 2)
        let binHz = sampleRate / Double(n)
        let (lo0, hi0) = zoom.range
        let count = SpectrumModel.barCount
        for i in 0..<count {
            let lo = lo0 * pow(hi0 / lo0, Double(i) / Double(count))
            let hi = lo0 * pow(hi0 / lo0, Double(i + 1) / Double(count))
            var m: Float = 0
            if hi - lo < binHz * 2 {
                // Barra più stretta di due bin (bassi): interpolazione al centro della barra,
                // così ogni barra mostra un valore e non compaiono "buchi".
                let pos = sqrt(lo * hi) / binHz
                let b0 = max(1, min(Int(pos.rounded(.down)), n / 2 - 2))
                let frac = Float(min(max(pos - Double(b0), 0), 1))
                m = mags[b0] * (1 - frac) + mags[b0 + 1] * frac
            } else {
                let b0 = max(1, min(Int((lo / binHz).rounded(.down)), n / 2 - 1))
                let b1 = max(b0 + 1, min(Int((hi / binHz).rounded(.up)), n / 2))
                for b in b0..<b1 { m = max(m, mags[b]) }
            }
            let db = max(SpectrumModel.floorDb, 10 * log10(max(m / norm, 1e-12)))
            // Salita immediata, discesa graduale (~36 dB/s) e leggero smussamento visivo.
            let fall = out[i] - 0.6
            out[i] = db >= fall ? (out[i] < db ? out[i] + (db - out[i]) * 0.65 : db) : fall
        }
    }
}
