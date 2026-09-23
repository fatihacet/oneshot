import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class OnboardingWindowController {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?

    static let completedKey = "onboardingCompleted"
    static let stepKey = "onboardingStep"

    static var isCompleted: Bool { UserDefaults.standard.bool(forKey: completedKey) }

    func show() {
        if window == nil {
            let view = OnboardingView { [weak self] in self?.finish() }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Welcome to OneShot"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        UserDefaults.standard.removeObject(forKey: Self.stepKey)
        window?.close()
        window = nil
    }
}

private enum OnboardingStep: Int, CaseIterable {
    case welcome
    case permissions
    case afterCapture
    case shortcuts
    case upload
    case search
    case done

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .permissions: return "Permissions"
        case .afterCapture: return "After Capture"
        case .shortcuts: return "Shortcuts"
        case .upload: return "Upload"
        case .search: return "Search"
        case .done: return "Done"
        }
    }
}

private struct OnboardingView: View {
    let finish: () -> Void
    @AppStorage(OnboardingWindowController.stepKey) private var stepIndex = 0

    private var step: OnboardingStep { OnboardingStep(rawValue: stepIndex) ?? .welcome }

    var body: some View {
        VStack(spacing: 0) {
            StepIndicator(current: step)
                .padding(.top, 28)
                .padding(.bottom, 8)

            Group {
                switch step {
                case .welcome: WelcomeStep()
                case .permissions: PermissionsStep()
                case .afterCapture: AfterCaptureStep()
                case .shortcuts: ShortcutsStep()
                case .upload: OptionalStep(
                    title: "Upload to your own storage",
                    subtitle: "Optional. Share screenshots as links from any S3-compatible bucket. You can set this up later in Settings › Upload."
                ) { UploadSettingsView() }
                case .search: OptionalStep(
                    title: "Search your screenshots",
                    subtitle: "OneShot keeps a local history and recognizes text on this Mac. Optionally add an AI provider for captions and smarter search."
                ) { AISettingsView() }
                case .done: DoneStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                if step != .welcome {
                    Button("Back") { stepIndex -= 1 }
                }
                Spacer()
                if step == .upload || step == .search {
                    Button("Skip") { stepIndex += 1 }
                }
                if step == .done {
                    Button("Start Using OneShot", action: finish)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(step == .welcome ? "Get Started" : "Continue") { stepIndex += 1 }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 640, height: 600)
    }
}

private struct StepIndicator: View {
    let current: OnboardingStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                Capsule()
                    .fill(step.rawValue <= current.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: step == current ? 22 : 8, height: 8)
                    .help(step.title)
            }
        }
        .animation(.snappy, value: current)
    }
}

private struct StepHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 12)
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
            Text("OneShot").font(.largeTitle.weight(.bold))
            Text("Fast screenshots for your Mac. This short setup takes about a minute.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                feature("camera.viewfinder", "Capture areas, windows, full screens and long scrolling pages")
                feature("pin.fill", "Pin screenshots above other windows for reference")
                feature("icloud.and.arrow.up", "Upload to your own S3-compatible storage and share links")
                feature("magnifyingglass", "Find any screenshot later by its text or content")
            }
            .padding(.top, 8)
        }
        .padding(32)
    }

    private func feature(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: 24)
        }
    }
}

private struct PermissionsStep: View {
    @State private var hasScreenRecording = Permissions.hasScreenRecording
    @State private var hasAccessibility = AXIsProcessTrusted()
    @State private var requestedScreenRecording = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 20) {
            StepHeader(
                title: "Allow OneShot to see your screen",
                subtitle: "macOS asks for permission before any app can take screenshots."
            )
            PermissionRow(
                symbol: "rectangle.dashed.badge.record",
                title: "Screen & System Audio Recording",
                detail: "Required for every capture.",
                isGranted: hasScreenRecording
            ) {
                Button("Allow…") {
                    requestedScreenRecording = true
                    if !Permissions.requestScreenRecording() { Permissions.openScreenRecordingSettings() }
                }
            }
            if requestedScreenRecording, !hasScreenRecording {
                HStack {
                    Text("After enabling OneShot in System Settings, relaunch to apply it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Relaunch OneShot") { Relauncher.relaunch() }
                        .controlSize(.small)
                }
            }
            PermissionRow(
                symbol: "accessibility",
                title: "Accessibility",
                detail: "Optional. Only used to auto-scroll during scrolling capture.",
                isGranted: hasAccessibility
            ) {
                Button("Allow…") {
                    AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                }
            }
        }
        .padding(.horizontal, 40)
        .onReceive(timer) { _ in
            hasScreenRecording = Permissions.hasScreenRecording
            hasAccessibility = AXIsProcessTrusted()
        }
    }
}

private struct PermissionRow<Action: View>: View {
    let symbol: String
    let title: String
    let detail: String
    let isGranted: Bool
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .frame(width: 36)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isGranted {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                action()
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct AfterCaptureStep: View {
    @AppStorage(PrefKey.copyToClipboard) private var copyToClipboard = true
    @AppStorage(PrefKey.saveToDisk) private var saveToDisk = false
    @AppStorage(PrefKey.saveDirectory) private var saveDirectory = Preferences.defaultSaveDirectory.path
    @AppStorage(PrefKey.showQuickAccess) private var showQuickAccess = true
    @AppStorage(PrefKey.playSound) private var playSound = true

    var body: some View {
        VStack(spacing: 8) {
            StepHeader(
                title: "What happens after a capture?",
                subtitle: "Pick the defaults. Every screenshot also stays in your local history."
            )
            Form {
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
                Toggle("Show a preview in the corner (Quick Access)", isOn: $showQuickAccess)
                Toggle("Play sound", isOn: $playSound)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
        }
        .padding(.horizontal, 24)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: saveDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            saveDirectory = url.path
        }
    }
}

private struct ShortcutsStep: View {
    @State private var systemShortcutsEnabled = SystemScreenshotShortcuts.anyEnabled

    private let highlighted: [ShortcutAction] = [
        .captureArea, .captureAreaToClipboard, .captureWindow, .captureFullscreen, .captureScrolling, .captureText, .openHistory,
    ]

    var body: some View {
        VStack(spacing: 8) {
            StepHeader(
                title: "Keyboard shortcuts",
                subtitle: "Click a shortcut to change it. All of them are also in the menu bar."
            )
            Form {
                if systemShortcutsEnabled {
                    HStack {
                        Label("macOS uses ⇧⌘3 and ⇧⌘4 for its own screenshots.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Use OneShot Instead") {
                            SystemScreenshotShortcuts.setEnabled(false)
                            systemShortcutsEnabled = SystemScreenshotShortcuts.anyEnabled
                        }
                    }
                }
                ForEach(highlighted) { action in
                    LabeledContent(action.title) { ShortcutRecorder(action: action) }
                }
            }
            .formStyle(.grouped)
        }
        .padding(.horizontal, 24)
    }
}

private struct OptionalStep<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            StepHeader(title: title, subtitle: subtitle)
            content()
        }
        .padding(.horizontal, 12)
    }
}

private struct DoneStep: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("You're all set").font(.title.weight(.semibold))
            if let hotKey = ShortcutStore.shared.hotKey(for: .captureArea) {
                Text("Press \(hotKey.displayString) to capture an area.")
                    .font(.title3)
            }
            Text("OneShot lives in the menu bar. Settings, History and every capture mode are there.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 60)
        }
    }
}
