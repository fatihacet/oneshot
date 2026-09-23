import CoreGraphics
import Foundation
import OneShotCore
import Testing

struct ScrollStitcherTests {
    private let width = 120
    private let viewport = 300
    private let headerRows = 24
    private let footerRows = 16

    /// A tall "page" with text-like stripes on a white background and some blank gaps.
    private func makePage(height: Int, seed: UInt64) -> [UInt32] {
        var generator = SeededGenerator(seed: seed)
        var pixels = [UInt32](repeating: 0xFFFF_FFFF, count: width * height)
        var row = 0
        while row < height {
            let lineHeight = Int.random(in: 6...14, using: &generator)
            let gap = Int.random(in: 2...30, using: &generator)
            for y in row..<min(row + lineHeight, height) {
                for x in 4..<(width - 40) where Bool.random(using: &generator) {
                    pixels[y * width + x] = UInt32.random(in: 0...UInt32.max, using: &generator) | 0xFF00_0000
                }
            }
            row += lineHeight + gap
        }
        return pixels
    }

    private func band(_ color: UInt32, rows: Int) -> [UInt32] {
        [UInt32](repeating: color, count: width * rows)
    }

    /// Renders a viewport: sticky header, page rows [offset, offset + content), sticky footer.
    private func frame(page: [UInt32], offset: Int) -> CGImage {
        let content = viewport - headerRows - footerRows
        var pixels = band(0xFF33_6699, rows: headerRows)
        pixels += page[(offset * width)..<((offset + content) * width)]
        pixels += band(0xFF99_3366, rows: footerRows)
        return image(from: pixels, height: viewport)
    }

    private func image(from pixels: [UInt32], height: Int) -> CGImage {
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    private func pixels(of image: CGImage) -> [UInt32] {
        var result = [UInt32](repeating: 0, count: image.width * image.height)
        result.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return result
    }

    @Test func reconstructsScrolledPageWithStickyHeaderAndFooter() throws {
        let pageHeight = 1400
        let page = makePage(height: pageHeight, seed: 42)
        let content = viewport - headerRows - footerRows
        var stitcher = ScrollStitcher(ignoredTrailingColumns: 8)

        var offsets = Array(stride(from: 0, through: pageHeight - content, by: 97))
        offsets.append(pageHeight - content)
        for offset in offsets {
            stitcher.add(frame(page: page, offset: offset))
        }
        // Repeating the last frame changes nothing.
        #expect(stitcher.add(frame(page: page, offset: pageHeight - content)) == .unchanged)

        let result = try #require(stitcher.makeImage())
        let expected = band(0xFF33_6699, rows: headerRows) + page + band(0xFF99_3366, rows: footerRows)
        #expect(result.height == headerRows + pageHeight + footerRows)
        let actual = pixels(of: result)
        let firstDifferentRow = zip(actual, expected).enumerated().first { $0.element.0 != $0.element.1 }.map { $0.offset / width }
        #expect(firstDifferentRow == nil)
    }

    @Test func handlesUnevenStepsAndChangingScrollBar() throws {
        let pageHeight = 1600
        let page = makePage(height: pageHeight, seed: 99)
        let content = viewport - headerRows - footerRows
        var stitcher = ScrollStitcher(ignoredTrailingColumns: 8)
        var generator = SeededGenerator(seed: 5)

        var offset = 0
        var offsets = [0]
        while offset < pageHeight - content {
            offset = min(offset + Int.random(in: 3...180, using: &generator), pageHeight - content)
            offsets.append(offset)
        }
        for offset in offsets {
            // Simulate an overlay scroll bar: the last columns change on every frame.
            var pixels = pixels(of: frame(page: page, offset: offset))
            for row in 0..<viewport {
                for column in (width - 6)..<width {
                    pixels[row * width + column] = UInt32.random(in: 0...UInt32.max, using: &generator) | 0xFF00_0000
                }
            }
            stitcher.add(image(from: pixels, height: viewport))
        }

        let result = try #require(stitcher.makeImage())
        #expect(result.height == headerRows + pageHeight + footerRows)
        // Compare everything except the scroll bar columns.
        let actual = pixels(of: result)
        let expected = band(0xFF33_6699, rows: headerRows) + page + band(0xFF99_3366, rows: footerRows)
        let mismatchedRows = (headerRows..<(headerRows + pageHeight)).filter { row in
            (0..<(width - 6)).contains { actual[row * width + $0] != expected[row * width + $0] }
        }
        #expect(mismatchedRows.isEmpty)
    }

    @Test func reportsMissingOverlap() {
        let page = makePage(height: 2000, seed: 7)
        var stitcher = ScrollStitcher(ignoredTrailingColumns: 8)
        stitcher.add(frame(page: page, offset: 0))
        #expect(stitcher.add(frame(page: page, offset: 900)) == .noOverlap)
    }

    @Test func stopsAtMaxHeight() {
        let page = makePage(height: 1400, seed: 3)
        var stitcher = ScrollStitcher(maxHeight: 400, ignoredTrailingColumns: 8)
        stitcher.add(frame(page: page, offset: 0))
        stitcher.add(frame(page: page, offset: 150))
        #expect(stitcher.outputHeight == 400)
        #expect(stitcher.add(frame(page: page, offset: 250)) == .full)
    }
}

/// Deterministic PRNG so test pages are reproducible.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
