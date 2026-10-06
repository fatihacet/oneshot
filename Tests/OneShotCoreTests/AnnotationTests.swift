import CoreGraphics
import Foundation
import OneShotCore
import Testing

struct AnnotationTests {
    private let red = RGBAColor(red: 1, green: 0, blue: 0)

    private func whiteImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// A fine checkerboard that pixelation should visibly flatten.
    private func checkerboard(size: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        for y in 0..<size {
            for x in 0..<size where (x + y).isMultiple(of: 2) {
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return context.makeImage()!
    }

    /// RGBA at (x, y) with a bottom-left origin.
    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: -x, y: -y, width: image.width, height: image.height))
        return bytes
    }

    @Test func rendersShapesAtPixelScale() throws {
        let document = AnnotationDocument(annotations: [
            Annotation(shape: .rectangle(CGRect(x: 10, y: 10, width: 20, height: 20), filled: true), color: red, lineWidth: 2),
        ])
        let result = try #require(AnnotationRenderer.render(image: whiteImage(width: 100, height: 100), scale: 2, document: document))
        #expect(result.width == 100 && result.height == 100)
        #expect(pixel(result, x: 40, y: 40) == [255, 0, 0, 255])  // inside the rect (20 pt * 2)
        #expect(pixel(result, x: 90, y: 90) == [255, 255, 255, 255])
    }

    @Test func cropsToDocumentCrop() throws {
        let document = AnnotationDocument(crop: CGRect(x: 10, y: 5, width: 20, height: 15))
        let result = try #require(AnnotationRenderer.render(image: whiteImage(width: 100, height: 100), scale: 2, document: document))
        #expect(result.width == 40 && result.height == 30)
    }

    @Test func pixelatesOnlyInsideTheRegion() throws {
        let image = checkerboard(size: 64)
        let document = AnnotationDocument(annotations: [
            Annotation(shape: .pixelate(CGRect(x: 0, y: 0, width: 32, height: 64)), color: red, lineWidth: 1),
        ])
        let result = try #require(AnnotationRenderer.render(image: image, scale: 1, document: document))
        // Inside: neighbours in one block are flattened to the same color.
        #expect(pixel(result, x: 12, y: 12) == pixel(result, x: 13, y: 12))
        // Outside: the checkerboard is untouched.
        #expect(pixel(result, x: 50, y: 4) != pixel(result, x: 51, y: 4))
    }

    @Test func hitTestsOutlinesAndLines() {
        let arrow = Annotation(shape: .arrow(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0)), color: red, lineWidth: 4)
        #expect(arrow.contains(CGPoint(x: 50, y: 5)))
        #expect(!arrow.contains(CGPoint(x: 50, y: 30)))

        let box = Annotation(shape: .rectangle(CGRect(x: 0, y: 0, width: 100, height: 100), filled: false), color: red, lineWidth: 4)
        #expect(box.contains(CGPoint(x: 1, y: 50)))
        #expect(!box.contains(CGPoint(x: 50, y: 50)))

        let document = AnnotationDocument(annotations: [box, arrow])
        #expect(document.annotation(at: CGPoint(x: 50, y: 1))?.id == arrow.id)
    }

    @Test func picksUpHollowShapesByTheirInside() {
        let outer = Annotation(shape: .rectangle(CGRect(x: 0, y: 0, width: 200, height: 200), filled: false), color: red, lineWidth: 4)
        let inner = Annotation(shape: .ellipse(CGRect(x: 50, y: 50, width: 100, height: 100), filled: false), color: red, lineWidth: 4)
        // Drawn last, the outer box still yields to the smaller shape it surrounds.
        let document = AnnotationDocument(annotations: [inner, outer])
        #expect(document.annotation(at: CGPoint(x: 100, y: 100)) == nil)
        #expect(document.annotation(at: CGPoint(x: 100, y: 100), interiors: true)?.id == inner.id)
        #expect(document.annotation(at: CGPoint(x: 180, y: 180), interiors: true)?.id == outer.id)
        // The corners of the ellipse's frame are outside it.
        #expect(document.annotation(at: CGPoint(x: 62, y: 62), interiors: true)?.id == outer.id)
    }

    @Test func reshapesRectanglesByTheirGrips() {
        let box = Annotation(shape: .rectangle(CGRect(x: 10, y: 10, width: 100, height: 50), filled: false), color: red, lineWidth: 4)
        #expect(box.handles.count == 8)
        #expect(box.handles.first { $0.handle == .frame(x: 1, y: 1) }?.position == CGPoint(x: 110, y: 60))

        // A corner moves both edges it touches; the opposite corner stays put.
        let corner = box.reshaped(dragging: .frame(x: 1, y: 1), to: CGPoint(x: 150, y: 90))
        #expect(corner.shape == .rectangle(CGRect(x: 10, y: 10, width: 140, height: 80), filled: false))
        #expect(corner.id == box.id)

        // An edge only moves along its own axis.
        let edge = box.reshaped(dragging: .frame(x: -1, y: 0), to: CGPoint(x: 30, y: 500))
        #expect(edge.shape == .rectangle(CGRect(x: 30, y: 10, width: 80, height: 50), filled: false))

        // Dragging past the opposite side flips the rectangle instead of inverting it.
        let flipped = box.reshaped(dragging: .frame(x: 0, y: 1), to: CGPoint(x: 0, y: 0))
        #expect(flipped.shape == .rectangle(CGRect(x: 10, y: 0, width: 100, height: 10), filled: false))

        // Shift keeps a corner drag square.
        let square = box.reshaped(dragging: .frame(x: 1, y: 1), to: CGPoint(x: 70, y: 40), constrained: true)
        #expect(square.shape == .rectangle(CGRect(x: 10, y: 10, width: 60, height: 60), filled: false))
    }

    @Test func reshapesLinesByTheirEndpoints() {
        let arrow = Annotation(shape: .arrow(start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0)), color: red, lineWidth: 4)
        #expect(arrow.handles.map(\.handle) == [.start, .end])
        #expect(arrow.reshaped(dragging: .end, to: CGPoint(x: 40, y: 80)).shape == .arrow(start: .zero, end: CGPoint(x: 40, y: 80)))
        // Shift snaps the dragged end to 45° around the other one.
        let snapped = arrow.reshaped(dragging: .start, to: CGPoint(x: 90, y: 3), constrained: true)
        guard case .arrow(let start, let end) = snapped.shape else { Issue.record("not an arrow"); return }
        #expect(abs(start.y) < 0.001 && start.x < 90)
        #expect(end == CGPoint(x: 100, y: 0))

        let counter = Annotation(shape: .counter(center: .zero, number: 1), color: red, lineWidth: 4)
        #expect(counter.handles.isEmpty)
    }

    @Test func movesAndNumbersAnnotations() {
        let counter = Annotation(shape: .counter(center: CGPoint(x: 10, y: 10), number: 1), color: red, lineWidth: 4)
        let moved = counter.offset(by: CGVector(dx: 5, dy: -5))
        #expect(moved.shape == .counter(center: CGPoint(x: 15, y: 5), number: 1))
        #expect(AnnotationDocument(annotations: [counter, moved]).nextCounterNumber == 2)
        #expect(AnnotationDocument().nextCounterNumber == 1)
    }

    @Test func measuresMultilineText() {
        let one = AnnotationRenderer.textSize("Hello", fontSize: 20)
        let two = AnnotationRenderer.textSize("Hello\nWorld", fontSize: 20)
        #expect(one.width > 0)
        #expect(two.height == one.height * 2)
    }
}
