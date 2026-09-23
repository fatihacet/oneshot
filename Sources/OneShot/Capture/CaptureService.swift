import AppKit

/// Entry point for every capture flow: runs the capture, then hands the result to the output pipeline.
@MainActor
final class CaptureService {
    static let shared = CaptureService()

    enum Output {
        /// Run the configured after-capture actions (clipboard, file, Quick Access).
        case image
        /// Copy to the clipboard only: no Quick Access preview, no file.
        case clipboardOnly
        /// Upload and copy the link: no Quick Access preview, no file.
        case upload
        /// Recognize text in the selection and copy it.
        case text
    }

    private var isBusy = false
    private var overlay: SelectionOverlayController?

    // MARK: Public flows

    /// - Parameter timer: Seconds to count down after the selection before capturing the live screen.
    func captureArea(startInWindowMode: Bool = false, output: Output = .image, timer: Int = 0, delay: TimeInterval = 0) {
        run(delay: delay) {
            let context = ScreenCapturer.frontmostContext()
            let windows = output != .text ? ScreenCapturer.onScreenWindows() : []
            let snapshots = try await ScreenCapturer.snapshotDisplays(includingWindows: PinManager.shared.windowIDs)
            let controller = SelectionOverlayController(
                snapshots: snapshots,
                windows: windows,
                initialMode: startInWindowMode ? .window : .area,
                allowsWindowMode: output != .text
            )
            self.overlay = controller
            let result = await controller.run()
            self.overlay = nil

            switch result {
            case .cancelled:
                return
            case .area(let snapshot, let rect):
                Preferences.lastArea = (snapshot.displayID, rect)
                var source = snapshot
                if timer > 0 {
                    guard await Countdown.run(seconds: timer, on: snapshot.screen) else { return }
                    let live = try await ScreenCapturer.snapshotDisplays(
                        only: snapshot.displayID, includingWindows: PinManager.shared.windowIDs
                    )
                    guard let first = live.first else { throw CaptureError.displayNotFound }
                    source = first
                }
                guard let image = source.crop(rect) else { throw CaptureError.emptyImage }
                let sourceRect = rect.offsetBy(dx: snapshot.screen.frame.minX, dy: snapshot.screen.frame.minY)
                self.deliver(Capture(image: image, scale: snapshot.scale, sourceRect: sourceRect, appName: context.appName, windowTitle: context.windowTitle), output: output)
            case .window(let info, let localRect, let snapshot):
                if timer > 0 {
                    guard await Countdown.run(seconds: timer, on: snapshot.screen) else { return }
                }
                let image = try await ScreenCapturer.captureWindow(id: info.id, includeShadow: Preferences.windowShadow)
                let sourceRect = localRect.offsetBy(dx: snapshot.screen.frame.minX, dy: snapshot.screen.frame.minY)
                self.deliver(Capture(image: image, scale: snapshot.scale, sourceRect: sourceRect, appName: info.ownerName, windowTitle: info.title), output: output)
            }
        }
    }

    /// Select a region, then scroll its content to capture more than fits on screen.
    func captureScrolling(delay: TimeInterval = 0) {
        run(delay: delay) {
            let context = ScreenCapturer.frontmostContext()
            let snapshots = try await ScreenCapturer.snapshotDisplays(includingWindows: PinManager.shared.windowIDs)
            let controller = SelectionOverlayController(
                snapshots: snapshots, windows: [], initialMode: .area, allowsWindowMode: false
            )
            self.overlay = controller
            let result = await controller.run()
            self.overlay = nil
            guard case .area(let snapshot, let rect) = result else { return }

            let session = ScrollingCaptureSession(
                screen: snapshot.screen, displayID: snapshot.displayID, rect: rect, scale: snapshot.scale
            )
            guard let image = await session.run() else { return }
            self.deliver(Capture(image: image, scale: snapshot.scale, sourceRect: nil, appName: context.appName, windowTitle: context.windowTitle), output: .image)
        }
    }

    func capturePreviousArea(delay: TimeInterval = 0) {
        guard let last = Preferences.lastArea else {
            captureArea(delay: delay)
            return
        }
        run(delay: delay) {
            let context = ScreenCapturer.frontmostContext()
            let snapshots = try await ScreenCapturer.snapshotDisplays(
                only: last.displayID, includingWindows: PinManager.shared.windowIDs
            )
            guard let snapshot = snapshots.first else { throw CaptureError.displayNotFound }
            let rect = last.rect.intersection(CGRect(origin: .zero, size: snapshot.screen.frame.size))
            guard !rect.isEmpty, let image = snapshot.crop(rect) else { throw CaptureError.emptyImage }
            let sourceRect = rect.offsetBy(dx: snapshot.screen.frame.minX, dy: snapshot.screen.frame.minY)
            self.deliver(Capture(image: image, scale: snapshot.scale, sourceRect: sourceRect, appName: context.appName, windowTitle: context.windowTitle), output: .image)
        }
    }

    func captureFullscreen(timer: Int = 0, delay: TimeInterval = 0) {
        run(delay: delay) {
            let screen = NSScreen.underMouse
            if timer > 0 {
                guard await Countdown.run(seconds: timer, on: screen) else { return }
            }
            let context = ScreenCapturer.frontmostContext()
            guard let displayID = screen?.displayID else { throw CaptureError.displayNotFound }
            let snapshots = try await ScreenCapturer.snapshotDisplays(
                only: displayID, includingWindows: PinManager.shared.windowIDs
            )
            guard let snapshot = snapshots.first else { throw CaptureError.displayNotFound }
            self.deliver(Capture(image: snapshot.image, scale: snapshot.scale, sourceRect: snapshot.screen.frame, appName: context.appName, windowTitle: context.windowTitle), output: .image)
        }
    }

    // MARK: Pipeline

    private func run(delay: TimeInterval = 0, _ body: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        guard Permissions.hasScreenRecording else {
            Permissions.requestScreenRecording()
            Permissions.presentScreenRecordingAlert()
            return
        }
        isBusy = true
        Task { @MainActor in
            defer { self.isBusy = false }
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            do {
                try await body()
            } catch {
                NSLog("OneShot: capture failed: \(error)")
                Toast.show("Capture failed: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    private func deliver(_ capture: Capture, output: Output) {
        var capture = capture
        switch output {
        case .text:
            TextRecognizer.recognizeAndCopy(capture.image)
        case .clipboardOnly:
            if Preferences.playSound { SoundPlayer.playCapture() }
            ImageExporter.copyToClipboard(capture)
            HistoryRecorder.record(&capture, savedURL: nil)
            Toast.show("Copied to clipboard")
        case .upload:
            if Preferences.playSound { SoundPlayer.playCapture() }
            HistoryRecorder.record(&capture, savedURL: nil)
            Uploader.shared.upload(capture)
        case .image:
            if Preferences.playSound { SoundPlayer.playCapture() }
            if Preferences.copyToClipboard { ImageExporter.copyToClipboard(capture) }

            var savedURL: URL?
            if Preferences.saveToDisk {
                do {
                    savedURL = try ImageExporter.save(capture)
                } catch {
                    Toast.show("Could not save: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
                }
            }
            HistoryRecorder.record(&capture, savedURL: savedURL)

            if Preferences.uploadAfterCapture, UploadSettings.isConfigured {
                Uploader.shared.upload(capture)
            }

            if Preferences.showQuickAccess {
                QuickAccessManager.shared.show(capture, savedURL: savedURL)
            } else if Preferences.copyToClipboard {
                Toast.show("Copied to clipboard")
            } else if let savedURL {
                Toast.show("Saved to \(savedURL.deletingLastPathComponent().lastPathComponent)")
            }
        }
    }
}

enum SoundPlayer {
    private static let captureSound = NSSound(
        contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif",
        byReference: true
    )

    static func playCapture() {
        captureSound?.stop()
        captureSound?.play()
    }
}
