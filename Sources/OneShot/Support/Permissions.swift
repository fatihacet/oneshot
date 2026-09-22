import AppKit
import CoreGraphics

enum Permissions {
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the system prompt the first time; afterwards macOS only allows changes in System Settings.
    @discardableResult
    static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    @MainActor
    static func presentScreenRecordingAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission required"
        alert.informativeText = """
        OneShot needs Screen Recording permission to take screenshots. \
        Enable OneShot in System Settings › Privacy & Security › Screen & System Audio Recording, \
        then relaunch OneShot.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            openScreenRecordingSettings()
        }
    }
}
