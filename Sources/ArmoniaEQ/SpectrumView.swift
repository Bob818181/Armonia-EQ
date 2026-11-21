import ArmoniaDSP
import SwiftUI

/// Curva EQ calcolata una sola volta per ogni combinazione di parametri (non a ogni fotogramma).
private final class CurveCache {
    private var key: [Double] = []
    private(set) var points: [(f: Double, db: Double)] = []
    private(set) var bandPoints: [(f: Double, db: Double)] = []

    func update(settings: EQSettings, eqEnabled: Bool, sampleRate: Double, range: (Double, Double)) {
        var k: [Double] = settings.gains.map { Double($0) }
        let extra: [Double] = [Double(settings.preamp), Double(settings.bass), Double(settings.treble),
                               Double(settings.bassFrequency), Double(settings.trebleFrequency),
                               eqEnabled ? 1.0 : 0.0, sampleRate, range.0, range.1]
        k.append(contentsOf: extra)
        guard k != key else { return }
        key = k
        let steps = 240
        settings.gains.withUnsafeBufferPointer { g in
            func r(_ f: Double) -> Double {
                eqEnabled ? aeq_response_full_db(g.baseAddress, settings.preamp, settings.bass, settings.bassFrequency,
                                                 settings.treble, settings.trebleFrequency, sampleRate, f) : 0
            }
            points = (0...steps).map { s in
                let f = range.0 * pow(range.1 / range.0, Double(s) / Double(steps))
                return (f, r(f))
            }
            bandPoints = bandFrequencies.map(Double.init).filter { $0 >= range.0 && $0 <= range.1 }.map { ($0, r($0)) }
        }
    }
}

/// Analizzatore di spettro (barre) + curva EQ reale (linea), BASSI e ALTI compresi.
/// La curva è calcolata con aeq_response_total_db, cioè con gli stessi coefficienti dei filtri attivi.
struct SpectrumView: View {
    @ObservedObject var spectrum: SpectrumModel
    let settings: EQSettings
    let eqEnabled: Bool
    let sampleRate: Double
    let zoom: SpectrumZoom

    @State private var cache = CurveCache()
    private let curveRange: Double = 15 // ±15 dB visibili per la curva

    private var gridFrequencies: [Double] {
        switch zoom {
        case .full: return bandFrequencies.map(Double.init)
        case .bass: return [20, 30, 40, 50, 60, 80, 100, 150, 200, 300, 400, 500]
        case .high: return [500, 1000, 2000, 4000, 6000, 8000, 10000, 12000, 16000, 20000]
        }
    }

    private func label(_ f: Double) -> String {
        f >= 1000 ? (f.truncatingRemainder(dividingBy: 1000) == 0 ? "\(Int(f / 1000))k" : String(format: "%.1fk", f / 1000)) : "\(Int(f))"
    }

    var body: some View {
        let range = zoom.range
        cache.update(settings: settings, eqEnabled: eqEnabled, sampleRate: sampleRate, range: range)
        return Canvas { ctx, size in
            let w = size.width, h = size.height
            let (minF, maxF) = range
            func x(_ f: Double) -> CGFloat { CGFloat(log10(f / minF) / log10(maxF / minF)) * w }
            func yCurve(_ db: Double) -> CGFloat { h / 2 - CGFloat(db / curveRange) * (h / 2 - 8) }

            // Griglia
            for f in gridFrequencies {
                var p = Path()
                p.move(to: CGPoint(x: x(f), y: 0))
                p.addLine(to: CGPoint(x: x(f), y: h))
                ctx.stroke(p, with: .color(.white.opacity(0.05)), lineWidth: 1)
            }
            for db in [-12.0, -6, 0, 6, 12] {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: yCurve(db)))
                p.addLine(to: CGPoint(x: w, y: yCurve(db)))
                ctx.stroke(p, with: .color(.white.opacity(db == 0 ? 0.14 : 0.05)), lineWidth: 1)
                ctx.draw(Text(db == 0 ? "0" : String(format: "%+.0f", db))
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundColor(Theme.textTertiary),
                         at: CGPoint(x: w - 4, y: yCurve(db) - 6), anchor: .trailing)
            }

            // Spettro (dB FS, -90...0)
            let n = SpectrumModel.barCount
            let barW = w / CGFloat(n)
            for i in 0..<n {
                let db = Double(spectrum.bars[i])
                let frac = CGFloat(max(0, min(1, (db - Double(SpectrumModel.floorDb)) / -Double(SpectrumModel.floorDb))))
                guard frac > 0.005 else { continue }
                let rect = CGRect(x: CGFloat(i) * barW + 0.75, y: h * (1 - frac), width: max(1, barW - 1.5), height: h * frac)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1.2),
                         with: .linearGradient(Gradient(colors: [Theme.spectrumHigh.opacity(0.55), Theme.spectrumLow.opacity(0.18)]),
                                               startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: h)))
            }

            // Curva EQ reale
            var curve = Path()
            var fill = Path()
            for (s, pt) in cache.points.enumerated() {
                let p = CGPoint(x: x(pt.f), y: yCurve(max(-curveRange, min(curveRange, pt.db))))
                if s == 0 {
                    curve.move(to: p)
                    fill.move(to: CGPoint(x: p.x, y: yCurve(0)))
                    fill.addLine(to: p)
                } else {
                    curve.addLine(to: p)
                    fill.addLine(to: p)
                }
            }
            fill.addLine(to: CGPoint(x: w, y: yCurve(0)))
            fill.closeSubpath()
            let tint = eqEnabled ? Theme.accent : Theme.textTertiary
            ctx.fill(fill, with: .color(tint.opacity(0.10)))
            ctx.stroke(curve, with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            // Punti alle frequenze delle bande (valore reale della curva in quel punto)
            for pt in cache.bandPoints {
                let c = CGPoint(x: x(pt.f), y: yCurve(max(-curveRange, min(curveRange, pt.db))))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(tint))
            }

            // Etichette frequenze
            for f in gridFrequencies {
                ctx.draw(Text(label(f)).font(.system(size: 8.5)).foregroundColor(Theme.textTertiary),
                         at: CGPoint(x: min(max(x(f), 10), w - 14), y: h - 6))
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.28)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
