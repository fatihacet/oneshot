import CoreGraphics
import Foundation

/// An sRGB color that can be stored in presets.
public struct RGBAColor: Codable, Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    public init?(cgColor: CGColor) {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3 else { return nil }
        self.init(
            red: Double(components[0]), green: Double(components[1]), blue: Double(components[2]),
            alpha: Double(components.count > 3 ? components[3] : 1)
        )
    }
}

public struct GradientFill: Codable, Equatable, Hashable, Sendable {
    public var colors: [RGBAColor]
    /// Direction in degrees: 0 goes left to right, 90 goes bottom to top.
    public var angle: Double

    public init(colors: [RGBAColor], angle: Double = 135) {
        self.colors = colors
        self.angle = angle
    }
}

public struct AspectRatio: Codable, Equatable, Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public var value: Double { height > 0 ? width / height : 1 }
}

public enum ContentAlignment: String, Codable, CaseIterable, Sendable {
    case topLeading, top, topTrailing
    case leading, center, trailing
    case bottomLeading, bottom, bottomTrailing

    /// Horizontal and vertical position from 0 (leading/bottom) to 1 (trailing/top).
    var factors: (x: Double, y: Double) {
        switch self {
        case .topLeading: return (0, 1)
        case .top: return (0.5, 1)
        case .topTrailing: return (1, 1)
        case .leading: return (0, 0.5)
        case .center: return (0.5, 0.5)
        case .trailing: return (1, 0.5)
        case .bottomLeading: return (0, 0)
        case .bottom: return (0.5, 0)
        case .bottomTrailing: return (1, 0)
        }
    }
}

/// Everything the background tool needs to render a screenshot onto a backdrop.
public struct BackgroundDesign: Codable, Equatable, Sendable {
    public enum Fill: Codable, Equatable, Sendable {
        case none
        case solid(RGBAColor)
        case gradient(GradientFill)
        /// A picture file drawn to fill the canvas.
        case image(path: String)
    }

    public var fill: Fill
    /// Space around the screenshot, in points.
    public var padding: Double
    /// Corner radius of the screenshot, in points.
    public var cornerRadius: Double
    /// Shadow blur radius in points; 0 disables the shadow.
    public var shadowRadius: Double
    public var shadowOpacity: Double
    /// Canvas aspect ratio; nil keeps the screenshot's shape plus padding.
    public var aspectRatio: AspectRatio?
    public var alignment: ContentAlignment

    public init(
        fill: Fill = .gradient(GradientFill.presets[0].fill),
        padding: Double = 64,
        cornerRadius: Double = 12,
        shadowRadius: Double = 28,
        shadowOpacity: Double = 0.35,
        aspectRatio: AspectRatio? = nil,
        alignment: ContentAlignment = .center
    ) {
        self.fill = fill
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadowRadius = shadowRadius
        self.shadowOpacity = shadowOpacity
        self.aspectRatio = aspectRatio
        self.alignment = alignment
    }
}

public extension GradientFill {
    static let presets: [(name: String, fill: GradientFill)] = [
        ("Sky", GradientFill(colors: [RGBAColor(hex: 0x4FACFE), RGBAColor(hex: 0x00F2FE)])),
        ("Sunset", GradientFill(colors: [RGBAColor(hex: 0xFA709A), RGBAColor(hex: 0xFEE140)])),
        ("Grape", GradientFill(colors: [RGBAColor(hex: 0xA18CD1), RGBAColor(hex: 0xFBC2EB)])),
        ("Ocean", GradientFill(colors: [RGBAColor(hex: 0x2E3192), RGBAColor(hex: 0x1BFFFF)])),
        ("Mint", GradientFill(colors: [RGBAColor(hex: 0x43E97B), RGBAColor(hex: 0x38F9D7)])),
        ("Peach", GradientFill(colors: [RGBAColor(hex: 0xFF9A9E), RGBAColor(hex: 0xFECFEF)])),
        ("Fire", GradientFill(colors: [RGBAColor(hex: 0xF12711), RGBAColor(hex: 0xF5AF19)])),
        ("Night", GradientFill(colors: [RGBAColor(hex: 0x0F2027), RGBAColor(hex: 0x203A43), RGBAColor(hex: 0x2C5364)])),
        ("Indigo", GradientFill(colors: [RGBAColor(hex: 0x4F46E5), RGBAColor(hex: 0x06B6D4)])),
        ("Steel", GradientFill(colors: [RGBAColor(hex: 0xD7D2CC), RGBAColor(hex: 0x304352)])),
    ]
}

public extension AspectRatio {
    static let presets: [(name: String, ratio: AspectRatio?)] = [
        ("Auto", nil),
        ("16:9", AspectRatio(width: 16, height: 9)),
        ("4:3", AspectRatio(width: 4, height: 3)),
        ("3:2", AspectRatio(width: 3, height: 2)),
        ("1:1", AspectRatio(width: 1, height: 1)),
        ("4:5 (Instagram)", AspectRatio(width: 4, height: 5)),
        ("9:16 (Story)", AspectRatio(width: 9, height: 16)),
        ("1.91:1 (Link preview)", AspectRatio(width: 1.91, height: 1)),
    ]
}
