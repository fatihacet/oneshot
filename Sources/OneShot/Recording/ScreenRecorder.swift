import AVFoundation
import OneShotCore
import ScreenCaptureKit

/// How a screen recording is encoded and which audio it includes.
struct RecordingConfiguration {
    /// Encoded size in pixels; ScreenCaptureKit scales the captured content to it.
    var pixelSize: CGSize
    var frameRate: Int
    var codec: RecordingCodec
    var quality: RecordingQuality
    var showsCursor: Bool
    var capturesSystemAudio: Bool
    var microphone: AVCaptureDevice?
}

/// Records a ScreenCaptureKit stream into an HEVC or H.264 MP4 file, with system audio and the
/// microphone in separate tracks (AudioTrackMixer combines them afterwards).
/// Sample buffers arrive on a private queue; all writer state is confined to it.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.oneshot.screen-recorder")
    private var stream: SCStream?
    private var microphone: MicrophoneCapture?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var isFinishing = false
    private(set) var outputURL: URL?

    /// Called on the recorder queue if the stream stops unexpectedly.
    var onFailure: (@Sendable (Error) -> Void)?

    /// - Parameter sourceRect: Display region in points (top-left origin), or nil for the whole filter content.
    func start(filter: SCContentFilter, sourceRect: CGRect?, configuration: RecordingConfiguration) async throws {
        let width = max(2, Int(configuration.pixelSize.width) / 2 * 2)
        let height = max(2, Int(configuration.pixelSize.height) / 2 * 2)
        let frameRate = configuration.frameRate
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OneShot-\(UUID().uuidString).mp4")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        var videoSettings = Self.videoSettings(
            codec: configuration.codec, width: width, height: height,
            frameRate: frameRate, quality: configuration.quality
        )
        if !writer.canApply(outputSettings: videoSettings, forMediaType: .video) {
            // Every Mac that runs macOS 14 encodes HEVC in hardware, but fall back rather than fail.
            videoSettings = Self.videoSettings(
                codec: .h264, width: width, height: height, frameRate: frameRate, quality: configuration.quality
            )
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)

        var systemAudioInput: AVAssetWriterInput?
        if configuration.capturesSystemAudio {
            systemAudioInput = Self.addAudioInput(to: writer, channels: 2, bitRate: 128_000)
        }

        var microphone: MicrophoneCapture?
        var microphoneInput: AVAssetWriterInput?
        if let device = configuration.microphone {
            microphone = try MicrophoneCapture(device: device, queue: queue) { [weak self] buffer in
                self?.appendMicrophone(buffer)
            }
            microphoneInput = Self.addAudioInput(to: writer, channels: 1, bitRate: 96_000)
        }

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        if let sourceRect { config.sourceRect = sourceRect }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        config.showsCursor = configuration.showsCursor
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6
        config.capturesAudio = configuration.capturesSystemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if configuration.capturesSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }

        queue.sync {
            self.writer = writer
            self.videoInput = videoInput
            self.systemAudioInput = systemAudioInput
            self.microphoneInput = microphoneInput
            self.sessionStarted = false
            self.isFinishing = false
            self.outputURL = url
        }
        guard writer.startWriting() else { throw writer.error ?? CaptureError.emptyImage }
        // Start the microphone first: it takes a moment, and samples before the first frame are dropped.
        microphone?.start()
        do {
            try await stream.startCapture()
        } catch {
            microphone?.stop()
            writer.cancelWriting()
            throw error
        }
        self.stream = stream
        self.microphone = microphone
    }

    private static func videoSettings(
        codec: RecordingCodec, width: Int, height: Int, frameRate: Int, quality: RecordingQuality
    ) -> [String: Any] {
        let bitRate = VideoEncoding.videoBitRate(
            pixelSize: CGSize(width: width, height: height), frameRate: frameRate, codec: codec, quality: quality
        )
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitRate,
            AVVideoExpectedSourceFrameRateKey: frameRate,
            // Few key frames: screen content changes little, and seeking still lands within 4 seconds.
            AVVideoMaxKeyFrameIntervalKey: frameRate * 4,
            AVVideoMaxKeyFrameIntervalDurationKey: 4,
        ]
        if codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        return [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ]
    }

    private static func addAudioInput(to writer: AVAssetWriter, channels: Int, bitRate: Int) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitRate,
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        return input
    }

    /// Stops capturing and finishes the file. Returns nil if no frame was recorded.
    func stop() async -> URL? {
        try? await stream?.stopCapture()
        stream = nil
        microphone?.stop()
        microphone = nil
        return await withCheckedContinuation { continuation in
            queue.async {
                self.isFinishing = true
                guard let writer = self.writer, writer.status == .writing, self.sessionStarted else {
                    self.writer?.cancelWriting()
                    continuation.resume(returning: nil)
                    return
                }
                // Hold the last frame until now, even if the screen did not change at the end.
                writer.endSession(atSourceTime: CMClockGetTime(CMClockGetHostTimeClock()))
                self.videoInput?.markAsFinished()
                self.systemAudioInput?.markAsFinished()
                self.microphoneInput?.markAsFinished()
                let url = self.outputURL
                writer.finishWriting {
                    continuation.resume(returning: writer.status == .completed ? url : nil)
                }
            }
        }
    }

    // MARK: Sample buffers (on the recorder queue)

    private var canAppend: Bool {
        !isFinishing && writer?.status == .writing
    }

    private func appendMicrophone(_ sampleBuffer: CMSampleBuffer) {
        guard canAppend, sessionStarted, let microphoneInput, microphoneInput.isReadyForMoreMediaData else { return }
        microphoneInput.append(sampleBuffer)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, canAppend, let writer else { return }
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
            guard sessionStarted, let systemAudioInput, systemAudioInput.isReadyForMoreMediaData else { return }
            systemAudioInput.append(sampleBuffer)
        default:
            break
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.onFailure?(error) }
    }
}
