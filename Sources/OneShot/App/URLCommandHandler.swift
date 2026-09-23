import AppKit

/// Handles `oneshot://` URLs, used by the `oneshot` command line tool, Raycast, Alfred and Shortcuts.
///
/// Every shortcut action is available by its kebab-case name, e.g. `oneshot://capture-area`,
/// `oneshot://record-gif` or `oneshot://open-history`. Capture commands accept `?timer=<seconds>`.
@MainActor
enum URLCommandHandler {
    static let scheme = "oneshot"

    /// Commands beyond the shortcut actions.
    private static let extraCommands: [String: () -> Void] = [
        "stop-recording": { if RecordingController.shared.isRecording { RecordingController.shared.stop() } },
        "pin-clipboard": {
            if !PinManager.shared.pinFromClipboard() { Toast.show("No image on the clipboard", symbol: "doc.on.clipboard") }
        },
        "upload-clipboard": { Uploader.shared.uploadClipboardImage() },
        "annotate-clipboard": { AnnotationEditorWindowController.shared.openClipboardImage() },
        "background-clipboard": { BackgroundToolWindowController.shared.openClipboardImage() },
        "open-settings": { SettingsWindowController.shared.show() },
        "setup": { OnboardingWindowController.shared.show() },
    ]

    /// All supported command names, for help output and docs.
    static var commandNames: [String] {
        ShortcutAction.allCases.map { commandName(for: $0) } + extraCommands.keys.sorted()
    }

    /// `captureAreaToClipboard` → `capture-area-to-clipboard`, `recordGIF` → `record-gif`.
    static func commandName(for action: ShortcutAction) -> String {
        var result = ""
        var previous: Character?
        for character in action.rawValue {
            if character.isUppercase, previous?.isLowercase == true { result += "-" }
            result += character.lowercased()
            previous = character
        }
        return result
    }

    static func handle(_ url: URL) {
        guard url.scheme?.lowercased() == scheme else { return }
        // Accept both oneshot://capture-area and oneshot:capture-area.
        let command = (url.host ?? url.path).trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let timer = query.first { $0.name == "timer" }.flatMap { $0.value.flatMap(Int.init) } ?? 0

        if let action = ShortcutAction.allCases.first(where: { commandName(for: $0) == command }) {
            switch (action, timer) {
            case (.captureArea, 1...): CaptureService.shared.captureArea(timer: timer)
            case (.captureFullscreen, 1...): CaptureService.shared.captureFullscreen(timer: timer)
            default: action.perform()
            }
        } else if let extra = extraCommands[command] {
            extra()
        } else {
            Toast.show("Unknown command: \(command)", symbol: "questionmark.circle")
        }
    }
}
