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
        Task {
            do {
                let data = try Data(contentsOf: url)
                let type = UTType(filenameExtension: url.pathExtension) ?? .data
                await upload(data: data, fileExtension: url.pathExtension, contentType: type, context: .init())
            } catch {
                Toast.show("Could not read the file", symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    /// Uploads the image on the clipboard, if any.
    func uploadClipboardImage() {
        guard let capture = Capture.fromClipboard() else {
            Toast.show("No image on the clipboard", symbol: "doc.on.clipboard")
            return
        }
        upload(capture)
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
