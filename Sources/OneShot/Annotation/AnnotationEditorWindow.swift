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
        window.contentMinSize = AnnotationEditorView.minimumSize
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
        let minimum = AnnotationEditorView.minimumSize
        return CGSize(
            width: max(minimum.width, imageSize.width * fit + chrome.width),
            height: max(minimum.height, imageSize.height * fit + chrome.height)
        )
    }
}

struct AnnotationEditorView: View {
    @ObservedObject var model: AnnotationEditorModel

    /// Wide enough for the whole toolbar.
    static let minimumSize = CGSize(width: 920, height: 480)

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            AnnotationCanvas(model: model)
                .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            actionBar
        }
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
    }

    private var toolbar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(AnnotationTool.allCases) { tool in
                    let selected = model.tool == tool
                    Button { model.tool = tool } label: {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 14))
                            .foregroundStyle(selected ? Color.accentColor : Color.primary)
                            .frame(width: 30, height: 26)
                            .background(selected ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(tool.title) (\(String(tool.key).uppercased()))")
                }
            }

            toolbarDivider

            HStack(spacing: 4) {
                ForEach(AnnotationEditorModel.palette, id: \.color) { swatch in
                    Button { model.color = swatch.color } label: {
                        colorSwatch(Circle().fill(Color(cgColor: swatch.color.cgColor)), selected: model.color == swatch.color)
                    }
                    .buttonStyle(.plain)
                    .help(swatch.name)
                }
                Button {
                    ColorPanelTarget.shared.show(model.color) { [weak model] in model?.color = $0 }
                } label: {
                    colorSwatch(Circle().fill(AngularGradient(colors: Self.spectrum, center: .center)), selected: !isPaletteColor)
                }
                .buttonStyle(.plain)
                .help("Custom color…")
            }

            toolbarDivider

            HStack(spacing: 8) {
                Picker("Line width", selection: $model.lineWidth) {
                    ForEach(AnnotationEditorModel.lineWidths, id: \.width) { Text($0.title).tag($0.width) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Line width")

                Toggle(isOn: $model.fillsShapes) {
                    Image(systemName: "square.fill")
                }
                .toggleStyle(.button)
                .help("Fill rectangles and ellipses")
                .disabled(model.tool != .rectangle && model.tool != .ellipse)
            }

            Spacer(minLength: 16)

            HStack(spacing: 6) {
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!model.canUndo)
                    .help("Undo (⌘Z)")
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!model.canRedo)
                    .help("Redo (⇧⌘Z)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var toolbarDivider: some View {
        Divider().frame(height: 22).padding(.horizontal, 14)
    }

    private static let spectrum: [Color] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red]

    private var isPaletteColor: Bool {
        AnnotationEditorModel.palette.contains { $0.color == model.color }
    }

    /// A round color button: the fill, a hairline so white reads on light backgrounds, and a ring when selected.
    private func colorSwatch(_ fill: some View, selected: Bool) -> some View {
        fill
            .frame(width: 18, height: 18)
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
            .padding(3)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0))
            .contentShape(Circle())
    }

    private var actionBar: some View {
        HStack {
            if model.document.crop != nil {
                Button("Reset Crop") { model.setCrop(nil) }
                    .help("Show the whole screenshot again")
            }
            if model.selectedID != nil {
                Button("Delete", role: .destructive) { model.deleteSelected() }
                    .help("Delete the selected annotation (⌫)")
            }
            Spacer()
            Button("Background…") { model.openBackgroundTool() }
                .help("Place the result on a background")
            Button("Pin") { model.pin() }
                .help("Pin the result above other windows")
            if UploadSettings.isConfigured {
                Button("Upload") { model.upload() }
                    .help("Upload the result")
            }
            Button("Save") { model.save() }
                .keyboardShortcut("s", modifiers: .command)
                .help("Save the result (⌘S)")
            Button("Copy") { model.copy() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help("Copy the result (⇧⌘C)")
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
    }
}

/// Routes the shared color panel to whichever editor opened it last.
@MainActor
private final class ColorPanelTarget: NSObject {
    static let shared = ColorPanelTarget()
    private var onChange: ((RGBAColor) -> Void)?

    func show(_ color: RGBAColor, onChange: @escaping (RGBAColor) -> Void) {
        let panel = NSColorPanel.shared
        // Detach first so setting the starting color doesn't report back to the previous editor.
        panel.setTarget(nil)
        panel.showsAlpha = false
        panel.color = NSColor(cgColor: color.cgColor) ?? .red
        self.onChange = onChange
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ panel: NSColorPanel) {
        guard let cgColor = panel.color.usingColorSpace(.sRGB)?.cgColor, let color = RGBAColor(cgColor: cgColor) else { return }
        onChange?(color)
    }
}
