import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var spectrum: SpectrumModel

    @State private var nameSheet: NameSheetMode?
    @State private var confirmDelete = false
    @State private var showManager = false
    @State private var showProfiles = false
    @State private var importMessage: String?

    private var zoom: SpectrumZoom { SpectrumZoom(rawValue: model.spectrumZoom) ?? .full }

    var body: some View {
        VStack(spacing: 10) {
            header
            banner
            controlBar
            SpectrumView(spectrum: spectrum, settings: model.settings, eqEnabled: model.eqEnabled,
                         sampleRate: model.currentSampleRate, zoom: zoom)
                .frame(height: 170)
                .overlay(alignment: .topLeading) {
                    Picker("", selection: Binding(get: { zoom }, set: { z in
                        model.spectrumZoom = z.rawValue
                        spectrum.zoom = z
                    })) {
                        ForEach(SpectrumZoom.allCases) { z in Text(z.label).tag(z) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 230)
                    .padding(6)
                    .help("Ingrandimento dello spettro: tutta la gamma, solo i bassi (20–500 Hz) o medi e alti")
                }
            equalizerPanel
            footer
        }
        .padding(14)
        .frame(width: 940)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .sheet(item: $nameSheet) { mode in
            NameSheet(mode: mode, model: model) { nameSheet = nil }
        }
        .sheet(isPresented: $showManager) {
            ProfileManagerSheet(model: model, onImport: importProfiles, onExport: exportProfiles) { showManager = false }
        }
        .alert("Eliminare il profilo \"\(model.selectedCustomProfile?.name ?? "")\"?", isPresented: $confirmDelete) {
            Button("Elimina", role: .destructive) {
                if let p = model.selectedCustomProfile { model.deleteProfile(p.id) }
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("L'operazione non si può annullare. L'audio non cambia: la curva resta attiva in modalità Manuale.")
        }
        .onChange(of: model.status) { status in
            spectrum.isActive = { if case .running = status { return true } else { return false } }()
            spectrum.sampleRate = model.currentSampleRate
        }
        .onAppear {
            spectrum.isActive = { if case .running = model.status { return true } else { return false } }()
            spectrum.sampleRate = model.currentSampleRate
            spectrum.zoom = zoom
        }
        .alert("Importazione profili", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("OK", role: .cancel) { importMessage = nil }
        } message: {
            Text(importMessage ?? "")
        }
    }

    // MARK: Intestazione: power, nome, profilo

    private var header: some View {
        HStack(spacing: 14) {
            PowerButton(status: model.status, on: model.powerOn) { model.setPower(!model.powerOn) }
            VStack(alignment: .leading, spacing: 2) {
                Text("Armonia EQ").font(.system(size: 15, weight: .semibold)).foregroundColor(Theme.textPrimary)
                Text(statusText).font(.system(size: 11)).foregroundColor(statusColor).lineLimit(1)
            }
            .frame(width: 215, alignment: .leading)
            .background(WindowDragArea())
            Spacer(minLength: 8)
                .frame(maxHeight: .infinity)
                .background(WindowDragArea())
                .debugFrame("area-libera")
            profileMenu
            Button(action: saveAction) {
                Label(saveLabel, systemImage: "square.and.arrow.down")
            }
            .fixedSize()
            .layoutPriority(1)
            .help(saveHelp)
            .disabled(!canSave)
            Menu {
                Button("Salva come nuovo profilo…") { nameSheet = .saveAs }
                Button("Rinomina profilo…") { nameSheet = .rename }
                    .disabled(model.selectedCustomProfile == nil)
                Button("Duplica profilo") {
                    if let p = model.selectedCustomProfile, let c = model.duplicateProfile(p.id) { model.select(.custom(c.id)) }
                }
                .disabled(model.selectedCustomProfile == nil)
                Button("Elimina profilo…") { confirmDelete = true }
                    .disabled(model.selectedCustomProfile == nil)
                Divider()
                Button("Importa profili…") { importProfiles() }
                Button("Esporta profili personali…") { exportProfiles() }
                    .disabled(model.customProfiles.isEmpty)
                Divider()
                Button("Ripristina valori del profilo") { model.revertToProfile() }
                    .disabled(!model.isModified)
                Button("Preamp automatico (picco a 0 dB)") { model.autoPreamp() }
                Divider()
                Button("Gestisci profili personali…") { showManager = true }
                Divider()
                Toggle("Avvia all'accesso a macOS", isOn: Binding(get: { model.launchAtLogin },
                                                                  set: { model.setLaunchAtLogin($0) }))
                Divider()
                Button("Confronto: copia \(model.ab.active.rawValue) nell'altra configurazione") { model.abCopyToOther() }
                Button("Confronto: azzera A/B") { model.abReset() }
                    .disabled(!model.ab.isInUse)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Button(action: model.resetToFlat) {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .fixedSize()
            .layoutPriority(1)
            .help("Reset immediato: bande, preamp, BASSI e ALTI a 0 dB (profilo Flat)")
        }
    }

    private var profileMenu: some View {
        Button { showProfiles.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: "slider.vertical.3").foregroundColor(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(model.selectionName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(1)
                        if model.isModified {
                            Text("MODIFICATO")
                                .font(.system(size: 8.5, weight: .bold))
                                .padding(.horizontal, 5).padding(.vertical, 1.5)
                                .background(Capsule().fill(Theme.warning.opacity(0.22)))
                                .foregroundColor(Theme.warning)
                        }
                    }
                    Text(model.selectionSummary)
                        .font(.system(size: 10.5))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(width: 285)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panelRaised))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.accent.opacity(0.45), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Scegli il profilo audio")
        .popover(isPresented: $showProfiles, arrowEdge: .bottom) {
            ProfileList(model: model) { showProfiles = false }
        }
    }

    private func exportProfiles() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "ArmoniaEQ-profili.json"
        panel.title = "Esporta profili personali"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.exportProfiles(to: url) } catch { importMessage = "Esportazione non riuscita: \(error.localizedDescription)" }
    }

    private func importProfiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.title = "Importa profili"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let r = try model.importProfiles(from: url)
            var msg = r.imported.isEmpty ? "Nessun profilo importato." : "Importati: " + r.imported.joined(separator: ", ")
            if r.skipped > 0 { msg += "\nVoci non valide saltate: \(r.skipped)" }
            importMessage = msg
        } catch {
            importMessage = error.localizedDescription
        }
    }

    private func selectionBinding(_ s: ProfileSelection) -> Binding<Bool> {
        Binding(get: { model.selection == s }, set: { _ in model.select(s) })
    }

    private var saveLabel: String {
        if model.selectedCustomProfile != nil { return "Salva" }
        return "Salva come…"
    }

    private var saveHelp: String {
        switch model.selection {
        case .custom: return "Aggiorna il profilo personale con la curva attuale"
        case .factory: return "I profili predefiniti non vengono sovrascritti: salva la curva come nuovo profilo personale"
        case .manual: return "Salva la curva manuale come profilo personale"
        }
    }

    private var canSave: Bool {
        if model.selectedCustomProfile != nil { return model.isModified }
        return true
    }

    private func saveAction() {
        if model.selectedCustomProfile != nil { model.updateSelectedCustomProfile() } else { nameSheet = .saveAs }
    }

    // MARK: Stato

    private var statusText: String {
        switch model.status {
        case .off: return "Spento · audio di sistema non elaborato"
        case .starting: return "Avvio…"
        case .running(let info):
            return String(format: "Attivo · %.1f kHz · latenza %.0f ms", info.sampleRate / 1000, info.latencyMs)
        case .needsDriver: return "Driver loopback non installato"
        case .needsPermission: return "Serve l'autorizzazione all'ingresso audio"
        case .error(let msg): return "Errore: \(msg)"
        }
    }

    private var statusColor: Color {
        switch model.status {
        case .running: return Theme.ok
        case .off: return Theme.textSecondary
        case .starting: return Theme.warning
        default: return Theme.danger
        }
    }

    @ViewBuilder private var banner: some View {
        switch model.status {
        case .needsDriver:
            BannerView(icon: "puzzlepiece.extension",
                       text: "Per elaborare l'audio di tutto il sistema su macOS 12 serve un driver loopback gratuito: installa BlackHole 2ch (brew install blackhole-2ch oppure dal sito), poi premi \"Ricontrolla\".",
                       buttons: [("Sito BlackHole", { NSWorkspace.shared.open(URL(string: "https://existential.audio/blackhole/")!) }),
                                 ("Ricontrolla", { model.refreshDevices(); if model.powerOn { model.startEngine() } })])
        case .needsPermission:
            BannerView(icon: "mic.slash",
                       text: "macOS considera il loopback un ingresso audio: consenti ad Armonia EQ l'accesso al Microfono in Impostazioni di Sistema › Sicurezza e privacy, poi riprova.",
                       buttons: [("Apri Impostazioni", {
                           NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                       }), ("Riprova", { model.startEngine() })])
        case .error(let msg):
            BannerView(icon: "exclamationmark.triangle", text: msg,
                       buttons: [("Riprova", { model.startEngine() })])
        default:
            EmptyView()
        }
    }

    // MARK: Uscita, volume, bilanciamento, interruttore EQ

    private var controlBar: some View {
        Panel {
            HStack(spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    SectionLabel("Dispositivo di uscita")
                    Picker("", selection: Binding(get: { model.selectedOutputUID ?? "" },
                                                  set: { model.selectOutput(uid: $0) })) {
                        if model.outputDevices.isEmpty { Text("Nessun dispositivo").tag("") }
                        ForEach(model.outputDevices) { d in
                            Text("\(d.displayName)  ·  \(d.transportLabel)\(d.isAppleDriver ? "" : " · driver software")").tag(d.uid)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 214)
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        SectionLabel("Volume")
                        Spacer()
                        Text("\(Int((model.volume * 100).rounded())) %  ·  \(model.volumeDbText)")
                            .font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.textSecondary)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundColor(Theme.textSecondary)
                        Slider(value: Binding(get: { Double(model.volume) }, set: { model.volume = Float($0) }), in: 0...1)
                            .controlSize(.small)
                        Image(systemName: "speaker.wave.3.fill").font(.system(size: 10)).foregroundColor(Theme.textSecondary)
                    }
                }
                .frame(width: 186)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        SectionLabel("Bilanciamento")
                        Spacer()
                        Text(balanceText).font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.textSecondary)
                    }
                    HStack(spacing: 6) {
                        Text("S").font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.textSecondary)
                        Slider(value: Binding(get: { Double(model.balance) },
                                              set: { v in model.balance = abs(v) < 0.03 ? 0 : Float(v) }), in: -1...1)
                            .controlSize(.small)
                        Text("D").font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.textSecondary)
                        Button("C") { model.balance = 0 }
                            .buttonStyle(.borderless).font(.system(size: 10, weight: .semibold))
                            .help("Centra il bilanciamento")
                    }
                }
                .frame(width: 176)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 3) {
                    SectionLabel("Equalizzazione")
                    Toggle(model.eqEnabled ? "Attiva" : "Bypass", isOn: $model.eqEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .help("Attiva/disattiva EQ, preamp, BASSI e ALTI senza interrompere l'audio")
                    Toggle(isOn: $model.autoGain) {
                        Text(model.autoGain ? String(format: "Auto Gain %+.1f", model.autoGainDb) : "Auto Gain")
                            .font(.system(size: 11, design: model.autoGain ? .monospaced : .default))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .debugFrame("auto-gain")
                    .help("Auto Gain: compensa la variazione di volume percepito prodotta dall'equalizzazione (stesso livello di Flat). Diverso dal limiter, che agisce solo sui picchi.")
                }
                ABSelector(active: model.ab.active, inUse: model.ab.isInUse) { model.abSwitch(to: $0) }
                    .debugFrame("ab")
            }
        }
    }

    private var balanceText: String {
        let b = model.balance
        if abs(b) < 0.005 { return "Centro" }
        return b < 0 ? "S \(Int((-b * 100).rounded())) %" : "D \(Int((b * 100).rounded())) %"
    }

    // MARK: EQ grafico, preamp, limiter, misuratori

    private var equalizerPanel: some View {
        Panel {
            HStack(alignment: .top, spacing: 0) {
                // Preamp
                SliderColumn(title: "PREAMP", value: model.settings.preamp, range: preampRange,
                             tint: Theme.warning, enabled: model.eqEnabled, debugName: "cursore-preamp") { model.setPreamp($0) }
                    .frame(width: 64)
                divider
                // Controlli BASSI e ALTI indipendenti dalle 10 bande
                SliderColumn(title: "BASSI", value: model.settings.bass, range: toneRange,
                             tint: Theme.tone, enabled: model.eqEnabled, debugName: "cursore-bassi",
                             quantize: quantizeTone,
                             frequency: FrequencyChoice(options: bassFrequencyOptions, selected: model.settings.bassFrequency,
                                                        debugName: "frequenza-bassi", onSelect: model.setBassFrequency)) {
                    model.setBass($0)
                }
                .frame(width: 62)
                SliderColumn(title: "ALTI", value: model.settings.treble, range: toneRange,
                             tint: Theme.tone, enabled: model.eqEnabled, debugName: "cursore-alti",
                             quantize: quantizeTone,
                             frequency: FrequencyChoice(options: trebleFrequencyOptions, selected: model.settings.trebleFrequency,
                                                        debugName: "frequenza-alti", onSelect: model.setTrebleFrequency)) {
                    model.setTreble($0)
                }
                .frame(width: 62)
                divider
                // 10 bande
                HStack(spacing: 0) {
                    ForEach(0..<bandCount, id: \.self) { i in
                        SliderColumn(title: bandLabel(bandFrequencies[i]) + " Hz",
                                     value: model.settings.gains[i], range: gainRange,
                                     tint: Theme.accent, enabled: model.eqEnabled,
                                     debugName: "cursore-" + bandLabel(bandFrequencies[i])) { model.setGain(band: i, $0) }
                            .frame(maxWidth: .infinity)
                    }
                }
                .overlay(alignment: .leading) { DbScale().frame(width: 22).offset(x: -6) }
                divider
                // Limiter
                VStack(spacing: 8) {
                    Text("LIMITER").font(.system(size: 9.5, weight: .semibold)).tracking(0.8)
                        .foregroundColor(Theme.textSecondary)
                    Toggle("", isOn: $model.limiterEnabled).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        .help("Limiter di picco: impedisce il clipping dopo l'equalizzazione")
                    HStack(alignment: .top, spacing: 8) {
                        VerticalSlider(value: model.limiterCeiling, range: -6...0, defaultValue: -1,
                                       tint: Theme.warning, enabled: model.limiterEnabled, bipolar: false) {
                            model.limiterCeiling = (($0 * 10).rounded()) / 10
                        }
                        .frame(width: 26)
                        ReductionMeter(reductionDb: spectrum.gainReduction)
                            .help("Riduzione di guadagno del limiter")
                    }
                    .frame(height: 170)
                    DbField(value: model.limiterCeiling, range: -6...0) { model.limiterCeiling = $0 }
                        .help("Soglia massima di uscita (dBFS)")
                    Text(String(format: "GR %.1f", spectrum.gainReduction))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(spectrum.gainReduction > 0.1 ? Theme.warning : Theme.textTertiary)
                }
                .frame(width: 74)
                divider
                // Misuratori di uscita
                VStack(spacing: 8) {
                    Text("OUT").font(.system(size: 9.5, weight: .semibold)).tracking(0.8)
                        .foregroundColor(Theme.textSecondary)
                    ClipLamp(clip: spectrum.clipSamples, over: spectrum.overSamples, signal: spectrum.hasSignal)
                        .frame(height: 18)
                    HStack(spacing: 4) {
                        LevelMeter(level: spectrum.peakL)
                        LevelMeter(level: spectrum.peakR)
                    }
                    .frame(height: 170)
                    Button(action: spectrum.resetMeters) {
                        Text(spectrum.peakHoldDb.isFinite ? String(format: "%+.1f", spectrum.peakHoldDb) : "–∞")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(spectrum.clipSamples > 0 ? Theme.danger
                                             : (spectrum.peakHoldDb > -1.0 ? Theme.warning : Theme.textPrimary))
                            .frame(width: 50, height: 18)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.35)))
                    }
                    .buttonStyle(.plain)
                    .debugFrame("picco-reset")
                    .help("Picco massimo in uscita (dBFS) dall'ultimo azzeramento. Clic per azzerare picco e indicatori.")
                    Text("picco").font(.system(size: 9)).foregroundColor(Theme.textTertiary)
                }
                .frame(width: 58)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.stroke).frame(width: 1).padding(.horizontal, 8)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Text("Trascina i controlli · ⌥ fine · rotella · doppio clic azzera · clic sul valore per digitarlo · sposta la finestra da titolo e spazi vuoti")
            Spacer()
            if case .running(let info) = model.status {
                switch model.volumeKeys {
                case .active:
                    Text("Tasti volume: senza click → \(info.outputName)")
                        .help("I tasti volume sono gestiti da Armonia EQ: il volume è applicato con una rampa graduale e resta sincronizzato con macOS")
                case .needsPermission:
                    Button("Tasti volume: consenti Accessibilità per evitare i click") { model.requestVolumeKeyPermission() }
                        .buttonStyle(.borderless)
                        .foregroundColor(Theme.warning)
                        .help("Senza il permesso Accessibilità i tasti volume cambiano il volume di BlackHole, che lo applica a gradino (click). Impostazioni di Sistema → Privacy e sicurezza → Accessibilità → Armonia EQ")
                case .inactive:
                    Text("Tasti volume → \(info.outputName)")
                }
                Text("Buffer \(info.bufferFrames)")
                    .help("Uscita in uso: \(info.outputDetail)")
            }
        }
        .font(.system(size: 10))
        .foregroundColor(Theme.textTertiary)
        .padding(.vertical, 2)
        .background(WindowDragArea())
    }
}

// MARK: - Sotto-viste

private struct SliderColumn: View {
    let title: String
    var subtitle: String? = nil
    let value: Float
    let range: ClosedRange<Float>
    let tint: Color
    let enabled: Bool
    var debugName = ""
    /// Arrotondamento al passo del controllo (es. 0,5 dB per BASSI/ALTI); nil = 0,1 dB del modello.
    var quantize: ((Float) -> Float)? = nil
    /// Scelta della frequenza di intervento (BASSI/ALTI), mostrata sotto il titolo.
    var frequency: FrequencyChoice? = nil
    let onChange: (Float) -> Void

    private func change(_ v: Float) { onChange(quantize.map { $0(v) } ?? v) }

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 9.5, weight: .semibold)).foregroundColor(Theme.textSecondary)
                .frame(height: 12)
            Group {
                if let f = frequency {
                    FrequencyPicker(choice: f)
                } else if let sub = subtitle {
                    Text(sub).font(.system(size: 8.5)).foregroundColor(Theme.textTertiary)
                } else {
                    Color.clear
                }
            }
            .frame(height: 18)
            VerticalSlider(value: value, range: range, defaultValue: 0, tint: tint, enabled: enabled, onChange: change)
                .frame(width: 28, height: 170)
                .debugFrame(debugName.isEmpty ? title : debugName)
            DbField(value: value, range: range, color: value == 0 ? Theme.textSecondary : Theme.textPrimary,
                    onCommit: change)
                .debugFrame("valore-" + (debugName.isEmpty ? title : debugName))
            Text("dB").font(.system(size: 9)).foregroundColor(Theme.textTertiary)
        }
    }
}

/// Scala +12 / 0 / -12 a sinistra delle bande.
private struct DbScale: View {
    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 12 + 8 + 18 + 8)
            ZStack {
                VStack {
                    Text("+12"); Spacer(); Text("+6"); Spacer(); Text("0"); Spacer(); Text("-6"); Spacer(); Text("-12")
                }
                .padding(.vertical, 1)
            }
            .frame(height: 170)
            Spacer()
        }
        .font(.system(size: 8, design: .monospaced))
        .foregroundColor(Theme.textTertiary)
    }
}

private struct PowerButton: View {
    let status: EngineStatus
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(color.opacity(on ? 0.2 : 0.06))
                Circle().stroke(color.opacity(on ? 0.9 : 0.35), lineWidth: 1.5)
                Image(systemName: "power").font(.system(size: 15, weight: .bold)).foregroundColor(color)
            }
            .frame(width: 38, height: 38)
        }
        .buttonStyle(.plain)
        .help(on ? "Spegni: l'audio torna direttamente al dispositivo, senza EQ" : "Accendi: tutto l'audio di sistema passa per l'equalizzatore")
    }

    private var color: Color {
        guard on else { return Theme.textSecondary }
        switch status {
        case .running: return Theme.ok
        case .starting: return Theme.warning
        default: return Theme.danger
        }
    }
}

private struct BannerView: View {
    let icon: String
    let text: String
    let buttons: [(String, () -> Void)]

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).foregroundColor(Theme.warning)
            Text(text).font(.system(size: 11.5)).foregroundColor(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            ForEach(Array(buttons.enumerated()), id: \.offset) { _, b in
                Button(b.0, action: b.1)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.warning.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.warning.opacity(0.35), lineWidth: 1))
    }
}

// MARK: - Fogli: nome profilo, gestione profili

enum NameSheetMode: String, Identifiable {
    case saveAs, rename
    var id: String { rawValue }
}

private struct NameSheet: View {
    let mode: NameSheetMode
    @ObservedObject var model: AppModel
    let dismiss: () -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode == .saveAs ? "Salva come nuovo profilo personale" : "Rinomina profilo")
                .font(.headline)
            if mode == .saveAs, case .factory = model.selection {
                Text("Il profilo predefinito \"\(model.selectionName)\" resta invariato: la curva attuale viene salvata come nuovo profilo.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Es. M60 – Voci limpide", text: $name, onCommit: confirm)
                .textFieldStyle(.roundedBorder)
                .frame(width: 340)
            if exists {
                Text(mode == .saveAs ? "Esiste già un profilo con questo nome: verrà aggiornato."
                                     : "Esiste già un altro profilo con questo nome.")
                    .font(.system(size: 11)).foregroundColor(Theme.warning)
            }
            HStack {
                Spacer()
                Button("Annulla", action: dismiss).keyboardShortcut(.cancelAction)
                Button(mode == .saveAs ? "Salva" : "Rinomina", action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || (mode == .rename && exists))
            }
        }
        .padding(20)
        .onAppear {
            if mode == .rename { name = model.selectedCustomProfile?.name ?? "" }
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var exists: Bool {
        !trimmed.isEmpty && model.profileNameExists(trimmed, excluding: mode == .rename ? model.selectedCustomProfile?.id : nil)
    }

    private func confirm() {
        guard !trimmed.isEmpty else { return }
        switch mode {
        case .saveAs: model.saveAsNewProfile(named: trimmed)
        case .rename:
            guard !exists, let p = model.selectedCustomProfile else { return }
            model.renameProfile(p.id, to: trimmed)
        }
        dismiss()
    }
}

private struct ProfileManagerSheet: View {
    @ObservedObject var model: AppModel
    let onImport: () -> Void
    let onExport: () -> Void
    let dismiss: () -> Void
    @State private var editingID: UUID?
    @State private var editingName = ""
    @State private var pendingDelete: CustomProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Profili personali").font(.headline)
            if model.customProfiles.isEmpty {
                Text("Nessun profilo personale. Regola l'equalizzatore e usa \"Salva come…\".")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                    .frame(width: 420, height: 80)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.customProfiles) { p in row(p) }
                    }
                }
                .frame(width: 480, height: min(CGFloat(model.customProfiles.count) * 38 + 8, 300))
            }
            Text("I profili predefiniti non si possono modificare: per cambiarli salvane una copia come profilo personale.")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Importa…", action: onImport)
                Button("Esporta…", action: onExport).disabled(model.customProfiles.isEmpty)
                Spacer()
                Button("Chiudi", action: dismiss).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .alert("Eliminare \"\(pendingDelete?.name ?? "")\"?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Elimina", role: .destructive) {
                if let p = pendingDelete { model.deleteProfile(p.id) }
                pendingDelete = nil
            }
            Button("Annulla", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("L'operazione non si può annullare.")
        }
    }

    @ViewBuilder private func row(_ p: CustomProfile) -> some View {
        HStack(spacing: 8) {
            Image(systemName: model.selection == .custom(p.id) ? "checkmark.circle.fill" : "circle")
                .foregroundColor(model.selection == .custom(p.id) ? Theme.accent : .secondary)
            if editingID == p.id {
                TextField("Nome", text: $editingName, onCommit: { commitRename(p) })
                    .textFieldStyle(.roundedBorder)
                Button("OK") { commitRename(p) }
                    .disabled(editingName.trimmingCharacters(in: .whitespaces).isEmpty
                              || model.profileNameExists(editingName, excluding: p.id))
            } else {
                Text(p.name).frame(maxWidth: .infinity, alignment: .leading)
                Button("Usa") { model.select(.custom(p.id)) }
                Button("Rinomina") { editingID = p.id; editingName = p.name }
                Button("Duplica") { model.duplicateProfile(p.id) }
            }
            Button(role: .destructive) { pendingDelete = p } label: { Image(systemName: "trash") }
                .help("Elimina")
        }
        .padding(.horizontal, 8).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    private func commitRename(_ p: CustomProfile) {
        let n = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !model.profileNameExists(n, excluding: p.id) else { return }
        model.renameProfile(p.id, to: n)
        editingID = nil
    }
}

/// Elenco a tendina dei profili: predefiniti, Manuale, personali.
private struct ProfileList: View {
    @ObservedObject var model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header("Profili predefiniti")
            ForEach(model.factoryProfiles) { p in
                row(p.name, p.summary, .factory(p.id))
            }
            Divider().padding(.vertical, 4)
            row("Manuale / Personalizzato", "Equalizzazione libera, salvata automaticamente", .manual)
            Divider().padding(.vertical, 4)
            header("Profili personali")
            if model.customProfiles.isEmpty {
                Text("Nessuno: regola l'EQ e usa \"Salva come…\"")
                    .font(.system(size: 11)).foregroundColor(Theme.textTertiary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
            } else {
                ForEach(model.customProfiles) { p in
                    row(p.name, nil, .custom(p.id))
                }
            }
        }
        .padding(8)
        .frame(width: 330)
        .background(Theme.panel)
    }

    private func header(_ t: String) -> some View {
        SectionLabel(t).padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
    }

    private func row(_ name: String, _ summary: String?, _ sel: ProfileSelection) -> some View {
        let selected = model.selection == sel
        return Button {
            model.select(sel)
            close()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.accent)
                    .opacity(selected ? 1 : 0)
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                        .foregroundColor(Theme.textPrimary)
                    if let s = summary, !s.isEmpty {
                        Text(s).font(.system(size: 10.5)).foregroundColor(Theme.textSecondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.accent.opacity(0.12) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Opzioni di frequenza per un controllo di tono.
struct FrequencyChoice {
    let options: [Float]
    let selected: Float
    let debugName: String
    let onSelect: (Float) -> Void
}

/// Menu a comparsa compatto con le frequenze di intervento (es. 60/80/100/120 Hz).
private struct FrequencyPicker: View {
    let choice: FrequencyChoice

    var body: some View {
        Picker("", selection: Binding(get: { choice.selected }, set: { choice.onSelect($0) })) {
            ForEach(choice.options, id: \.self) { hz in
                Text(frequencyLabel(hz)).tag(hz)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.mini)
        .font(.system(size: 9.5))
        .frame(width: 60)
        .debugFrame(choice.debugName)
        .help("Frequenza di intervento (indipendente dal guadagno)")
    }
}
