import AppKit
import OneShotCore
import UniformTypeIdentifiers

enum ImageFormat: String, CaseIterable, Identifiable {
    case png
    case jpeg

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        }
    }

    var utType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        }
    }
}

/// UserDefaults keys. SwiftUI views bind to these with `@AppStorage`.
enum PrefKey {
    static let copyToClipboard = "copyToClipboard"
    static let saveToDisk = "saveToDisk"
    static let saveDirectory = "saveDirectory"
    static let showQuickAccess = "showQuickAccess"
    static let quickAccessAutoClose = "quickAccessAutoClose"
    static let imageFormat = "imageFormat"
    static let fileNamePattern = "fileNamePattern"
    static let jpegQuality = "jpegQuality"
    static let downscaleRetina = "downscaleRetina"
    static let windowShadow = "windowShadow"
    static let showCrosshair = "showCrosshair"
    static let selfTimerSeconds = "selfTimerSeconds"
    static let hideDesktopIcons = "hideDesktopIcons"
    static let hideDesktopWidgets = "hideDesktopWidgets"
    static let uploadAfterCapture = "uploadAfterCapture"
    static let copyLinkAfterUpload = "copyLinkAfterUpload"
    static let uploadFileNamePattern = "uploadFileNamePattern"
    static let historyEnabled = "historyEnabled"
    static let historyRetentionDays = "historyRetentionDays"
    static let indexingPaused = "indexingPaused"
    static let playSound = "playSound"
    static let ocrKeepLineBreaks = "ocrKeepLineBreaks"
    static let lastAreaDisplayID = "lastAreaDisplayID"
    static let lastAreaRect = "lastAreaRect"
}

/// Typed access to user preferences for non-UI code.
enum Preferences {
    private static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        defaults.register(defaults: [
            PrefKey.copyToClipboard: true,
            PrefKey.saveToDisk: false,
            PrefKey.saveDirectory: defaultSaveDirectory.path,
            PrefKey.showQuickAccess: true,
            PrefKey.quickAccessAutoClose: 8,
            PrefKey.imageFormat: ImageFormat.png.rawValue,
            PrefKey.fileNamePattern: FileNamePattern.defaultPattern,
            PrefKey.jpegQuality: 0.9,
            PrefKey.downscaleRetina: false,
            PrefKey.windowShadow: true,
            PrefKey.showCrosshair: true,
            PrefKey.selfTimerSeconds: 5,
            PrefKey.hideDesktopIcons: false,
            PrefKey.hideDesktopWidgets: false,
            PrefKey.uploadAfterCapture: false,
            PrefKey.copyLinkAfterUpload: true,
            PrefKey.uploadFileNamePattern: Preferences.defaultUploadFileNamePattern,
            PrefKey.historyEnabled: true,
            PrefKey.historyRetentionDays: 90,
            PrefKey.indexingPaused: false,
            PrefKey.playSound: true,
            PrefKey.ocrKeepLineBreaks: true,
        ])
    }

    static var defaultSaveDirectory: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
    }

    static var copyToClipboard: Bool { defaults.bool(forKey: PrefKey.copyToClipboard) }
    static var saveToDisk: Bool { defaults.bool(forKey: PrefKey.saveToDisk) }
    static var showQuickAccess: Bool { defaults.bool(forKey: PrefKey.showQuickAccess) }
    static var downscaleRetina: Bool { defaults.bool(forKey: PrefKey.downscaleRetina) }
    static var windowShadow: Bool { defaults.bool(forKey: PrefKey.windowShadow) }
    static var showCrosshair: Bool { defaults.bool(forKey: PrefKey.showCrosshair) }

    static var hideDesktopIcons: Bool { defaults.bool(forKey: PrefKey.hideDesktopIcons) }
    static var hideDesktopWidgets: Bool { defaults.bool(forKey: PrefKey.hideDesktopWidgets) }

    static var uploadAfterCapture: Bool { defaults.bool(forKey: PrefKey.uploadAfterCapture) }
    static var copyLinkAfterUpload: Bool { defaults.bool(forKey: PrefKey.copyLinkAfterUpload) }

    static let defaultUploadFileNamePattern = "{random:10}"

    static var uploadFileNamePattern: String {
        defaults.string(forKey: PrefKey.uploadFileNamePattern) ?? defaultUploadFileNamePattern
    }

    static var historyEnabled: Bool { defaults.bool(forKey: PrefKey.historyEnabled) }
    /// Days to keep captures in the history; 0 keeps them forever.
    static var historyRetentionDays: Int { defaults.integer(forKey: PrefKey.historyRetentionDays) }
    static var indexingPaused: Bool { defaults.bool(forKey: PrefKey.indexingPaused) }

    static let selfTimerChoices = [3, 5, 10]

    static var selfTimerSeconds: Int {
        get { defaults.integer(forKey: PrefKey.selfTimerSeconds) }
        set { defaults.set(newValue, forKey: PrefKey.selfTimerSeconds) }
    }
    static var playSound: Bool { defaults.bool(forKey: PrefKey.playSound) }
    static var ocrKeepLineBreaks: Bool { defaults.bool(forKey: PrefKey.ocrKeepLineBreaks) }
    static var jpegQuality: Double { defaults.double(forKey: PrefKey.jpegQuality) }

    /// Seconds before the Quick Access overlay closes itself. 0 means never.
    static var quickAccessAutoClose: Int { defaults.integer(forKey: PrefKey.quickAccessAutoClose) }

    static var imageFormat: ImageFormat {
        ImageFormat(rawValue: defaults.string(forKey: PrefKey.imageFormat) ?? "") ?? .png
    }

    static var fileNamePattern: String {
        defaults.string(forKey: PrefKey.fileNamePattern) ?? FileNamePattern.defaultPattern
    }

    static var saveDirectory: URL {
        get {
            let path = defaults.string(forKey: PrefKey.saveDirectory) ?? defaultSaveDirectory.path
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        set { defaults.set(newValue.path, forKey: PrefKey.saveDirectory) }
    }

    /// The last area selection, used by "Capture Previous Area".
    static var lastArea: (displayID: CGDirectDisplayID, rect: CGRect)? {
        get {
            guard let id = defaults.object(forKey: PrefKey.lastAreaDisplayID) as? UInt32,
                  let rectString = defaults.string(forKey: PrefKey.lastAreaRect) else { return nil }
            let rect = NSRectFromString(rectString)
            guard rect.width > 0, rect.height > 0 else { return nil }
            return (id, rect)
        }
        set {
            if let newValue {
                defaults.set(newValue.displayID, forKey: PrefKey.lastAreaDisplayID)
                defaults.set(NSStringFromRect(newValue.rect), forKey: PrefKey.lastAreaRect)
            } else {
                defaults.removeObject(forKey: PrefKey.lastAreaDisplayID)
                defaults.removeObject(forKey: PrefKey.lastAreaRect)
            }
        }
    }
}
