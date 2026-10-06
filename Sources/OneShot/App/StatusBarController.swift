import AppKit

/// The menu bar icon and its menu.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private(set) static var shared: StatusBarController?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var recordingTimer: Timer?
    private var stopRecording: (() -> Void)?

    /// Delay for captures started from the menu, so the closing menu is not captured.
    private let menuDelay: TimeInterval = 0.25

    override init() {
        super.init()
        showIdleIcon()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        Self.shared = self
    }

    private func showIdleIcon() {
        guard let button = statusItem.button else { return }
        button.image = MenuBarIcon.image
        button.title = ""
        button.imagePosition = .imageOnly
        button.contentTintColor = nil
    }

    // MARK: Recording mode

    /// Turns the menu bar item into a stop button with the elapsed time.
    func showRecording(since start: Date, stop: @escaping () -> Void) {
        stopRecording = stop
        statusItem.menu = nil
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(stopClicked)
        let update = { [weak button] in
            let seconds = Int(Date().timeIntervalSince(start))
            button?.image = MenuBarIcon.recording(elapsed: String(format: "%d:%02d", seconds / 60, seconds % 60))
        }
        update()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { update() }
        }
    }

    func hideRecording() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        stopRecording = nil
        statusItem.button?.target = nil
        statusItem.button?.action = nil
        showIdleIcon()
        statusItem.menu = menu
    }

    @objc private func stopClicked() {
        stopRecording?()
    }

    /// Actions with a shortcut come first, mirroring the keyboard. Everything else is grouped:
    /// the remaining captures and recordings, clipboard tools and pins in submenus, then history,
    /// the folder, and the app itself.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let store = ShortcutStore.shared
        let assigned = ShortcutAction.allCases.filter { store.hotKey(for: $0) != nil }
        let unassigned = { (group: ShortcutAction.MenuGroup) in
            ShortcutAction.allCases.filter { $0.menuGroup == group && !assigned.contains($0) }
        }
        for action in assigned {
            menu.addItem(actionItem(action))
        }
        if !assigned.isEmpty { menu.addItem(.separator()) }

        let captures = unassigned(.capture)
        let captureMenu = NSMenu()
        captures.forEach { captureMenu.addItem(actionItem($0)) }
        if !captures.isEmpty { captureMenu.addItem(.separator()) }
        captureMenu.addItem(selfTimerItem())
        let hasAssignedCaptures = assigned.contains { $0.menuGroup == .capture }
        menu.addItem(submenuItem(hasAssignedCaptures ? "More Captures" : "Capture", captureMenu))

        let recordings = unassigned(.record)
        if !recordings.isEmpty {
            let recordMenu = NSMenu()
            recordings.forEach { recordMenu.addItem(actionItem($0)) }
            menu.addItem(submenuItem("Record", recordMenu))
        }

        menu.addItem(submenuItem("Clipboard Image", clipboardMenu()))
        menu.addItem(.separator())

        unassigned(.history).forEach { menu.addItem(actionItem($0)) }
        let pins = PinManager.shared
        if pins.hasPins {
            menu.addItem(submenuItem("Pinned Screenshots", pinsMenu(pins)))
        }
        menu.addItem(ClosureMenuItem(title: "Open Screenshots Folder") {
            let directory = Preferences.saveDirectory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        })
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(title: "Settings…", key: ",") { SettingsWindowController.shared.show() })
        let updates = ClosureMenuItem(title: "Check for Updates…") { Updater.shared.checkForUpdates() }
        updates.isEnabled = Updater.shared.canCheckForUpdates
        menu.addItem(updates)
        menu.addItem(ClosureMenuItem(title: "Quit OneShot", key: "q") { NSApp.terminate(nil) })
    }

    /// Runs a shortcut action, showing its shortcut if it has one.
    private func actionItem(_ action: ShortcutAction) -> NSMenuItem {
        let item = ClosureMenuItem(title: action.title) { [menuDelay] in action.perform(delay: menuDelay) }
        if let hotKey = ShortcutStore.shared.hotKey(for: action) {
            let equivalent = hotKey.menuKeyEquivalent
            item.keyEquivalent = equivalent.key
            item.keyEquivalentModifierMask = equivalent.modifiers
        }
        return item
    }

    private func submenuItem(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        submenu.autoenablesItems = false
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func selfTimerItem() -> NSMenuItem {
        let submenu = NSMenu()
        for seconds in Preferences.selfTimerChoices {
            let choice = ClosureMenuItem(title: "\(seconds) seconds") { Preferences.selfTimerSeconds = seconds }
            choice.state = Preferences.selfTimerSeconds == seconds ? .on : .off
            submenu.addItem(choice)
        }
        return submenuItem("Self-Timer: \(Preferences.selfTimerSeconds) s", submenu)
    }

    /// Tools for the image on the clipboard, disabled when there is none.
    private func clipboardMenu() -> NSMenu {
        let submenu = NSMenu()
        let hasImage = NSImage.canInit(with: .general)
        let items = [
            ClosureMenuItem(title: "Pin to Screen") { _ = PinManager.shared.pinFromClipboard() },
            ClosureMenuItem(title: "Annotate…") { AnnotationEditorWindowController.shared.openClipboardImage() },
            ClosureMenuItem(title: "Add Background…") { BackgroundToolWindowController.shared.openClipboardImage() },
            ClosureMenuItem(title: "Upload") { Uploader.shared.uploadClipboardImage() },
        ]
        for item in items {
            item.isEnabled = hasImage
            submenu.addItem(item)
        }
        if !hasImage {
            submenu.addItem(.separator())
            let hint = NSMenuItem(title: "Copy an image to use these", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            submenu.addItem(hint)
        }
        return submenu
    }

    private func pinsMenu(_ pins: PinManager) -> NSMenu {
        let submenu = NSMenu()
        submenu.addItem(ClosureMenuItem(title: pins.isHidden ? "Show All" : "Hide All") {
            pins.setHidden(!pins.isHidden)
        })
        if pins.hasLockedPins {
            submenu.addItem(ClosureMenuItem(title: "Unlock All") { pins.unlockAll() })
        }
        submenu.addItem(ClosureMenuItem(title: "Close All") { pins.closeAll() })
        return submenu
    }
}

/// An NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    /// `key` is a ⌘ key equivalent, e.g. "," for Settings.
    init(title: String, key: String = "", action handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() {
        MainActor.assumeIsolated { handler() }
    }
}
