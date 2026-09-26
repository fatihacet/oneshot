import AppKit
import AVFoundation
import OneShotCore
import SwiftUI

enum RecordingCaptureMode: String, CaseIterable, Identifiable {
    case screen
    case window
    case area

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screen: return "Full Screen"
        case .window: return "Window"
        case .area: return "Area"
        }
    }

    var symbol: String {
        switch self {
        case .screen: return "display"
        case .window: return "macwindow"
        case .area: return "rectangle.dashed"
        }
    }
}

/// What the user picked in the recording panel. The camera is not part of it: the bubble is already on
/// screen and is recorded like any other window.
struct RecordingOptions {
    var mode: RecordingCaptureMode
    var displayID: CGDirectDisplayID?
    var resolution: RecordingResolution
    var microphone: AVCaptureDevice?
    var systemAudio: Bool
}

/// State of the recording panel. Choices are remembered for the next recording.
@MainActor
final class RecordingSetupModel: ObservableObject {
    struct DeviceChoice: Identifiable, Hashable {
        let id: String
        let name: String
    }

    struct ScreenChoice: Identifiable, Hashable {
        let id: CGDirectDisplayID
        let name: String
    }

    @Published var mode: RecordingCaptureMode {
        didSet { Preferences.recordMode = mode }
    }
    @Published var displayID: CGDirectDisplayID {
        didSet {
            Preferences.recordDisplayID = displayID
            if let screen = selectedScreen { CameraBubble.shared.place(on: screen) }
        }
    }
    @Published var resolution: RecordingResolution {
        didSet { Preferences.recordResolution = resolution }
    }
    @Published var cameraID: String {
        didSet {
            guard cameraID != oldValue else { return }
            Preferences.recordCameraID = cameraID
            updateCamera()
        }
    }
    @Published var microphoneID: String {
        didSet {
            guard microphoneID != oldValue else { return }
            Preferences.recordMicrophoneID = microphoneID
            updateMicrophone()
        }
    }
    @Published var systemAudio: Bool {
        didSet { Preferences.recordAudio = systemAudio }
    }

    @Published private(set) var screens: [ScreenChoice] = []
    @Published private(set) var cameras: [DeviceChoice] = []
    @Published private(set) var microphones: [DeviceChoice] = []
    /// Microphone input level from 0 to 1, for the meter.
    @Published private(set) var microphoneLevel: Float = 0
    @Published private(set) var cameraDenied = false
    @Published private(set) var microphoneDenied = false
    @Published private(set) var deviceError: String?

    private var isActive = false
    private var meter: MicrophoneCapture?
    private let meterQueue = DispatchQueue(label: "dev.oneshot.microphone-meter")
    private var observers: [NSObjectProtocol] = []

    init() {
        mode = Preferences.recordMode
        resolution = Preferences.recordResolution
        systemAudio = Preferences.recordAudio
        let connected = NSScreen.screens.compactMap(\.displayID)
        displayID = Preferences.recordDisplayID.flatMap { connected.contains($0) ? $0 : nil }
            ?? NSScreen.underMouse?.displayID ?? connected.first ?? CGMainDisplayID()
        cameraID = CaptureDevices.device(for: Preferences.recordCameraID, mediaType: .video)?.uniqueID ?? CaptureDevices.noDevice
        microphoneID = CaptureDevices.device(for: Preferences.recordMicrophoneID, mediaType: .audio)?.uniqueID
            ?? CaptureDevices.noDevice
        refreshDevices()
    }

    var selectedScreen: NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID }
    }

    var options: RecordingOptions {
        RecordingOptions(
            mode: mode,
            displayID: displayID,
            resolution: resolution,
            microphone: CaptureDevices.isAuthorized(for: .audio)
                ? CaptureDevices.device(for: microphoneID, mediaType: .audio) : nil,
            systemAudio: systemAudio
        )
    }

    /// Output size and expected file size for the chosen screen, e.g. "1670 × 1080 · about 25 MB per minute".
    var resolutionSummary: String {
        guard let screen = selectedScreen ?? NSScreen.main else { return "" }
        let native = CGSize(
            width: screen.frame.width * screen.backingScaleFactor,
            height: screen.frame.height * screen.backingScaleFactor
        )
        let size = resolution.outputSize(for: native)
        let bitRate = VideoEncoding.videoBitRate(
            pixelSize: size, frameRate: Preferences.recordFrameRate,
            codec: Preferences.recordCodec, quality: Preferences.recordQuality
        )
        let hasAudio = systemAudio || microphoneID != CaptureDevices.noDevice
        let megabytes = Int(VideoEncoding.megabytesPerMinute(videoBitRate: bitRate, hasAudio: hasAudio).rounded())
        let dimensions = "\(Int(size.width)) × \(Int(size.height))"
        return "\(mode == .screen ? dimensions : "Up to \(dimensions)") · about \(megabytes) MB per minute"
    }

    // MARK: Lifecycle

    /// Starts the camera preview and microphone meter. Call when the panel appears.
    func activate() {
        isActive = true
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDevices() }
            })
        }
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDevices() }
        })
        updateCamera()
        updateMicrophone()
    }

    /// Stops the microphone meter. The camera bubble stays up when a recording is about to start.
    func deactivate(keepingCamera: Bool) {
        isActive = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        stopMeter()
        if !keepingCamera { CameraBubble.shared.hide() }
    }

    private func refreshDevices() {
        screens = NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            let width = Int(screen.frame.width * screen.backingScaleFactor)
            let height = Int(screen.frame.height * screen.backingScaleFactor)
            return ScreenChoice(id: id, name: "\(screen.localizedName) (\(width) × \(height))")
        }
        cameras = CaptureDevices.cameras.map { DeviceChoice(id: $0.uniqueID, name: $0.localizedName) }
        microphones = CaptureDevices.microphones.map { DeviceChoice(id: $0.uniqueID, name: $0.localizedName) }
        // Unplugged devices fall back to the default one, or to none.
        if cameraID != CaptureDevices.noDevice, !cameras.contains(where: { $0.id == cameraID }) {
            cameraID = cameras.first?.id ?? CaptureDevices.noDevice
        }
        if microphoneID != CaptureDevices.noDevice, !microphones.contains(where: { $0.id == microphoneID }) {
            microphoneID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? microphones.first?.id ?? CaptureDevices.noDevice
        }
        if !screens.contains(where: { $0.id == displayID }), let first = screens.first {
            displayID = first.id
        }
    }

    // MARK: Camera

    private func updateCamera() {
        deviceError = nil
        cameraDenied = false
        guard isActive, let device = CaptureDevices.device(for: cameraID, mediaType: .video) else {
            CameraBubble.shared.hide()
            return
        }
        Task {
            let granted = await CaptureDevices.requestAccess(for: .video)
            guard isActive, cameraID == device.uniqueID else { return }
            guard granted else {
                cameraDenied = true
                CameraBubble.shared.hide()
                return
            }
            do {
                let screen = mode == .screen ? selectedScreen : NSScreen.underMouse
                try CameraBubble.shared.show(device: device, on: screen)
            } catch {
                deviceError = error.localizedDescription
            }
        }
    }

    // MARK: Microphone

    private func updateMicrophone() {
        stopMeter()
        deviceError = nil
        microphoneDenied = false
        guard isActive, let device = CaptureDevices.device(for: microphoneID, mediaType: .audio) else { return }
        Task {
            let granted = await CaptureDevices.requestAccess(for: .audio)
            guard isActive, microphoneID == device.uniqueID else { return }
            guard granted else {
                microphoneDenied = true
                return
            }
            startMeter(device: device)
        }
    }

    private func startMeter(device: AVCaptureDevice) {
        var peak: Float = 0
        var lastUpdate: CFTimeInterval = 0
        do {
            let meter = try MicrophoneCapture(device: device, queue: meterQueue) { [weak self] buffer in
                peak = max(peak, MicrophoneCapture.peakLevel(of: buffer))
                let now = CACurrentMediaTime()
                guard now - lastUpdate >= 1.0 / 20 else { return }
                lastUpdate = now
                // Map -50…0 dBFS onto the meter.
                let level = peak > 0 ? max(0, min(1, (20 * log10(peak) + 50) / 50)) : 0
                peak = 0
                Task { @MainActor in self?.microphoneLevel = level }
            }
            self.meter = meter
            DispatchQueue.global(qos: .userInitiated).async { meter.start() }
        } catch {
            deviceError = error.localizedDescription
        }
    }

    private func stopMeter() {
        microphoneLevel = 0
        guard let meter else { return }
        self.meter = nil
        DispatchQueue.global(qos: .userInitiated).async { meter.stop() }
    }
}

/// The floating "Record Screen" panel: what to record, resolution, camera, microphone and system audio.
final class RecordingSetupPanel: NSPanel {
    /// Called when the user closes the panel with the close button or Escape.
    var onCancel: (() -> Void)?

    init(model: RecordingSetupModel, onStart: @escaping () -> Void) {
        super.init(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let hosting = NSHostingController(rootView: RecordingSetupView(model: model, onStart: onStart))
        hosting.sizingOptions = [.preferredContentSize]
        contentViewController = hosting
        // Size the panel now so it can be placed; SwiftUI would otherwise resize it after it is shown.
        setContentSize(hosting.view.fittingSize)
        title = "Record Screen"
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        level = .floating
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    override func close() {
        super.close()
        let onCancel = onCancel
        self.onCancel = nil
        onCancel?()
    }

    /// Closes the panel without reporting a cancellation.
    func dismiss() {
        onCancel = nil
        close()
    }

    /// Puts the panel in the top-right corner of `screen`, next to the menu bar, like Loom.
    func place(on screen: NSScreen) {
        let visible = screen.visibleFrame
        setFrameOrigin(CGPoint(x: visible.maxX - frame.width - 16, y: visible.maxY - frame.height - 16))
    }
}

private struct RecordingSetupView: View {
    @ObservedObject var model: RecordingSetupModel
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            modePicker
                .padding(.horizontal, 20)
                .padding(.top, 16)
            Form {
                Section {
                    if model.mode == .screen, model.screens.count > 1 {
                        Picker("Screen", selection: $model.displayID) {
                            ForEach(model.screens) { Text($0.name).tag($0.id) }
                        }
                    }
                    Picker("Resolution", selection: $model.resolution) {
                        ForEach(RecordingResolution.allCases) { Text($0.title).tag($0) }
                    }
                    Text(model.resolutionSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Picker(selection: $model.cameraID) {
                        Text("No Camera").tag(CaptureDevices.noDevice)
                        ForEach(model.cameras) { Text($0.name).tag($0.id) }
                    } label: {
                        Label("Camera", systemImage: "video")
                    }
                    if model.cameraDenied {
                        PermissionRow(message: "OneShot is not allowed to use the camera.", mediaType: .video)
                    }
                    Picker(selection: $model.microphoneID) {
                        Text("No Microphone").tag(CaptureDevices.noDevice)
                        ForEach(model.microphones) { Text($0.name).tag($0.id) }
                    } label: {
                        Label("Microphone", systemImage: "mic")
                    }
                    if model.microphoneDenied {
                        PermissionRow(message: "OneShot is not allowed to use the microphone.", mediaType: .audio)
                    } else if model.microphoneID != CaptureDevices.noDevice {
                        LevelMeter(level: model.microphoneLevel)
                    }
                    Toggle(isOn: $model.systemAudio) {
                        Label("System audio", systemImage: "speaker.wave.2")
                    }
                    if let error = model.deviceError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            Button(action: onStart) {
                Label("Start Recording", systemImage: "record.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.horizontal, 20)

            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)
        }
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var modePicker: some View {
        HStack(spacing: 8) {
            ForEach(RecordingCaptureMode.allCases) { mode in
                let isSelected = model.mode == mode
                Button { model.mode = mode } label: {
                    VStack(spacing: 6) {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 20))
                            .frame(height: 24)
                        Text(mode.title)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var footnote: String {
        let next: String
        switch model.mode {
        case .screen: next = ""
        case .window: next = "Next, click the window to record. "
        case .area: next = "Next, drag to select an area. "
        }
        let countdown = Preferences.recordCountdown
        let start = countdown > 0 ? "Recording starts after a \(countdown) second countdown. " : ""
        return next + start + "Stop it from the menu bar."
    }
}

private struct PermissionRow: View {
    let message: String
    let mediaType: AVMediaType

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
            Spacer()
            Button("Open Settings") { CaptureDevices.openPrivacySettings(for: mediaType) }
                .controlSize(.small)
        }
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(level > 0.9 ? Color.orange : Color.green)
                    .frame(width: proxy.size.width * CGFloat(level))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
        .frame(height: 6)
        .accessibilityLabel("Microphone level")
    }
}
