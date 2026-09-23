import CoreGraphics
import Foundation

/// Stitches consecutive captures of a scrolling region into one tall image.
///
/// Each new frame is compared with the previous one using per-row hashes. Rows that stay put at the
/// top and bottom (sticky headers, footers, toolbars) are detected and kept only once; the vertical
/// scroll offset is the shift with the best row match in the remaining content band. Only the newly
/// revealed rows are appended, so memory stays proportional to the output height.
public struct ScrollStitcher {
    public enum FrameResult: Equatable {
        /// The frame revealed `rows` new pixel rows.
        case appended(rows: Int)
        /// Nothing moved (or the content scrolled backwards).
        case unchanged
        /// No reliable overlap with the previous frame, e.g. because the content scrolled too far.
        case noOverlap
        /// The output reached `maxHeight`.
        case full
        /// The frame's size differs from the first frame.
        case sizeMismatch
    }

    public let maxHeight: Int
    /// Columns on the right that are ignored when matching (overlay scroll bars change while scrolling).
    public let ignoredTrailingColumns: Int
    /// Fraction of informative rows that must match for an offset to be accepted.
    public let matchThreshold: Double

    private var width = 0
    private var height = 0
    private var colorSpace: CGColorSpace?

    private var firstFrame: Frame?
    private var previous: Frame?
    private var latest: Frame?
    /// Rows appended after the first frame's content band.
    private var appended = Data()
    private var appendedRows = 0
    private var headerRows: Int?
    /// End of the first frame's content band; set by the first matched pair.
    private var firstEnd: Int?
    /// Row (in the latest frame) where the emitted content ends. Rows below it form the footer.
    private var lastEnd = 0
    private var isFull = false

    public init(maxHeight: Int = 30_000, ignoredTrailingColumns: Int = 32, matchThreshold: Double = 0.97) {
        self.maxHeight = maxHeight
        self.ignoredTrailingColumns = ignoredTrailingColumns
        self.matchThreshold = matchThreshold
    }

    /// Current height of the stitched image in pixels.
    public var outputHeight: Int {
        guard firstFrame != nil else { return 0 }
        guard let firstEnd else { return height }
        return firstEnd + appendedRows + (isFull ? 0 : height - lastEnd)
    }

    public var pixelWidth: Int { width }

    @discardableResult
    public mutating func add(_ image: CGImage) -> FrameResult {
        if firstFrame == nil {
            let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
            guard let frame = Frame(image: image, colorSpace: space, ignoredTrailingColumns: ignoredTrailingColumns) else {
                return .sizeMismatch
            }
            width = image.width
            height = image.height
            colorSpace = space
            firstFrame = frame
            previous = frame
            latest = frame
            return .appended(rows: height)
        }
        guard image.width == width, image.height == height, let colorSpace, let previous,
              let frame = Frame(image: image, colorSpace: colorSpace, ignoredTrailingColumns: ignoredTrailingColumns)
        else { return .sizeMismatch }

        if isFull { return .full }
        if frame.hashes == previous.hashes { return .unchanged }

        // Static bands at the top and bottom (sticky headers and footers).
        var top = 0
        while top < height, frame.hashes[top] == previous.hashes[top] { top += 1 }
        var bottom = 0
        while bottom < height - top, frame.hashes[height - 1 - bottom] == previous.hashes[height - 1 - bottom] {
            bottom += 1
        }
        // The header is fixed by the first pair; later pairs may only see a subset of it.
        let header = headerRows ?? top
        let bandStart = min(header, top)
        let bandEnd = height - bottom
        let bandHeight = bandEnd - bandStart
        guard bandHeight > 8 else { return .unchanged }

        guard let shift = bestShift(previous: previous, current: frame, bandStart: bandStart, bandHeight: bandHeight) else {
            return .noOverlap
        }
        if firstEnd == nil {
            headerRows = header
            firstEnd = bandEnd
            lastEnd = bandEnd
        }

        // Continue exactly where the emitted content ended, now `shift` rows higher.
        let start = max(lastEnd - shift, bandStart)
        let count = bandEnd - start
        self.previous = frame
        latest = frame
        guard count > 0 else {
            lastEnd = max(lastEnd - shift, 0)
            return .unchanged
        }

        let available = maxHeight - (firstEnd! + appendedRows)
        let newRows = min(count, max(available, 0))
        if newRows < count { isFull = true }
        guard newRows > 0 else { return .full }
        frame.appendRows(from: start, count: newRows, to: &appended)
        appendedRows += newRows
        lastEnd = start + newRows
        return .appended(rows: newRows)
    }

    /// The stitched image: the first frame's content, the new rows, then the rest of the latest frame.
    public func makeImage() -> CGImage? {
        guard let firstFrame, let latest, let colorSpace else { return nil }
        let bytesPerRow = width * 4
        var data = Data(capacity: outputHeight * bytesPerRow)
        firstFrame.appendRows(from: 0, count: firstEnd ?? height, to: &data)
        if firstEnd != nil {
            data.append(appended)
            if !isFull { latest.appendRows(from: lastEnd, count: height - lastEnd, to: &data) }
        }

        let totalRows = data.count / bytesPerRow
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: totalRows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: Frame.bitmapInfo, provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    // MARK: Matching

    /// Finds how many rows the content moved up between `previous` and `current` within the band.
    private func bestShift(previous: Frame, current: Frame, bandStart: Int, bandHeight: Int) -> Int? {
        let minimumOverlap = max(8, bandHeight / 10)
        guard bandHeight - 1 >= minimumOverlap else { return nil }

        var best: (shift: Int, score: Double)?
        for shift in 1...(bandHeight - minimumOverlap) {
            let overlap = bandHeight - shift
            var informative = 0
            var matches = 0
            var mismatches = 0
            let allowedMismatches = Int(Double(overlap) * (1 - matchThreshold)) + 1
            for offset in 0..<overlap {
                let currentRow = bandStart + offset
                // Uniform rows (blank background) carry no position information.
                guard !current.uniform[currentRow] else { continue }
                informative += 1
                if previous.hashes[bandStart + shift + offset] == current.hashes[currentRow] {
                    matches += 1
                } else {
                    mismatches += 1
                    if mismatches > allowedMismatches { break }
                }
            }
            guard mismatches <= allowedMismatches, informative >= 4 else { continue }
            let score = Double(matches) / Double(informative)
            guard score >= matchThreshold else { continue }
            if best == nil || score > best!.score + 1e-9 {
                best = (shift, score)
                if score == 1 { break }
            }
        }
        return best?.shift
    }
}

/// One frame's pixels in a fixed RGBA layout plus per-row fingerprints.
private struct Frame {
    static let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

    let width: Int
    let height: Int
    let pixels: Data
    let hashes: [UInt64]
    let uniform: [Bool]

    init?(image: CGImage, colorSpace: CGColorSpace, ignoredTrailingColumns: Int) {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var buffer = Data(count: bytesPerRow * height)
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: Frame.bitmapInfo.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        let hashedColumns = max(1, width - min(ignoredTrailingColumns, width / 4))
        var hashes = [UInt64](repeating: 0, count: height)
        var uniform = [Bool](repeating: true, count: height)
        buffer.withUnsafeBytes { raw in
            let words = raw.bindMemory(to: UInt32.self)
            for row in 0..<height {
                let start = row * width
                let first = words[start]
                var hash: UInt64 = 0xCBF2_9CE4_8422_2325
                var isUniform = true
                for column in 0..<hashedColumns {
                    let pixel = words[start + column]
                    if pixel != first { isUniform = false }
                    hash = (hash ^ UInt64(pixel)) &* 0x0000_0100_0000_01B3
                }
                hashes[row] = hash
                uniform[row] = isUniform
            }
        }
        self.width = width
        self.height = height
        self.pixels = buffer
        self.hashes = hashes
        self.uniform = uniform
    }

    /// Appends `count` rows starting at `row` (top-down) to `data`.
    func appendRows(from row: Int, count: Int, to data: inout Data) {
        guard count > 0 else { return }
        let bytesPerRow = width * 4
        let start = row * bytesPerRow
        data.append(pixels.subdata(in: start..<(start + count * bytesPerRow)))
    }
}
