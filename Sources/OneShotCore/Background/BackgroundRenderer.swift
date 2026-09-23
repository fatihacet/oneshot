import CoreGraphics
import Foundation
import ImageIO

/// Renders a screenshot onto a background with padding, rounded corners and a shadow.
public enum BackgroundRenderer {
    public struct Layout: Equatable {
        public var canvasSize: CGSize
        /// Where the screenshot goes, in canvas pixels (bottom-left origin).
        public var contentRect: CGRect
    }

    /// Canvas size and screenshot placement in pixels.
    public static func layout(imageSize: CGSize, scale: CGFloat, style: BackgroundStyle) -> Layout {
        let padding = max(0, style.padding) * scale
        var width = imageSize.width + 2 * padding
        var height = imageSize.height + 2 * padding
        if let ratio = style.aspectRatio?.value, ratio > 0 {
            if width / height < ratio {
                width = height * ratio
            } else {
                height = width / ratio
            }
        }
        width = width.rounded()
        height = height.rounded()

        let factors = style.alignment.factors
        let freeX = max(0, width - 2 * padding - imageSize.width)
        let freeY = max(0, height - 2 * padding - imageSize.height)
        let origin = CGPoint(
            x: (padding + freeX * factors.x).rounded(),
            y: (padding + freeY * factors.y).rounded()
        )
        return Layout(canvasSize: CGSize(width: width, height: height), contentRect: CGRect(origin: origin, size: imageSize))
    }

    /// - Parameters:
    ///   - scale: Pixels per point of the screenshot, so padding and radii look the same on any display.
    ///   - backgroundImage: The decoded picture for `.image` fills.
    public static func render(
        image: CGImage,
        scale: CGFloat,
        style: BackgroundStyle,
        backgroundImage: CGImage? = nil
    ) -> CGImage? {
        let layout = layout(imageSize: CGSize(width: image.width, height: image.height), scale: scale, style: style)
        let space = (image.colorSpace?.model == .rgb ? image.colorSpace : nil) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: Int(layout.canvasSize.width), height: Int(layout.canvasSize.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        let canvas = CGRect(origin: .zero, size: layout.canvasSize)

        drawFill(style.fill, in: canvas, context: context, space: space, backgroundImage: backgroundImage)

        let radius = min(max(0, style.cornerRadius) * scale, min(layout.contentRect.width, layout.contentRect.height) / 2)
        let clip = CGPath(
            roundedRect: layout.contentRect, cornerWidth: radius, cornerHeight: radius, transform: nil
        )
        if style.shadowRadius > 0, style.shadowOpacity > 0 {
            let blur = style.shadowRadius * scale
            context.setShadow(
                offset: CGSize(width: 0, height: -blur * 0.35),
                blur: blur,
                color: CGColor(gray: 0, alpha: min(max(style.shadowOpacity, 0), 1))
            )
        }
        // A transparency layer makes the shadow follow the rounded, possibly translucent screenshot.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.addPath(clip)
        context.clip()
        context.draw(image, in: layout.contentRect)
        context.endTransparencyLayer()

        return context.makeImage()
    }

    private static func drawFill(
        _ fill: BackgroundStyle.Fill, in rect: CGRect, context: CGContext, space: CGColorSpace, backgroundImage: CGImage?
    ) {
        switch fill {
        case .none:
            break
        case .solid(let color):
            context.setFillColor(color.cgColor)
            context.fill(rect)
        case .gradient(let gradient):
            let colors = gradient.colors.isEmpty ? [RGBAColor(hex: 0xFFFFFF)] : gradient.colors
            let cgColors = (colors.count == 1 ? [colors[0], colors[0]] : colors).map(\.cgColor)
            guard let cgGradient = CGGradient(colorsSpace: space, colors: cgColors as CFArray, locations: nil) else { return }
            let radians = gradient.angle * .pi / 180
            let direction = CGPoint(x: cos(radians), y: sin(radians))
            let length = abs(rect.width * direction.x) + abs(rect.height * direction.y)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let start = CGPoint(x: center.x - direction.x * length / 2, y: center.y - direction.y * length / 2)
            let end = CGPoint(x: center.x + direction.x * length / 2, y: center.y + direction.y * length / 2)
            context.drawLinearGradient(
                cgGradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        case .image:
            guard let backgroundImage else { return }
            // Aspect fill.
            let imageSize = CGSize(width: backgroundImage.width, height: backgroundImage.height)
            let factor = max(rect.width / imageSize.width, rect.height / imageSize.height)
            let size = CGSize(width: imageSize.width * factor, height: imageSize.height * factor)
            context.draw(
                backgroundImage,
                in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
            )
        }
    }

    /// Loads a background picture from disk.
    public static func loadImage(at path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
