import AppKit
import OneShotCore

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select
    case arrow
    case line
    case rectangle
    case ellipse
    case pen
    case highlighter
    case text
    case counter
    case pixelate
    case crop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Select"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .text: return "Text"
        case .counter: return "Counter"
        case .pixelate: return "Pixelate"
        case .crop: return "Crop"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .pixelate: return "mosaic"
        case .crop: return "crop"
        }
    }

    /// Single-key shortcut used while the canvas has focus.
    var key: Character {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .line: return "l"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .pen: return "p"
        case .highlighter: return "h"
        case .text: return "t"
        case .counter: return "n"
        case .pixelate: return "x"
        case .crop: return "c"
        }
    }
}

/// State of one annotation editor: the document, the current tool and style, and undo history.
@MainActor
final class AnnotationEditorModel: ObservableObject {
    let capture: Capture
    let pointSize: CGSize

    @Published private(set) var document = AnnotationDocument()
    @Published var tool = AnnotationTool.arrow {
        didSet { if tool != .select { selectedID = nil } }
    }
    @Published var color = AnnotationEditorModel.palette[0] {
        didSet { restyleSelection() }
    }
    @Published var lineWidth: Double = 4 {
        didSet { restyleSelection() }
    }
    @Published var fillsShapes = false
    @Published var selectedID: UUID?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    var close: () -> Void = {}

    static let palette: [RGBAColor] = [
        RGBAColor(hex: 0xFF3B30), RGBAColor(hex: 0xFF9500), RGBAColor(hex: 0xFFCC00), RGBAColor(hex: 0x34C759),
        RGBAColor(hex: 0x007AFF), RGBAColor(hex: 0xAF52DE), RGBAColor(hex: 0x000000), RGBAColor(hex: 0xFFFFFF),
    ]
    static let lineWidths: [(title: String, width: Double)] = [("Thin", 2), ("Medium", 4), ("Thick", 8)]

    private var undoStack: [AnnotationDocument] = []
    private var redoStack: [AnnotationDocument] = []
    private var cachedPixelated: CGImage??

    init(capture: Capture) {
        self.capture = capture
        self.pointSize = capture.pointSize
    }

    /// A pixelated copy of the screenshot, computed once when first needed.
    var pixelatedImage: CGImage? {
        if let cachedPixelated { return cachedPixelated }
        let image = AnnotationRenderer.pixelate(capture.image, scale: capture.scale)
        cachedPixelated = .some(image)
        return image
    }

    var selectedAnnotation: Annotation? {
        document.annotations.first { $0.id == selectedID }
    }

    // MARK: Editing

    /// Applies a change as one undoable step.
    func update(_ change: (inout AnnotationDocument) -> Void) {
        var next = document
        change(&next)
        guard next != document else { return }
        undoStack.append(document)
        redoStack.removeAll()
        document = next
        refreshUndoState()
    }

    func add(_ annotation: Annotation) {
        update { $0.annotations.append(annotation) }
    }

    func replace(_ annotation: Annotation) {
        update { document in
            guard let index = document.annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
            document.annotations[index] = annotation
        }
    }

    func deleteSelected() {
        guard let selectedID else { return }
        update { $0.annotations.removeAll { $0.id == selectedID } }
        self.selectedID = nil
    }

    func setCrop(_ rect: CGRect?) {
        update { $0.crop = rect }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document)
        document = previous
        selectedID = nil
        refreshUndoState()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document)
        document = next
        selectedID = nil
        refreshUndoState()
    }

    private func refreshUndoState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    /// Changing color or width while something is selected restyles it.
    private func restyleSelection() {
        guard var annotation = selectedAnnotation else { return }
        guard annotation.color != color || annotation.lineWidth != lineWidth else { return }
        annotation.color = color
        annotation.lineWidth = lineWidth
        replace(annotation)
    }

    // MARK: Output

    func renderedCapture() -> Capture? {
        guard let image = AnnotationRenderer.render(image: capture.image, scale: capture.scale, document: document) else {
            return nil
        }
        return Capture(
            image: image, scale: capture.scale, sourceRect: nil,
            appName: capture.appName, windowTitle: capture.windowTitle
        )
    }

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

    func openBackgroundTool() {
        guard let result = renderedCapture() else { return }
        BackgroundToolWindowController.shared.open(result)
    }
}
