import CoreGraphics
import Foundation

/// A single markup element. Geometry is in image points (pixels / scale) with a bottom-left origin.
public struct Annotation: Identifiable, Codable, Equatable, Sendable {
    public enum Shape: Codable, Equatable, Sendable {
        case arrow(start: CGPoint, end: CGPoint)
        case line(start: CGPoint, end: CGPoint)
        case rectangle(CGRect, filled: Bool)
        case ellipse(CGRect, filled: Bool)
        case pen(points: [CGPoint])
        case highlighter(points: [CGPoint])
        case text(origin: CGPoint, string: String, fontSize: Double)
        case counter(center: CGPoint, number: Int)
        /// Hides sensitive content by pixelating the underlying screenshot.
        case pixelate(CGRect)
    }

    /// A grip on a selected annotation that reshapes it when dragged.
    public enum Handle: Hashable, Sendable {
        /// An arrow or line endpoint.
        case start, end
        /// A grip on a rectangle's frame; `x` and `y` are each -1 (min edge), 0 (middle) or 1 (max edge).
        case frame(x: Int, y: Int)
    }

    public var id: UUID
    public var shape: Shape
    public var color: RGBAColor
    public var lineWidth: Double

    public init(id: UUID = UUID(), shape: Shape, color: RGBAColor, lineWidth: Double) {
        self.id = id
        self.shape = shape
        self.color = color
        self.lineWidth = lineWidth
    }

    /// Size of the numbered circle for a counter.
    public static func counterRadius(lineWidth: Double) -> Double { max(12, lineWidth * 3.5) }

    /// Bounding box in image points, including stroke and decorations.
    public var bounds: CGRect {
        let pad = lineWidth * 2 + 4
        switch shape {
        case .arrow(let start, let end), .line(let start, let end):
            return CGRect(points: [start, end]).insetBy(dx: -pad * 2, dy: -pad * 2)
        case .rectangle(let rect, _), .ellipse(let rect, _), .pixelate(let rect):
            return rect.standardized.insetBy(dx: -pad, dy: -pad)
        case .pen(let points):
            return CGRect(points: points).insetBy(dx: -pad, dy: -pad)
        case .highlighter(let points):
            return CGRect(points: points).insetBy(dx: -pad * 3, dy: -pad * 3)
        case .text(let origin, let string, let fontSize):
            let size = AnnotationRenderer.textSize(string, fontSize: fontSize)
            return CGRect(origin: origin, size: size).insetBy(dx: -4, dy: -4)
        case .counter(let center, _):
            let radius = Self.counterRadius(lineWidth: lineWidth)
            return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        }
    }

    /// Whether `point` (image points) touches this annotation, with `tolerance` in points.
    public func contains(_ point: CGPoint, tolerance: Double = 6) -> Bool {
        let slack = tolerance + lineWidth / 2
        switch shape {
        case .arrow(let start, let end), .line(let start, let end):
            return point.distance(toSegment: start, end) <= slack
        case .rectangle(let rect, let filled), .ellipse(let rect, let filled):
            let rect = rect.standardized
            if filled { return rect.insetBy(dx: -slack, dy: -slack).contains(point) }
            // Hollow shapes are hit near their outline.
            return rect.insetBy(dx: -slack, dy: -slack).contains(point) && !rect.insetBy(dx: slack, dy: slack).contains(point)
        case .pen(let points), .highlighter(let points):
            let extra = { if case .highlighter = shape { return lineWidth * 2 } else { return 0.0 } }()
            return zip(points, points.dropFirst()).contains { point.distance(toSegment: $0, $1) <= slack + extra }
                || (points.count == 1 && point.distance(to: points[0]) <= slack + extra)
        case .text, .counter, .pixelate:
            return bounds.contains(point)
        }
    }

    /// Whether `point` lies inside a rectangle or ellipse, hollow or not.
    public func encloses(_ point: CGPoint) -> Bool {
        switch shape {
        case .rectangle(let rect, _): return rect.standardized.contains(point)
        case .ellipse(let rect, _): return CGPath(ellipseIn: rect.standardized, transform: nil).contains(point)
        default: return false
        }
    }

    /// Grips for reshaping, with their positions in image points. Freehand strokes, text and counters only move.
    public var handles: [(handle: Handle, position: CGPoint)] {
        switch shape {
        case .arrow(let start, let end), .line(let start, let end):
            return [(.start, start), (.end, end)]
        case .rectangle(let rect, _), .ellipse(let rect, _), .pixelate(let rect):
            let rect = rect.standardized
            return [-1, 0, 1].flatMap { x in
                [-1, 0, 1].filter { y in x != 0 || y != 0 }.map { y in
                    (.frame(x: x, y: y), CGPoint(x: rect.midX + CGFloat(x) * rect.width / 2, y: rect.midY + CGFloat(y) * rect.height / 2))
                }
            }
        case .pen, .highlighter, .text, .counter:
            return []
        }
    }

    /// Returns a copy with `handle` dragged to `point`. With `constrained` (Shift), lines snap to 45°
    /// and corner drags keep rectangles square, as they do while drawing.
    public func reshaped(dragging handle: Handle, to point: CGPoint, constrained: Bool = false) -> Annotation {
        var copy = self
        switch shape {
        case .arrow(var start, var end), .line(var start, var end):
            switch handle {
            case .start: start = constrained ? point.snappedTo45Degrees(from: end) : point
            case .end: end = constrained ? point.snappedTo45Degrees(from: start) : point
            case .frame: break
            }
            if case .arrow = shape { copy.shape = .arrow(start: start, end: end) } else { copy.shape = .line(start: start, end: end) }
        case .rectangle(let rect, let filled):
            copy.shape = .rectangle(rect.reshaped(dragging: handle, to: point, square: constrained), filled: filled)
        case .ellipse(let rect, let filled):
            copy.shape = .ellipse(rect.reshaped(dragging: handle, to: point, square: constrained), filled: filled)
        case .pixelate(let rect):
            copy.shape = .pixelate(rect.reshaped(dragging: handle, to: point, square: constrained))
        case .pen, .highlighter, .text, .counter:
            break
        }
        return copy
    }

    /// Returns a copy moved by `offset`.
    public func offset(by offset: CGVector) -> Annotation {
        func move(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + offset.dx, y: point.y + offset.dy) }
        var copy = self
        switch shape {
        case .arrow(let start, let end): copy.shape = .arrow(start: move(start), end: move(end))
        case .line(let start, let end): copy.shape = .line(start: move(start), end: move(end))
        case .rectangle(let rect, let filled): copy.shape = .rectangle(rect.offsetBy(dx: offset.dx, dy: offset.dy), filled: filled)
        case .ellipse(let rect, let filled): copy.shape = .ellipse(rect.offsetBy(dx: offset.dx, dy: offset.dy), filled: filled)
        case .pen(let points): copy.shape = .pen(points: points.map(move))
        case .highlighter(let points): copy.shape = .highlighter(points: points.map(move))
        case .text(let origin, let string, let fontSize): copy.shape = .text(origin: move(origin), string: string, fontSize: fontSize)
        case .counter(let center, let number): copy.shape = .counter(center: move(center), number: number)
        case .pixelate(let rect): copy.shape = .pixelate(rect.offsetBy(dx: offset.dx, dy: offset.dy))
        }
        return copy
    }
}

/// All markup for one screenshot.
public struct AnnotationDocument: Codable, Equatable, Sendable {
    public var annotations: [Annotation]
    /// Crop rectangle in image points; nil keeps the whole image.
    public var crop: CGRect?

    public init(annotations: [Annotation] = [], crop: CGRect? = nil) {
        self.annotations = annotations
        self.crop = crop
    }

    public var isEmpty: Bool { annotations.isEmpty && crop == nil }

    /// The number the next counter should show.
    public var nextCounterNumber: Int {
        let numbers = annotations.compactMap { annotation -> Int? in
            if case .counter(_, let number) = annotation.shape { return number }
            return nil
        }
        return (numbers.max() ?? 0) + 1
    }

    /// Topmost annotation at `point`. With `interiors`, a press inside a hollow rectangle or ellipse
    /// picks it up too when nothing is hit directly, preferring the smallest such shape.
    public func annotation(at point: CGPoint, tolerance: Double = 6, interiors: Bool = false) -> Annotation? {
        if let hit = annotations.last(where: { $0.contains(point, tolerance: tolerance) }) { return hit }
        guard interiors else { return nil }
        return annotations.filter { $0.encloses(point) }.min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }
}

extension CGRect {
    /// The rectangle spanning two drag points; with `square`, the longer side wins on both axes.
    public init(from start: CGPoint, to end: CGPoint, square: Bool) {
        var width = end.x - start.x
        var height = end.y - start.y
        if square {
            let side = Swift.max(abs(width), abs(height))
            width = width < 0 ? -side : side
            height = height < 0 ? -side : side
        }
        self = CGRect(x: start.x, y: start.y, width: width, height: height).standardized
    }

    /// This rectangle with the frame grip `handle` dragged to `point`; the opposite side stays put.
    func reshaped(dragging handle: Annotation.Handle, to point: CGPoint, square: Bool) -> CGRect {
        guard case .frame(let x, let y) = handle else { return self }
        let rect = standardized
        let anchor = CGPoint(x: rect.midX - CGFloat(x) * rect.width / 2, y: rect.midY - CGFloat(y) * rect.height / 2)
        if x == 0 { return CGRect(from: CGPoint(x: rect.minX, y: anchor.y), to: CGPoint(x: rect.maxX, y: point.y), square: false) }
        if y == 0 { return CGRect(from: CGPoint(x: anchor.x, y: rect.minY), to: CGPoint(x: point.x, y: rect.maxY), square: false) }
        return CGRect(from: anchor, to: point, square: square)
    }

    init(points: [CGPoint]) {
        guard let first = points.first else {
            self = .zero
            return
        }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points {
            minX = Swift.min(minX, point.x)
            maxX = Swift.max(maxX, point.x)
            minY = Swift.min(minY, point.y)
            maxY = Swift.max(maxY, point.y)
        }
        self.init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

extension CGPoint {
    /// This point moved onto the nearest multiple of 45° around `origin`, keeping its distance.
    public func snappedTo45Degrees(from origin: CGPoint) -> CGPoint {
        let dx = x - origin.x
        let dy = y - origin.y
        let length = hypot(dx, dy)
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: origin.x + cos(angle) * length, y: origin.y + sin(angle) * length)
    }

    func distance(to other: CGPoint) -> Double {
        hypot(Double(x - other.x), Double(y - other.y))
    }

    func distance(toSegment start: CGPoint, _ end: CGPoint) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(to: start) }
        let t = Swift.max(0, Swift.min(1, ((x - start.x) * dx + (y - start.y) * dy) / lengthSquared))
        return distance(to: CGPoint(x: start.x + t * dx, y: start.y + t * dy))
    }
}
