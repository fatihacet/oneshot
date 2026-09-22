import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()
        NSApp.mainMenu = makeMainMenu()
        statusBar = StatusBarController()
        registerHotKeys()

        if !Preferences.didCompleteFirstLaunch {
            Preferences.didCompleteFirstLaunch = true
            runFirstLaunchSetup()
        }
    }

    private func registerHotKeys() {
        ShortcutStore.shared.registerAll()
    }

    /// Minimal first-run setup until the full onboarding wizard lands.
    private func runFirstLaunchSetup() {
        if !Permissions.hasScreenRecording {
            Permissions.requestScreenRecording()
        }
        guard SystemScreenshotShortcuts.anyEnabled else { return }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Use OneShot for ⇧⌘3 and ⇧⌘4?"
        alert.informativeText = """
        The built-in macOS screenshot shortcuts take priority over other apps. \
        OneShot can disable them so ⇧⌘3 and ⇧⌘4 open OneShot instead. \
        You can restore them any time in Settings › Shortcuts.
        """
        alert.addButton(withTitle: "Disable macOS Shortcuts")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            SystemScreenshotShortcuts.setEnabled(false)
        }
    }

    /// Accessory apps have no visible menu bar, but key equivalents in windows still route through it.
    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit OneShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        return mainMenu
    }
}
