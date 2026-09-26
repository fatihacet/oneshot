import AppKit
@preconcurrency import AVFoundation

/// A round, mirrored camera preview that floats above other windows, like Loom's.
///
/// It is a real window, so screen recordings pick it up: RecordingController adds it to the capture
/// filter. Drag it anywhere; right-click it to change its size or turn the camera off.
@MainActor
final class CameraBubble {
    static let shared = CameraBubble()

    enum Size: String, CaseIterable {
        case small
        case medium
        case large

        var diameter: CGFloat {
            switch self {
            case .small: return 140
            case .medium: return 210
            case .large: return 320
            }
        }

        var title: String { rawValue.capitalized }
    }

    /// Called when the user turns the camera off from the bubble's menu.
    var onTurnOff: (() -> Void)?

    private var panel: CameraBubblePanel?
    private var session: AVCaptureSession?
    private var input: AVCaptureDeviceInput?
    private let sessionQueue = DispatchQueue(label: "dev.oneshot.camera")
    private let margin: CGFloat = 28

    var isVisible: Bool { panel != nil }
    var windowID: CGWindowID? { panel.map { CGWindowID($0.windowNumber) } }

    /// Shows `device` in the bubble, switching cameras if it is already visible.
    func show(device: AVCaptureDevice, on screen: NSScreen?) throws {
        if let session, let input {
            guard input.device.uniqueID != device.uniqueID else { return }
            let newInput = try AVCaptureDeviceInput(device: device)
            sessionQueue.async {
                session.beginConfiguration()
                session.removeInput(input)
                if session.canAddInput(newInput) { session.addInput(newInput) }
                session.commitConfiguration()
            }
            self.input = newInput
            return
        }

        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureDeviceError.unavailable(device.localizedName) }
        session.addInput(input)
        // The bubble is at most 640 pixels wide, so 720p is plenty and keeps the camera light.
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }

        let diameter = Preferences.cameraBubbleSize.diameter
        let panel = CameraBubblePanel(size: CGSize(width: diameter, height: diameter), preview: preview)
        panel.bubbleView.menuProvider = { [weak self] in self?.makeMenu() }
        self.panel = panel
        self.session = session
        self.input = input
        if let screen = screen ?? NSScreen.underMouse { place(on: screen) }
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        sessionQueue.async { session.startRunning() }
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        input = nil
        if let session {
            sessionQueue.async { session.stopRunning() }
        }
        session = nil
    }

    /// Moves the bubble to the bottom-left corner of `screen`.
    func place(on screen: NSScreen) {
        guard let panel else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(x: visible.minX + margin, y: visible.minY + margin))
    }

    /// Moves the bubble into the bottom-left corner of `rect` (AppKit global coordinates) unless it is
    /// already inside, so it appears in a recording of that area. Areas too small for it are left alone.
    func keep(inside rect: CGRect) {
        guard let panel, !rect.contains(panel.frame) else { return }
        let size = panel.frame.size
        guard rect.width >= size.width * 2, rect.height >= size.height * 1.5 else { return }
        let inset = min(margin, rect.width / 20)
        panel.setFrameOrigin(CGPoint(x: rect.minX + inset, y: rect.minY + inset))
    }

    private func resize(to size: Size) {
        Preferences.cameraBubbleSize = size
        guard let panel else { return }
        // Grow from the bottom-left corner, which is where the bubble usually sits.
        var frame = panel.frame
        frame.size = CGSize(width: size.diameter, height: size.diameter)
        if let visible = panel.screen?.visibleFrame {
            frame.origin.x = min(frame.origin.x, visible.maxX - frame.width)
            frame.origin.y = min(frame.origin.y, visible.maxY - frame.height)
        }
        panel.setFrame(frame, display: true, animate: true)
        panel.invalidateShadow()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let current = Preferences.cameraBubbleSize
        for size in Size.allCases {
            let item = ClosureMenuItem(title: size.title) { [weak self] in self?.resize(to: size) }
            item.state = size == current ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Turn Off Camera") { [weak self] in
            self?.hide()
            self?.onTurnOff?()
        })
        return menu
    }
}

private final class CameraBubblePanel: NSPanel {
    let bubbleView: CameraBubbleView

    init(size: CGSize, preview: AVCaptureVideoPreviewLayer) {
        bubbleView = CameraBubbleView(frame: CGRect(origin: .zero, size: size), preview: preview)
        super.init(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = bubbleView
    }

    // Clicking the bubble must not take focus away from the app being recorded.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CameraBubbleView: NSView {
    var menuProvider: (() -> NSMenu?)?
    private let preview: AVCaptureVideoPreviewLayer
    private let ring = CAShapeLayer()

    init(frame: CGRect, preview: AVCaptureVideoPreviewLayer) {
        self.preview = preview
        super.init(frame: frame)
        wantsLayer = true
        guard let layer else { return }
        // The dark fill gives the window its round shape (and shadow) before the first camera frame.
        layer.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        layer.masksToBounds = true
        layer.addSublayer(preview)
        ring.fillColor = nil
        ring.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        ring.lineWidth = 3
        layer.addSublayer(ring)
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = bounds.width / 2
        preview.frame = bounds
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: ring.lineWidth / 2, dy: ring.lineWidth / 2), transform: nil)
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
