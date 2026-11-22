import AppKit
import ObjectiveC

/// Indicatore del volume per i tasti volume gestiti da Armonia EQ: è l'indicatore ORIGINALE di
/// macOS (lo stesso che compare premendo i tasti volume), disegnato dal servizio di sistema OSDUIHelper.
///
/// Perché non lascia semplicemente il tasto a macOS: in quel caso macOS cambierebbe il volume di
/// BlackHole a gradino, cioè il disturbo a ogni tacca. Armonia gestisce il tasto (volume applicato
/// con una rampa, nessun click) e chiede a macOS di mostrare il suo indicatore con il nuovo valore.
/// L'indicatore si richiede con OSDManager di OSD.framework (framework di sistema non documentato,
/// presente da macOS 10.12, usato anche da app diffuse come MonitorControl). Se non fosse disponibile,
/// nessun indicatore viene mostrato (il volume funziona comunque).
final class VolumeHUD {
    static let shared = VolumeHUD()

    private typealias ShowImageFn = @convention(c) (AnyObject, Selector, Int64, UInt32, UInt32, UInt32, UInt32, UInt32, Bool) -> Void
    private var manager: AnyObject?
    private var showImage: ShowImageFn?
    private let showSelector = NSSelectorFromString("showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:")
    private var loaded = false

    /// Immagini dell'indicatore di sistema (valori di OSDUIHelper).
    private enum OSDImage: Int64 {
        case speaker = 3
        case speakerMuted = 4
    }

    /// Carica OSD.framework e risolve il metodo (una sola volta, all'avvio).
    func prepare() {
        guard !loaded else { return }
        loaded = true
        guard let bundle = Bundle(path: "/System/Library/PrivateFrameworks/OSD.framework"), bundle.load(),
              let cls = NSClassFromString("OSDManager") as? NSObject.Type else {
            UIDebug.log("indicatore di macOS non disponibile (OSD.framework)")
            return
        }
        let sharedSel = NSSelectorFromString("sharedManager")
        let clsObject: AnyObject = cls
        guard clsObject.responds(to: sharedSel), let mgr = clsObject.perform(sharedSel)?.takeUnretainedValue(),
              let method = class_getInstanceMethod(object_getClass(mgr), showSelector) else {
            UIDebug.log("indicatore di macOS non disponibile (OSDManager)")
            return
        }
        manager = mgr
        showImage = unsafeBitCast(method_getImplementation(method), to: ShowImageFn.self)
    }

    /// true se l'indicatore di macOS può essere mostrato.
    var isAvailable: Bool { prepare(); return showImage != nil }

    func show(volume: Float, muted: Bool, device: String) {
        prepare()
        guard let mgr = manager, let show = showImage else { return }
        let v = min(max(volume, 0), 1)
        // 16 tacche come l'indicatore di macOS, ciascuna divisa in 4 (passi fini con ⌥⇧).
        let total: UInt32 = 64
        let filled = muted ? 0 : UInt32((v * Float(total)).rounded())
        let image: OSDImage = (muted || v <= 0) ? .speakerMuted : .speaker
        // Schermo con la barra dei menu (dove macOS mostra l'indicatore del volume).
        let display = CGMainDisplayID()
        show(mgr, showSelector, image.rawValue, display, 0x1F4, 1000, filled, total, false)
        UIDebug.log(String(format: "hud volume=%.4f muto=%d (indicatore di macOS)", volume, muted ? 1 : 0))
    }
}
