import AppKit
import Carbon.HIToolbox
import OneShotCore
import ServiceManagement
import SwiftUI

enum SettingsTab: String {
    case general
    case capture
    case shortcuts
    case upload
    case history
    case ai
}

@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var tab: SettingsTab = .general
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(tab: SettingsTab? = nil) {
        if let tab { SettingsNavigation.shared.tab = tab }
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "OneShot Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject private var navigation = SettingsNavigation.shared

    var body: some View {
        TabView(selection: $navigation.tab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            CaptureSettingsView()
                .tabItem { Label("Capture", systemImage: "camera.viewfinder") }
                .tag(SettingsTab.capture)
            ShortcutSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag(SettingsTab.shortcuts)
            UploadSettingsView()
                .tabItem { Label("Upload", systemImage: "icloud.and.arrow.up") }
                .tag(SettingsTab.upload)
            HistorySettingsView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(SettingsTab.history)
            AISettingsView()
                .tabItem { Label("AI", systemImage: "sparkles") }
                .tag(SettingsTab.ai)
        }
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(PrefKey.copyToClipboard) private var copyToClipboard = true
    @AppStorage(PrefKey.saveToDisk) private var saveToDisk = false
    @AppStorage(PrefKey.saveDirectory) private var saveDirectory = Preferences.defaultSaveDirectory.path
    @AppStorage(PrefKey.showQuickAccess) private var showQuickAccess = true
    @AppStorage(PrefKey.quickAccessAutoClose) private var quickAccessAutoClose = 8
    @AppStorage(PrefKey.playSound) private var playSound = true
    @AppStorage(PrefKey.fileNamePattern) private var fileNamePattern = FileNamePattern.defaultPattern
    @AppStorage(PrefKey.imageFormat) private var imageFormat = ImageFormat.png.rawValue
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var checksForUpdates = Updater.shared.automaticallyChecksForUpdates

    var body: some View {
        Form {
            Section("After capture") {
                Toggle("Copy to clipboard", isOn: $copyToClipboard)
                Toggle("Save to folder", isOn: $saveToDisk)
                LabeledContent("Folder") {
                    HStack {
                        Text((saveDirectory as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Toggle("Show Quick Access overlay", isOn: $showQuickAccess)
                Picker("Close overlay after", selection: $quickAccessAutoClose) {
                    Text("5 seconds").tag(5)
                    Text("8 seconds").tag(8)
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("Never").tag(0)
                }
                .disabled(!showQuickAccess)
            }
            Section("File name") {
                TextField("Pattern", text: $fileNamePattern, prompt: Text(FileNamePattern.defaultPattern))
                LabeledContent("Preview") {
                    Text(fileNamePreview)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(FileNamePattern.placeholders, id: \.token) { placeholder in
                        Button(placeholder.token) { fileNamePattern += placeholder.token }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(placeholder.description)
                    }
                }
                HStack {
                    Text("Click a placeholder to append it. Hover for details.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset") { fileNamePattern = FileNamePattern.defaultPattern }
                        .controlSize(.small)
                        .disabled(fileNamePattern == FileNamePattern.defaultPattern)
                }
            }
            Section {
                LabeledContent("Command line tool") {
                    Button(CLIInstaller.installedLink == nil ? "Install…" : "Reinstall…") { CLIInstaller.install() }
                }
            } header: {
                Text("Automation")
            } footer: {
                Text("Run captures from Terminal, Raycast or Alfred with the oneshot command or oneshot:// links, e.g. oneshot://capture-area.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("General") {
                Toggle("Play sound", isOn: $playSound)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                HStack {
                    Toggle("Check for updates automatically", isOn: $checksForUpdates)
                        .onChange(of: checksForUpdates) { _, enabled in Updater.shared.automaticallyChecksForUpdates = enabled }
                    Spacer()
                    Button("Check Now") { Updater.shared.checkForUpdates() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var fileNamePreview: String {
        let name = FileNamePattern.fileName(
            pattern: fileNamePattern,
            context: .init(appName: "Safari", pixelSize: CGSize(width: 1280, height: 800))
        )
        let fileExtension = (ImageFormat(rawValue: imageFormat) ?? .png).fileExtension
        return "\(name).\(fileExtension)"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: saveDirectory)
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            saveDirectory = url.path
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("OneShot: launch at login change failed: \(error)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct CaptureSettingsView: View {
    @AppStorage(PrefKey.imageFormat) private var imageFormat = ImageFormat.png.rawValue
    @AppStorage(PrefKey.jpegQuality) private var jpegQuality = 0.9
    @AppStorage(PrefKey.downscaleRetina) private var downscaleRetina = false
    @AppStorage(PrefKey.windowShadow) private var windowShadow = true
    @AppStorage(PrefKey.showCrosshair) private var showCrosshair = true
    @AppStorage(PrefKey.selfTimerSeconds) private var selfTimerSeconds = 5
    @AppStorage(PrefKey.hideDesktopIcons) private var hideDesktopIcons = false
    @AppStorage(PrefKey.hideDesktopWidgets) private var hideDesktopWidgets = false
    @AppStorage(PrefKey.recordAudio) private var recordAudio = true
    @AppStorage(PrefKey.recordCodec) private var recordCodec = RecordingCodec.hevc.rawValue
    @AppStorage(PrefKey.recordFrameRate) private var recordFrameRate = 30
    @AppStorage(PrefKey.recordQuality) private var recordQuality = RecordingQuality.standard.rawValue
    @AppStorage(PrefKey.recordCursor) private var recordCursor = true
    @AppStorage(PrefKey.recordCountdown) private var recordCountdown = 3
    @AppStorage(PrefKey.gifFrameRate) private var gifFrameRate = 15
    @AppStorage(PrefKey.gifMaxWidth) private var gifMaxWidth = 960
    @AppStorage(PrefKey.ocrKeepLineBreaks) private var ocrKeepLineBreaks = true

    var body: some View {
        Form {
            Section("Image") {
                Picker("File format", selection: $imageFormat) {
                    ForEach(ImageFormat.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                if imageFormat == ImageFormat.jpeg.rawValue {
                    LabeledContent("JPEG quality") {
                        Slider(value: $jpegQuality, in: 0.5...1, step: 0.05)
                            .frame(width: 200)
                    }
                }
                Toggle("Save Retina screenshots at 1x", isOn: $downscaleRetina)
            }
            Section("Area selection") {
                Toggle("Show crosshair guides", isOn: $showCrosshair)
                Picker("Self-timer", selection: $selfTimerSeconds) {
                    ForEach(Preferences.selfTimerChoices, id: \.self) { Text("\($0) seconds").tag($0) }
                }
            }
            Section("Desktop") {
                Toggle("Hide desktop icons", isOn: $hideDesktopIcons)
                Toggle("Hide desktop widgets", isOn: $hideDesktopWidgets)
            }
            Section("Window capture") {
                Toggle("Include window shadow", isOn: $windowShadow)
            }
            Section {
                Picker("Video format", selection: $recordCodec) {
                    ForEach(RecordingCodec.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Frame rate", selection: $recordFrameRate) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Picker("Quality", selection: $recordQuality) {
                    ForEach(RecordingQuality.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Record system audio", isOn: $recordAudio)
                Toggle("Show the mouse pointer", isOn: $recordCursor)
                Picker("Countdown", selection: $recordCountdown) {
                    Text("None").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                }
                Picker("GIF frame rate", selection: $gifFrameRate) {
                    ForEach([10, 15, 20, 30], id: \.self) { Text("\($0) fps").tag($0) }
                }
                Picker("GIF maximum width", selection: $gifMaxWidth) {
                    ForEach([480, 640, 960, 1280, 1920], id: \.self) { Text("\($0) px").tag($0) }
                }
            } header: {
                Text("Screen recording")
            } footer: {
                Text("Choose the screen, resolution, camera and microphone in the panel that opens when you record. HEVC files are about 40% smaller than H.264 and play in current browsers; High quality doubles the file size.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Text recognition") {
                Toggle("Keep line breaks", isOn: $ocrKeepLineBreaks)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutSettingsView: View {
    @ObservedObject private var store = ShortcutStore.shared
    @State private var systemShortcutsEnabled = SystemScreenshotShortcuts.anyEnabled
    @State private var hasScreenRecording = Permissions.hasScreenRecording

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases) { action in
                    LabeledContent {
                        ShortcutRecorder(action: action)
                    } label: {
                        Text(action.title)
                        if store.failedActions.contains(action) {
                            Text("Could not register. Another app may be using this shortcut.")
                                .foregroundStyle(.orange)
                        } else if let subtitle = action.subtitle {
                            Text(subtitle)
                        }
                    }
                }
            } header: {
                Text("Shortcuts")
            } footer: {
                HStack(alignment: .top) {
                    Text("Click a shortcut, then press the new key combination. Esc cancels, Delete clears. Press Space while selecting an area to switch to window capture.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") { store.resetToDefaults() }
                        .controlSize(.small)
                }
            }
            Section("macOS screenshot shortcuts") {
                LabeledContent("Status") {
                    Text(systemShortcutsEnabled ? "Enabled (they override OneShot)" : "Disabled")
                        .foregroundStyle(systemShortcutsEnabled ? .orange : .secondary)
                }
                HStack {
                    Spacer()
                    if systemShortcutsEnabled {
                        Button("Disable macOS Shortcuts") { setSystemShortcuts(enabled: false) }
                    } else {
                        Button("Restore macOS Shortcuts") { setSystemShortcuts(enabled: true) }
                    }
                }
            }
            Section("Permissions") {
                LabeledContent("Screen Recording") {
                    Text(hasScreenRecording ? "Granted" : "Not granted")
                        .foregroundStyle(hasScreenRecording ? .green : .orange)
                }
                if !hasScreenRecording {
                    HStack {
                        Spacer()
                        Button("Open System Settings") { Permissions.openScreenRecordingSettings() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            systemShortcutsEnabled = SystemScreenshotShortcuts.anyEnabled
            hasScreenRecording = Permissions.hasScreenRecording
        }
    }

    private func setSystemShortcuts(enabled: Bool) {
        SystemScreenshotShortcuts.setEnabled(enabled)
        systemShortcutsEnabled = SystemScreenshotShortcuts.anyEnabled
    }
}

/// Click to record a new global shortcut for an action.
struct ShortcutRecorder: View {
    let action: ShortcutAction
    @ObservedObject private var store = ShortcutStore.shared
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button(action: { isRecording ? stopRecording() : startRecording() }) {
                Text(label)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundStyle(isRecording || store.hotKey(for: action) == nil ? .secondary : .primary)
                    .frame(minWidth: 120)
            }
            // Always laid out, and only hidden, so every recorder lines up whether or not it can be cleared.
            let canClear = store.hotKey(for: action) != nil && !isRecording
            Button(action: { store.set(nil, for: action) }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Clear shortcut")
            .opacity(canClear ? 1 : 0)
            .disabled(!canClear)
            .accessibilityHidden(!canClear)
        }
        .onDisappear(perform: stopRecording)
    }

    private var label: String {
        if isRecording { return "Press shortcut…" }
        return store.hotKey(for: action)?.displayString ?? "Record Shortcut"
    }

    private func startRecording() {
        isRecording = true
        // Release global hotkeys so pressing an existing shortcut records it instead of capturing.
        store.isSuspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        store.isSuspended = false
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case kVK_Escape where flags.isEmpty:
            stopRecording()
            return
        case kVK_Delete where flags.isEmpty, kVK_ForwardDelete where flags.isEmpty:
            store.set(nil, for: action)
            stopRecording()
            return
        default:
            break
        }
        // Require a real modifier (Shift alone is not enough) unless it is a function key.
        guard !flags.subtracting(.shift).isEmpty || KeyCodes.isFunctionKey(event.keyCode) else {
            NSSound.beep()
            return
        }
        store.set(HotKey(keyCode: event.keyCode, flags: flags), for: action)
        stopRecording()
    }
}
