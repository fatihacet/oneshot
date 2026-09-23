import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Converts a screen recording into a looping animated GIF.
public enum GIFConverter {
    public enum ConversionError: LocalizedError {
        case noVideoTrack
        case cannotCreateFile

        public var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "The recording has no video."
            case .cannotCreateFile: return "Could not create the GIF file."
            }
        }
    }

    /// - Parameters:
    ///   - fps: Frames per second in the GIF (10–15 keeps files small).
    ///   - maxWidth: Frames wider than this are scaled down.
    ///   - progress: Called with values from 0 to 1.
    public static func convert(
        videoAt videoURL: URL,
        to outputURL: URL,
        fps: Int,
        maxWidth: Int,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let asset = AVURLAsset(url: videoURL)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw ConversionError.noVideoTrack }
        let duration = try await asset.load(.duration).seconds
        let frameRate = max(1, fps)
        let frameCount = max(1, Int((duration * Double(frameRate)).rounded(.down)))
        let times = (0..<frameCount).map { CMTime(seconds: Double($0) / Double(frameRate), preferredTimescale: 600) }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5 / Double(frameRate), preferredTimescale: 600)
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth * 4)

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL, UTType.gif.identifier as CFString, frameCount, nil
        ) else { throw ConversionError.cannotCreateFile }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let delay = 1 / Double(frameRate)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ],
        ] as CFDictionary

        var written = 0
        for await result in generator.images(for: times) {
            if let image = try? result.image {
                CGImageDestinationAddImage(destination, image, frameProperties)
                written += 1
            }
            progress?(Double(written) / Double(frameCount))
        }
        guard written > 0, CGImageDestinationFinalize(destination) else { throw ConversionError.cannotCreateFile }
    }

    /// Number of frames in a GIF file.
    public static func frameCount(of url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
        return CGImageSourceGetCount(source)
    }
}
