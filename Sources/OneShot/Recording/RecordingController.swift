import AppKit
import AVFoundation
import OneShotCore
import ScreenCaptureKit

enum RecordingFormat {
    case video
    case gif

    var fileExtension: String { self == .video ? "mp4" : "gif" }
}

/// Runs a screen recording: the recording panel (videos only), region selection, countdown, recording,
/// and post-processing.
@MainActor
final class RecordingController {
    static let shared = RecordingController()

    private var recorder: ScreenRecorder?
    private var format = RecordingFormat.video
    private var frameWindow: RegionFrameWindow?
    private var isStarting = false
    private var context: (appName: String?, windowTitle: String?) = (nil, nil)
    private var setupPanel: RecordingSetupPanel?
    private var setupModel: RecordingSetupModel?
    /// The app that was active before the panel opened; it gets focus back when recording starts.
    private var previousApp: NSRunningApplication?

    var isRecording: Bool { recorder != nil }

    /// Stops the current recording. Otherwise videos open the recording panel (or close it if it is
    /// already open) and GIFs go straight to area selection.
    func toggle(format: RecordingFormat, delay: TimeInterval = 0) {
        if isRecording {
            stop()
        } else if setupPanel != nil {
            setupPanel?.performClose(nil)
        } else if !isStarting {
            if format == .video {
                showSetup()
            } else {
                start(format: format, options: nil, delay: delay)
            }
        }
    }

    // MARK: Recording panel

    private func showSetup() {
        guard Permissions.hasScreenRecording else {
            Permissions.requestScreenRecording()
            Permissions.presentScreenRecordingAlert()
            return
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        context = ScreenCapturer.frontmostContext()

        let model = RecordingSetupModel()
        let panel = RecordingSetupPanel(model: model) { [weak self] in self?.startFromSetup() }
        panel.onCancel = { [weak self] in self?.closeSetup(keepingCamera: false) }
        if let screen = NSScreen.underMouse { panel.place(on: screen) }
        setupModel = model
        setupPanel = panel
        CameraBubble.shared.onTurnOff = { [weak model] in model?.cameraID = CaptureDevices.noDevice }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        model.activate()
    }

    private func closeSetup(keepingCamera: Bool) {
        setupModel?.deactivate(keepingCamera: keepingCamera)
        setupModel = nil
        setupPanel?.dismiss()
        setupPanel = nil
        CameraBubble.shared.onTurnOff = nil
        if let previousApp, previousApp != NSRunningApplication.current {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate()
        }
    }

    private func startFromSetup() {
        guard let options = setupModel?.options else { return }
        closeSetup(keepingCamera: true)
        // Give the panel a moment to leave the screen before the selection overlay freezes it.
        start(format: .video, options: options, delay: 0.2)
    }

    // MARK: Recording

    private func start(format: RecordingFormat, options: RecordingOptions?, delay: TimeInterval) {
        guard !isStarting else { return }
        guard Permissions.hasScreenRecording else {
            Permissions.requestScreenRecording()
            Permissions.presentScreenRecordingAlert()
            return
        }
        isStarting = true
        self.format = format
        Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            do {
                let started = try await selectAndRecord(options: options)
                isStarting = false
                // Cancelling the selection or the countdown goes back to the panel.
                if !started, format == .video { showSetup() }
            } catch {
                isStarting = false
                NSLog("OneShot: recording failed: \(error)")
                cleanUpUI()
                CameraBubble.shared.hide()
                Toast.show("Recording failed: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    /// What to record, once the user has picked a screen, window or area.
    private struct Target {
        var filter: SCContentFilter
        /// Region of the display in points (top-left origin), or nil for everything the filter shows.
        var sourceRect: CGRect?
        /// Size of the recorded content in pixels, before scaling to the chosen resolution.
        var pixelSize: CGSize
        /// Region to outline while recording, in AppKit global coordinates. Nil for a whole screen.
        var frame: CGRect?
        var screen: NSScreen?
    }

    /// Returns false if the user cancelled.
    private func selectAndRecord(options: RecordingOptions?) async throws -> Bool {
        if options == nil { context = ScreenCapturer.frontmostContext() }
        guard let target = try await selectTarget(mode: options?.mode ?? .area, displayID: options?.displayID) else {
            return false
        }

        if let frame = target.frame {
            let window = RegionFrameWindow(around: frame, color: .systemRed)
            window.orderFrontRegardless()
            frameWindow = window
        }

        let countdown = Preferences.recordCountdown
        if countdown > 0 {
            guard await Countdown.run(seconds: countdown, on: target.screen ?? NSScreen.underMouse) else {
                cleanUpUI()
                return false
            }
        }

        let recorder = ScreenRecorder()
        recorder.onFailure = { error in
            Task { @MainActor in
                Toast.show("Recording stopped: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill", duration: 4)
                RecordingController.shared.stop()
            }
        }
        let resolution = options?.resolution ?? .original
        try await recorder.start(filter: target.filter, sourceRect: target.sourceRect, configuration: RecordingConfiguration(
            pixelSize: resolution.outputSize(for: target.pixelSize),
            frameRate: Preferences.recordFrameRate,
            codec: Preferences.recordCodec,
            quality: Preferences.recordQuality,
            showsCursor: Preferences.recordCursor,
            capturesSystemAudio: format == .video && (options?.systemAudio ?? false),
            microphone: format == .video ? options?.microphone : nil
        ))
        self.recorder = recorder
        if Preferences.playSound { NSSound(named: "Tink")?.play() }
        StatusBarController.shared?.showRecording(since: Date()) { [weak self] in self?.stop() }
        return true
    }

    /// Shows the selection overlay for areas and windows. Returns nil if the user cancelled.
    private func selectTarget(mode: RecordingCaptureMode, displayID: CGDirectDisplayID?) async throws -> Target? {
        var selection: SelectionResult?
        if mode != .screen {
            let windows = ScreenCapturer.onScreenWindows()
            let snapshots = try await ScreenCapturer.snapshotDisplays(includingWindows: PinManager.shared.windowIDs)
            let overlay = SelectionOverlayController(
                snapshots: snapshots, windows: windows,
                initialMode: mode == .window ? .window : .area, allowsWindowMode: true
            )
            selection = await overlay.run()
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownApps = content.applications.filter { $0.processID == getpid() }
        var keptWindows = content.windows.filter {
            PinManager.shared.windowIDs.contains($0.windowID) || ScreenCapturer.isOwnRegularWindow($0)
        }
        let bubble = CameraBubble.shared
        let bubbleWindow = format == .video
            ? bubble.windowID.flatMap { id in content.windows.first { $0.windowID == id } }
            : nil
        if let bubbleWindow { keptWindows.append(bubbleWindow) }

        switch selection {
        case .cancelled:
            return nil
        case nil:
            guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) ?? NSScreen.underMouse,
                  let display = content.displays.first(where: { $0.displayID == screen.displayID })
            else { throw CaptureError.displayNotFound }
            // Excluding the app (not just its current windows) also hides toasts shown while recording.
            return Target(
                filter: SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: keptWindows),
                pixelSize: CGSize(
                    width: screen.frame.width * screen.backingScaleFactor,
                    height: screen.frame.height * screen.backingScaleFactor
                ),
                screen: screen
            )
        case .area(let snapshot, let rect):
            guard let display = content.displays.first(where: { $0.displayID == snapshot.displayID }) else {
                throw CaptureError.displayNotFound
            }
            let isFullScreen = rect.size == snapshot.screen.frame.size
            let globalRect = rect.offsetBy(dx: snapshot.screen.frame.minX, dy: snapshot.screen.frame.minY)
            if !isFullScreen { bubble.keep(inside: globalRect) }
            return Target(
                filter: SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: keptWindows),
                sourceRect: isFullScreen ? nil : CGRect(
                    x: rect.minX, y: snapshot.screen.frame.height - rect.maxY, width: rect.width, height: rect.height
                ),
                pixelSize: CGSize(width: rect.width * snapshot.scale, height: rect.height * snapshot.scale),
                frame: isFullScreen ? nil : globalRect,
                screen: snapshot.screen
            )
        case .window(let info, let localRect, let snapshot):
            guard let window = content.windows.first(where: { $0.windowID == info.id }) else {
                throw CaptureError.windowNotFound
            }
            context = (info.ownerName, info.title)
            let globalRect = localRect.offsetBy(dx: snapshot.screen.frame.minX, dy: snapshot.screen.frame.minY)
            if let bubbleWindow, let display = content.displays.first(where: { $0.displayID == snapshot.displayID }) {
                // A single-window filter would leave the camera out, so record the window's part of the
                // display with nothing but the window and the camera bubble in it.
                bubble.keep(inside: globalRect)
                let bounds = CGDisplayBounds(snapshot.displayID)
                let sourceRect = info.frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
                    .intersection(CGRect(origin: .zero, size: bounds.size))
                return Target(
                    filter: SCContentFilter(display: display, including: [window, bubbleWindow]),
                    sourceRect: sourceRect,
                    pixelSize: CGSize(width: sourceRect.width * snapshot.scale, height: sourceRect.height * snapshot.scale),
                    frame: globalRect,
                    screen: snapshot.screen
                )
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let contentInfo = SCShareableContent.info(for: filter)
            let scale = CGFloat(contentInfo.pointPixelScale)
            return Target(
                filter: filter,
                pixelSize: CGSize(width: contentInfo.contentRect.width * scale, height: contentInfo.contentRect.height * scale),
                frame: globalRect,
                screen: snapshot.screen
            )
        }
    }

    func stop() {
        guard let recorder else { return }
        self.recorder = nil
        cleanUpUI()
        CameraBubble.shared.hide()
        let format = format
        let context = context
        Task {
            guard let recordedURL = await recorder.stop() else {
                Toast.show("Nothing was recorded", symbol: "exclamationmark.triangle.fill")
                return
            }
            let videoURL = await Self.mixingAudioTracks(of: recordedURL)
            let thumbnail = await Self.thumbnail(for: videoURL)
            do {
                let url = try await finish(videoURL: videoURL, format: format, context: context)
                if format == .gif { try? FileManager.default.removeItem(at: videoURL) }
                if Preferences.playSound { SoundPlayer.playCapture() }
                if let thumbnail {
                    QuickAccessManager.shared.showRecording(at: url, thumbnail: thumbnail)
                } else {
                    Toast.show("Saved to \(url.deletingLastPathComponent().lastPathComponent)")
                }
            } catch {
                Toast.show("Could not save the recording: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    private func cleanUpUI() {
        frameWindow?.orderOut(nil)
        frameWindow = nil
        StatusBarController.shared?.hideRecording()
    }

    /// Browsers and most players only play a video's first audio track, so the microphone and system
    /// audio tracks are mixed into one. Returns the original file if there is nothing to mix or mixing fails.
    private static func mixingAudioTracks(of url: URL) async -> URL {
        guard (try? await AudioTrackMixer.audioTrackCount(of: url)) ?? 0 > 1 else { return url }
        Toast.show("Finishing recording…", symbol: "waveform", duration: 600)
        defer { Toast.hide() }
        let mixedURL = url.deletingLastPathComponent().appendingPathComponent("OneShot-\(UUID().uuidString).mp4")
        do {
            try await AudioTrackMixer.mixAudioTracks(of: url, to: mixedURL)
            try? FileManager.default.removeItem(at: url)
            return mixedURL
        } catch {
            // QuickTime still plays both tracks of the unmixed file, so keep it rather than lose the recording.
            NSLog("OneShot: mixing audio tracks failed: \(error)")
            try? FileManager.default.removeItem(at: mixedURL)
            return url
        }
    }

    /// Moves the video into the save folder, converting it to GIF first if needed.
    private func finish(videoURL: URL, format: RecordingFormat, context: (appName: String?, windowTitle: String?)) async throws -> URL {
        let destination = try ImageExporter.destinationURL(fileExtension: format.fileExtension, appName: context.appName)
        switch format {
        case .video:
            try FileManager.default.moveItem(at: videoURL, to: destination)
        case .gif:
            Toast.show("Creating GIF…", symbol: "photo.stack", duration: 300)
            defer { Toast.hide() }
            try await GIFConverter.convert(
                videoAt: videoURL, to: destination,
                fps: max(5, Preferences.gifFrameRate), maxWidth: max(320, Preferences.gifMaxWidth)
            )
        }
        return destination
    }

    private static func thumbnail(for videoURL: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        return try? await generator.image(at: .zero).image
    }
}
