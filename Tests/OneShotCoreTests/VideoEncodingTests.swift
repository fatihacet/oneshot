import CoreGraphics
import OneShotCore
import Testing

struct VideoEncodingTests {
    private let retina = CGSize(width: 3456, height: 2234)

    @Test func scalesRetinaScreenToFitPresetBox() {
        #expect(RecordingResolution.fhd1080.outputSize(for: retina) == CGSize(width: 1670, height: 1080))
        #expect(RecordingResolution.qhd1440.outputSize(for: retina) == CGSize(width: 2226, height: 1440))
        #expect(RecordingResolution.hd720.outputSize(for: retina) == CGSize(width: 1112, height: 720))
        #expect(RecordingResolution.original.outputSize(for: retina) == retina)
    }

    @Test func wideContentIsLimitedByWidth() {
        let ultrawide = CGSize(width: 5120, height: 1440)
        #expect(RecordingResolution.fhd1080.outputSize(for: ultrawide) == CGSize(width: 1920, height: 540))
    }

    @Test func portraitContentUsesATurnedBox() {
        let portrait = CGSize(width: 1200, height: 2400)
        #expect(RecordingResolution.fhd1080.outputSize(for: portrait) == CGSize(width: 960, height: 1920))
    }

    @Test func neverScalesUpAndKeepsSizesEven() {
        let small = CGSize(width: 801, height: 601)
        #expect(RecordingResolution.uhd2160.outputSize(for: small) == CGSize(width: 800, height: 600))
        #expect(RecordingResolution.original.outputSize(for: CGSize(width: 1, height: 1)) == CGSize(width: 2, height: 2))
    }

    @Test func bitRateMatchesReferenceAt1080p() {
        let rate = VideoEncoding.videoBitRate(
            pixelSize: CGSize(width: 1920, height: 1080), frameRate: 30, codec: .hevc, quality: .standard
        )
        #expect(rate == 3_500_000)
    }

    @Test func twentyThreeMinutesAt1080pIsLoomSized() {
        let size = RecordingResolution.fhd1080.outputSize(for: retina)
        let rate = VideoEncoding.videoBitRate(pixelSize: size, frameRate: 30, codec: .hevc, quality: .standard)
        let megabytes = VideoEncoding.megabytesPerMinute(videoBitRate: rate, hasAudio: true) * 23
        #expect(megabytes > 400 && megabytes < 700)
    }

    @Test func bitRateGrowsWithResolutionFrameRateCodecAndQuality() {
        func rate(_ size: CGSize, fps: Int = 30, codec: RecordingCodec = .hevc, quality: RecordingQuality = .standard) -> Int {
            VideoEncoding.videoBitRate(pixelSize: size, frameRate: fps, codec: codec, quality: quality)
        }
        let hd = CGSize(width: 1920, height: 1080)
        #expect(rate(CGSize(width: 3840, height: 2160)) > rate(hd))
        // Four times the pixels needs less than four times the bits.
        #expect(rate(CGSize(width: 3840, height: 2160)) < rate(hd) * 4)
        #expect(rate(hd, fps: 60) > rate(hd))
        #expect(rate(hd, codec: .h264) > rate(hd))
        #expect(rate(hd, quality: .high) == rate(hd) * 2)
        #expect(rate(CGSize(width: 10, height: 10)) == VideoEncoding.minimumBitRate)
    }
}
