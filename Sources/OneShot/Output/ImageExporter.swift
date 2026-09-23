import AppKit
import ImageIO
import OneShotCore
import UniformTypeIdentifiers

/// A finished screenshot.
struct Capture {
    let image: CGImage
    /// Pixels per point of the source display.
    let scale: CGFloat
    /// Where the captured content was on screen, in AppKit global coordinates.
    let sourceRect: CGRect?
    /// Name of the app that was frontmost (or owned the window) when capturing.
    var appName: String?
    /// Title of that app's front window, when known.
    var windowTitle: String?
    /// ID of this capture in the local history, if it was recorded.
    var historyID: String?
    let date = Date()

    var pointSize: CGSize {
        CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }

    var nsImage: NSImage { NSImage(cgImage: image, size: pointSize) }
}

enum ImageExporter {
    /// Encodes the capture with DPI metadata so Retina images keep their point size in other apps.
    static func encode(_ capture: Capture, as format: ImageFormat) -> Data? {
        var image = capture.image
        var scale = capture.scale
        if Preferences.downscaleRetina, scale > 1, let resized = resize(image, by: 1 / scale) {
            image = resized
            scale = 1
        }
        if format == .jpeg, let flattened = flatten(image) {
            image = flattened
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, format.utType.identifier as CFString, 1, nil
        ) else { return nil }

        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * scale,
            kCGImagePropertyDPIHeight: 72 * scale,
        ]
        if format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = Preferences.jpegQuality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func copyToClipboard(_ capture: Capture) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard let png = encode(capture, as: .png) else { return }
        pasteboard.declareTypes([.png, .tiff], owner: nil)
        pasteboard.setData(png, forType: .png)
        if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
    }

    /// Writes the capture into `directory` using the configured format and returns the file URL.
    static func save(_ capture: Capture, to directory: URL = Preferences.saveDirectory) throws -> URL {
        let format = Preferences.imageFormat
        guard let data = encode(capture, as: format) else { throw CaptureError.emptyImage }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let baseName = FileNamePattern.fileName(
            pattern: Preferences.fileNamePattern,
            context: .init(date: capture.date, appName: capture.appName, pixelSize: capture.image.pixelSize)
        )
        let url = uniqueURL(in: directory, baseName: baseName, fileExtension: format.fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Writes the capture to a temporary file, used for drag and drop and "open with".
    static func temporaryFile(for capture: Capture) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OneShot", isDirectory: true)
        return try save(capture, to: directory)
    }

    private static func uniqueURL(in directory: URL, baseName: String, fileExtension: String) -> URL {
        var url = directory.appendingPathComponent(baseName).appendingPathExtension(fileExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(baseName) (\(counter))").appendingPathExtension(fileExtension)
            counter += 1
        }
        return url
    }

    private static func resize(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        let width = max(1, Int(CGFloat(image.width) * factor))
        let height = max(1, Int(CGFloat(image.height) * factor))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// JPEG has no alpha channel, so transparent areas (such as window shadows) go on white.
    private static func flatten(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }
}
