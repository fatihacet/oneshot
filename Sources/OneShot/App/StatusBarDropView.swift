import AppKit

/// A transparent overlay on the menu bar button that accepts dropped files.
/// Clicks pass through to the button, which opens the menu or stops a recording.
final class StatusBarDropView: NSView {
    private weak var button: NSStatusBarButton?
    private let onDrop: @MainActor ([URL]) -> Void

    init(button: NSStatusBarButton, onDrop: @escaping @MainActor ([URL]) -> Void) {
        self.button = button
        self.onDrop = onDrop
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Clicks

    override func mouseDown(with event: NSEvent) {
        button?.performClick(nil)
    }

    override func rightMouseDown(with event: NSEvent) {
        button?.performClick(nil)
    }

    // MARK: Dragging

    private func fileURLs(from info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(from: sender).isEmpty else { return [] }
        button?.highlight(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        button?.highlight(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        button?.highlight(false)
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        MainActor.assumeIsolated { onDrop(urls) }
        return true
    }
}
