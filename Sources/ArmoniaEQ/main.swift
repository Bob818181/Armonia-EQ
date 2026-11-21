import AppKit
import SwiftUI

/// Vista SwiftUI che non sposta MAI la finestra con il mouse: AppKit, per le viste non opache,
/// considera "trascinabile" lo sfondo; con i controlli disegnati da SwiftUI questo faceva spostare
/// la finestra invece del cursore. Lo spostamento avviene solo dalle zone dedicate (WindowDragArea).
final class NonDraggingHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var model: AppModel!
    private var spectrum: SpectrumModel!
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        buildMenu()
        model = AppModel()
        spectrum = SpectrumModel(dsp: model.dsp)
        spectrum.renderErrors = { [weak m = self.model] in m?.router.renderErrors ?? 0 }
        spectrum.diagExtra = { [weak m = self.model] in
            guard let db = m?.router.loopbackCaptureGainDb else { return "loopback=-" }
            return String(format: "volumeBlackHole=%.1fdB(compensato)", db)
        }
        // Icona nella barra dei menu: sempre presente, anche a finestra chiusa.
        menuBar = MenuBarController(model: model,
                                    openWindow: { [weak self] in self?.showWindow() },
                                    quit: { NSApp.terminate(nil) })
        // Se l'app è stata spostata, aggiorna il percorso dell'avvio automatico.
        LoginItem.refreshIfNeeded(appPath: Bundle.main.bundlePath)

        if CommandLine.arguments.contains(LoginItem.launchArgument) {
            // Avvio all'accesso: nessuna finestra, solo l'icona nella barra dei menu.
            NSApp.setActivationPolicy(.accessory)
            UIDebug.log("avvio in secondo piano (solo barra dei menu)")
        } else {
            showWindow()
        }
    }

    /// Mostra la finestra principale (e l'icona nel Dock). Il motore audio non dipende dalla finestra.
    private func showWindow() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            spectrum.isVisible = true
            UIDebug.log("finestra aperta")
            return
        }
        let host = NonDraggingHostingView(rootView: ContentView(model: model, spectrum: spectrum))
        let size = host.fittingSize
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Armonia EQ"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        // NON movibile dallo sfondo: con true, AppKit intercettava i trascinamenti sui cursori
        // SwiftUI (che non sono NSView opache) e spostava la finestra. La finestra si sposta dalla
        // barra del titolo e dalle aree libere marcate con WindowDragArea.
        w.isMovableByWindowBackground = false
        w.backgroundColor = NSColor(red: 0.055, green: 0.062, blue: 0.078, alpha: 1)
        w.contentView = host
        // Striscia di trascinamento sopra la barra del titolo trasparente (i pulsanti della finestra
        // restano sopra e cliccabili): è l'unica zona "di sistema" da cui spostare la finestra,
        // oltre alle aree libere dell'interfaccia (WindowDragArea).
        let flipped = host.isFlipped
        let strip = WindowDragArea.DragView(frame: NSRect(x: 0, y: flipped ? 0 : size.height - 28, width: size.width, height: 28))
        strip.autoresizingMask = flipped ? [.width, .maxYMargin] : [.width, .minYMargin]
        host.addSubview(strip)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setFrameAutosaveName("ArmoniaEQMainWindow")
        if !w.setFrameUsingName("ArmoniaEQMainWindow") { w.center() }
        w.setContentSize(size)
        window = w
        w.makeKeyAndOrderFront(nil)
        UIDebug.log("finestra aperta")
        // Analizzatore in pausa quando la finestra non è visibile (nessun lavoro inutile).
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w,
                                               queue: .main) { [weak self] _ in
            self?.spectrum.isVisible = w.occlusionState.contains(.visible) && !w.isMiniaturized
        }
        if UIDebug.enabled {
            DispatchQueue.main.async { [weak self] in self?.logWindowFrame(w) }
            NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: w, queue: .main) { [weak self] _ in
                UIDebug.log("finestra spostata")
                self?.logWindowFrame(w)
            }
            NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: w, queue: .main) { [weak self] _ in
                self?.logWindowFrame(w)
            }
        }
    }

    private func logWindowFrame(_ w: NSWindow) {
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        let f = w.frame
        // Coordinate globali con origine in alto a sinistra (come CGEvent).
        UIDebug.log(String(format: "finestra x=%.1f y=%.1f w=%.1f h=%.1f", f.minX, screenH - f.maxY, f.width, f.height))
    }

    // L'elaborazione continua anche chiudendo la finestra: resta l'icona nella barra dei menu,
    // da cui si riapre la finestra o si esce dall'app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        spectrum.isVisible = false
        UIDebug.log("finestra chiusa (audio sempre attivo)")
        menuBar?.logStatusItemFrame()
        // Senza finestra l'app vive solo nella barra dei menu (niente icona nel Dock).
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.applicationWillTerminate()
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Informazioni su Armonia EQ",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Nascondi Armonia EQ", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Esci da Armonia EQ", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Modifica")
        edit.addItem(withTitle: "Annulla", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Taglia", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copia", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Incolla", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Seleziona tutto", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Finestra")
        windowMenu.addItem(withTitle: "Riduci a icona", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Chiudi", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
