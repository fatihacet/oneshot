import AppKit
import AVFoundation
import OneShotCore
import ScreenCaptureKit

enum RecordingFormat {
    case video
    case gif

    var fileExtension: String { self == .video ? "mp4" : "gif" }
}

/// Runs a screen recording: region selection, countdown, recording, and post-processing.
@MainActor
final class RecordingController {
    static let shared = RecordingController()

    private var recorder: ScreenRecorder?
    private var format = RecordingFormat.video
    private var frameWindow: RegionFrameWindow?
    private var isStarting = false
    private var context: (appName: String?, windowTitle: String?) = (nil, nil)

    var isRecording: Bool { recorder != nil }

    /// Starts a recording, or stops the current one.
    func toggle(format: RecordingFormat, delay: TimeInterval = 0) {
        if isRecording {
            stop()
        } else {
            start(format: format, delay: delay)
        }
    }

    private func start(format: RecordingFormat, delay: TimeInterval) {
        guard !isStarting else { return }
        guard Permissions.hasScreenRecording else {
            Permissions.requestScreenRecording()
            Permissions.presentScreenRecordingAlert()
            return
        }
        isStarting = true
        self.format = format
        Task {
            defer { isStarting = false }
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            do {
                try await selectAndRecord()
            } catch {
                NSLog("OneShot: recording failed: \(error)")
                cleanUpUI()
                Toast.show("Recording failed: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    private func selectAndRecord() async throws {
        context = ScreenCapturer.frontmostContext()
        let windows = ScreenCapturer.onScreenWindows()
        let snapshots = try await ScreenCapturer.snapshotDisplays(includingWindows: PinManager.shared.windowIDs)
        let overlay = SelectionOverlayController(snapshots: snapshots, windows: windows, initialMode: .area, allowsWindowMode: true)
        let selection = await overlay.run()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownApps = content.applications.filter { $0.processID == getpid() }
        let keptWindows = content.windows.filter {
            PinManager.shared.windowIDs.contains($0.windowID) || ScreenCapturer.isOwnRegularWindow($0)
        }

        let filter: SCContentFilter
        let pixelSize: CGSize
        var sourceRect: CGRect?
        var frame: CGRect?

        switch selection {
        case .cancelled:
            return
        case .area(let snapshot, let rect):
            guard let display = content.displays.first(where: { $0.displayID == snapshot.displayID }) else {
                throw CaptureError.displayNotFound
            }
            // Excluding the app (not just its current windows) also hides toasts shown while recording.
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: keptWindows)
            let isFullScreen = rect.size == snapshot.screen.frame.size
            sourceRect = isFullScreen ? nil : CGRect(
                x: rect.minX, y: snapshot.screen.frame.height - rect.maxY, width: rect.width, height: rect.height
            )
            pixelSize = CGSize(width: rect.width * snapshot.scale, height: rect.height * snapshot.scale)
            if !isFullScreen {
                frame = rect.offsetBy(dx: snapshot.screen.frame.minX, dy: snapshot.screen.frame.minY)
            }
        case .window(let info, let localRect, let snapshot):
            guard let window = content.windows.first(where: { $0.windowID == info.id }) else {
                throw CaptureError.windowNotFound
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            let contentInfo = SCShareableContent.info(for: filter)
            let scale = CGFloat(contentInfo.pointPixelScale)
            pixelSize = CGSize(width: contentInfo.contentRect.width * scale, height: contentInfo.contentRect.height * scale)
            frame = localRect.offsetBy(dx: snapshot.screen.frame.minX, dy: snapshot.screen.frame.minY)
            context = (info.ownerName, info.title)
        }

        if let frame {
            let window = RegionFrameWindow(around: frame, color: .systemRed)
            window.orderFrontRegardless()
            frameWindow = window
        }

        let countdown = Preferences.recordCountdown
        if countdown > 0 {
            guard await Countdown.run(seconds: countdown, on: NSScreen.underMouse) else {
                cleanUpUI()
                return
            }
        }

        let recorder = ScreenRecorder()
        recorder.onFailure = { error in
            Task { @MainActor in
                Toast.show("Recording stopped: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill", duration: 4)
                RecordingController.shared.stop()
            }
        }
        try await recorder.start(
            filter: filter,
            pixelSize: pixelSize,
            sourceRect: sourceRect,
            showsCursor: Preferences.recordCursor,
            capturesAudio: Preferences.recordAudio && format == .video
        )
        self.recorder = recorder
        if Preferences.playSound { NSSound(named: "Tink")?.play() }
        StatusBarController.shared?.showRecording(since: Date()) { [weak self] in self?.stop() }
    }

    func stop() {
        guard let recorder else { return }
        self.recorder = nil
        cleanUpUI()
        let format = format
        let context = context
        Task {
            guard let videoURL = await recorder.stop() else {
                Toast.show("Nothing was recorded", symbol: "exclamationmark.triangle.fill")
                return
            }
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

    /// Moves the video into the save folder, converting it to GIF first if needed.
    private func finish(videoURL: URL, format: RecordingFormat, context: (appName: String?, windowTitle: String?)) async throws -> URL {
        let destination = try ImageExporter.destinationURL(fileExtension: format.fileExtension, appName: context.appName)
        switch format {
        case .video:
            try FileManager.default.moveItem(at: videoURL, to: destination)
        case .gif:
            Toast.show("Creating GIF…", symbol: "photo.stack", duration: 300)
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
