import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// Draws annotations with Core Graphics, both in the editor and for the exported image.
public enum AnnotationRenderer {
    /// Draws every annotation into `context`, whose user space must be image points (bottom-left origin).
    /// - Parameter pixelated: A pixelated copy of the screenshot, shown inside `.pixelate` shapes.
    public static func draw(
        _ document: AnnotationDocument,
        in context: CGContext,
        imageRect: CGRect,
        pixelated: CGImage?
    ) {
        // Redactions first, so other markup stays readable on top of them.
        for annotation in document.annotations {
            if case .pixelate(let rect) = annotation.shape, let pixelated {
                context.saveGState()
                context.clip(to: rect.standardized.intersection(imageRect))
                context.interpolationQuality = .none
                context.draw(pixelated, in: imageRect)
                context.restoreGState()
            }
        }
        for annotation in document.annotations {
            draw(annotation, in: context)
        }
    }

    public static func draw(_ annotation: Annotation, in context: CGContext) {
        let color = annotation.color.cgColor
        let width = CGFloat(annotation.lineWidth)
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(width)

        switch annotation.shape {
        case .arrow(let start, let end):
            drawArrow(from: start, to: end, width: width, in: context)
        case .line(let start, let end):
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
        case .rectangle(let rect, let filled):
            let rect = rect.standardized
            let radius = min(width * 1.5, rect.width / 2, rect.height / 2)
            context.addPath(CGPath(
                roundedRect: filled ? rect : rect.insetBy(dx: width / 2, dy: width / 2),
                cornerWidth: radius, cornerHeight: radius, transform: nil
            ))
            filled ? context.fillPath() : context.strokePath()
        case .ellipse(let rect, let filled):
            let rect = rect.standardized
            context.addEllipse(in: filled ? rect : rect.insetBy(dx: width / 2, dy: width / 2))
            filled ? context.fillPath() : context.strokePath()
        case .pen(let points):
            strokePolyline(points, in: context)
        case .highlighter(let points):
            context.setLineWidth(width * 4)
            context.setLineCap(.square)
            context.setBlendMode(.multiply)
            context.setStrokeColor(annotation.color.cgColor.copy(alpha: 0.45) ?? color)
            strokePolyline(points, in: context)
        case .text(let origin, let string, let fontSize):
            drawText(string, at: origin, fontSize: fontSize, color: color, in: context)
        case .counter(let center, let number):
            drawCounter(number, at: center, radius: Annotation.counterRadius(lineWidth: annotation.lineWidth), color: color, in: context)
        case .pixelate:
            break
        }
    }

    /// Renders the screenshot with its annotations and crop at full resolution.
    public static func render(image: CGImage, scale: CGFloat, document: AnnotationDocument) -> CGImage? {
        let pointSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let imageRect = CGRect(origin: .zero, size: pointSize)
        let crop = (document.crop?.standardized.intersection(imageRect)).flatMap { $0.isEmpty ? nil : $0 } ?? imageRect

        let width = Int((crop.width * scale).rounded())
        let height = Int((crop.height * scale).rounded())
        let space = (image.colorSpace?.model == .rgb ? image.colorSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -crop.minX, y: -crop.minY)
        context.interpolationQuality = .high
        context.draw(image, in: imageRect)
        let needsPixelation = document.annotations.contains { if case .pixelate = $0.shape { return true } else { return false } }
        draw(document, in: context, imageRect: imageRect, pixelated: needsPixelation ? pixelate(image, scale: scale) : nil)
        return context.makeImage()
    }

    /// A pixelated copy of `image` used for redaction.
    public static func pixelate(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(max(10, 12 * scale), forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(output, from: input.extent)
    }

    // MARK: Primitives

    private static func strokePolyline(_ points: [CGPoint], in context: CGContext) {
        guard let first = points.first else { return }
        if points.count == 1 {
            context.move(to: first)
            context.addLine(to: first)
        } else {
            context.move(to: first)
            // Smooth freehand strokes with quadratic curves through midpoints.
            for index in 1..<points.count {
                let mid = CGPoint(x: (points[index - 1].x + points[index].x) / 2, y: (points[index - 1].y + points[index].y) / 2)
                context.addQuadCurve(to: mid, control: points[index - 1])
            }
            context.addLine(to: points[points.count - 1])
        }
        context.strokePath()
    }

    private static func drawArrow(from start: CGPoint, to end: CGPoint, width: CGFloat, in context: CGContext) {
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > 0 else { return }
        let headLength = min(max(12, width * 4), length * 0.6)
        let headWidth = headLength * 0.85
        let unit = CGPoint(x: (end.x - start.x) / length, y: (end.y - start.y) / length)
        let normal = CGPoint(x: -unit.y, y: unit.x)
        let base = CGPoint(x: end.x - unit.x * headLength, y: end.y - unit.y * headLength)

        context.move(to: start)
        context.addLine(to: CGPoint(x: base.x + unit.x * 1, y: base.y + unit.y * 1))
        context.strokePath()

        context.move(to: end)
        context.addLine(to: CGPoint(x: base.x + normal.x * headWidth / 2, y: base.y + normal.y * headWidth / 2))
        context.addLine(to: CGPoint(x: base.x - normal.x * headWidth / 2, y: base.y - normal.y * headWidth / 2))
        context.closePath()
        context.fillPath()
    }

    private static func font(size: Double) -> CTFont {
        CTFontCreateUIFontForLanguage(.emphasizedSystem, CGFloat(size), nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, CGFloat(size), nil)
    }

    private static func line(_ string: String, fontSize: Double, color: CGColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size: fontSize),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    }

    /// Size of a text annotation's lines, in points.
    public static func textSize(_ string: String, fontSize: Double) -> CGSize {
        let lines = string.components(separatedBy: "\n")
        let lineHeight = fontSize * 1.25
        let width = lines.map { CTLineGetTypographicBounds(line($0, fontSize: fontSize, color: CGColor(gray: 0, alpha: 1)), nil, nil, nil) }.max() ?? 0
        return CGSize(width: width, height: lineHeight * Double(max(lines.count, 1)))
    }

    /// Draws multi-line text whose bounding box starts at `origin` (bottom-left).
    private static func drawText(_ string: String, at origin: CGPoint, fontSize: Double, color: CGColor, in context: CGContext) {
        let lines = string.components(separatedBy: "\n")
        let lineHeight = fontSize * 1.25
        let descent = fontSize * 0.25
        context.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: CGColor(gray: 0, alpha: 0.45))
        for (index, text) in lines.enumerated() {
            let baseline = origin.y + lineHeight * Double(lines.count - 1 - index) + descent
            context.textPosition = CGPoint(x: origin.x, y: baseline)
            CTLineDraw(line(text, fontSize: fontSize, color: color), context)
        }
    }

    private static func drawCounter(_ number: Int, at center: CGPoint, radius: Double, color: CGColor, in context: CGContext) {
        let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: CGColor(gray: 0, alpha: 0.4))
        context.fillEllipse(in: circle)
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(max(1.5, radius * 0.12))
        context.strokeEllipse(in: circle.insetBy(dx: radius * 0.06, dy: radius * 0.06))

        let label = line(String(number), fontSize: radius * 1.1, color: CGColor(gray: 1, alpha: 1))
        let bounds = CTLineGetBoundsWithOptions(label, .useOpticalBounds)
        context.textPosition = CGPoint(x: center.x - bounds.midX, y: center.y - bounds.midY)
        CTLineDraw(label, context)
    }
}
