import AppKit
import Combine
import SwiftUI

/// Icona nella barra dei menu di macOS con pannello rapido (NSStatusItem + NSPopover: soluzione
/// nativa disponibile su macOS 12; MenuBarExtra richiederebbe macOS 13). Resta attiva anche con
/// la finestra principale chiusa e usa lo stesso AppModel della finestra: i due restano sempre
/// sincronizzati e il motore audio non dipende da nessuna delle due viste.
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let model: AppModel
    private var cancellables: Set<AnyCancellable> = []

    init(model: AppModel, openWindow: @escaping () -> Void, quit: @escaping () -> Void) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            // Simbolo di Armonia EQ (template: si adatta a barra chiara/scura e allo stato attenuato).
            button.image = ArmoniaSymbol.image(pointSize: 18)
            button.imageScaling = .scaleNone
            if let img = button.image {
                UIDebug.log(String(format: "icona barra dei menu: simbolo Armonia EQ (template=%d, %.0fx%.0f pt)",
                                   img.isTemplate ? 1 : 0, img.size.width, img.size.height))
            }
            button.toolTip = "Armonia EQ"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        statusItem.isVisible = true

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let panel = MenuBarPanel(model: model,
                                 openWindow: { [weak self] in self?.popover.performClose(nil); openWindow() },
                                 quit: quit)
        popover.contentViewController = NSHostingController(rootView: panel)

        // Icona attenuata quando l'equalizzazione non è attiva.
        model.$status.combineLatest(model.$powerOn)
            .receive(on: RunLoop.main)
            .sink { [weak self] status, on in
                guard let button = self?.statusItem.button else { return }
                let running: Bool = { if case .running = status { return true } else { return false } }()
                button.appearsDisabled = !(on && running)
                button.toolTip = "Armonia EQ – " + (on && running ? "attivo" : "spento")
            }
            .store(in: &cancellables)

        if UIDebug.enabled {
            // La posizione definitiva dell'icona è nota solo dopo che macOS l'ha inserita nella barra.
            for delay in [0.0, 1.0, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.logStatusItemFrame() }
            }
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        UIDebug.log("pannello barra dei menu aperto")
        if UIDebug.enabled {
            DispatchQueue.main.async { [weak self] in self?.logPopoverFrame() }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        UIDebug.log("pannello barra dei menu chiuso")
    }

    // MARK: Diagnostica (coordinate globali, origine in alto a sinistra come CGEvent)

    private func cgRect(_ r: NSRect) -> NSRect {
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: screenH - r.maxY, width: r.width, height: r.height)
    }

    func logStatusItemFrame() {
        guard let button = statusItem.button, let w = button.window else { return }
        let r = cgRect(w.convertToScreen(button.convert(button.bounds, to: nil)))
        UIDebug.log(String(format: "barra dei menu x=%.1f y=%.1f w=%.1f h=%.1f", r.minX, r.minY, r.width, r.height))
    }

    private func logPopoverFrame() {
        guard let view = popover.contentViewController?.view, let w = view.window else { return }
        let r = cgRect(w.convertToScreen(view.convert(view.bounds, to: nil)))
        UIDebug.log(String(format: "pannello x=%.1f y=%.1f w=%.1f h=%.1f", r.minX, r.minY, r.width, r.height))
    }
}

/// Pannello rapido della barra dei menu.
struct MenuBarPanel: View {
    @ObservedObject var model: AppModel
    let openWindow: () -> Void
    let quit: () -> Void

    /// Profili a portata di un clic (gli altri restano nel menu completo sotto).
    private static let quickProfiles: [(id: String, label: String)] = [
        ("flat", "Flat"), ("electronic", "Elettronica"), ("pop", "Pop"), ("voice", "Voce"),
    ]
    private static let symbol = ArmoniaSymbol.image(pointSize: 18)

    private var active: Bool { model.powerOn && model.isRunning }

    private var quickSelection: String? {
        if case .factory(let id) = model.selection { return id }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Accensione e stato
            HStack(spacing: 10) {
                Image(nsImage: Self.symbol)
                    .renderingMode(.template)
                    .foregroundColor(active ? Theme.accent : Theme.textTertiary)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Armonia EQ").font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.textPrimary)
                    Text(model.statusSummary)
                        .font(.system(size: 10.5))
                        .foregroundColor(model.isRunning ? Theme.ok : Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { model.powerOn }, set: { model.setPower($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .screenFrame("pop-power")
                    .help("Attiva/disattiva Armonia EQ")
            }

            Divider()

            // Profilo: scelta rapida + menu completo (Classica, Manuale, profili personali)
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Profilo")
                SegmentedChips(items: Self.quickProfiles.map { ($0.id, $0.label) },
                               selected: quickSelection,
                               debugPrefix: "pop-rapido",
                               onSelect: { model.select(.factory($0)) })
                Picker("", selection: Binding(get: { model.selection }, set: { model.select($0) })) {
                    ForEach(model.factoryProfiles) { p in Text(p.name).tag(ProfileSelection.factory(p.id)) }
                    Text("Manuale / Personalizzato").tag(ProfileSelection.manual)
                    if !model.customProfiles.isEmpty {
                        Divider()
                        ForEach(model.customProfiles) { p in Text(p.name).tag(ProfileSelection.custom(p.id)) }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .screenFrame("pop-profilo")
            }

            // Volume
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    SectionLabel("Volume")
                    Spacer()
                    Text(model.muted ? "muto" : "\(Int((model.volume * 100).rounded())) %")
                        .font(.system(size: 10.5, design: .monospaced)).foregroundColor(Theme.textSecondary)
                }
                HStack(spacing: 6) {
                    Image(systemName: "speaker.fill").font(.system(size: 9)).foregroundColor(Theme.textSecondary)
                    Slider(value: Binding(get: { Double(model.volume) }, set: { model.volume = Float($0) }), in: 0...1)
                        .controlSize(.small)
                        .screenFrame("pop-volume")
                    Image(systemName: "speaker.wave.3.fill").font(.system(size: 9)).foregroundColor(Theme.textSecondary)
                }
                if model.volumeKeys == .needsPermission {
                    Button("Consenti Accessibilità: tasti volume senza click") { model.requestVolumeKeyPermission() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10.5))
                        .foregroundColor(Theme.warning)
                }
            }

            // BASSI e ALTI
            VStack(alignment: .leading, spacing: 12) {
                ToneRow(title: "Bassi", value: model.settings.bass, options: bassFrequencyOptions,
                        frequency: model.settings.bassFrequency, debugName: "pop-bassi",
                        onValue: model.setBass, onFrequency: model.setBassFrequency)
                ToneRow(title: "Alti", value: model.settings.treble, options: trebleFrequencyOptions,
                        frequency: model.settings.trebleFrequency, debugName: "pop-alti",
                        onValue: model.setTreble, onFrequency: model.setTrebleFrequency)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panelRaised.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke))

            // Auto Gain
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto Gain").font(.system(size: 12, weight: .medium)).foregroundColor(Theme.textPrimary)
                    Text(model.autoGain
                         ? (abs(model.autoGainDb) < 0.05 ? "Compensazione 0.0 dB" : String(format: "Compensazione %+.1f dB", model.autoGainDb))
                         : "Stesso volume percepito con ogni profilo")
                        .font(.system(size: 10, design: model.autoGain ? .monospaced : .default))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Toggle("", isOn: $model.autoGain)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .screenFrame("pop-autogain")
                    .help("Compensa automaticamente la variazione di volume dovuta all'equalizzazione")
            }

            Divider()

            Toggle("Avvia all'accesso a macOS", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))
                .screenFrame("pop-login")
            if let err = model.loginItemError {
                Text(err).font(.system(size: 10)).foregroundColor(Theme.danger)
            }

            HStack {
                Button("Apri finestra", action: openWindow)
                    .screenFrame("pop-apri")
                Spacer()
                Button("Esci da Armonia EQ", action: quit)
                    .screenFrame("pop-esci")
                    .help("Chiude completamente l'applicazione e ripristina l'uscita audio di sistema")
            }
        }
        .padding(14)
        .frame(width: 312)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
    }
}

/// Riga BASSI/ALTI del pannello: valore in dB, cursore -12…+12 dB a passi di 0,5 dB e frequenza
/// di intervento scelta con un selettore a segmenti.
private struct ToneRow: View {
    let title: String
    let value: Float
    let options: [Float]
    let frequency: Float
    let debugName: String
    let onValue: (Float) -> Void
    let onFrequency: (Float) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SectionLabel(title)
                Spacer()
                Text(value == 0 ? "0.0 dB" : String(format: "%+.1f dB", value))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(value == 0 ? Theme.textSecondary : Theme.tone)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(value == 0 ? Color.white.opacity(0.05) : Theme.tone.opacity(0.14)))
                Button { onValue(0) } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 9.5, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundColor(Theme.textSecondary)
                .disabled(value == 0)
                .opacity(value == 0 ? 0.35 : 1)
                .help("Azzera")
            }
            // Passi di 0,5 dB applicati da quantizeTone (senza "step:" il cursore non mostra 48 tacche).
            Slider(value: Binding(get: { Double(value) }, set: { onValue(quantizeTone(Float($0))) }),
                   in: Double(toneRange.lowerBound)...Double(toneRange.upperBound))
                .controlSize(.small)
                .screenFrame(debugName)
            SegmentedChips(items: options.map { ($0, frequencyLabel($0)) },
                           selected: frequency,
                           debugPrefix: debugName + "-f",
                           compact: true,
                           onSelect: onFrequency)
                .help("Frequenza di intervento")
        }
    }
}

/// Selettore a segmenti (pillole) per il pannello: un clic sceglie, la voce attiva è evidenziata.
private struct SegmentedChips<T: Hashable>: View {
    let items: [(T, String)]
    let selected: T?
    let debugPrefix: String
    var compact = false
    let onSelect: (T) -> Void
    @State private var hovered: T?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { item in
                Button { onSelect(item.0) } label: {
                    chipLabel(item.1, isOn: item.0 == selected, isHovered: hovered == item.0)
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { hovered = item.0 } else if hovered == item.0 { hovered = nil }
                }
                .screenFrame("\(debugPrefix)-\(item.1)")
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: compact ? 7 : 8).fill(Color.black.opacity(0.28)))
        .overlay(RoundedRectangle(cornerRadius: compact ? 7 : 8).stroke(Theme.stroke))
        .animation(.easeOut(duration: 0.12), value: selected)
    }

    private func chipLabel(_ text: String, isOn: Bool, isHovered: Bool) -> some View {
        let textColor: Color = isOn ? Color.black.opacity(0.85) : (isHovered ? Theme.textPrimary : Theme.textSecondary)
        let fill: Color = isOn ? Theme.accent : (isHovered ? Color.white.opacity(0.07) : Color.clear)
        return Text(text)
            .font(.system(size: compact ? 10 : 11, weight: isOn ? .semibold : .regular))
            .foregroundColor(textColor)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, compact ? 3 : 4)
            .background(RoundedRectangle(cornerRadius: compact ? 5 : 6).fill(fill))
            .contentShape(Rectangle())
    }
}
