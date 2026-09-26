import AVFoundation
import CoreGraphics
import Foundation
import OneShotCore
import Testing

struct AudioTrackMixerTests {
    private let sampleRate = 48_000
    private let size = CGSize(width: 160, height: 120)

    /// Writes a recording like ScreenRecorder does with system audio and a microphone: a video track,
    /// a mono "microphone" track with a 440 Hz tone and a stereo "system audio" track with a 1 kHz tone
    /// on the left channel only.
    private func makeRecording(seconds: Int) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        func aac(channels: Int) -> AVAssetWriterInput {
            AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 128_000,
            ])
        }
        let microphone = aac(channels: 1)
        let system = aac(channels: 2)
        for input in [video, microphone, system] {
            input.expectsMediaDataInRealTime = true
            writer.add(input)
        }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let chunksPerSecond = 10
        let framesPerChunk = sampleRate / chunksPerSecond
        for chunk in 0..<(seconds * chunksPerSecond) {
            let start = chunk * framesPerChunk
            let mono = (0..<framesPerChunk).map { Float(0.3 * sin(2 * .pi * 440 * Double(start + $0) / Double(sampleRate))) }
            let leftOnly = (0..<framesPerChunk).flatMap {
                [Float(0.3 * sin(2 * .pi * 1000 * Double(start + $0) / Double(sampleRate))), 0]
            }
            try await append(makeAudioBuffer(mono, channels: 1, startFrame: start), to: microphone)
            try await append(makeAudioBuffer(leftOnly, channels: 2, startFrame: start), to: system)

            while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixelBuffer = try #require(buffer)
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(chunk), timescale: CMTimeScale(chunksPerSecond)))
        }
        [video, microphone, system].forEach { $0.markAsFinished() }
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(seconds), timescale: 1))
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    private func append(_ buffer: CMSampleBuffer, to input: AVAssetWriterInput) async throws {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
        #expect(input.append(buffer))
    }

    /// Interleaved 32-bit float PCM.
    private func makeAudioBuffer(_ samples: [Float], channels: Int, startFrame: Int) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        )
        let byteCount = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        )
        let blockBuffer = try #require(block)
        samples.withUnsafeBytes { bytes in
            _ = CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount
            )
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid
        )
        var sampleSize = 4 * channels
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: nil, dataBuffer: blockBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format, sampleCount: samples.count / channels, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        return try #require(sampleBuffer)
    }

    /// Root mean square of the left and right channels of the first audio track.
    private func channelLevels(of url: URL) async throws -> (left: Double, right: Double) {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.startReading()
        var sums = (left: 0.0, right: 0.0)
        var frames = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var samples = [Float](repeating: 0, count: length / 4)
            samples.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            for index in stride(from: 0, to: samples.count - 1, by: 2) {
                sums.left += Double(samples[index] * samples[index])
                sums.right += Double(samples[index + 1] * samples[index + 1])
            }
            frames += samples.count / 2
        }
        let count = Double(max(1, frames))
        return ((sums.left / count).squareRoot(), (sums.right / count).squareRoot())
    }

    @Test func mixesMicrophoneAndSystemAudioIntoOneTrack() async throws {
        let recording = try await makeRecording(seconds: 2)
        #expect(try await AudioTrackMixer.audioTrackCount(of: recording) == 2)

        let mixed = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        try await AudioTrackMixer.mixAudioTracks(of: recording, to: mixed)

        let asset = AVURLAsset(url: mixed)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 2) < 0.1)

        let levels = try await channelLevels(of: mixed)
        // The mono microphone is heard on both sides...
        #expect(levels.right > 0.05)
        // ...and the system audio adds its left-only tone.
        #expect(levels.left > levels.right * 1.2)
    }
}
