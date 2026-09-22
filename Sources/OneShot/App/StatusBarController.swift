import AppKit

/// The menu bar icon and its menu.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    /// Delay for captures started from the menu, so the closing menu is not captured.
    private let menuDelay: TimeInterval = 0.25

    override init() {
        super.init()
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "OneShot")
            image?.isTemplate = true
            button.image = image
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        for action in ShortcutAction.allCases {
            addItem(action.title, shortcut: action) { [menuDelay] in action.perform(delay: menuDelay) }
        }

        menu.addItem(.separator())

        addItem("Pin Image from Clipboard") {
            if !PinManager.shared.pinFromClipboard() {
                Toast.show("No image on the clipboard", symbol: "doc.on.clipboard")
            }
        }
        let pins = PinManager.shared
        addItem(pins.isHidden ? "Show Pinned Screenshots" : "Hide Pinned Screenshots", enabled: pins.hasPins) {
            pins.setHidden(!pins.isHidden)
        }
        if pins.hasLockedPins {
            addItem("Unlock Pinned Screenshots") { pins.unlockAll() }
        }
        addItem("Close All Pinned Screenshots", enabled: pins.hasPins) { pins.closeAll() }

        menu.addItem(.separator())

        addItem("Open Screenshots Folder") {
            let directory = Preferences.saveDirectory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        }
        addItem("Settings…", key: ",") { SettingsWindowController.shared.show() }
        menu.addItem(.separator())
        addItem("Quit OneShot", key: "q") { NSApp.terminate(nil) }
    }

    private func addItem(
        _ title: String,
        shortcut: ShortcutAction? = nil,
        key: String = "",
        enabled: Bool = true,
        action: @escaping @MainActor () -> Void
    ) {
        let item = ClosureMenuItem(title: title, action: action)
        if let shortcut, let hotKey = ShortcutStore.shared.hotKey(for: shortcut) {
            let equivalent = hotKey.menuKeyEquivalent
            item.keyEquivalent = equivalent.key
            item.keyEquivalentModifierMask = equivalent.modifiers
        } else if !key.isEmpty {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = .command
        }
        item.isEnabled = enabled
        menu.addItem(item)
    }
}

/// An NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, action handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() {
        MainActor.assumeIsolated { handler() }
    }
}
