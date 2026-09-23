import AppKit

/// A click-through dashed frame drawn just outside a capture or recording region.
final class RegionFrameWindow: NSWindow {
    init(around rect: CGRect, color: NSColor = .white) {
        let inset: CGFloat = 4
        super.init(
            contentRect: rect.insetBy(dx: -inset, dy: -inset),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let path = CGPath(rect: view.bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        let shadow = CAShapeLayer()
        shadow.path = path
        shadow.fillColor = nil
        shadow.strokeColor = NSColor.black.withAlphaComponent(0.4).cgColor
        shadow.lineWidth = 3
        let line = CAShapeLayer()
        line.path = path
        line.fillColor = nil
        line.strokeColor = color.cgColor
        line.lineWidth = 1.5
        line.lineDashPattern = [6, 4]
        view.layer?.addSublayer(shadow)
        view.layer?.addSublayer(line)
        contentView = view
    }
}
