import AppKit
import SwiftUI

/// One thumbnail in the Quick Access stack.
@MainActor
final class QuickAccessItem: ObservableObject, Identifiable {
    let id = UUID()
    let capture: Capture
    /// Set for screen recordings: the video or GIF file. `capture` is then its thumbnail.
    let mediaURL: URL?
    @Published var savedURL: URL?
    @Published var isHovering = false {
        didSet { isHovering ? cancelAutoClose() : scheduleAutoClose() }
    }

    fileprivate var panel: NSPanel?
    private var autoCloseTask: Task<Void, Never>?
    fileprivate var onAutoClose: (() -> Void)?

    init(capture: Capture, savedURL: URL?, mediaURL: URL? = nil) {
        self.capture = capture
        self.savedURL = savedURL
        self.mediaURL = mediaURL
    }

    var isRecording: Bool { mediaURL != nil }

    func scheduleAutoClose() {
        cancelAutoClose()
        let seconds = Preferences.quickAccessAutoClose
        guard seconds > 0 else { return }
        autoCloseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, !self.isHovering else { return }
            self.onAutoClose?()
        }
    }

    func cancelAutoClose() {
        autoCloseTask?.cancel()
        autoCloseTask = nil
    }

    /// A file on disk for drag and drop or opening in another app.
    func fileURL() -> URL? {
        if let mediaURL { return mediaURL }
        if let savedURL, FileManager.default.fileExists(atPath: savedURL.path) { return savedURL }
        return try? ImageExporter.temporaryFile(for: capture)
    }
}

/// Floating thumbnails shown after each capture, stacked in the bottom-left corner.
@MainActor
final class QuickAccessManager {
    static let shared = QuickAccessManager()

    private var items: [QuickAccessItem] = []
    private let spacing: CGFloat = 12
    private let margin: CGFloat = 20

    func show(_ capture: Capture, savedURL: URL?) {
        present(QuickAccessItem(capture: capture, savedURL: savedURL))
    }

    /// Shows a finished screen recording (video or GIF) with its first frame as the thumbnail.
    func showRecording(at url: URL, thumbnail: CGImage) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        present(QuickAccessItem(capture: Capture(image: thumbnail, scale: scale, sourceRect: nil), savedURL: url, mediaURL: url))
    }

    private func present(_ item: QuickAccessItem) {
        let view = QuickAccessView(item: item, actions: QuickAccessActions(
            copy: { [weak self] in self?.copy(item) },
            save: { [weak self] in self?.save(item) },
            pin: { [weak self] in self?.pin(item) },
            copyText: { [weak self] in self?.copyText(item) },
            upload: { [weak self] in self?.upload(item) },
            background: { [weak self] in self?.openBackgroundTool(item) },
            annotate: { [weak self] in self?.annotate(item) },
            open: { [weak self] in self?.open(item) },
            close: { [weak self] in self?.close(item) }
        ))
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize

        let panel = QuickAccessPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting

        item.panel = panel
        item.onAutoClose = { [weak self, weak item] in
            guard let item else { return }
            self?.close(item)
        }
        items.append(item)
        layout(animatedExcept: item)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        item.scheduleAutoClose()
    }

    func closeAll() {
        items.forEach { close($0) }
    }

    private func layout(animatedExcept newItem: QuickAccessItem? = nil) {
        guard let screen = NSScreen.underMouse ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var y = visible.minY + margin
        for item in items.reversed() {
            guard let panel = item.panel else { continue }
            let frame = CGRect(x: visible.minX + margin, y: y, width: panel.frame.width, height: panel.frame.height)
            if item === newItem {
                panel.setFrame(frame, display: true)
            } else {
                panel.animator().setFrame(frame, display: true)
            }
            y += frame.height + spacing
        }
    }

    private func close(_ item: QuickAccessItem) {
        item.cancelAutoClose()
        guard let panel = item.panel else { return }
        item.panel = nil
        items.removeAll { $0 === item }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; panel.animator().alphaValue = 0 }) {
            panel.orderOut(nil)
        }
        layout()
    }

    // MARK: Actions

    private func copy(_ item: QuickAccessItem) {
        if let mediaURL = item.mediaURL {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([mediaURL as NSURL])
            Toast.show("Copied file to clipboard")
            close(item)
            return
        }
        ImageExporter.copyToClipboard(item.capture)
        Toast.show("Copied to clipboard")
        close(item)
    }

    private func save(_ item: QuickAccessItem) {
        if let url = item.savedURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            close(item)
            return
        }
        do {
            let url = try ImageExporter.save(item.capture)
            item.savedURL = url
            HistoryRecorder.noteSaved(item.capture, at: url)
            Toast.show("Saved to \(url.deletingLastPathComponent().lastPathComponent)")
            close(item)
        } catch {
            Toast.show("Could not save: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
        }
    }

    private func pin(_ item: QuickAccessItem) {
        PinManager.shared.pin(item.capture)
        close(item)
    }

    private func copyText(_ item: QuickAccessItem) {
        TextRecognizer.recognizeAndCopy(item.capture.image)
    }

    private func upload(_ item: QuickAccessItem) {
        if let mediaURL = item.mediaURL {
            Uploader.shared.upload(fileAt: mediaURL)
            close(item)
            return
        }
        Uploader.shared.upload(item.capture)
        close(item)
    }

    private func annotate(_ item: QuickAccessItem) {
        AnnotationEditorWindowController.shared.open(item.capture)
        close(item)
    }

    private func openBackgroundTool(_ item: QuickAccessItem) {
        BackgroundToolWindowController.shared.open(item.capture)
        close(item)
    }

    private func open(_ item: QuickAccessItem) {
        guard let url = item.fileURL() else { return }
        NSWorkspace.shared.open(url)
        close(item)
    }
}

private final class QuickAccessPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

struct QuickAccessActions {
    let copy: () -> Void
    let save: () -> Void
    let pin: () -> Void
    let copyText: () -> Void
    let upload: () -> Void
    let background: () -> Void
    let annotate: () -> Void
    let open: () -> Void
    let close: () -> Void
}

private struct QuickAccessView: View {
    @ObservedObject var item: QuickAccessItem
    let actions: QuickAccessActions

    private let width: CGFloat = 240

    private var height: CGFloat {
        let size = item.capture.pointSize
        guard size.width > 0 else { return 150 }
        return min(max(width * size.height / size.width, 110), 200)
    }

    var body: some View {
        ZStack {
            Image(nsImage: item.capture.nsImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: height)
                .clipped()

            if item.isRecording, !item.isHovering {
                VStack {
                    Spacer()
                    HStack {
                        Label(
                            item.mediaURL?.pathExtension.lowercased() == "gif" ? "GIF" : "Video",
                            systemImage: item.mediaURL?.pathExtension.lowercased() == "gif" ? "photo.stack" : "play.fill"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.6), in: Capsule())
                        Spacer()
                    }
                }
                .padding(8)
            }

            if item.isHovering {
                Color.black.opacity(0.5)
                VStack(spacing: 8) {
                    PillButton(title: "Copy", action: actions.copy)
                    PillButton(title: item.savedURL == nil ? "Save" : "Show in Finder", action: actions.save)
                    if UploadSettings.isConfigured {
                        PillButton(title: "Upload", action: actions.upload)
                    }
                }
                VStack {
                    HStack {
                        CornerButton(symbol: "xmark", help: "Close", action: actions.close)
                        Spacer()
                        if !item.isRecording {
                            CornerButton(symbol: "pin.fill", help: "Pin to screen", action: actions.pin)
                        }
                    }
                    Spacer()
                    HStack {
                        if !item.isRecording {
                            CornerButton(symbol: "text.viewfinder", help: "Copy text", action: actions.copyText)
                            CornerButton(symbol: "rectangle.center.inset.filled", help: "Add background", action: actions.background)
                            CornerButton(symbol: "pencil.tip.crop.circle", help: "Annotate", action: actions.annotate)
                        }
                        Spacer()
                        CornerButton(symbol: "arrow.up.forward.app", help: "Open", action: actions.open)
                    }
                }
                .padding(8)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { item.isHovering = $0 }
        .onTapGesture(count: 2, perform: item.isRecording ? actions.open : actions.annotate)
        .onDrag {
            guard let url = item.fileURL() else { return NSItemProvider() }
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
    }
}

private struct PillButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.black)
                .frame(minWidth: 96)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(Color.white.opacity(0.92), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct CornerButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(0.92), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
