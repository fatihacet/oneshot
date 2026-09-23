import AppKit
import OneShotCore
import ScreenCaptureKit
import SwiftUI

/// Captures a region repeatedly while its content scrolls and stitches the frames together.
/// The user scrolls manually, or OneShot scrolls for them (requires Accessibility permission).
@MainActor
final class ScrollingCaptureSession {
    private let screen: NSScreen
    private let displayID: CGDirectDisplayID
    /// Region in the screen's local AppKit coordinates.
    private let rect: CGRect
    private let scale: CGFloat

    private let model = ScrollingCaptureModel()
    private let worker: StitchWorker
    private var frameWindow: RegionFrameWindow?
    private var panel: ScrollingCapturePanel?
    private var loopTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var lastPreviewUpdate = Date.distantPast

    init(screen: NSScreen, displayID: CGDirectDisplayID, rect: CGRect, scale: CGFloat) {
        self.screen = screen
        self.displayID = displayID
        self.rect = rect
        self.scale = scale
        // Overlay scroll bars are about 16 pt wide.
        self.worker = StitchWorker(ignoredTrailingColumns: Int(20 * scale))
    }

    /// Returns the stitched image, or nil if the user cancelled.
    func run() async -> CGImage? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            present()
        }
    }

    private var globalRect: CGRect {
        rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
    }

    private func present() {
        let frameWindow = RegionFrameWindow(around: globalRect)
        frameWindow.orderFrontRegardless()
        self.frameWindow = frameWindow

        let panel = ScrollingCapturePanel(model: model, actions: .init(
            toggleAutoScroll: { [weak self] in self?.toggleAutoScroll() },
            done: { [weak self] in self?.finish() },
            cancel: { [weak self] in self?.cancel() }
        ))
        panel.place(beside: globalRect, on: screen)
        panel.orderFrontRegardless()
        panel.makeKey()
        self.panel = panel

        loopTask = Task { [weak self] in await self?.captureLoop() }
    }

    // MARK: Capture loop

    private func captureLoop() async {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            model.status = "Could not start: \(error.localizedDescription)"
            return
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            model.status = "The display is no longer available."
            return
        }
        let excluded = ScreenCapturer.windowsToExclude(from: content, keeping: [])
        let sourceRect = CGRect(
            x: rect.minX, y: screen.frame.height - rect.maxY, width: rect.width, height: rect.height
        )
        var unchangedFrames = 0

        while !Task.isCancelled {
            if model.isAutoScrolling {
                postScroll()
                try? await Task.sleep(for: .milliseconds(220))
            } else {
                try? await Task.sleep(for: .milliseconds(90))
            }
            guard !Task.isCancelled else { return }

            let image: CGImage
            do {
                image = try await ScreenCapturer.captureRegion(
                    display: display, excluding: excluded, sourceRect: sourceRect, scale: scale
                )
            } catch {
                model.status = "Capture failed: \(error.localizedDescription)"
                continue
            }

            let result = await worker.add(image)
            model.pixelHeight = await worker.outputHeight
            switch result {
            case .appended:
                unchangedFrames = 0
                model.status = model.isAutoScrolling ? "Scrolling…" : "Keep scrolling, then click Done."
                await updatePreview()
            case .unchanged:
                unchangedFrames += 1
                // In auto mode, a few frames without movement mean the end was reached.
                if model.isAutoScrolling, unchangedFrames >= 4 {
                    finish()
                    return
                }
            case .noOverlap:
                model.status = "Lost track. Scroll back up a little, then scroll slower."
            case .full:
                model.status = "Maximum height reached."
                finish()
                return
            case .sizeMismatch:
                model.status = "The region changed size."
            }
        }
    }

    private func updatePreview(force: Bool = false) async {
        guard force || Date().timeIntervalSince(lastPreviewUpdate) > 0.6 else { return }
        lastPreviewUpdate = Date()
        model.preview = await worker.makeImage()
    }

    // MARK: Auto-scroll

    private func toggleAutoScroll() {
        if model.isAutoScrolling {
            model.isAutoScrolling = false
            model.status = "Auto-scroll stopped. Scroll manually or click Done."
            return
        }
        guard AXIsProcessTrusted() else {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            model.status = "Allow OneShot in Privacy & Security › Accessibility to use auto-scroll."
            return
        }
        // Scroll events go to the view under the pointer, so park it in the middle of the region.
        let center = CGPoint(x: globalRect.midX, y: globalRect.midY)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: center.x, y: primaryHeight - center.y))
        CGAssociateMouseAndMouseCursorPosition(1)
        model.isAutoScrolling = true
        model.status = "Scrolling…"
    }

    private func postScroll() {
        let distance = Int32(max(rect.height * 0.45, 40))
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -distance, wheel2: 0, wheel3: 0
        ) else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        event.location = CGPoint(x: globalRect.midX, y: primaryHeight - globalRect.midY)
        event.post(tap: .cghidEventTap)
    }

    // MARK: Finish

    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        loopTask?.cancel()
        model.isAutoScrolling = false
        Task {
            let image = await worker.makeImage()
            tearDown()
            continuation.resume(returning: image)
        }
    }

    private func cancel() {
        guard let continuation else { return }
        self.continuation = nil
        loopTask?.cancel()
        tearDown()
        continuation.resume(returning: nil)
    }

    private func tearDown() {
        frameWindow?.orderOut(nil)
        panel?.orderOut(nil)
        frameWindow = nil
        panel = nil
    }
}

/// Runs the (CPU heavy) stitching off the main thread.
private actor StitchWorker {
    private var stitcher: ScrollStitcher

    init(ignoredTrailingColumns: Int) {
        stitcher = ScrollStitcher(ignoredTrailingColumns: ignoredTrailingColumns)
    }

    func add(_ image: CGImage) -> ScrollStitcher.FrameResult { stitcher.add(image) }
    func makeImage() -> CGImage? { stitcher.makeImage() }
    var outputHeight: Int { stitcher.outputHeight }
}

@MainActor
private final class ScrollingCaptureModel: ObservableObject {
    @Published var preview: CGImage?
    @Published var pixelHeight = 0
    @Published var status = "Scroll the content inside the frame, or use Auto-Scroll."
    @Published var isAutoScrolling = false
}

// MARK: - Windows

private struct ScrollingCaptureActions {
    let toggleAutoScroll: () -> Void
    let done: () -> Void
    let cancel: () -> Void
}

private final class ScrollingCapturePanel: NSPanel {
    init(model: ScrollingCaptureModel, actions: ScrollingCaptureActions) {
        let hosting = NSHostingView(rootView: ScrollingCaptureView(model: model, actions: actions))
        let size = hosting.fittingSize
        super.init(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .statusBar
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        contentView = hosting
    }

    override var canBecomeKey: Bool { true }

    /// Places the panel next to the region: right, then left, then inside the region.
    func place(beside region: CGRect, on screen: NSScreen) {
        let visible = screen.visibleFrame
        let size = frame.size
        let gap: CGFloat = 16
        var origin = CGPoint(x: region.maxX + gap, y: region.maxY - size.height)
        if origin.x + size.width > visible.maxX {
            origin.x = region.minX - gap - size.width
        }
        if origin.x < visible.minX {
            origin.x = region.maxX - size.width - gap
        }
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        setFrameOrigin(origin)
    }
}

private struct ScrollingCaptureView: View {
    @ObservedObject var model: ScrollingCaptureModel
    let actions: ScrollingCaptureActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scrolling Capture")
                .font(.headline)

            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                if let preview = model.preview {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 216, height: 300, alignment: .bottom)
                        .clipped()
                } else {
                    Image(systemName: "arrow.up.and.down.text.horizontal")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 216, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(model.pixelHeight > 0 ? "\(model.pixelHeight) px tall" : " ")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 216, height: 32, alignment: .topLeading)

            Button(action: actions.toggleAutoScroll) {
                Label(
                    model.isAutoScrolling ? "Stop Auto-Scroll" : "Auto-Scroll",
                    systemImage: model.isAutoScrolling ? "stop.fill" : "arrow.down.circle"
                )
                .frame(maxWidth: .infinity)
            }
            HStack {
                Button("Cancel", role: .cancel, action: actions.cancel)
                    .keyboardShortcut(.cancelAction)
                    .frame(maxWidth: .infinity)
                Button("Done", action: actions.done)
                    .keyboardShortcut(.defaultAction)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .frame(width: 240)
    }
}
