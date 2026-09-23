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
