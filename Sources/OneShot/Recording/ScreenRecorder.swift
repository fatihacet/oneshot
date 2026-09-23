import AVFoundation
import ScreenCaptureKit

/// Records a ScreenCaptureKit stream into an H.264 MP4 file with optional system audio.
/// Sample buffers arrive on a private queue; all writer state is confined to it.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.oneshot.screen-recorder")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private(set) var outputURL: URL?

    /// Called on the recorder queue if the stream stops unexpectedly.
    var onFailure: (@Sendable (Error) -> Void)?

    /// - Parameters:
    ///   - pixelSize: Output size; rounded down to even numbers for H.264.
    ///   - sourceRect: Display region in points (top-left origin), or nil for the whole filter content.
    func start(
        filter: SCContentFilter,
        pixelSize: CGSize,
        sourceRect: CGRect?,
        showsCursor: Bool,
        capturesAudio: Bool
    ) async throws {
        let width = max(2, Int(pixelSize.width) / 2 * 2)
        let height = max(2, Int(pixelSize.height) / 2 * 2)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OneShot-\(UUID().uuidString).mp4")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, width * height * 6),
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalKey: 120,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if capturesAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ])
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            audioInput = input
        }

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        if let sourceRect { config.sourceRect = sourceRect }
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = showsCursor
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6
        config.capturesAudio = capturesAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if capturesAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }

        queue.sync {
            self.writer = writer
            self.videoInput = videoInput
            self.audioInput = audioInput
            self.sessionStarted = false
            self.outputURL = url
        }
        guard writer.startWriting() else { throw writer.error ?? CaptureError.emptyImage }
        try await stream.startCapture()
        self.stream = stream
    }

    /// Stops capturing and finishes the file. Returns nil if no frame was recorded.
    func stop() async -> URL? {
        try? await stream?.stopCapture()
        stream = nil
        return await withCheckedContinuation { continuation in
            queue.async {
                guard let writer = self.writer, writer.status == .writing, self.sessionStarted else {
                    self.writer?.cancelWriting()
                    continuation.resume(returning: nil)
                    return
                }
                // Hold the last frame until now, even if the screen did not change at the end.
                writer.endSession(atSourceTime: CMClockGetTime(CMClockGetHostTimeClock()))
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                let url = self.outputURL
                writer.finishWriting {
                    continuation.resume(returning: writer.status == .completed ? url : nil)
                }
            }
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, let writer, writer.status == .writing else { return }
        switch type {
        case .screen:
            // Only complete frames carry new pixels; idle frames repeat the previous one.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let rawStatus = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: rawStatus) == .complete,
                  let videoInput
            else { return }
            if !sessionStarted {
                writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
                sessionStarted = true
            }
            if videoInput.isReadyForMoreMediaData { videoInput.append(sampleBuffer) }
        case .audio:
            guard sessionStarted, let audioInput, audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(sampleBuffer)
        default:
            break
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.onFailure?(error) }
    }
}
