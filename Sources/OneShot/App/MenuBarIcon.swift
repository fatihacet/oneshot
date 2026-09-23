import AppKit

/// The menu bar version of the app icon: viewfinder brackets around a single dot.
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

            let dot: CGFloat = 4.4
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - dot / 2, y: rect.midY - dot / 2, width: dot, height: dot)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "OneShot"
        return image
    }()
}
