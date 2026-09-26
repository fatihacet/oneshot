import CoreGraphics
import Vision

/// Names what an image shows with Apple's on-device classifier (about 1,300 labels such as
/// "sunset sunrise", "beach", "cat", "chart" or "document"), so history search finds photos and
/// pictures that contain no text. Nothing leaves the Mac.
enum ImageLabeler {
    /// Below this confidence labels are mostly noise; above it a sunset photo gets
    /// "outdoor, sky, sunset sunrise, hill, water" and a screenshot "document, screenshot".
    static let minimumConfidence: Float = 0.3
    static let maximumLabels = 8

    static func labels(for image: CGImage) throws -> [String] {
        let request = VNClassifyImageRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? [])
            .filter { $0.confidence >= minimumConfidence }
            .sorted { $0.confidence > $1.confidence }
            .prefix(maximumLabels)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
    }
}
