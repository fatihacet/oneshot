import CoreGraphics
import Foundation

/// Output resolution of a screen recording. Each preset is a box the recording is scaled down to fit,
/// so a 3456×2234 Retina screen at 1080p becomes 1670×1080. Recordings are never scaled up.
public enum RecordingResolution: String, CaseIterable, Identifiable, Sendable {
    case original
    case uhd2160 = "2160p"
    case qhd1440 = "1440p"
    case fhd1080 = "1080p"
    case hd720 = "720p"

    public static let `default` = RecordingResolution.fhd1080

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .original: return "Original"
        case .uhd2160: return "4K"
        case .qhd1440: return "1440p"
        case .fhd1080: return "1080p"
        case .hd720: return "720p"
        }
    }

    /// Long and short side of the bounding box, or nil to keep the captured size.
    private var box: (long: CGFloat, short: CGFloat)? {
        switch self {
        case .original: return nil
        case .uhd2160: return (3840, 2160)
        case .qhd1440: return (2560, 1440)
        case .fhd1080: return (1920, 1080)
        case .hd720: return (1280, 720)
        }
    }

    /// The encoded size for content captured at `sourcePixels`: scaled to fit the preset's box
    /// (turned to match portrait content), rounded down to even numbers as H.264 and HEVC require.
    public func outputSize(for sourcePixels: CGSize) -> CGSize {
        var scale: CGFloat = 1
        if let box {
            let isPortrait = sourcePixels.height > sourcePixels.width
            let maxWidth = isPortrait ? box.short : box.long
            let maxHeight = isPortrait ? box.long : box.short
            scale = min(1, maxWidth / sourcePixels.width, maxHeight / sourcePixels.height)
        }
        // The tolerance keeps 2234 × (1080 / 2234) at 1080 despite floating point error.
        func even(_ value: CGFloat) -> CGFloat { max(2, CGFloat(Int(value + 0.001) / 2 * 2)) }
        return CGSize(width: even(sourcePixels.width * scale), height: even(sourcePixels.height * scale))
    }
}

public enum RecordingCodec: String, CaseIterable, Identifiable, Sendable {
    /// H.265: about 40% smaller than H.264 at the same quality. Plays in every current browser and on Apple devices.
    case hevc
    /// Plays everywhere, including older Windows PCs without HEVC support.
    case h264

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hevc: return "HEVC (smaller files)"
        case .h264: return "H.264 (most compatible)"
        }
    }
}

public enum RecordingQuality: String, CaseIterable, Identifiable, Sendable {
    /// Comparable to Loom: sharp text at roughly 25 MB per minute at 1080p.
    case standard
    /// Twice the bit rate, for fast motion or fine detail.
    case high

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: return "Standard"
        case .high: return "High"
        }
    }
}

/// Bit rates for screen recordings.
///
/// The target scales with pixel count to the power of 0.75 (bigger frames need fewer bits per pixel),
/// anchored at 3.5 Mbit/s for 1920×1080 HEVC at 30 fps. Screen content is mostly static, so this keeps
/// text crisp while a 23 minute 1080p recording stays around 500–600 MB instead of several gigabytes.
public enum VideoEncoding {
    public static let referencePixels: Double = 1920 * 1080
    public static let referenceBitRate: Double = 3_500_000
    /// AAC bit rate of the final audio track.
    public static let audioBitRate = 160_000
    public static let minimumBitRate = 600_000

    public static func videoBitRate(
        pixelSize: CGSize,
        frameRate: Int,
        codec: RecordingCodec,
        quality: RecordingQuality
    ) -> Int {
        let pixels = max(1, Double(pixelSize.width * pixelSize.height))
        var rate = referenceBitRate * pow(pixels / referencePixels, 0.75)
        rate *= pow(Double(max(1, frameRate)) / 30, 0.6)
        if codec == .h264 { rate *= 1.6 }
        if quality == .high { rate *= 2 }
        return max(minimumBitRate, Int(rate))
    }

    /// Upper estimate of the file size per minute, in megabytes (10^6 bytes).
    public static func megabytesPerMinute(videoBitRate: Int, hasAudio: Bool) -> Double {
        let bitsPerSecond = Double(videoBitRate + (hasAudio ? audioBitRate : 0))
        return bitsPerSecond * 60 / 8 / 1_000_000
    }
}
