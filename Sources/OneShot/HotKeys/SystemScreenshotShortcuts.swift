import Foundation

/// Reads and toggles the built-in macOS screenshot shortcuts (⇧⌘3, ⌃⇧⌘3, ⇧⌘4, ⌃⇧⌘4).
/// While they are enabled, macOS consumes those key combinations before OneShot sees them.
enum SystemScreenshotShortcuts {
    private static let domain = "com.apple.symbolichotkeys" as CFString
    private static let key = "AppleSymbolicHotKeys" as CFString

    /// Symbolic hotkey IDs with their default (ASCII code, key code, modifier mask) parameters.
    private static let entries: [(id: Int, parameters: [Int])] = [
        (28, [51, 20, 1_179_648]), // ⇧⌘3  Save picture of screen as a file
        (29, [51, 20, 1_441_792]), // ⌃⇧⌘3 Copy picture of screen to the clipboard
        (30, [52, 21, 1_179_648]), // ⇧⌘4  Save picture of selected area as a file
        (31, [52, 21, 1_441_792]), // ⌃⇧⌘4 Copy picture of selected area to the clipboard
    ]

    private static func currentHotKeys() -> [String: Any] {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key, domain) as? [String: Any] ?? [:]
    }

    /// True if any of the system screenshot shortcuts is still active.
    static var anyEnabled: Bool {
        let hotKeys = currentHotKeys()
        return entries.contains { entry in
            guard let item = hotKeys[String(entry.id)] as? [String: Any] else { return true }
            return (item["enabled"] as? Bool) ?? true
        }
    }

    static func setEnabled(_ enabled: Bool) {
        var hotKeys = currentHotKeys()
        for entry in entries {
            var item = hotKeys[String(entry.id)] as? [String: Any] ?? [
                "value": ["parameters": entry.parameters, "type": "standard"] as [String: Any],
            ]
            item["enabled"] = enabled
            hotKeys[String(entry.id)] = item
        }
        CFPreferencesSetValue(key, hotKeys as CFDictionary, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        applyWithoutLogout()
    }

    /// Asks the system to reload keyboard shortcut settings immediately.
    private static func applyWithoutLogout() {
        let tool = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-u"]
        try? process.run()
        process.waitUntilExit()
    }
}
