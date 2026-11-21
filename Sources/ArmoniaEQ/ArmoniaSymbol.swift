import AppKit

/// Simbolo di Armonia EQ (barre + curva con punti, come l'icona dell'app) disegnato in vettoriale.
/// È un'immagine "template": macOS la colora da sé per barra dei menu chiara/scura, stato
/// evidenziato e icona attenuata, ed è nitida a qualsiasi risoluzione (Retina compreso).
enum ArmoniaSymbol {
    /// Punti della curva in un riquadro 18×18 (origine in alto a sinistra).
    private static let points: [CGPoint] = {
        let xs: [CGFloat] = [3, 7, 11, 15]
        let values: [CGFloat] = [0.50, 0.80, 0.38, 0.70]
        return zip(xs, values).map { CGPoint(x: $0, y: bottom - $1 * (bottom - top)) }
    }()
    private static let top: CGFloat = 1.5
    private static let bottom: CGFloat = 16.5

    static func image(pointSize: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current else { return false }
            let s = rect.width / 18
            ctx.cgContext.scaleBy(x: s, y: s)

            // 1) barre (semitrasparenti) dal basso fino al punto della curva
            NSColor.black.withAlphaComponent(0.47).setFill()
            let barWidth: CGFloat = 1.7
            for p in points {
                NSBezierPath(roundedRect: NSRect(x: p.x - barWidth / 2, y: p.y, width: barWidth, height: bottom - p.y),
                             xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            }

            // 2) spazio vuoto attorno alla curva, così curva e barre restano distinte anche a 18 pt
            ctx.compositingOperation = .clear
            curve(width: 3.4).stroke()
            for p in points { dot(p, radius: 3.0).fill() }

            // 3) curva e punti pieni
            ctx.compositingOperation = .sourceOver
            NSColor.black.setStroke()
            NSColor.black.setFill()
            curve(width: 1.5).stroke()
            for p in points { dot(p, radius: 2.0).fill() }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Armonia EQ"
        return image
    }

    private static func curve(width: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.move(to: points[0])
        for p in points.dropFirst() { path.line(to: p) }
        return path
    }

    private static func dot(_ p: CGPoint, radius r: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    }
}
