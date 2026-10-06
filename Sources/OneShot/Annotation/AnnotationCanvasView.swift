import AppKit
import Combine
import OneShotCore

/// Draws the screenshot with its annotations and turns mouse input into annotations.
final class AnnotationCanvasView: NSView, NSTextFieldDelegate {
    private let model: AnnotationEditorModel
    private var observation: AnyCancellable?

    /// The annotation being drawn right now, not yet in the document.
    private var draft: Annotation?
    private var draftCrop: CGRect?
    private var dragStart: CGPoint?
    private var dragLast: CGPoint?
    /// The existing annotation being moved or reshaped, and its edited copy shown until mouse up.
    private var activeGrab: Grab?
    private var pendingEdit: Annotation?
    private var textField: NSTextField?
    private var editingTextOrigin: CGPoint?
    private var editingTextID: UUID?

    init(model: AnnotationEditorModel) {
        self.model = model
        super.init(frame: .zero)
        observation = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.needsDisplay = true }
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    /// Screen points per image point.
    private var zoom: CGFloat {
        let size = model.pointSize
        guard size.width > 0, size.height > 0 else { return 1 }
        let available = bounds.insetBy(dx: 24, dy: 24)
        return min(available.width / size.width, available.height / size.height, 2)
    }

    /// Where the image is drawn, in view coordinates.
    private var imageFrame: CGRect {
        let size = CGSize(width: model.pointSize.width * zoom, height: model.pointSize.height * zoom)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        imagePoint(at: convert(event.locationInWindow, from: nil))
    }

    private func imagePoint(at point: CGPoint) -> CGPoint {
        let frame = imageFrame
        return CGPoint(x: (point.x - frame.minX) / zoom, y: (point.y - frame.minY) / zoom)
    }

    private func viewPoint(_ point: CGPoint) -> CGPoint {
        let frame = imageFrame
        return CGPoint(x: frame.minX + point.x * zoom, y: frame.minY + point.y * zoom)
    }

    private var imageBounds: CGRect { CGRect(origin: .zero, size: model.pointSize) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let frame = imageFrame

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 12, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(frame)
        context.restoreGState()

        context.saveGState()
        context.translateBy(x: frame.minX, y: frame.minY)
        context.scaleBy(x: zoom, y: zoom)
        context.clip(to: imageBounds)
        context.interpolationQuality = .high
        context.draw(model.capture.image, in: imageBounds)

        var document = model.document
        if let pendingEdit, let index = document.annotations.firstIndex(where: { $0.id == pendingEdit.id }) {
            document.annotations[index] = pendingEdit
        }
        if let draft { document.annotations.append(draft) }
        let needsPixelation = document.annotations.contains { if case .pixelate = $0.shape { return true } else { return false } }
        AnnotationRenderer.draw(
            document, in: context, imageRect: imageBounds,
            pixelated: needsPixelation ? model.pixelatedImage : nil
        )

        drawCropOverlay(in: context)
        context.restoreGState()
        drawSelection(in: context)
    }

    /// Outlines the selection, or shows its grips when it can be reshaped. Drawn in view points, outside the image clip.
    private func drawSelection(in context: CGContext) {
        guard let selected = pendingEdit ?? model.selectedAnnotation else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(1.5)
        let handles = selected.handles
        guard !handles.isEmpty else {
            let bounds = selected.bounds
            context.setLineDash(phase: 0, lengths: [5, 3])
            context.stroke(CGRect(origin: viewPoint(bounds.origin), size: CGSize(width: bounds.width * zoom, height: bounds.height * zoom)))
            return
        }
        context.setFillColor(NSColor.white.cgColor)
        context.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 1.5, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        for (_, position) in handles {
            let center = viewPoint(position)
            let radius = Self.handleRadius
            context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
        context.drawPath(using: .fillStroke)
    }

    private func drawCropOverlay(in context: CGContext) {
        guard let crop = (draftCrop ?? model.document.crop)?.standardized else { return }
        context.saveGState()
        let path = CGMutablePath()
        path.addRect(imageBounds)
        path.addRect(crop)
        context.addPath(path)
        context.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        context.fillPath(using: .evenOdd)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.5 / zoom)
        context.setLineDash(phase: 0, lengths: [6 / zoom, 4 / zoom])
        context.stroke(crop)
        context.restoreGState()
    }

    // MARK: Mouse

    /// What a press on an existing annotation picks up.
    private enum Grab {
        case move(Annotation)
        case reshape(Annotation, Annotation.Handle)

        var annotation: Annotation {
            switch self {
            case .move(let annotation), .reshape(let annotation, _): return annotation
            }
        }
    }

    /// Radius of a selection grip, in view points.
    private static let handleRadius: CGFloat = 4.5

    /// What a press at `point` (image points) would pick up: a grip of the selection, or an annotation
    /// to move. Every tool but Text and Crop can grab; only Select also grabs hollow shapes by their inside,
    /// so drawing tools can still start a new shape there.
    private func grab(at point: CGPoint) -> Grab? {
        guard model.tool != .text, model.tool != .crop else { return nil }
        if let selected = model.selectedAnnotation {
            let reach = (Self.handleRadius + 3) / zoom
            let nearest = selected.handles
                .map { (handle: $0.handle, distance: hypot($0.position.x - point.x, $0.position.y - point.y)) }
                .filter { $0.distance <= reach }
                .min { $0.distance < $1.distance }
            if let nearest { return .reshape(selected, nearest.handle) }
        }
        return model.document.annotation(at: point, tolerance: 6 / zoom, interiors: model.tool == .select).map(Grab.move)
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor()
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor()
    }

    private func updateCursor() {
        guard let window, activeGrab == nil else { return }
        let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(location), textField?.frame.contains(location) != true else { return }
        cursor(at: imagePoint(at: location)).set()
    }

    private func cursor(at point: CGPoint) -> NSCursor {
        switch grab(at: point) {
        case .move: return .openHand
        case .reshape(_, let handle): return Self.cursor(for: handle)
        case nil: break
        }
        switch model.tool {
        case .select: return .arrow
        case .text: return imageBounds.contains(point) ? .iBeam : .arrow
        default: return imageBounds.contains(point) ? .crosshair : .arrow
        }
    }

    private static func cursor(for handle: Annotation.Handle) -> NSCursor {
        guard case .frame(let x, let y) = handle else { return .crosshair }
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition
            switch (x, y) {
            case (-1, 1): position = .topLeft
            case (0, 1): position = .top
            case (1, 1): position = .topRight
            case (-1, 0): position = .left
            case (1, 0): position = .right
            case (-1, -1): position = .bottomLeft
            case (0, -1): position = .bottom
            default: position = .bottomRight
            }
            return .frameResize(position: position, directions: .all)
        }
        if y == 0 { return .resizeLeftRight }
        if x == 0 { return .resizeUpDown }
        return .crosshair
    }

    override func mouseDown(with event: NSEvent) {
        commitTextEditing()
        window?.makeFirstResponder(self)
        let point = imagePoint(event)
        dragStart = point
        dragLast = point

        if let grab = grab(at: point) {
            let hit = grab.annotation
            model.selectedID = hit.id
            model.color = hit.color
            model.lineWidth = hit.lineWidth
            if event.clickCount == 2, case .text(let origin, let string, let fontSize) = hit.shape {
                beginTextEditing(at: origin, text: string, fontSize: fontSize, replacing: hit.id)
            } else {
                activeGrab = grab
                if case .move = grab { NSCursor.closedHand.set() }
            }
            needsDisplay = true
            return
        }
        model.selectedID = nil

        switch model.tool {
        case .text:
            if let hit = model.document.annotation(at: point, tolerance: 4 / zoom),
               case .text(let origin, let string, let fontSize) = hit.shape {
                beginTextEditing(at: origin, text: string, fontSize: fontSize, replacing: hit.id)
            } else {
                beginTextEditing(at: point, text: "", fontSize: fontSize, replacing: nil)
            }
        case .counter:
            model.add(Annotation(
                shape: .counter(center: point, number: model.document.nextCounterNumber),
                color: model.color, lineWidth: model.lineWidth
            ))
        case .pen:
            draft = Annotation(shape: .pen(points: [point]), color: model.color, lineWidth: model.lineWidth)
        case .highlighter:
            draft = Annotation(shape: .highlighter(points: [point]), color: model.color, lineWidth: model.lineWidth)
        default:
            break
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        var point = imagePoint(event)
        let shift = event.modifierFlags.contains(.shift)

        if let activeGrab {
            switch activeGrab {
            case .move(let original):
                var offset = CGVector(dx: point.x - start.x, dy: point.y - start.y)
                // Shift keeps the move horizontal or vertical.
                if shift {
                    if abs(offset.dx) > abs(offset.dy) { offset.dy = 0 } else { offset.dx = 0 }
                }
                pendingEdit = original.offset(by: offset)
            case .reshape(let original, let handle):
                pendingEdit = original.reshaped(dragging: handle, to: point, constrained: shift)
            }
            dragLast = point
            needsDisplay = true
            return
        }

        switch model.tool {
        case .arrow, .line:
            if shift { point = point.snappedTo45Degrees(from: start) }
            let shape: Annotation.Shape = model.tool == .arrow ? .arrow(start: start, end: point) : .line(start: start, end: point)
            draft = Annotation(id: draft?.id ?? UUID(), shape: shape, color: model.color, lineWidth: model.lineWidth)
        case .rectangle, .ellipse, .pixelate:
            let rect = CGRect(from: start, to: point, square: shift)
            let shape: Annotation.Shape
            switch model.tool {
            case .rectangle: shape = .rectangle(rect, filled: model.fillsShapes)
            case .ellipse: shape = .ellipse(rect, filled: model.fillsShapes)
            default: shape = .pixelate(rect)
            }
            draft = Annotation(id: draft?.id ?? UUID(), shape: shape, color: model.color, lineWidth: model.lineWidth)
        case .pen, .highlighter:
            guard var current = draft else { return }
            switch current.shape {
            case .pen(let points): current.shape = .pen(points: points + [point])
            case .highlighter(let points):
                // Highlighter strokes stay straight and horizontal with Shift.
                let next = shift ? CGPoint(x: point.x, y: points[0].y) : point
                current.shape = .highlighter(points: shift ? [points[0], next] : points + [next])
            default: break
            }
            draft = current
        case .crop:
            draftCrop = CGRect(from: start, to: point, square: shift).intersection(imageBounds)
        case .select, .text, .counter:
            break
        }
        dragLast = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            dragLast = nil
            activeGrab = nil
            pendingEdit = nil
            draft = nil
            draftCrop = nil
            needsDisplay = true
            updateCursor()
        }
        if activeGrab != nil {
            // A grip dragged until the shape collapses snaps back instead.
            if let pendingEdit, Self.isMeaningful(pendingEdit) { model.replace(pendingEdit) }
            return
        }
        if model.tool == .crop {
            if let crop = draftCrop, crop.width > 4, crop.height > 4 { model.setCrop(crop) }
            return
        }
        guard let draft, Self.isMeaningful(draft) else { return }
        model.add(draft)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command, event.charactersIgnoringModifiers == "z" { model.undo(); return }
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z" { model.redo(); return }

        switch Int(event.keyCode) {
        case 51, 117: // Delete, Forward Delete
            model.deleteSelected()
            return
        case 53: // Escape
            model.selectedID = nil
            draft = nil
            needsDisplay = true
            return
        case 36 where model.tool == .crop: // Return confirms the crop and switches back
            model.tool = .select
            return
        default:
            break
        }
        if flags.isEmpty, let character = event.charactersIgnoringModifiers?.lowercased().first,
           let tool = AnnotationTool.allCases.first(where: { $0.key == character }) {
            model.tool = tool
            updateCursor()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command, event.charactersIgnoringModifiers == "z" { model.undo(); return true }
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "z" { model.redo(); return true }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Text

    private var fontSize: Double { max(14, model.lineWidth * 5) }

    private func beginTextEditing(at origin: CGPoint, text: String, fontSize: Double, replacing id: UUID?) {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.boldSystemFont(ofSize: fontSize * zoom)
        field.textColor = NSColor(cgColor: model.color.cgColor)
        field.delegate = self
        field.placeholderString = "Text"
        let position = viewPoint(origin)
        field.frame = CGRect(x: position.x - 2, y: position.y - 2, width: max(160, (field.intrinsicContentSize.width + 40)), height: fontSize * zoom * 1.4)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        editingTextOrigin = origin
        editingTextID = id
        if let id {
            // Hide the original while it is being edited.
            draft = nil
            model.selectedID = nil
            model.update { $0.annotations.removeAll { $0.id == id } }
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        commitTextEditing()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = textField else { return }
        field.frame.size.width = max(160, field.intrinsicContentSize.width + 40)
    }

    private func commitTextEditing() {
        guard let field = textField, let origin = editingTextOrigin else { return }
        textField = nil
        editingTextOrigin = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        if !text.isEmpty {
            model.add(Annotation(
                id: editingTextID ?? UUID(),
                shape: .text(origin: origin, string: text, fontSize: fontSize),
                color: model.color, lineWidth: model.lineWidth
            ))
        }
        editingTextID = nil
        window?.makeFirstResponder(self)
    }

    // MARK: Helpers

    private static func isMeaningful(_ annotation: Annotation) -> Bool {
        switch annotation.shape {
        case .arrow(let start, let end), .line(let start, let end):
            return hypot(end.x - start.x, end.y - start.y) > 4
        case .rectangle(let rect, _), .ellipse(let rect, _), .pixelate(let rect):
            return rect.width > 3 && rect.height > 3
        case .pen, .highlighter, .text, .counter:
            return true
        }
    }
}
