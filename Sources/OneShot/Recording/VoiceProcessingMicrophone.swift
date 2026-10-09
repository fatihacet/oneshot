import AVFoundation
import CoreAudio

/// Captures a microphone through voice processing, as 48 kHz mono float samples.
///
/// Voice processing is what FaceTime uses: it removes echo from the speakers, and the Mic Mode picked
/// in Control Center applies to it (Voice Isolation removes background noise). Apps cannot pick the
/// mode themselves. Buffers carry the host time they were captured at, which ScreenCaptureKit also
/// uses, so the voice lines up with the screen. The handler is called on the queue passed to `init`.
final class VoiceProcessingMicrophone: @unchecked Sendable {
    private static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true
    )!

    private let engine = AVAudioEngine()
    private let device: AVCaptureDevice
    private let queue: DispatchQueue
    private let handler: (CMSampleBuffer) -> Void
    /// Serializes starting, stopping and restarting the engine.
    private let control = DispatchQueue(label: "dev.oneshot.voice-processing")
    private var isRunning = false
    private var configurationObserver: NSObjectProtocol?

    init(device: AVCaptureDevice, queue: DispatchQueue, handler: @escaping (CMSampleBuffer) -> Void) throws {
        self.device = device
        self.queue = queue
        self.handler = handler
        let input = engine.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
            // Voice processing turns other audio down, which would also quieten the system audio in
            // the recording.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(
                enableAdvancedDucking: false, duckingLevel: .min
            )
            try configure()
        } catch {
            NSLog("OneShot: could not set up voice processing for \(device.localizedName): \(error)")
            throw CaptureDeviceError.unavailable(device.localizedName)
        }
        engine.prepare()
    }

    /// Blocks until the microphone is running, so call it off the main thread.
    func start() throws {
        try control.sync {
            do {
                try engine.start()
            } catch {
                NSLog("OneShot: could not start voice processing for \(device.localizedName): \(error)")
                throw CaptureDeviceError.unavailable(device.localizedName)
            }
            isRunning = true
            // The engine stops itself when the input or output hardware changes, e.g. when headphones
            // are connected.
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                self?.control.async { self?.restart() }
            }
        }
    }

    func stop() {
        control.sync {
            isRunning = false
            if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
            configurationObserver = nil
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
    }

    /// Called on `control` after a hardware change stopped the engine.
    private func restart() {
        guard isRunning else { return }
        engine.stop()
        do {
            try configure()
            try engine.start()
        } catch {
            NSLog("OneShot: could not restart voice processing for \(device.localizedName): \(error)")
        }
    }

    /// Selects the microphone, connects the output and installs the tap that delivers the samples.
    private func configure() throws {
        let input = engine.inputNode
        try Self.select(device, on: input)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: Self.format)
        else { throw CaptureDeviceError.unavailable(device.localizedName) }
        // Every channel carries the processed voice. Without a map, the converter turns the discrete
        // channels into silence.
        converter.channelMap = [0]
        // Voice processing also runs the output, for echo cancellation, and fails every 10 ms without a
        // source. The mixer plays silence; its format must match the input's.
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: inputFormat)
        // The converter holds back part of each buffer, so its output can start before the buffer that
        // went in. Counting the frames in and out places the output on the timeline.
        var framesIn = 0.0
        var framesOut = 0.0
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4_800, format: inputFormat) { [queue, handler] buffer, time in
            let output = Self.convert(buffer, with: converter)
            let heldBack = framesIn - framesOut * inputFormat.sampleRate / Self.format.sampleRate
            framesIn += Double(buffer.frameLength)
            framesOut += Double(output?.frameLength ?? 0)
            guard time.isHostTimeValid, let output else { return }
            let start = CMClockMakeHostTimeFromSystemUnits(time.hostTime) - CMTime(
                seconds: heldBack / inputFormat.sampleRate, preferredTimescale: CMTimeScale(Self.format.sampleRate)
            )
            guard let sampleBuffer = Self.sampleBuffer(from: output, at: start) else { return }
            queue.async { handler(sampleBuffer) }
        }
    }

    /// Points the input node at `device`. The voice processing unit takes its input device on the input
    /// element; `AUAudioUnit.setDeviceID` would change its output device instead.
    private static func select(_ device: AVCaptureDevice, on input: AVAudioInputNode) throws {
        guard var id = audioDeviceID(for: device), let unit = input.audioUnit else {
            throw CaptureDeviceError.unavailable(device.localizedName)
        }
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 1,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    /// The Core Audio device behind a microphone, whose unique ID is the Core Audio device UID.
    private static func audioDeviceID(for device: AVCaptureDevice) -> AudioDeviceID? {
        var uid = device.uniqueID as CFString
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &uid) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), qualifier, &size, &id
            )
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    /// Converts a buffer from the input node to `format`. Returns nil while the converter fills up.
    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(
            (Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate).rounded(.up)
        ) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    private static func sampleBuffer(from output: AVAudioPCMBuffer, at time: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: format.formatDescription, sampleCount: CMItemCount(output.frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer,
            CMSampleBufferSetDataBufferFromAudioBufferList(
                sampleBuffer, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0, bufferList: output.audioBufferList
            ) == noErr
        else { return nil }
        return sampleBuffer
    }
}

/// Calls `onChange` on the main queue when the user picks another Mic Mode in Control Center.
final class MicrophoneModeObserver: NSObject {
    private static let keyPath = "preferredMicrophoneMode"
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        super.init()
        // The mode is a key-value observable class property.
        (AVCaptureDevice.self as AnyObject).addObserver(self, forKeyPath: Self.keyPath, options: [], context: nil)
    }

    deinit {
        (AVCaptureDevice.self as AnyObject).removeObserver(self, forKeyPath: Self.keyPath)
    }

    override func observeValue(
        forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        DispatchQueue.main.async { [onChange] in MainActor.assumeIsolated { onChange() } }
    }
}
