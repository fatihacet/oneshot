import AppKit
import SwiftUI

/// A small, non-interactive HUD message shown near the bottom of the active screen.
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    /// Shows `message` for `duration` seconds, replacing any toast that is on screen.
    static func show(_ message: String, symbol: String = "checkmark.circle.fill", duration: TimeInterval = 1.6) {
        hideWork?.cancel()
        panel?.orderOut(nil)

        let hosting = NSHostingView(rootView: ToastView(message: message, symbol: symbol))
        hosting.layoutSubtreeIfNeeded()
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
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = hosting

        if let screen = NSScreen.underMouse {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(CGPoint(x: frame.midX - size.width / 2, y: frame.minY + 80))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        self.panel = panel

        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 }) {
                panel.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// Hides the current toast early, e.g. a progress message once the work is done.
    static func hide() {
        guard let work = hideWork, !work.isCancelled else { return }
        hideWork = nil
        work.perform()
        work.cancel()
    }
}

private struct ToastView: View {
    let message: String
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
            Text(message).lineLimit(2)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .frame(maxWidth: 420)
    }
}
