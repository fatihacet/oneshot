import AppKit
import OneShotCore
import UniformTypeIdentifiers

/// Uploads captures and files to the configured bucket and hands out the link.
@MainActor
final class Uploader {
    static let shared = Uploader()

    func upload(_ capture: Capture) {
        let format = Preferences.imageFormat
        guard let data = ImageExporter.encode(capture, as: format) else {
            Toast.show("Could not encode the image", symbol: "exclamationmark.triangle.fill")
            return
        }
        let context = FileNamePattern.Context(
            date: capture.date, appName: capture.appName, pixelSize: capture.image.pixelSize
        )
        Task {
            let record = await upload(data: data, fileExtension: format.fileExtension, contentType: format.utType, context: context)
            if let record { HistoryRecorder.noteUploaded(capture, link: record.link) }
        }
    }

    func upload(fileAt url: URL) {
        upload(filesAt: [url])
    }

    /// Uploads files one after another. With several files, all links are copied together.
    func upload(filesAt urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            var links: [String] = []
            for url in urls {
                if let record = await upload(fileAt: url) { links.append(record.link) }
            }
            if links.count > 1 {
                if Preferences.copyLinkAfterUpload {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(links.joined(separator: "\n"), forType: .string)
                    Toast.show("Uploaded \(links.count) files – links copied", symbol: "link")
                } else {
                    Toast.show("Uploaded \(links.count) files", symbol: "icloud.and.arrow.up")
                }
            }
        }
    }

    private func upload(fileAt url: URL) async -> UploadRecord? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            Toast.show("Could not read \(url.lastPathComponent)", symbol: "exclamationmark.triangle.fill")
            return nil
        }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        return await upload(data: data, fileExtension: url.pathExtension, contentType: type, context: .init())
    }

    /// Uploads files copied in Finder, or else the image on the clipboard.
    func uploadClipboard() {
        let files = Self.clipboardFileURLs()
        if !files.isEmpty {
            upload(filesAt: files)
        } else if let capture = Capture.fromClipboard() {
            upload(capture)
        } else {
            Toast.show("No image or file on the clipboard", symbol: "doc.on.clipboard")
        }
    }

    /// Regular files on the clipboard, e.g. copied in Finder.
    static func clipboardFileURLs() -> [URL] {
        let urls = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    /// Lets the user pick files to upload.
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "Upload Files"
        panel.prompt = "Upload"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = Preferences.saveDirectory
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        upload(filesAt: panel.urls)
    }

    /// The newest recordings in the screenshots folder.
    static func recentRecordings(limit: Int = 5) -> [(url: URL, date: Date)] {
        let extensions = Set(RecordingFormat.allCases.map(\.fileExtension))
        let keys: [URLResourceKey] = [.creationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Preferences.saveDirectory, includingPropertiesForKeys: keys, options: .skipsHiddenFiles
        )) ?? []
        return files
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { (url: $0.0, date: $0.1) }
    }

    @discardableResult
    func upload(
        data: Data,
        fileExtension: String,
        contentType: UTType,
        context: FileNamePattern.Context
    ) async -> UploadRecord? {
        let configuration = UploadSettings.configuration
        let client: S3Client
        do {
            client = try UploadSettings.client(for: configuration)
        } catch {
            Self.showSetup()
            return nil
        }

        let baseName = FileNamePattern.fileName(pattern: Preferences.uploadFileNamePattern, context: context)
        let key = configuration.objectKey(for: "\(baseName).\(fileExtension)")
        Toast.show("Uploading…", symbol: "icloud.and.arrow.up", duration: 120)

        do {
            try await client.putObject(
                key: key, data: data, contentType: contentType.preferredMIMEType ?? "application/octet-stream"
            )
            let link = try client.link(for: key)
            let record = UploadRecord(
                key: key, link: link.absoluteString, date: Date(), byteCount: data.count,
                contentType: contentType.preferredMIMEType ?? "", configuration: configuration
            )
            UploadHistory.shared.add(record)
            if Preferences.copyLinkAfterUpload {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(link.absoluteString, forType: .string)
                Toast.show("Uploaded – link copied", symbol: "link")
            } else {
                Toast.show("Uploaded", symbol: "icloud.and.arrow.up")
            }
            return record
        } catch {
            NSLog("OneShot: upload failed: \(error)")
            Toast.show("Upload failed: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill", duration: 4)
            return nil
        }
    }

    /// Points the user to the upload settings when no bucket is set up.
    static func showSetup() {
        Toast.show("Set up uploads in Settings › Upload", symbol: "icloud.slash")
        SettingsWindowController.shared.show(tab: .upload)
    }

    /// Uploads and deletes a tiny object to verify credentials and permissions.
    static func testConnection(configuration: S3Configuration, credentials: AWSCredentials) async throws {
        let client = S3Client(configuration: configuration, credentials: credentials)
        let key = configuration.objectKey(for: ".oneshot-connection-test-\(UUID().uuidString.prefix(8)).txt")
        try await client.putObject(key: key, data: Data("OneShot connection test".utf8), contentType: "text/plain")
        try await client.deleteObject(key: key)
    }
}
