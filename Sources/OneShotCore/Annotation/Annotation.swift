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

    /// Topmost annotation at `point`.
    public func annotation(at point: CGPoint, tolerance: Double = 6) -> Annotation? {
        annotations.last { $0.contains(point, tolerance: tolerance) }
    }
}

extension CGRect {
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
