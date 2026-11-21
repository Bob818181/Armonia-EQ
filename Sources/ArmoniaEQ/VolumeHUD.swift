import AppKit
import SwiftUI

/// Indicatore del volume a schermo per i tasti volume gestiti da Armonia EQ (quando l'app
/// intercetta il tasto, macOS non mostra il proprio indicatore). Pannello non attivabile: non ruba
/// il focus, ignora il mouse e compare anche sopra le app a schermo intero.
final class VolumeHUD {
    static let shared = VolumeHUD()

    private final class State: ObservableObject {
        @Published var volume: Float = 0
        @Published var muted = false
        @Published var device = ""
    }

    private let state = State()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    /// Crea il pannello in anticipo: la prima pressione non paga il costo di creazione della vista.
    func prepare() {
        if panel == nil { panel = makePanel() }
    }

    func show(volume: Float, muted: Bool, device: String) {
        UIDebug.log(String(format: "hud volume=%.4f muto=%d", volume, muted ? 1 : 0))
        state.volume = volume
        state.muted = muted
        state.device = device
        let p = panel ?? makePanel()
        panel = p
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.minY + 110))
        }
        p.alphaValue = 1
        p.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                self?.panel?.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                if self?.panel?.alphaValue == 0 { self?.panel?.orderOut(nil) }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 64),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.contentView = NSHostingView(rootView: HUDView(state: state))
        return p
    }

    private struct HUDView: View {
        @ObservedObject var state: State

        private var icon: String {
            if state.muted || state.volume <= 0 { return "speaker.slash.fill" }
            if state.volume < 0.34 { return "speaker.wave.1.fill" }
            if state.volume < 0.67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        }

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(state.muted ? Theme.textTertiary : Theme.accent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 6) {
                    // 16 tacche come i tasti di macOS; la tacca parziale mostra i passi fini (⌥⇧).
                    HStack(spacing: 3) {
                        ForEach(0..<16, id: \.self) { i in
                            let fill = CGFloat(min(max(state.volume * 16 - Float(i), 0), 1))
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 1.5).fill(Color.white.opacity(0.12))
                                    RoundedRectangle(cornerRadius: 1.5)
                                        .fill(state.muted ? Theme.textTertiary : Theme.accent)
                                        .frame(width: geo.size.width * fill)
                                }
                            }
                            .frame(height: 8)
                        }
                    }
                    Text(state.muted ? "Muto · \(state.device)" : "\(Int((state.volume * 100).rounded())) % · \(state.device)")
                        .font(.system(size: 10.5))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .frame(width: 300, height: 64)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel.opacity(0.94)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.stroke))
            .preferredColorScheme(.dark)
        }
    }
}
