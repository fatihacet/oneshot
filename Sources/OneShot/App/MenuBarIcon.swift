import AppKit

/// The menu bar version of the app icon: viewfinder brackets around a "1" made of a stem and a dot.
/// Drawn as a template image so macOS tints it for light, dark and highlighted menu bars.
enum MenuBarIcon {
    static let image: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let frame = rect.insetBy(dx: 2, dy: 2)
            let arm: CGFloat = 4.6
            let radius: CGFloat = 1.8
            let path = NSBezierPath()
            path.lineWidth = 1.7
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            let corners: [(NSPoint, CGFloat, CGFloat)] = [
                (NSPoint(x: frame.minX, y: frame.maxY), 1, -1),
                (NSPoint(x: frame.maxX, y: frame.maxY), -1, -1),
                (NSPoint(x: frame.minX, y: frame.minY), 1, 1),
                (NSPoint(x: frame.maxX, y: frame.minY), -1, 1),
            ]
            for (corner, dx, dy) in corners {
                path.move(to: NSPoint(x: corner.x, y: corner.y + dy * arm))
                path.appendArc(
                    from: corner,
                    to: NSPoint(x: corner.x + dx * arm, y: corner.y),
                    radius: radius
                )
                path.line(to: NSPoint(x: corner.x + dx * arm, y: corner.y))
            }
            NSColor.black.setStroke()
            path.stroke()

            // The "1": a rounded stem with a dot up and to its left, a small gap apart.
            let dotSize: CGFloat = 3
            let stemWidth: CGFloat = 2.5
            let stemTop = NSPoint(x: rect.midX + 2.25, y: rect.midY + 3.45)
            let stem = NSBezierPath()
            stem.lineWidth = stemWidth
            stem.lineCapStyle = .round
            stem.move(to: stemTop)
            stem.line(to: NSPoint(x: stemTop.x, y: rect.midY - 3.45))
            stem.stroke()

            let flagDistance = (dotSize + stemWidth) / 2 + 1.2
            let flagAngle: CGFloat = 15 * .pi / 180
            let dot = NSPoint(x: stemTop.x - flagDistance * cos(flagAngle), y: stemTop.y - flagDistance * sin(flagAngle))
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: dot.x - dotSize / 2, y: dot.y - dotSize / 2, width: dotSize, height: dotSize)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "OneShot"
        return image
    }()
}
