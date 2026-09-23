import AppKit

/// Links the bundled `oneshot` script into a folder on the user's PATH.
@MainActor
enum CLIInstaller {
    private static var toolURL: URL? {
        Bundle.main.url(forResource: "oneshot", withExtension: nil)
    }

    /// Where the link goes: Homebrew's bin, /usr/local/bin, or ~/.local/bin as a fallback.
    private static var candidateDirectories: [URL] {
        [
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin"),
        ]
    }

    static var installedLink: URL? {
        candidateDirectories
            .map { $0.appendingPathComponent("oneshot") }
            .first { (try? FileManager.default.destinationOfSymbolicLink(atPath: $0.path)) != nil }
    }

    static func install() {
        guard let toolURL else {
            present("The command line tool is missing from the app bundle.", informative: "")
            return
        }
        let fileManager = FileManager.default
        let directory = candidateDirectories.first { directory in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory)
                && isDirectory.boolValue && fileManager.isWritableFile(atPath: directory.path)
        } ?? candidateDirectories[2]

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let link = directory.appendingPathComponent("oneshot")
            if (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) != nil || fileManager.fileExists(atPath: link.path) {
                try fileManager.removeItem(at: link)
            }
            try fileManager.createSymbolicLink(at: link, withDestinationURL: toolURL)
            let pathHint = directory == candidateDirectories[2]
                ? "Make sure ~/.local/bin is in your PATH."
                : "Try it with: oneshot capture-area"
            present("Installed \(link.path)", informative: pathHint)
        } catch {
            present("Could not install the command line tool", informative: error.localizedDescription)
        }
    }

    private static func present(_ message: String, informative: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.runModal()
    }
}
