import AVFoundation
import Foundation

/// Mixes all audio tracks of a recording into one.
///
/// Recordings keep system audio and the microphone in separate tracks while recording. Browsers, Slack
/// and most players only play the first audio track, so the tracks are mixed before the file is shared.
/// Video is copied as is, so this takes seconds even for long recordings.
public enum AudioTrackMixer {
    public enum MixError: LocalizedError {
        case cannotRead(Error?)
        case cannotWrite(Error?)

        public var errorDescription: String? {
            switch self {
            case .cannotRead(let error): return "Could not read the recording. \(error?.localizedDescription ?? "")"
            case .cannotWrite(let error): return "Could not write the recording. \(error?.localizedDescription ?? "")"
            }
        }
    }

    public static func audioTrackCount(of url: URL) async throws -> Int {
        try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).count
    }

    public static func mixAudioTracks(of inputURL: URL, to outputURL: URL, fileType: AVFileType = .mp4) async throws {
        let asset = AVURLAsset(url: inputURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)

        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw MixError.cannotRead(error)
        }
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        } catch {
            throw MixError.cannotWrite(error)
        }

        var pumps: [SamplePump] = []
        for track in videoTracks {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(
                mediaType: .video, outputSettings: nil,
                sourceFormatHint: try await track.load(.formatDescriptions).first
            )
            input.transform = try await track.load(.preferredTransform)
            pumps.append(SamplePump(output: output, input: input))
        }
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: VideoEncoding.audioBitRate,
            ])
            pumps.append(SamplePump(output: output, input: input))
        }

        for pump in pumps {
            guard reader.canAdd(pump.output) else { throw MixError.cannotRead(nil) }
            reader.add(pump.output)
            guard writer.canAdd(pump.input) else { throw MixError.cannotWrite(nil) }
            writer.add(pump.input)
        }
        guard reader.startReading() else { throw MixError.cannotRead(reader.error) }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw MixError.cannotWrite(writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        // Each track is copied on its own queue so the writer can interleave them.
        await withTaskGroup(of: Void.self) { group in
            for pump in pumps {
                group.addTask { await pump.run(cancelling: reader) }
            }
        }

        guard reader.status == .completed else {
            writer.cancelWriting()
            throw MixError.cannotRead(reader.error)
        }
        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()
        guard writer.status == .completed else { throw MixError.cannotWrite(writer.error) }
    }
}

/// Copies samples from a reader output to a writer input until the output runs dry.
private final class SamplePump: @unchecked Sendable {
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "dev.oneshot.audio-mixer")

    init(output: AVAssetReaderOutput, input: AVAssetWriterInput) {
        self.output = output
        self.input = input
    }

    func run(cancelling reader: AVAssetReader) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var isDone = false
            input.requestMediaDataWhenReady(on: queue) { [self] in
                func finish() {
                    isDone = true
                    input.markAsFinished()
                    continuation.resume()
                }
                guard !isDone else { return }
                while input.isReadyForMoreMediaData {
                    // Nil means the track is done, or reading failed.
                    guard let buffer = output.copyNextSampleBuffer() else { return finish() }
                    if !input.append(buffer) {
                        // The writer failed; stop the other tracks too.
                        reader.cancelReading()
                        return finish()
                    }
                }
            }
        }
    }
}
