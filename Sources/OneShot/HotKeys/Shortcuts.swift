import AppKit
import Carbon.HIToolbox

/// Actions that can be triggered by a global shortcut.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case captureArea
    case captureAreaToClipboard
    case captureAreaAndUpload
    case capturePreviousArea
    case captureWindow
    case captureScrolling
    case captureFullscreen
    case captureAreaWithTimer
    case captureFullscreenWithTimer
    case captureText
    case recordVideo
    case recordGIF
    case openHistory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .captureArea: return "Capture Area"
        case .captureAreaToClipboard: return "Capture Area to Clipboard"
        case .captureAreaAndUpload: return "Capture Area and Upload"
        case .capturePreviousArea: return "Capture Previous Area"
        case .captureWindow: return "Capture Window"
        case .captureScrolling: return "Capture Scrolling Area"
        case .captureFullscreen: return "Capture Fullscreen"
        case .captureAreaWithTimer: return "Capture Area with Timer"
        case .captureFullscreenWithTimer: return "Capture Fullscreen with Timer"
        case .captureText: return "Capture Text (OCR)"
        case .recordVideo: return "Record Screen"
        case .recordGIF: return "Record GIF"
        case .openHistory: return "Open History"
        }
    }

    var subtitle: String? {
        switch self {
        case .captureAreaToClipboard: return "Copies only. No preview, no file."
        case .captureAreaAndUpload: return "Uploads and copies the link. No preview, no file."
        case .captureAreaWithTimer: return "Select an area, then capture after the self-timer."
        case .captureScrolling: return "Select an area, then scroll to capture long pages."
        case .recordVideo: return "Opens the recording panel. Press again to stop."
        case .recordGIF: return "Press again to stop. Return records the whole screen."
        default: return nil
        }
    }

    /// Capture actions are listed together at the top of the menu bar menu.
    var isCapture: Bool { self != .openHistory }

    var defaultHotKey: HotKey? {
        let commandShift = HotKey.command | HotKey.shift
        switch self {
        case .captureArea:
            return HotKey(keyCode: UInt32(kVK_ANSI_4), modifiers: commandShift)
        case .captureAreaToClipboard:
            return HotKey(keyCode: UInt32(kVK_ANSI_4), modifiers: commandShift | HotKey.control)
        case .captureAreaAndUpload:
            return HotKey(keyCode: UInt32(kVK_ANSI_4), modifiers: HotKey.command | HotKey.option)
        case .capturePreviousArea:
            return HotKey(keyCode: UInt32(kVK_ANSI_4), modifiers: commandShift | HotKey.option)
        case .captureWindow, .captureScrolling, .captureAreaWithTimer, .captureFullscreenWithTimer, .openHistory,
             .recordVideo, .recordGIF:
            return nil
        case .captureFullscreen:
            return HotKey(keyCode: UInt32(kVK_ANSI_3), modifiers: commandShift)
        case .captureText:
            return HotKey(keyCode: UInt32(kVK_ANSI_2), modifiers: commandShift)
        }
    }

    @MainActor
    func perform(delay: TimeInterval = 0) {
        let service = CaptureService.shared
        switch self {
        case .captureArea: service.captureArea(delay: delay)
        case .captureAreaToClipboard: service.captureArea(output: .clipboardOnly, delay: delay)
        case .captureAreaAndUpload:
            // Ask for setup before the selection rather than after the capture is taken.
            guard UploadSettings.isConfigured else {
                Uploader.showSetup()
                return
            }
            service.captureArea(output: .upload, delay: delay)
        case .capturePreviousArea: service.capturePreviousArea(delay: delay)
        case .captureWindow: service.captureArea(startInWindowMode: true, delay: delay)
        case .captureScrolling: service.captureScrolling(delay: delay)
        case .captureFullscreen: service.captureFullscreen(delay: delay)
        case .captureAreaWithTimer: service.captureArea(timer: Preferences.selfTimerSeconds, delay: delay)
        case .captureFullscreenWithTimer: service.captureFullscreen(timer: Preferences.selfTimerSeconds, delay: delay)
        case .captureText: service.captureArea(output: .text, delay: delay)
        case .recordVideo: RecordingController.shared.toggle(format: .video, delay: delay)
        case .recordGIF: RecordingController.shared.toggle(format: .gif, delay: delay)
        case .openHistory: HistoryWindowController.shared.show()
        }
    }
}

/// Persists user shortcut bindings and keeps the global hotkeys registered.
@MainActor
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    @Published private(set) var bindings: [ShortcutAction: HotKey] = [:]
    /// Actions whose hotkey could not be registered (usually taken by another app).
    @Published private(set) var failedActions: Set<ShortcutAction> = []

    /// While true (e.g. during shortcut recording) no global hotkeys are active.
    var isSuspended = false {
        didSet { if isSuspended != oldValue { registerAll() } }
    }

    private let defaultsKey = "shortcuts"

    private init() {
        load()
    }

    func hotKey(for action: ShortcutAction) -> HotKey? { bindings[action] }

    /// Assigns a hotkey (or clears it with nil). A hotkey used by another action is moved to this one.
    func set(_ hotKey: HotKey?, for action: ShortcutAction) {
        if let hotKey {
            for (other, existing) in bindings where other != action && existing == hotKey {
                bindings[other] = nil
            }
        }
        bindings[action] = hotKey
        save()
        registerAll()
    }

    func resetToDefaults() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        load()
        registerAll()
    }

    func registerAll() {
        let manager = HotKeyManager.shared
        manager.unregisterAll()
        var failed: Set<ShortcutAction> = []
        if !isSuspended {
            for action in ShortcutAction.allCases {
                guard let hotKey = bindings[action] else { continue }
                if !manager.register(hotKey, handler: { action.perform() }) {
                    failed.insert(action)
                }
            }
        }
        failedActions = failed
    }

    private func load() {
        let stored = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        var bindings: [ShortcutAction: HotKey] = [:]
        for action in ShortcutAction.allCases {
            if let value = stored[action.rawValue] {
                // An empty string means the user cleared this shortcut.
                bindings[action] = HotKey(storageString: value)
            } else {
                bindings[action] = action.defaultHotKey
            }
        }
        self.bindings = bindings
    }

    private func save() {
        var stored: [String: String] = [:]
        // Only overrides are stored, so future default changes still reach untouched actions.
        for action in ShortcutAction.allCases where bindings[action] != action.defaultHotKey {
            stored[action.rawValue] = bindings[action]?.storageString ?? ""
        }
        UserDefaults.standard.set(stored, forKey: defaultsKey)
    }
}
