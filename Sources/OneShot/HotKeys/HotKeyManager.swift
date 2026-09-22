import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut expressed with Carbon key codes and modifier flags.
struct HotKey: Hashable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let command = UInt32(cmdKey)
    static let shift = UInt32(shiftKey)
    static let option = UInt32(optionKey)
    static let control = UInt32(controlKey)

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= HotKey.control }
        if flags.contains(.option) { modifiers |= HotKey.option }
        if flags.contains(.shift) { modifiers |= HotKey.shift }
        if flags.contains(.command) { modifiers |= HotKey.command }
        self.init(keyCode: UInt32(keyCode), modifiers: modifiers)
    }

    /// Serialized form used in UserDefaults, e.g. "21:768".
    var storageString: String { "\(keyCode):\(modifiers)" }

    init?(storageString: String) {
        let parts = storageString.split(separator: ":").compactMap { UInt32($0) }
        guard parts.count == 2 else { return nil }
        self.init(keyCode: parts[0], modifiers: parts[1])
    }

    /// Human-readable form such as "⌥⇧⌘4".
    var displayString: String {
        var result = ""
        if modifiers & HotKey.control != 0 { result += "⌃" }
        if modifiers & HotKey.option != 0 { result += "⌥" }
        if modifiers & HotKey.shift != 0 { result += "⇧" }
        if modifiers & HotKey.command != 0 { result += "⌘" }
        return result + (KeyCodes.key(for: keyCode)?.display ?? "#\(keyCode)")
    }

    /// Key equivalent for NSMenuItem display.
    var menuKeyEquivalent: (key: String, modifiers: NSEvent.ModifierFlags) {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & HotKey.control != 0 { flags.insert(.control) }
        if modifiers & HotKey.option != 0 { flags.insert(.option) }
        if modifiers & HotKey.shift != 0 { flags.insert(.shift) }
        if modifiers & HotKey.command != 0 { flags.insert(.command) }
        return (KeyCodes.key(for: keyCode)?.menuEquivalent ?? "", flags)
    }
}

/// Registers system-wide hotkeys through the Carbon Event Manager, which works without
/// Accessibility permission.
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x4F4E_5348 // "ONSH"

    private init() {}

    @discardableResult
    func register(_ hotKey: HotKey, handler: @escaping () -> Void) -> Bool {
        installEventHandlerIfNeeded()

        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(
            hotKey.keyCode, hotKey.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref
        )
        guard status == noErr, let ref else {
            NSLog("OneShot: failed to register hotkey \(hotKey.displayString) (status \(status))")
            return false
        }
        refs[id] = ref
        handlers[id] = handler
        return true
    }

    func unregisterAll() {
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }

    private func handle(id: UInt32) {
        guard let handler = handlers[id] else { return }
        DispatchQueue.main.async(execute: handler)
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue().handle(id: hotKeyID.id)
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(), callback, 1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(), &eventHandler
        )
    }
}
