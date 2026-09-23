import AppKit
import SwiftUI

/// The self-timer countdown shown before a delayed capture.
@MainActor
enum Countdown {
    private static let tickSound = NSSound(named: "Tink")

    /// Counts down on `screen`. Returns false if the user cancelled by clicking the countdown.
    static func run(seconds: Int, on screen: NSScreen?) async -> Bool {
        let model = CountdownModel(remaining: seconds)
        let hosting = NSHostingView(rootView: CountdownView(model: model))
        let size = hosting.fittingSize

        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        if let frame = (screen ?? NSScreen.underMouse)?.visibleFrame {
            panel.setFrameOrigin(CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        }
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }

        for remaining in stride(from: seconds, to: 0, by: -1) {
            model.remaining = remaining
            if Preferences.playSound { tickSound?.stop(); tickSound?.play() }
            // Poll in small steps so a click cancels immediately.
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(100))
                if model.isCancelled { return false }
            }
        }
        return true
    }
}

@MainActor
private final class CountdownModel: ObservableObject {
    @Published var remaining: Int
    @Published var isCancelled = false

    init(remaining: Int) {
        self.remaining = remaining
    }
}

private struct CountdownView: View {
    @ObservedObject var model: CountdownModel

    var body: some View {
        VStack(spacing: 4) {
            Text("\(model.remaining)")
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy, value: model.remaining)
            Text("Click to cancel")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 160, height: 160)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { model.isCancelled = true }
    }
}
