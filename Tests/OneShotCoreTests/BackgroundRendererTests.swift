import CoreGraphics
import Foundation
import OneShotCore
import Testing

struct BackgroundRendererTests {
    private let red = RGBAColor(red: 1, green: 0, blue: 0)

    private func solidImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// RGBA of the pixel at (x, y) with a top-left origin.
    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return bytes
    }

    @Test func addsPaddingScaledToPixels() {
        let style = BackgroundStyle(fill: .solid(red), padding: 10, cornerRadius: 0, shadowRadius: 0)
        let layout = BackgroundRenderer.layout(imageSize: CGSize(width: 100, height: 50), scale: 2, style: style)
        #expect(layout.canvasSize == CGSize(width: 140, height: 90))
        #expect(layout.contentRect == CGRect(x: 20, y: 20, width: 100, height: 50))
    }

    @Test func widensCanvasForAspectRatioAndAligns() {
        var style = BackgroundStyle(fill: .solid(red), padding: 5, cornerRadius: 0, shadowRadius: 0)
        style.aspectRatio = AspectRatio(width: 2, height: 1)
        style.alignment = .leading
        let layout = BackgroundRenderer.layout(imageSize: CGSize(width: 10, height: 10), scale: 1, style: style)
        #expect(layout.canvasSize == CGSize(width: 40, height: 20))
        #expect(layout.contentRect.origin == CGPoint(x: 5, y: 5))

        style.alignment = .trailing
        #expect(BackgroundRenderer.layout(imageSize: CGSize(width: 10, height: 10), scale: 1, style: style)
            .contentRect.origin == CGPoint(x: 25, y: 5))
    }

    @Test func tallRatioAddsHeight() {
        var style = BackgroundStyle(fill: .none, padding: 0, cornerRadius: 0, shadowRadius: 0)
        style.aspectRatio = AspectRatio(width: 1, height: 1)
        style.alignment = .top
        let layout = BackgroundRenderer.layout(imageSize: CGSize(width: 40, height: 10), scale: 1, style: style)
        #expect(layout.canvasSize == CGSize(width: 40, height: 40))
        #expect(layout.contentRect.origin == CGPoint(x: 0, y: 30))
    }

    @Test func rendersBackgroundAndScreenshot() throws {
        let style = BackgroundStyle(fill: .solid(red), padding: 5, cornerRadius: 0, shadowRadius: 0)
        let result = try #require(BackgroundRenderer.render(image: solidImage(width: 10, height: 10), scale: 1, style: style))
        #expect(result.width == 20 && result.height == 20)
        #expect(pixel(result, x: 1, y: 1) == [255, 0, 0, 255])
        #expect(pixel(result, x: 10, y: 10) == [0, 0, 255, 255])
    }

    @Test func roundsScreenshotCorners() throws {
        let style = BackgroundStyle(fill: .solid(red), padding: 0, cornerRadius: 10, shadowRadius: 0)
        let result = try #require(BackgroundRenderer.render(image: solidImage(width: 40, height: 40), scale: 1, style: style))
        // The very corner is background, the center is screenshot.
        #expect(pixel(result, x: 0, y: 0) == [255, 0, 0, 255])
        #expect(pixel(result, x: 20, y: 20) == [0, 0, 255, 255])
    }
}
