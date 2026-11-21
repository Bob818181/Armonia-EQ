import AppKit
import SwiftUI

enum Theme {
    static let background = Color(red: 0.055, green: 0.062, blue: 0.078)
    static let panel = Color(red: 0.086, green: 0.098, blue: 0.122)
    static let panelRaised = Color(red: 0.118, green: 0.133, blue: 0.161)
    static let stroke = Color.white.opacity(0.07)
    static let track = Color.white.opacity(0.09)
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.32)
    static let accent = Color(red: 0.27, green: 0.86, blue: 0.76)
    static let accentDim = Color(red: 0.27, green: 0.86, blue: 0.76).opacity(0.35)
    static let cut = Color(red: 0.45, green: 0.62, blue: 1.0)
    static let tone = Color(red: 0.36, green: 0.80, blue: 0.95)
    static let warning = Color(red: 1.0, green: 0.71, blue: 0.28)
    static let danger = Color(red: 1.0, green: 0.38, blue: 0.36)
    static let ok = Color(red: 0.36, green: 0.86, blue: 0.47)
    static let spectrumLow = Color(red: 0.22, green: 0.36, blue: 0.62)
    static let spectrumHigh = Color(red: 0.42, green: 0.62, blue: 0.95)
}

struct Panel<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1))
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.9)
            .foregroundColor(Theme.textTertiary)
    }
}

/// Cursore verticale preciso.
/// - trascinamento relativo (nessun salto al clic); tenere premuto ⌥ per la regolazione fine (1/5);
/// - doppio clic: torna al valore predefinito;
/// - rotella/trackpad: passi di 0,1 dB (via onScroll nella vista contenitore).
struct VerticalSlider: View {
    let value: Float
    let range: ClosedRange<Float>
    var defaultValue: Float = 0
    var tint: Color = Theme.accent
    var enabled = true
    var bipolar = true
    let onChange: (Float) -> Void

    @State private var dragStart: Float?

    private let thumbHeight: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height - thumbHeight
            let span = CGFloat(range.upperBound - range.lowerBound)
            let pos = { (v: Float) -> CGFloat in
                thumbHeight / 2 + h * (1 - CGFloat(v - range.lowerBound) / span)
            }
            let y = pos(value)
            let anchor = bipolar ? pos(min(max(0, range.lowerBound), range.upperBound)) : pos(range.lowerBound)
            let color = bipolar && value < 0 ? Theme.cut : tint
            ZStack(alignment: .top) {
                Capsule()
                    .fill(Theme.track)
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)
                    .padding(.vertical, thumbHeight / 2)
                if bipolar {
                    Rectangle().fill(Color.white.opacity(0.18))
                        .frame(width: 14, height: 1)
                        .offset(y: anchor - 0.5)
                }
                Capsule()
                    .fill(color.opacity(enabled ? 0.9 : 0.3))
                    .frame(width: 4, height: max(0, abs(anchor - y)))
                    .offset(y: min(anchor, y))
                RoundedRectangle(cornerRadius: 3)
                    .fill(enabled ? Color.white.opacity(0.95) : Color.white.opacity(0.4))
                    .frame(width: 22, height: thumbHeight)
                    .overlay(Rectangle().fill(color).frame(width: 12, height: 2))
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    .offset(y: y - thumbHeight / 2)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        let start = dragStart ?? value
                        if dragStart == nil { dragStart = value }
                        let fine: Float = NSEvent.modifierFlags.contains(.option) ? 0.2 : 1
                        var v = start - Float(g.translation.height / max(h, 1)) * Float(span) * fine
                        v = min(max(v, range.lowerBound), range.upperBound)
                        onChange(v)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) { onChange(defaultValue) }
            .background(ScrollCatcher { delta in
                let step: Float = NSEvent.modifierFlags.contains(.option) ? 0.1 : 0.5
                let v = value + (delta > 0 ? step : -step)
                onChange(min(max(v, range.lowerBound), range.upperBound))
            })
        }
        .opacity(enabled ? 1 : 0.55)
    }
}

/// Intercetta la rotella del mouse / lo scorrimento del trackpad sopra un controllo.
/// Usa un monitor locale degli eventi dell'app (affidabile): gli eventi di scorrimento che cadono
/// dentro l'area del controllo vengono gestiti e consumati. La vista non riceve MAI clic o
/// trascinamenti (hitTest = nil), che restano ai gesti SwiftUI.
struct ScrollCatcher: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    final class CatcherView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        private var accumulated: CGFloat = 0
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self = self, let win = self.window, event.window === win, !self.isHiddenOrHasHiddenAncestor else { return event }
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return event }
                self.handle(event)
                return nil
            }
        }

        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }

        private func handle(_ event: NSEvent) {
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 8 : event.scrollingDeltaY
            accumulated += event.isDirectionInvertedFromDevice ? -dy : dy
            while abs(accumulated) >= 1 {
                onScroll?(accumulated > 0 ? 1 : -1)
                accumulated -= accumulated > 0 ? 1 : -1
            }
        }
    }

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onScroll = onScroll
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) { nsView.onScroll = onScroll }
}

/// Campo numerico in dB modificabile (clic, digitazione, Invio).
struct DbField: View {
    let value: Float
    let range: ClosedRange<Float>
    var color: Color = Theme.textPrimary
    let onCommit: (Float) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    static func format(_ v: Float) -> String {
        let r = (v * 10).rounded() / 10
        if r == 0 { return "0.0" }
        return String(format: "%+.1f", r)
    }

    var body: some View {
        TextField("", text: Binding(
            get: { focused ? text : DbField.format(value) },
            set: {
                text = $0
                UIDebug.log("testo campo '\($0)'")
            }
        ))
        .focused($focused)
        .onSubmit { commit() }
        .onChange(of: focused) { isFocused in
            UIDebug.log("campo valore \(isFocused ? "attivo" : "lasciato")")
            if isFocused {
                text = DbField.format(value)
            } else {
                commit() // uscire dal campo conferma il valore digitato
            }
        }
        .textFieldStyle(.plain)
        .multilineTextAlignment(.center)
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundColor(color)
        .frame(width: 44, height: 18)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.stroke, lineWidth: 1))
        .help("Clic per digitare un valore, Invio per confermare")
    }

    private func commit() {
        guard !text.isEmpty else { return }
        UIDebug.log("valore digitato '\(text)'")
        let cleaned = text.replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "dB", with: "")
            .trimmingCharacters(in: .whitespaces)
        if let v = Float(cleaned), v != (DbField.format(value) as NSString).floatValue || cleaned != DbField.format(value) {
            onCommit(min(max(v, range.lowerBound), range.upperBound))
        }
        text = ""
    }
}

/// Misuratore verticale (picco in dBFS, scala -60...0).
struct LevelMeter: View {
    let level: Float  // lineare
    var body: some View {
        GeometryReader { geo in
            let db = level > 0 ? 20 * log10(level) : -100
            let frac = CGFloat(min(max((db + 60) / 60, 0), 1))
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.track)
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: [Theme.ok, Theme.ok, Theme.warning, Theme.danger],
                                         startPoint: .bottom, endPoint: .top))
                    .mask(alignment: .bottom) {
                        Rectangle().frame(height: geo.size.height * frac)
                    }
            }
        }
        .frame(width: 6)
    }
}

/// Indicatore di riduzione del guadagno del limiter (0...12 dB, dall'alto verso il basso).
struct ReductionMeter: View {
    let reductionDb: Float
    var body: some View {
        GeometryReader { geo in
            let frac = CGFloat(min(max(reductionDb / 12, 0), 1))
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.track)
                RoundedRectangle(cornerRadius: 2).fill(Theme.warning)
                    .frame(height: geo.size.height * frac)
            }
        }
        .frame(width: 6)
    }
}

// MARK: - Trascinamento della finestra solo dalle aree libere

/// Area che sposta la finestra. Va messa SOLO dietro zone senza controlli (titolo, spazi vuoti,
/// piè di pagina): la finestra non è più "movibile dallo sfondo", così cursori e manopole ricevono
/// sempre i propri trascinamenti.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        private var startMouse: NSPoint?
        private var startOrigin: NSPoint?

        override var mouseDownCanMoveWindow: Bool { false } // il trascinamento lo gestiamo noi
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // Spostamento esplicito: posizione iniziale del mouse e della finestra, poi la finestra
        // segue la differenza. Deterministico e uguale su tutte le versioni di macOS.
        override func mouseDown(with event: NSEvent) {
            startMouse = NSEvent.mouseLocation
            startOrigin = window?.frame.origin
        }
        override func mouseDragged(with event: NSEvent) {
            guard let s = startMouse, let o = startOrigin, let w = window else { return }
            let p = NSEvent.mouseLocation
            w.setFrameOrigin(NSPoint(x: o.x + p.x - s.x, y: o.y + p.y - s.y))
        }
        override func mouseUp(with event: NSEvent) {
            startMouse = nil
            startOrigin = nil
        }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

// MARK: - Diagnostica dell'interfaccia (ARMONIA_DEBUG=1)

enum UIDebug {
    static let enabled = ProcessInfo.processInfo.environment["ARMONIA_DEBUG"] == "1"
    static func log(_ message: String) {
        if enabled { NSLog("ArmoniaEQ ui: %@", message) }
    }
}

/// In modalità diagnostica registra la posizione di un controllo (coordinate della finestra,
/// origine in alto a sinistra): serve al test automatico dei trascinamenti.
struct DebugFrame: ViewModifier {
    let name: String
    func body(content: Content) -> some View {
        if UIDebug.enabled {
            content.background(GeometryReader { geo in
                Color.clear.onAppear {
                    let f = geo.frame(in: .global)
                    UIDebug.log(String(format: "controllo %@ x=%.1f y=%.1f w=%.1f h=%.1f", name, f.minX, f.minY, f.width, f.height))
                }
            })
        } else {
            content
        }
    }
}

extension View {
    func debugFrame(_ name: String) -> some View { modifier(DebugFrame(name: name)) }
}

// MARK: - Confronto A/B

/// Selettore A/B: due pulsanti ben visibili; quello attivo è evidenziato.
struct ABSelector: View {
    let active: ABCompare.Slot
    let inUse: Bool
    let onSelect: (ABCompare.Slot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel("Confronto")
            HStack(spacing: 0) {
                ForEach([ABCompare.Slot.a, .b], id: \.self) { slot in
                    Button { onSelect(slot) } label: {
                        Text(slot.rawValue)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(slot == active ? Color.black.opacity(0.85) : Theme.textSecondary)
                            .frame(width: 34, height: 22)
                            .background(slot == active ? Theme.accent : Color.white.opacity(0.06))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(slot == active ? "Configurazione \(slot.rawValue) in ascolto"
                                         : "Ascolta la configurazione \(slot.rawValue) (la prima volta parte come copia di quella attuale)")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent.opacity(inUse ? 0.6 : 0.25), lineWidth: 1))
        }
    }
}

// MARK: - Indicatore di clipping

/// OK (verde) = livello normale; LIM (giallo) = segnale oltre 0 dBFS fermato dal limiter;
/// CLIP (rosso) = clipping effettivo in uscita. Resta acceso fino all'azzeramento.
struct ClipLamp: View {
    let clip: UInt32
    let over: UInt32
    let signal: Bool

    var body: some View {
        let (text, color, help): (String, Color, String) = {
            if clip > 0 { return ("CLIP", Theme.danger, "Clipping effettivo in uscita (\(clip) campioni oltre 0 dBFS). Attiva il limiter o riduci preamp/volume.") }
            if over > 0 { return ("LIM", Theme.warning, "Il segnale ha superato 0 dBFS (\(over) campioni) ed è stato contenuto dal limiter: nessun clipping in uscita.") }
            return (signal ? "OK" : "–", signal ? Theme.ok : Theme.textTertiary, "Livello normale, nessun clipping")
        }()
        Text(text)
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .foregroundColor(color)
            .frame(width: 38, height: 16)
            .background(Capsule().fill(color.opacity(0.16)))
            .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
            .help(help)
    }
}

/// In modalità diagnostica registra la posizione di un controllo in coordinate dello SCHERMO
/// (origine in alto a sinistra, come CGEvent), calcolata da AppKit: affidabile anche dentro
/// finestre speciali come i pannelli della barra dei menu.
struct ScreenFrameProbe: NSViewRepresentable {
    let name: String

    final class ProbeView: NSView {
        var name = ""
        private var last = NSRect.zero
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            report()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            last = .zero
            DispatchQueue.main.async { [weak self] in self?.report() }
        }
        func report() {
            guard UIDebug.enabled, let w = window else { return }
            let r = w.convertToScreen(convert(bounds, to: nil))
            let h = NSScreen.screens.first?.frame.height ?? 0
            let cg = NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
            guard cg != last, cg.width > 0 else { return }
            last = cg
            UIDebug.log(String(format: "schermo %@ x=%.1f y=%.1f w=%.1f h=%.1f", name, cg.minX, cg.minY, cg.width, cg.height))
        }
    }

    func makeNSView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.name = name
        return v
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.name = name
        DispatchQueue.main.async { nsView.report() }
    }
}

struct ScreenFrame: ViewModifier {
    let name: String
    func body(content: Content) -> some View {
        if UIDebug.enabled {
            content.background(ScreenFrameProbe(name: name))
        } else {
            content
        }
    }
}

extension View {
    func screenFrame(_ name: String) -> some View { modifier(ScreenFrame(name: name)) }
}
