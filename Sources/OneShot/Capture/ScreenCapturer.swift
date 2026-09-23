import AppKit
import ScreenCaptureKit

/// A frozen, full-resolution image of one display.
struct DisplaySnapshot {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let image: CGImage

    /// Pixels per point.
    var scale: CGFloat { CGFloat(image.width) / screen.frame.width }

    /// Crops a rect given in the screen's local AppKit coordinates (points, bottom-left origin).
    func crop(_ localRect: CGRect) -> CGImage? {
        let height = screen.frame.height
        let pixelRect = CGRect(
            x: localRect.minX * scale,
            y: (height - localRect.maxY) * scale,
            width: localRect.width * scale,
            height: localRect.height * scale
        ).integral
        return image.cropping(to: pixelRect)
    }
}

/// An on-screen window that can be picked in window capture mode.
struct WindowInfo {
    let id: CGWindowID
    /// Frame in CoreGraphics global coordinates (top-left origin).
    let frame: CGRect
    let ownerName: String?
    let title: String?
}

enum CaptureError: LocalizedError {
    case permissionDenied
    case displayNotFound
    case windowNotFound
    case emptyImage

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Screen Recording permission is missing."
        case .displayNotFound: return "The display could not be found."
        case .windowNotFound: return "The window is no longer available."
        case .emptyImage: return "The captured image is empty."
        }
    }
}

enum ScreenCapturer {
    /// Captures every display (or only the given one) at native resolution.
    /// OneShot's capture UI is excluded, but its regular windows and pinned screenshots are kept;
    /// desktop icons and widgets are excluded when the corresponding settings are on.
    static func snapshotDisplays(
        only displayID: CGDirectDisplayID? = nil,
        includingWindows includedWindowIDs: Set<CGWindowID> = []
    ) async throws -> [DisplaySnapshot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let excludedWindows = windowsToExclude(from: content, keeping: includedWindowIDs)

        var snapshots: [DisplaySnapshot] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID, displayID == nil || displayID == id else { continue }
            guard let display = content.displays.first(where: { $0.displayID == id }) else { continue }

            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
            let config = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            config.width = Int((screen.frame.width * scale).rounded())
            config.height = Int((screen.frame.height * scale).rounded())
            config.showsCursor = false
            config.captureResolution = .best

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            snapshots.append(DisplaySnapshot(screen: screen, displayID: id, image: image))
        }
        if snapshots.isEmpty { throw CaptureError.displayNotFound }
        return snapshots
    }

    private static let finderBundleID = "com.apple.finder"
    private static let notificationCenterBundleID = "com.apple.notificationcenterui"
    private static let normalWindowLevel = Int(CGWindowLevelForKey(.normalWindow))

    /// Whether a window is one of OneShot's regular windows (History, Settings, the editors), which are
    /// captured like any other app's. The rest of its UI (overlays, toasts, Quick Access, countdowns,
    /// frames) floats above the normal level and is kept out of captures.
    static func isOwnRegularWindow(_ window: SCWindow) -> Bool {
        window.owningApplication?.processID == getpid() && window.windowLayer == normalWindowLevel
    }

    static func windowsToExclude(from content: SCShareableContent, keeping keptWindowIDs: Set<CGWindowID>) -> [SCWindow] {
        let ownPID = getpid()
        let desktopIconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let hideIcons = Preferences.hideDesktopIcons
        let hideWidgets = Preferences.hideDesktopWidgets

        return content.windows.filter { window in
            let app = window.owningApplication
            if app?.processID == ownPID {
                return !isOwnRegularWindow(window) && !keptWindowIDs.contains(window.windowID)
            }
            if hideIcons, app?.bundleIdentifier == finderBundleID, window.windowLayer == desktopIconLevel {
                return true
            }
            // Desktop widgets live just above the icon level, below normal windows.
            if hideWidgets, app?.bundleIdentifier == notificationCenterBundleID,
               window.windowLayer > desktopIconLevel, window.windowLayer < 0 {
                return true
            }
            return false
        }
    }

    /// Captures part of a display. `sourceRect` is in points, relative to the display's top-left corner.
    static func captureRegion(
        display: SCDisplay,
        excluding windows: [SCWindow],
        sourceRect: CGRect,
        scale: CGFloat
    ) async throws -> CGImage {
        let filter = SCContentFilter(display: display, excludingWindows: windows)
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = Int((sourceRect.width * scale).rounded())
        config.height = Int((sourceRect.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Captures a single window independently of what is covering it.
    static func captureWindow(id: CGWindowID, includeShadow: Bool) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            throw CaptureError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let info = SCShareableContent.info(for: filter)
        let config = SCStreamConfiguration()
        let scale = CGFloat(info.pointPixelScale)
        config.width = Int((info.contentRect.width * scale).rounded())
        config.height = Int((info.contentRect.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = !includeShadow
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// The frontmost app and the title of its front window, captured before OneShot takes focus.
    static func frontmostContext() -> (appName: String?, windowTitle: String?) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return (nil, nil) }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        let title = list.first { entry in
            (entry[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier
                && (entry[kCGWindowLayer as String] as? Int) == 0
        }?[kCGWindowName as String] as? String
        return (app.localizedName, title?.isEmpty == true ? nil : title)
    }

    /// Normal application windows currently on screen, OneShot's own included, ordered front to back.
    static func onScreenWindows() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == normalWindowLevel,
                  let number = entry[kCGWindowNumber as String] as? Int,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict),
                  frame.width > 20, frame.height > 20
            else { return nil }
            return WindowInfo(
                id: CGWindowID(number),
                frame: frame,
                ownerName: entry[kCGWindowOwnerName as String] as? String,
                title: entry[kCGWindowName as String] as? String
            )
        }
    }
}
