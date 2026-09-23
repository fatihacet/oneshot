import AppKit
import QuartzCore

enum SelectionMode {
    case area
    case window
}

enum SelectionResult {
    /// `rect` is in the snapshot screen's local coordinates (points, bottom-left origin).
    case area(DisplaySnapshot, rect: CGRect)
    case window(WindowInfo, localRect: CGRect, DisplaySnapshot)
    case cancelled
}

/// Shows a frozen snapshot of every display and lets the user pick an area or a window.
@MainActor
final class SelectionOverlayController {
    private let snapshots: [DisplaySnapshot]
    private let windowInfos: [WindowInfo]
    private let allowsWindowMode: Bool
    private var mode: SelectionMode
    private var windows: [SelectionOverlayWindow] = []
    private var views: [SelectionOverlayView] = []
    private var previousApp: NSRunningApplication?
    private var continuation: CheckedContinuation<SelectionResult, Never>?

    init(snapshots: [DisplaySnapshot], windows: [WindowInfo], initialMode: SelectionMode, allowsWindowMode: Bool) {
        self.snapshots = snapshots
        self.windowInfos = windows
        self.allowsWindowMode = allowsWindowMode
        self.mode = allowsWindowMode ? initialMode : .area
    }

    func run() async -> SelectionResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            present()
        }
    }

    private func present() {
        previousApp = NSWorkspace.shared.frontmostApplication
        for snapshot in snapshots {
            let window = SelectionOverlayWindow(screen: snapshot.screen)
            let view = SelectionOverlayView(
                frame: CGRect(origin: .zero, size: snapshot.screen.frame.size),
                snapshot: snapshot,
                windowTargets: windowTargets(for: snapshot),
                controller: self
            )
            view.mode = mode
            window.contentView = view
            windows.append(window)
            views.append(view)
        }

        NSApp.activate(ignoringOtherApps: true)
        windows.forEach { $0.orderFrontRegardless() }
        let mouseScreen = NSScreen.underMouse
        if let index = snapshots.firstIndex(where: { $0.screen == mouseScreen }) ?? snapshots.indices.first {
            windows[index].makeKey()
            windows[index].makeFirstResponder(views[index])
            views[index].setPointer(globalLocation: NSEvent.mouseLocation)
        }
        NSCursor.crosshair.set()
    }

    private func windowTargets(for snapshot: DisplaySnapshot) -> [WindowTarget] {
        let displayBounds = CGDisplayBounds(snapshot.displayID)
        let screenHeight = snapshot.screen.frame.height
        return windowInfos.compactMap { info in
            guard info.frame.intersects(displayBounds) else { return nil }
            let local = CGRect(
                x: info.frame.minX - displayBounds.minX,
                y: screenHeight - (info.frame.maxY - displayBounds.minY),
                width: info.frame.width,
                height: info.frame.height
            )
            return WindowTarget(info: info, rect: local)
        }
    }

    // MARK: Called by views

    func toggleMode() {
        guard allowsWindowMode else { return }
        mode = mode == .area ? .window : .area
        views.forEach { $0.mode = mode }
    }

    /// Space while dragging moves the selection (like the macOS screenshot tool);
    /// Space without a drag toggles window mode.
    func spaceKey(isDown: Bool, isRepeat: Bool) {
        if isDown {
            if views.contains(where: \.isDragging) {
                views.forEach { $0.setMovingSelection(true) }
            } else if !isRepeat {
                toggleMode()
            }
        } else {
            views.forEach { $0.setMovingSelection(false) }
        }
    }

    func pointerDidMove(on activeView: SelectionOverlayView) {
        for view in views where view !== activeView {
            view.clearPointer()
        }
    }

    func cancel() {
        finish(.cancelled)
    }

    func finish(_ result: SelectionResult) {
        guard let continuation else { return }
        self.continuation = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        NSCursor.arrow.set()
        if let previousApp, previousApp != NSRunningApplication.current {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate()
        }
        continuation.resume(returning: result)
    }
}

struct WindowTarget {
    let info: WindowInfo
    /// Window frame in the overlay view's coordinates.
    let rect: CGRect
}

final class SelectionOverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class SelectionOverlayView: NSView {
    private unowned let controller: SelectionOverlayController
    let snapshot: DisplaySnapshot
    private let windowTargets: [WindowTarget]

    var mode: SelectionMode = .area {
        didSet {
            dragStart = nil
            selection = nil
            updateHoveredWindow()
            refresh()
        }
    }

    private var dragStart: CGPoint?
    /// Last pointer location while Space is held to move the selection.
    private var moveAnchor: CGPoint?
    private var isSpaceHeld = false

    var isDragging: Bool { dragStart != nil }
    private var selection: CGRect?
    private var pointer: CGPoint?
    private var hoveredWindow: WindowTarget?

    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let highlightLayer = CAShapeLayer()
    private let crosshairShadow = CAShapeLayer()
    private let crosshairLine = CAShapeLayer()
    private let showsCrosshair = Preferences.showCrosshair
    private let labelLayer = CALayer()
    private let labelText = CATextLayer()
    private let loupeLayer = CALayer()
    private let loupeImage = CALayer()
    private let loupeCenter = CAShapeLayer()

    private static let loupeSize: CGFloat = 120
    private static let loupeZoom: CGFloat = 8
    private static let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    init(frame: CGRect, snapshot: DisplaySnapshot, windowTargets: [WindowTarget], controller: SelectionOverlayController) {
        self.snapshot = snapshot
        self.windowTargets = windowTargets
        self.controller = controller
        super.init(frame: frame)

        // Layer-hosting view: we own the whole layer tree, which keeps redraws on the GPU.
        let root = CALayer()
        root.frame = bounds
        layer = root
        wantsLayer = true
        setUpLayers(in: root)

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setUpLayers(in root: CALayer) {
        let contentsScale = snapshot.screen.backingScaleFactor

        imageLayer.frame = bounds
        imageLayer.contents = snapshot.image
        imageLayer.contentsGravity = .resize
        root.addSublayer(imageLayer)

        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.4).cgColor
        root.addSublayer(dimLayer)

        highlightLayer.lineWidth = 1
        root.addSublayer(highlightLayer)

        // A dark line under a light one keeps the guides visible on any background.
        crosshairShadow.strokeColor = NSColor.black.withAlphaComponent(0.35).cgColor
        crosshairShadow.lineWidth = 3
        crosshairLine.strokeColor = NSColor.white.withAlphaComponent(0.85).cgColor
        crosshairLine.lineWidth = 1
        crosshairLine.lineDashPattern = [6, 4]
        root.addSublayer(crosshairShadow)
        root.addSublayer(crosshairLine)

        labelLayer.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        labelLayer.cornerRadius = 4
        labelLayer.isHidden = true
        labelText.font = Self.labelFont
        labelText.fontSize = Self.labelFont.pointSize
        labelText.foregroundColor = NSColor.white.cgColor
        labelText.alignmentMode = .center
        labelText.contentsScale = contentsScale
        labelLayer.addSublayer(labelText)
        root.addSublayer(labelLayer)

        let size = Self.loupeSize
        loupeLayer.frame = CGRect(x: 0, y: 0, width: size, height: size)
        loupeLayer.cornerRadius = size / 2
        loupeLayer.masksToBounds = true
        loupeLayer.borderWidth = 2
        loupeLayer.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        loupeLayer.backgroundColor = NSColor.black.cgColor
        loupeLayer.isHidden = true

        loupeImage.frame = loupeLayer.bounds
        loupeImage.contents = snapshot.image
        loupeImage.contentsGravity = .resize
        loupeImage.magnificationFilter = .nearest
        loupeLayer.addSublayer(loupeImage)

        let cell = Self.loupeZoom
        loupeCenter.path = CGPath(rect: CGRect(x: (size - cell) / 2, y: (size - cell) / 2, width: cell, height: cell), transform: nil)
        loupeCenter.fillColor = nil
        loupeCenter.strokeColor = NSColor.systemRed.cgColor
        loupeCenter.lineWidth = 1
        loupeLayer.addSublayer(loupeCenter)
        root.addSublayer(loupeLayer)
    }

    // MARK: Pointer

    func setPointer(globalLocation: CGPoint) {
        let origin = snapshot.screen.frame.origin
        pointer = CGPoint(x: globalLocation.x - origin.x, y: globalLocation.y - origin.y)
        updateHoveredWindow()
        refresh()
    }

    func clearPointer() {
        guard pointer != nil || hoveredWindow != nil else { return }
        pointer = nil
        hoveredWindow = nil
        refresh()
    }

    private func location(of event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(
            x: min(max(point.x.rounded(), 0), bounds.width),
            y: min(max(point.y.rounded(), 0), bounds.height)
        )
    }

    private func updateHoveredWindow() {
        guard mode == .window, let pointer else {
            hoveredWindow = nil
            return
        }
        hoveredWindow = windowTargets.first { $0.rect.contains(pointer) }
    }

    // MARK: Events

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseMoved(with event: NSEvent) {
        pointer = location(of: event)
        controller.pointerDidMove(on: self)
        updateHoveredWindow()
        NSCursor.crosshair.set()
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        guard dragStart == nil else { return }
        clearPointer()
    }

    override func mouseDown(with event: NSEvent) {
        let point = location(of: event)
        switch mode {
        case .window:
            pointer = point
            updateHoveredWindow()
            if let target = hoveredWindow {
                controller.finish(.window(target.info, localRect: target.rect, snapshot))
            }
        case .area:
            window?.makeKey()
            window?.makeFirstResponder(self)
            dragStart = point
            selection = nil
            pointer = point
            moveAnchor = isSpaceHeld ? point : nil
            refresh()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area, var start = dragStart else { return }
        let point = location(of: event)
        pointer = point

        if let anchor = moveAnchor {
            // Move the whole selection, keeping it on screen.
            var dx = point.x - anchor.x
            var dy = point.y - anchor.y
            let current = selection ?? CGRect(origin: start, size: .zero)
            dx = min(max(dx, -current.minX), bounds.width - current.maxX)
            dy = min(max(dy, -current.minY), bounds.height - current.maxY)
            start = CGPoint(x: start.x + dx, y: start.y + dy)
            dragStart = start
            selection = selection?.offsetBy(dx: dx, dy: dy)
            moveAnchor = point
            refresh()
            return
        }

        selection = CGRect(
            x: min(start.x, point.x),
            y: min(start.y, point.y),
            width: abs(point.x - start.x),
            height: abs(point.y - start.y)
        )
        refresh()
    }

    /// Enters or leaves "move selection" mode while dragging.
    func setMovingSelection(_ moving: Bool) {
        isSpaceHeld = moving
        guard dragStart != nil else {
            moveAnchor = nil
            return
        }
        if moving {
            if moveAnchor == nil { moveAnchor = pointer }
        } else if let selection, let pointer, moveAnchor != nil {
            // Resume resizing from the corner opposite the pointer.
            moveAnchor = nil
            dragStart = CGPoint(
                x: abs(pointer.x - selection.minX) < abs(pointer.x - selection.maxX) ? selection.maxX : selection.minX,
                y: abs(pointer.y - selection.minY) < abs(pointer.y - selection.maxY) ? selection.maxY : selection.minY
            )
        } else {
            moveAnchor = nil
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .area else { return }
        defer {
            dragStart = nil
            moveAnchor = nil
        }
        guard let selection, selection.width >= 2, selection.height >= 2 else {
            self.selection = nil
            refresh()
            return
        }
        controller.finish(.area(snapshot, rect: selection))
    }

    override func rightMouseDown(with event: NSEvent) {
        controller.cancel()
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: // Escape
            controller.cancel()
        case 49: // Space
            controller.spaceKey(isDown: true, isRepeat: event.isARepeat)
        default:
            break
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { controller.spaceKey(isDown: false, isRepeat: false) }
    }

    // MARK: Rendering

    private func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        switch mode {
        case .area:
            if let selection, selection.width > 0, selection.height > 0 {
                dim(except: selection)
                highlightLayer.path = CGPath(rect: selection.insetBy(dx: -0.5, dy: -0.5), transform: nil)
                highlightLayer.fillColor = nil
                highlightLayer.strokeColor = NSColor.white.cgColor
                showLabel("\(Int(selection.width)) × \(Int(selection.height))", for: selection)
            } else {
                dimLayer.isHidden = true
                highlightLayer.path = nil
                labelLayer.isHidden = true
            }
            updateLoupe()
            updateCrosshair()
        case .window:
            loupeLayer.isHidden = true
            crosshairShadow.path = nil
            crosshairLine.path = nil
            if let target = hoveredWindow {
                dim(except: target.rect)
                highlightLayer.path = CGPath(rect: target.rect, transform: nil)
                highlightLayer.fillColor = NSColor.systemBlue.withAlphaComponent(0.25).cgColor
                highlightLayer.strokeColor = NSColor.systemBlue.cgColor
                showLabel(target.info.ownerName ?? "Window", for: target.rect)
            } else {
                dim(except: nil)
                highlightLayer.path = nil
                labelLayer.isHidden = true
            }
        }
    }

    private func dim(except hole: CGRect?) {
        let path = CGMutablePath()
        path.addRect(bounds)
        if let hole { path.addRect(hole) }
        dimLayer.path = path
        dimLayer.isHidden = false
    }

    private func showLabel(_ text: String, for rect: CGRect) {
        let textSize = (text as NSString).size(withAttributes: [.font: Self.labelFont])
        let size = CGSize(width: ceil(textSize.width) + 12, height: ceil(textSize.height) + 6)
        var origin = CGPoint(x: rect.maxX - size.width, y: rect.minY - size.height - 6)
        if origin.y < 4 { origin.y = rect.minY + 6 }
        origin.x = min(max(origin.x, 4), bounds.width - size.width - 4)
        labelLayer.frame = CGRect(origin: origin, size: size)
        labelText.frame = CGRect(x: 0, y: 3, width: size.width, height: ceil(textSize.height))
        labelText.string = text
        labelLayer.isHidden = false
    }

    private func updateCrosshair() {
        guard showsCrosshair, let pointer, moveAnchor == nil else {
            crosshairShadow.path = nil
            crosshairLine.path = nil
            return
        }
        // Centered on the pixel column/row right of and above the pointer.
        let x = pointer.x + 0.5
        let y = pointer.y + 0.5
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: bounds.width, y: y))
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: bounds.height))
        crosshairShadow.path = path
        crosshairLine.path = path
    }

    private func updateLoupe() {
        guard let pointer else {
            loupeLayer.isHidden = true
            return
        }
        let size = Self.loupeSize
        let visible = size / Self.loupeZoom
        loupeImage.contentsRect = CGRect(
            x: (pointer.x - visible / 2) / bounds.width,
            y: (pointer.y - visible / 2) / bounds.height,
            width: visible / bounds.width,
            height: visible / bounds.height
        )

        var origin = CGPoint(x: pointer.x + 20, y: pointer.y - 20 - size)
        if origin.x + size > bounds.width { origin.x = pointer.x - 20 - size }
        if origin.y < 0 { origin.y = pointer.y + 20 }
        loupeLayer.frame = CGRect(origin: origin, size: CGSize(width: size, height: size))
        loupeLayer.isHidden = false
    }
}
