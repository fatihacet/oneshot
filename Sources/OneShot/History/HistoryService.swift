import AppKit
import ImageIO
import OneShotCore
import UniformTypeIdentifiers

extension Notification.Name {
    /// Posted on the main thread when captures are added, changed or removed.
    static let historyDidChange = Notification.Name("OneShotHistoryDidChange")
}

/// Owns the history database and its image files. All database access goes through this actor.
actor HistoryService {
    static let shared = HistoryService()

    nonisolated let directory: URL
    nonisolated let imagesDirectory: URL
    nonisolated let thumbnailsDirectory: URL
    private var store: HistoryStore?

    private init() {
        directory = AppPaths.applicationSupport.appendingPathComponent("History", isDirectory: true)
        imagesDirectory = directory.appendingPathComponent("Images", isDirectory: true)
        thumbnailsDirectory = directory.appendingPathComponent("Thumbnails", isDirectory: true)
    }

    private func database() throws -> HistoryStore {
        if let store { return store }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
        let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        self.store = store
        return store
    }

    nonisolated func imageURL(for item: HistoryItem) -> URL {
        imagesDirectory.appendingPathComponent(item.fileName)
    }

    nonisolated func thumbnailURL(for item: HistoryItem) -> URL {
        thumbnailsDirectory.appendingPathComponent(item.thumbnailName)
    }

    // MARK: Recording

    /// Stores the image and a thumbnail, then inserts a record with the capture's metadata.
    func record(
        id: String,
        image: CGImage,
        scale: CGFloat,
        date: Date,
        appName: String?,
        windowTitle: String?,
        savedPath: String?,
        describe: Bool
    ) {
        do {
            let store = try database()
            let fileName = "\(id).heic"
            let thumbnailName = "\(id).jpg"
            try Self.write(image, to: imagesDirectory.appendingPathComponent(fileName), type: .heic, quality: 0.85)
            let thumbnail = image.resized(toFit: 480) ?? image
            try Self.write(thumbnail, to: thumbnailsDirectory.appendingPathComponent(thumbnailName), type: .jpeg, quality: 0.8)
            try store.insert(HistoryItem(
                id: id, createdAt: date, fileName: fileName, thumbnailName: thumbnailName,
                pixelWidth: image.width, pixelHeight: image.height, scale: Double(scale),
                appName: appName, windowTitle: windowTitle, savedPath: savedPath,
                descriptionState: describe ? .pending : .skipped
            ))
            notifyChange()
        } catch {
            NSLog("OneShot: could not record capture in history: \(error)")
        }
    }

    // MARK: Queries

    func recent(limit: Int, filter: HistoryFilter) -> [HistoryItem] {
        (try? database().recent(limit: limit, filter: filter)) ?? []
    }

    func search(text: String, queryVector: [Float]?, embeddingModel: String?, filter: HistoryFilter) -> [HistoryItem] {
        (try? database().search(text: text, queryVector: queryVector, embeddingModel: embeddingModel, filter: filter)) ?? []
    }

    func item(id: String) -> HistoryItem? {
        try? database().item(id: id)
    }

    func appNames() -> [String] {
        (try? database().appNames()) ?? []
    }

    func count() -> Int {
        (try? database().count()) ?? 0
    }

    func stats(embeddingModel: String?) -> IndexingStats? {
        try? database().indexingStats(embeddingModel: embeddingModel)
    }

    /// Bytes used by images, thumbnails and the database.
    func diskUsage() -> Int64 {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let url = enumerator?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    // MARK: Updates used by the indexer and actions

    func pendingTextRecognition(limit: Int) -> [HistoryItem] {
        (try? database().pendingTextRecognition(limit: limit)) ?? []
    }

    func pendingDescriptions(limit: Int) -> [HistoryItem] {
        (try? database().pendingDescriptions(limit: limit)) ?? []
    }

    func pendingEmbeddings(model: String, limit: Int) -> [HistoryItem] {
        (try? database().pendingEmbeddings(model: model, limit: limit)) ?? []
    }

    func updateRecognizedText(id: String, text: String) {
        try? database().updateRecognizedText(id: id, text: text)
        notifyChange()
    }

    func updateDescription(id: String, caption: String, tags: [String]) {
        try? database().updateDescription(id: id, caption: caption, tags: tags)
        notifyChange()
    }

    func setDescriptionState(id: String, _ state: HistoryItem.DescriptionState) {
        try? database().setDescriptionState(id: id, state)
    }

    func setDescriptionState(from states: [HistoryItem.DescriptionState], to state: HistoryItem.DescriptionState) {
        try? database().setDescriptionState(from: states, to: state)
        notifyChange()
    }

    func updateEmbedding(id: String, vector: [Float], model: String) {
        try? database().updateEmbedding(id: id, vector: vector, model: model)
    }

    func setUploadLink(id: String, link: String) {
        try? database().setUploadLink(id: id, link: link)
        notifyChange()
    }

    func setSavedPath(id: String, path: String) {
        try? database().setSavedPath(id: id, path: path)
        notifyChange()
    }

    // MARK: Deleting

    func delete(_ item: HistoryItem) {
        try? database().delete(id: item.id)
        removeFiles(of: item)
        notifyChange()
    }

    func deleteAll() {
        guard let store = try? database() else { return }
        try? store.deleteAll()
        for folder in [imagesDirectory, thumbnailsDirectory] {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            files.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        notifyChange()
    }

    /// Deletes captures older than `days` days. 0 keeps everything.
    func applyRetention(days: Int) {
        guard days > 0, let store = try? database() else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let expired = (try? store.items(olderThan: cutoff)) ?? []
        guard !expired.isEmpty else { return }
        for item in expired {
            try? store.delete(id: item.id)
            removeFiles(of: item)
        }
        notifyChange()
    }

    private func removeFiles(of item: HistoryItem) {
        try? FileManager.default.removeItem(at: imageURL(for: item))
        try? FileManager.default.removeItem(at: thumbnailURL(for: item))
    }

    private nonisolated func notifyChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .historyDidChange, object: nil)
        }
    }

    private static func write(_ image: CGImage, to url: URL, type: UTType, quality: Double) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CaptureError.emptyImage
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.emptyImage }
    }
}

extension CGImage {
    /// Scales down so the longer side is at most `maxDimension` pixels.
    func resized(toFit maxDimension: CGFloat) -> CGImage? {
        let longest = CGFloat(max(width, height))
        guard longest > maxDimension else { return self }
        return resized(by: maxDimension / longest)
    }
}

/// Records deliverable captures in the history, if enabled.
@MainActor
enum HistoryRecorder {
    /// Assigns a history ID to `capture` and stores it in the background.
    static func record(_ capture: inout Capture, savedURL: URL?) {
        guard Preferences.historyEnabled else { return }
        let id = UUID().uuidString
        capture.historyID = id
        let snapshot = capture
        let describe = AISettings.describesCaptures
        Task.detached(priority: .utility) {
            await HistoryService.shared.record(
                id: id, image: snapshot.image, scale: snapshot.scale, date: snapshot.date,
                appName: snapshot.appName, windowTitle: snapshot.windowTitle,
                savedPath: savedURL?.path, describe: describe
            )
            await HistoryService.shared.applyRetention(days: Preferences.historyRetentionDays)
            await HistoryIndexer.shared.wake()
        }
    }

    static func noteSaved(_ capture: Capture, at url: URL) {
        guard let id = capture.historyID else { return }
        Task { await HistoryService.shared.setSavedPath(id: id, path: url.path) }
    }

    static func noteUploaded(_ capture: Capture, link: String) {
        guard let id = capture.historyID else { return }
        Task { await HistoryService.shared.setUploadLink(id: id, link: link) }
    }
}
