import AppKit

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The screen that currently contains the mouse pointer.
    static var underMouse: NSScreen? {
        let location = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(location, $0.frame, false) } ?? main
    }
}

extension CGImage {
    var pixelSize: CGSize { CGSize(width: width, height: height) }
}

extension CGRect {
    /// Converts a rect from CoreGraphics global coordinates (top-left origin of the primary display)
    /// to AppKit global coordinates (bottom-left origin of the primary display).
    var flippedToAppKit: CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: minX, y: primaryHeight - maxY, width: width, height: height)
    }
}
