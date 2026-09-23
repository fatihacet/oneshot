import AppKit
import OneShotCore
import SwiftUI

/// Opens annotation editor windows, one per screenshot.
@MainActor
final class AnnotationEditorWindowController: NSObject, NSWindowDelegate {
    static let shared = AnnotationEditorWindowController()
    private var windows: Set<NSWindow> = []

    func open(_ capture: Capture) {
        let model = AnnotationEditorModel(capture: capture)
        let window = NSWindow(contentViewController: NSHostingController(rootView: AnnotationEditorView(model: model)))
        window.title = "Annotate"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(Self.initialSize(for: capture.pointSize))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        windows.insert(window)
        model.close = { [weak window] in window?.close() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func openClipboardImage() {
        guard let capture = Capture.fromClipboard() else {
            Toast.show("No image on the clipboard", symbol: "doc.on.clipboard")
            return
        }
        open(capture)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows.remove(window)
    }

    private static func initialSize(for imageSize: CGSize) -> CGSize {
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let chrome = CGSize(width: 48, height: 150)
        let maxSize = CGSize(width: visible.width * 0.85, height: visible.height * 0.85)
        let fit = min(1, (maxSize.width - chrome.width) / imageSize.width, (maxSize.height - chrome.height) / imageSize.height)
        return CGSize(
            width: max(760, imageSize.width * fit + chrome.width),
            height: max(480, imageSize.height * fit + chrome.height)
        )
    }
}

struct AnnotationEditorView: View {
    @ObservedObject var model: AnnotationEditorModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            AnnotationCanvas(model: model)
                .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            actionBar
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(AnnotationTool.allCases) { tool in
                    Button { model.tool = tool } label: {
                        Image(systemName: tool.symbol)
                            .frame(width: 28, height: 24)
                            .background(model.tool == tool ? Color.accentColor.opacity(0.25) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("\(tool.title) (\(String(tool.key).uppercased()))")
                }
            }

            Divider().frame(height: 22)

            HStack(spacing: 5) {
                ForEach(AnnotationEditorModel.palette, id: \.self) { color in
                    Button { model.color = color } label: {
                        Circle()
                            .fill(Color(cgColor: color.cgColor))
                            .frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1))
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: model.color == color ? 2.5 : 0).padding(-3))
                    }
                    .buttonStyle(.plain)
                }
                ColorPicker("Color", selection: Binding(
                    get: { Color(cgColor: model.color.cgColor) },
                    set: { if let rgba = RGBAColor(color: $0) { model.color = rgba } }
                ))
                .labelsHidden()
            }

            Picker("Width", selection: $model.lineWidth) {
                ForEach(AnnotationEditorModel.lineWidths, id: \.width) { Text($0.title).tag($0.width) }
            }
            .labelsHidden()
            .frame(width: 96)

            Toggle(isOn: $model.fillsShapes) {
                Image(systemName: "square.fill")
            }
            .toggleStyle(.button)
            .help("Fill rectangles and ellipses")
            .disabled(model.tool != .rectangle && model.tool != .ellipse)

            Spacer()

            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
                .help("Undo (⌘Z)")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
                .help("Redo (⇧⌘Z)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var actionBar: some View {
        HStack {
            if model.document.crop != nil {
                Button("Reset Crop") { model.setCrop(nil) }
            }
            if model.selectedID != nil {
                Button("Delete", role: .destructive) { model.deleteSelected() }
            }
            Spacer()
            Button("Background…") { model.openBackgroundTool() }
            Button("Pin") { model.pin() }
            if UploadSettings.isConfigured {
                Button("Upload") { model.upload() }
            }
            Button("Save") { model.save() }
                .keyboardShortcut("s", modifiers: .command)
            Button("Copy") { model.copy() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Done") {
                model.copy()
                model.close()
            }
            .keyboardShortcut(.defaultAction)
            .help("Copy the result and close")
        }
        .padding(12)
    }
}

private struct AnnotationCanvas: NSViewRepresentable {
    let model: AnnotationEditorModel

    func makeNSView(context: Context) -> AnnotationCanvasView {
        let view = AnnotationCanvasView(model: model)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: AnnotationCanvasView, context: Context) {
        view.needsDisplay = true
        view.window?.invalidateCursorRects(for: view)
    }
}
