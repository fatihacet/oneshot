import AppKit

/// Keeps track of screenshots pinned above other windows.
@MainActor
final class PinManager {
    static let shared = PinManager()

    private(set) var windows: [PinWindow] = []
    private(set) var isHidden = false

    var hasPins: Bool { !windows.isEmpty }
    var hasLockedPins: Bool { windows.contains { $0.isLocked } }
    var windowIDs: Set<CGWindowID> { Set(windows.map { CGWindowID($0.windowNumber) }) }

    func pin(_ capture: Capture) {
        let window = PinWindow(capture: capture)
        windows.append(window)
        if isHidden { setHidden(false) }
        window.orderFrontRegardless()
    }

    /// Pins the image currently on the clipboard. Returns false if there is none.
    @discardableResult
    func pinFromClipboard() -> Bool {
        guard let capture = Capture.fromClipboard() else { return false }
        pin(capture)
        return true
    }

    func setHidden(_ hidden: Bool) {
        isHidden = hidden
        windows.forEach { hidden ? $0.orderOut(nil) : $0.orderFrontRegardless() }
    }

    func unlockAll() {
        windows.forEach { $0.isLocked = false }
    }

    func closeAll() {
        windows.forEach { $0.close() }
        windows.removeAll()
    }

    fileprivate func didClose(_ window: PinWindow) {
        windows.removeAll { $0 === window }
    }
}

/// A borderless, always-on-top window showing a single screenshot.
/// Scroll to resize, ⌥ + scroll to change opacity, drag to move, Esc to close.
final class PinWindow: NSPanel {
    let capture: Capture
    private let content: PinContentView

    var isLocked = false {
        didSet {
            ignoresMouseEvents = isLocked
            content.showHUD(isLocked ? "Locked" : "Unlocked")
        }
    }

    init(capture: Capture) {
        self.capture = capture
        self.content = PinContentView(image: capture.image)
        super.init(
            contentRect: PinWindow.initialFrame(for: capture),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentAspectRatio = capture.pointSize
        minSize = CGSize(width: 48, height: 48)
        content.window_ = self
        contentView = content
    }

    override var canBecomeKey: Bool { true }

    override func close() {
        super.close()
        MainActor.assumeIsolated { PinManager.shared.didClose(self) }
    }

    private static func initialFrame(for capture: Capture) -> CGRect {
        let screen = capture.sourceRect.flatMap { rect in
            NSScreen.screens.first { $0.frame.intersects(rect) }
        } ?? NSScreen.underMouse ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        var size = capture.pointSize
        let maxSize = CGSize(width: visible.width * 0.7, height: visible.height * 0.7)
        let fit = min(1, maxSize.width / size.width, maxSize.height / size.height)
        size = CGSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())

        let center = capture.sourceRect.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? CGPoint(x: visible.midX, y: visible.midY)
        var frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        return frame
    }

    // MARK: Actions

    func resize(by factor: CGFloat) {
        let aspect = capture.pointSize.height / max(capture.pointSize.width, 1)
        let width = min(max(frame.width * factor, 48), 8000)
        let height = width * aspect
        let newFrame = CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
        setFrame(newFrame.integral, display: true)
        content.showHUD("\(Int((width / capture.pointSize.width * 100).rounded()))%")
    }

    func resetSize() {
        let size = capture.pointSize
        setFrame(CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height).integral, display: true)
        content.showHUD("100%")
    }

    func setOpacity(_ value: CGFloat) {
        alphaValue = min(max(value, 0.1), 1)
        content.showHUD("Opacity \(Int((alphaValue * 100).rounded()))%")
    }

    @objc func copyImage() {
        ImageExporter.copyToClipboard(capture)
        MainActor.assumeIsolated { Toast.show("Copied to clipboard") }
    }

    @objc func saveImage() {
        MainActor.assumeIsolated {
            do {
                let url = try ImageExporter.save(capture)
                Toast.show("Saved to \(url.deletingLastPathComponent().lastPathComponent)")
            } catch {
                Toast.show("Could not save: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    @objc func openBackgroundTool() {
        MainActor.assumeIsolated { BackgroundToolWindowController.shared.open(capture) }
    }

    @objc func uploadImage() {
        MainActor.assumeIsolated { Uploader.shared.upload(capture) }
    }

    @objc func copyText() {
        MainActor.assumeIsolated { TextRecognizer.recognizeAndCopy(capture.image) }
    }

    @objc func toggleLock() { isLocked.toggle() }
    @objc func resetSizeAction() { resetSize() }
    @objc func closeAction() { close() }

    @objc func opacityAction(_ sender: NSMenuItem) {
        setOpacity(CGFloat(sender.tag) / 100)
    }
}

private final class PinContentView: NSView {
    weak var window_: PinWindow?
    private let imageLayer = CALayer()
    private let hudLayer = CATextLayer()
    private let closeButton: NSButton
    private var hudWork: DispatchWorkItem?

    init(image: CGImage) {
        closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")!,
            target: nil,
            action: #selector(PinWindow.closeAction)
        )
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        imageLayer.contents = image
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        imageLayer.borderWidth = 1
        imageLayer.borderColor = NSColor.gray.withAlphaComponent(0.4).cgColor
        layer?.addSublayer(imageLayer)

        hudLayer.fontSize = 12
        hudLayer.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        hudLayer.foregroundColor = NSColor.white.cgColor
        hudLayer.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        hudLayer.cornerRadius = 6
        hudLayer.alignmentMode = .center
        hudLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        hudLayer.isHidden = true
        layer?.addSublayer(hudLayer)

        closeButton.isBordered = false
        closeButton.contentTintColor = .white
        closeButton.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        closeButton.isHidden = true
        closeButton.shadow = {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 3
            shadow.shadowColor = .black.withAlphaComponent(0.6)
            return shadow
        }()
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
        closeButton.target = window_
        closeButton.frame = CGRect(x: 6, y: bounds.height - 28, width: 22, height: 22)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }

    override func scrollWheel(with event: NSEvent) {
        guard let window = window_ else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.005 : event.scrollingDeltaY * 0.05
        guard delta != 0 else { return }
        if event.modifierFlags.contains(.option) {
            window.setOpacity(window.alphaValue + delta)
        } else {
            window.resize(by: 1 + delta)
        }
    }

    override func magnify(with event: NSEvent) {
        window_?.resize(by: 1 + event.magnification)
    }

    override func keyDown(with event: NSEvent) {
        guard let window = window_ else { return }
        switch Int(event.keyCode) {
        case 53: window.close() // Escape
        case 29 where event.modifierFlags.contains(.command): window.resetSize() // ⌘0
        default: super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let window = window_, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "c": window.copyImage(); return true
        case "s": window.saveImage(); return true
        case "w": window.close(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let window = window_ else { return nil }
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, key: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = window
            menu.addItem(item)
        }
        add("Copy", #selector(PinWindow.copyImage), key: "c")
        add("Save", #selector(PinWindow.saveImage), key: "s")
        add("Copy Text", #selector(PinWindow.copyText))
        add("Upload", #selector(PinWindow.uploadImage))
        add("Add Background…", #selector(PinWindow.openBackgroundTool))
        menu.addItem(.separator())

        let opacity = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        for value in [100, 75, 50, 25] {
            let item = NSMenuItem(title: "\(value)%", action: #selector(PinWindow.opacityAction(_:)), keyEquivalent: "")
            item.tag = value
            item.target = window
            item.state = Int((window.alphaValue * 100).rounded()) == value ? .on : .off
            opacityMenu.addItem(item)
        }
        opacity.submenu = opacityMenu
        menu.addItem(opacity)
        add("Actual Size", #selector(PinWindow.resetSizeAction), key: "0")
        add("Lock (Click Through)", #selector(PinWindow.toggleLock))
        menu.addItem(.separator())
        add("Close", #selector(PinWindow.closeAction), key: "w")
        return menu
    }

    func showHUD(_ text: String) {
        hudWork?.cancel()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let textSize = (text as NSString).size(withAttributes: [.font: font])
        let size = CGSize(width: ceil(textSize.width) + 16, height: ceil(textSize.height) + 8)
        hudLayer.string = text
        hudLayer.frame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        hudLayer.isHidden = false
        CATransaction.commit()

        let work = DispatchWorkItem { [weak self] in self?.hudLayer.isHidden = true }
        hudWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }
}
