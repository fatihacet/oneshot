import AppKit
import AVFoundation

/// Cameras and microphones for screen recordings, and their privacy permissions.
enum CaptureDevices {
    /// Stored device ID meaning "none".
    static let noDevice = "none"
    /// Stored device ID meaning "the system default".
    static let defaultDevice = "default"

    static var cameras: [AVCaptureDevice] {
        unique(AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video, position: .unspecified
        ).devices)
    }

    static var microphones: [AVCaptureDevice] {
        unique(AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified
        ).devices)
    }

    /// Resolves a stored ID. A device that is no longer connected falls back to the default one.
    static func device(for id: String, mediaType: AVMediaType) -> AVCaptureDevice? {
        guard id != noDevice else { return nil }
        let devices = mediaType == .video ? cameras : microphones
        return devices.first { $0.uniqueID == id } ?? AVCaptureDevice.default(for: mediaType) ?? devices.first
    }

    private static func unique(_ devices: [AVCaptureDevice]) -> [AVCaptureDevice] {
        var seen: Set<String> = []
        return devices.filter { seen.insert($0.uniqueID).inserted }
    }

    // MARK: Permissions

    static func isAuthorized(for mediaType: AVMediaType) -> Bool {
        AVCaptureDevice.authorizationStatus(for: mediaType) == .authorized
    }

    static func isDenied(for mediaType: AVMediaType) -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: mediaType)
        return status == .denied || status == .restricted
    }

    /// Asks for access the first time; afterwards returns the stored decision.
    static func requestAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: mediaType)
        default: return false
        }
    }

    static func openPrivacySettings(for mediaType: AVMediaType) {
        let pane = mediaType == .video ? "Privacy_Camera" : "Privacy_Microphone"
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

enum CaptureDeviceError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let name): return "\(name) is not available. Another app may be using it."
        }
    }
}

/// Captures a microphone as 48 kHz mono float samples.
///
/// Buffers are retimed to the host clock, which ScreenCaptureKit also uses, so the voice lines up
/// with the screen. The handler is called on the queue passed to `init`.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let handler: (CMSampleBuffer) -> Void
    /// The session's clock, read on the first buffer. Only used on the handler queue.
    private var clock: CMClock?

    init(device: AVCaptureDevice, queue: DispatchQueue, handler: @escaping (CMSampleBuffer) -> Void) throws {
        self.handler = handler
        super.init()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw CaptureDeviceError.unavailable(device.localizedName)
        }
        session.addInput(input)
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
    }

    /// Blocks until the microphone is running, so call it off the main thread.
    func start() {
        session.startRunning()
    }

    func stop() {
        session.stopRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if clock == nil { clock = session.synchronizationClock }
        handler(Self.retimed(sampleBuffer, from: clock))
    }

    /// Moves a buffer's timestamps from the capture session's clock (usually the audio device clock)
    /// to the host clock.
    private static func retimed(_ buffer: CMSampleBuffer, from clock: CMClock?) -> CMSampleBuffer {
        guard let clock else { return buffer }
        let original = buffer.presentationTimeStamp
        let converted = CMSyncConvertTime(original, from: clock, to: CMClockGetHostTimeClock())
        guard converted.isValid, original.isValid else { return buffer }
        let offset = converted - original
        guard abs(offset.seconds) > 0.000_5, var timings = try? buffer.sampleTimingInfos() else { return buffer }
        for index in timings.indices {
            timings[index].presentationTimeStamp = timings[index].presentationTimeStamp + offset
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = timings[index].decodeTimeStamp + offset
            }
        }
        return (try? CMSampleBuffer(copying: buffer, withNewTiming: timings)) ?? buffer
    }

    /// The loudest sample in a buffer of float samples, from 0 to 1.
    static func peakLevel(of buffer: CMSampleBuffer) -> Float {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return 0 }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: &pointer
        ) == kCMBlockBufferNoErr, let pointer else { return 0 }
        let count = length / MemoryLayout<Float>.size
        return pointer.withMemoryRebound(to: Float.self, capacity: count) { samples in
            var peak: Float = 0
            for index in 0..<count { peak = max(peak, abs(samples[index])) }
            return min(1, peak)
        }
    }
}
