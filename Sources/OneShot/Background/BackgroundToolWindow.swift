import AppKit
import OneShotCore
import SwiftUI

/// Opens background tool windows, one per screenshot.
@MainActor
final class BackgroundToolWindowController: NSObject, NSWindowDelegate {
    static let shared = BackgroundToolWindowController()
    private var windows: Set<NSWindow> = []

    func open(_ capture: Capture) {
        let model = BackgroundEditorModel(capture: capture)
        let window = NSWindow(contentViewController: NSHostingController(rootView: BackgroundEditorView(model: model)))
        window.title = "Background"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(CGSize(width: 980, height: 640))
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
}

@MainActor
final class BackgroundEditorModel: ObservableObject {
    let capture: Capture
    @Published var style: BackgroundDesign {
        didSet {
            BackgroundPresetStore.shared.lastStyle = style
            if case .image(let path) = style.fill, path != loadedBackgroundPath { loadBackground(path) }
            schedulePreview()
        }
    }
    @Published private(set) var preview: CGImage?
    var close: () -> Void = {}

    private let previewSource: CGImage
    private let previewScale: CGFloat
    private var backgroundImage: CGImage?
    private var loadedBackgroundPath: String?
    private var previewTask: Task<Void, Never>?

    init(capture: Capture) {
        self.capture = capture
        self.style = BackgroundPresetStore.shared.lastStyle

        // Preview a downscaled copy so sliders stay responsive with 5K screenshots.
        let maxDimension: CGFloat = 1400
        let largest = CGFloat(max(capture.image.width, capture.image.height))
        let factor = min(1, maxDimension / largest)
        previewSource = factor < 1 ? (capture.image.resized(by: factor) ?? capture.image) : capture.image
        previewScale = capture.scale * factor

        if case .image(let path) = style.fill { loadBackground(path) }
        schedulePreview()
    }

    private func loadBackground(_ path: String) {
        loadedBackgroundPath = path
        backgroundImage = BackgroundRenderer.loadImage(at: path)
    }

    private func schedulePreview() {
        previewTask?.cancel()
        let source = previewSource
        let scale = previewScale
        let style = style
        let background = backgroundImage
        previewTask = Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                BackgroundRenderer.render(image: source, scale: scale, style: style, backgroundImage: background)
            }.value
            guard !Task.isCancelled else { return }
            self?.preview = image
        }
    }

    /// The full-resolution result.
    func renderedCapture() -> Capture? {
        guard let image = BackgroundRenderer.render(
            image: capture.image, scale: capture.scale, style: style, backgroundImage: backgroundImage
        ) else { return nil }
        return Capture(image: image, scale: capture.scale, sourceRect: nil, appName: capture.appName)
    }

    // MARK: Actions

    func copy() {
        guard let result = renderedCapture() else { return }
        ImageExporter.copyToClipboard(result)
        Toast.show("Copied to clipboard")
    }

    func save() {
        guard let result = renderedCapture() else { return }
        do {
            let url = try ImageExporter.save(result)
            Toast.show("Saved to \(url.deletingLastPathComponent().lastPathComponent)")
        } catch {
            Toast.show("Could not save: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
        }
    }

    func upload() {
        guard let result = renderedCapture() else { return }
        Uploader.shared.upload(result)
    }

    func pin() {
        guard let result = renderedCapture() else { return }
        PinManager.shared.pin(result)
    }

    func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            style.fill = .image(path: url.path)
        }
    }

    func useDesktopWallpaper() {
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return }
        style.fill = .image(path: url.path)
    }
}

extension Capture {
    static func fromClipboard() -> Capture? {
        guard let image = NSImage(pasteboard: .general),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = image.size.width > 0 ? CGFloat(cgImage.width) / image.size.width : 1
        return Capture(image: cgImage, scale: max(scale, 1), sourceRect: nil)
    }
}

extension CGImage {
    func resized(by factor: CGFloat) -> CGImage? {
        let width = max(1, Int(CGFloat(self.width) * factor))
        let height = max(1, Int(CGFloat(self.height) * factor))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

// MARK: - Editor UI

private enum FillKind: String, CaseIterable, Identifiable {
    case none = "None"
    case color = "Color"
    case gradient = "Gradient"
    case image = "Image"

    var id: String { rawValue }
}

struct BackgroundEditorView: View {
    @ObservedObject var model: BackgroundEditorModel
    @ObservedObject private var presets = BackgroundPresetStore.shared
    @State private var isNamingPreset = false
    @State private var presetName = ""

    var body: some View {
        HStack(spacing: 0) {
            previewArea
            Divider()
            VStack(spacing: 0) {
                controls
                Divider()
                actionBar
            }
            .frame(width: 300)
        }
        .frame(minWidth: 820, minHeight: 560)
        .alert("Save Preset", isPresented: $isNamingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") { presets.add(name: presetName, style: model.style) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var previewArea: some View {
        ZStack {
            CheckerboardView()
            if let preview = model.preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(24)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        Form {
            Section("Presets") {
                if presets.presets.isEmpty {
                    Text("Save the current look to reuse it later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(presets.presets) { preset in
                        Button(preset.name) { model.style = preset.style }
                            .buttonStyle(.link)
                            .contextMenu {
                                Button("Delete Preset", role: .destructive) { presets.remove(preset) }
                            }
                    }
                }
                Button("Save as Preset…") {
                    presetName = ""
                    isNamingPreset = true
                }
            }

            Section("Background") {
                Picker("Fill", selection: fillKind) {
                    ForEach(FillKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                fillControls
            }

            Section("Layout") {
                SliderRow(title: "Padding", value: $model.style.padding, range: 0...240)
                SliderRow(title: "Corners", value: $model.style.cornerRadius, range: 0...60)
                SliderRow(title: "Shadow", value: $model.style.shadowRadius, range: 0...80)
                SliderRow(title: "Shadow opacity", value: $model.style.shadowOpacity, range: 0...1, format: "%.2f")
                Picker("Aspect ratio", selection: aspectRatioIndex) {
                    ForEach(AspectRatio.presets.indices, id: \.self) { Text(AspectRatio.presets[$0].name).tag($0) }
                }
                LabeledContent("Alignment") {
                    AlignmentGrid(selection: $model.style.alignment)
                }
                .disabled(model.style.aspectRatio == nil)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var fillControls: some View {
        switch model.style.fill {
        case .none:
            Text("Transparent background").font(.caption).foregroundStyle(.secondary)
        case .solid(let color):
            ColorPicker("Color", selection: Binding(
                get: { Color(cgColor: color.cgColor) },
                set: { model.style.fill = .solid(RGBAColor(color: $0) ?? color) }
            ), supportsOpacity: false)
        case .gradient(let gradient):
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ForEach(GradientFill.presets, id: \.name) { preset in
                    Button { model.style.fill = .gradient(preset.fill) } label: {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(LinearGradient(
                                colors: preset.fill.colors.map { Color(cgColor: $0.cgColor) },
                                startPoint: .bottomLeading, endPoint: .topTrailing
                            ))
                            .frame(height: 28)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.accentColor, lineWidth: preset.fill.colors == gradient.colors ? 2 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(preset.name)
                }
            }
            ColorPicker("Start", selection: gradientColor(at: 0, of: gradient), supportsOpacity: false)
            ColorPicker("End", selection: gradientColor(at: gradient.colors.count - 1, of: gradient), supportsOpacity: false)
            SliderRow(title: "Angle", value: Binding(
                get: { gradient.angle },
                set: { var updated = gradient; updated.angle = $0; model.style.fill = .gradient(updated) }
            ), range: 0...360, format: "%.0f°")
        case .image(let path):
            Text((path as NSString).lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
            HStack {
                Button("Choose Image…") { model.chooseBackgroundImage() }
                Button("Desktop Wallpaper") { model.useDesktopWallpaper() }
            }
        }
    }

    private var actionBar: some View {
        HStack {
            Button("Copy") { model.copy() }
                .keyboardShortcut("c", modifiers: .command)
            Button("Save") { model.save() }
                .keyboardShortcut("s", modifiers: .command)
            if UploadSettings.isConfigured {
                Button("Upload") { model.upload() }
            }
            Button("Pin") { model.pin() }
            Spacer()
            Button("Done") { model.close() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private var fillKind: Binding<FillKind> {
        Binding(
            get: {
                switch model.style.fill {
                case .none: return .none
                case .solid: return .color
                case .gradient: return .gradient
                case .image: return .image
                }
            },
            set: { kind in
                switch kind {
                case .none: model.style.fill = .none
                case .color: model.style.fill = .solid(RGBAColor(hex: 0xF2F2F7))
                case .gradient: model.style.fill = .gradient(GradientFill.presets[0].fill)
                case .image: model.chooseBackgroundImage()
                }
            }
        )
    }

    private var aspectRatioIndex: Binding<Int> {
        Binding(
            get: { AspectRatio.presets.firstIndex { $0.ratio == model.style.aspectRatio } ?? 0 },
            set: { model.style.aspectRatio = AspectRatio.presets[$0].ratio }
        )
    }

    private func gradientColor(at index: Int, of gradient: GradientFill) -> Binding<Color> {
        Binding(
            get: { Color(cgColor: gradient.colors[max(0, index)].cgColor) },
            set: { newColor in
                var updated = gradient
                guard let rgba = RGBAColor(color: newColor), updated.colors.indices.contains(index) else { return }
                updated.colors[index] = rgba
                model.style.fill = .gradient(updated)
            }
        )
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format = "%.0f"

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range)
                Text(String(format: format, value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}

private struct AlignmentGrid: View {
    @Binding var selection: ContentAlignment

    var body: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { column in
                        let alignment = ContentAlignment.allCases[row * 3 + column]
                        Button { selection = alignment } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(selection == alignment ? Color.accentColor : Color.secondary.opacity(0.25))
                                .frame(width: 18, height: 12)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// Shows transparency behind the preview.
private struct CheckerboardView: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 10
            for row in 0...Int(size.height / cell) {
                for column in 0...Int(size.width / cell) where (row + column).isMultiple(of: 2) {
                    context.fill(
                        Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                        with: .color(.secondary.opacity(0.08))
                    )
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

extension RGBAColor {
    init?(color: Color) {
        guard let cgColor = NSColor(color).usingColorSpace(.sRGB)?.cgColor else { return nil }
        self.init(cgColor: cgColor)
    }
}
