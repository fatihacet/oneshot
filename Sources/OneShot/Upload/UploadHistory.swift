import Foundation
import OneShotCore

struct UploadRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var key: String
    var link: String
    var date: Date
    var byteCount: Int
    var contentType: String
    /// Bucket settings at upload time, so the object can be deleted after settings change.
    var configuration: S3Configuration

    var fileName: String { (key as NSString).lastPathComponent }
}

/// Uploads made from this Mac, stored as JSON in Application Support.
@MainActor
final class UploadHistory: ObservableObject {
    static let shared = UploadHistory()

    @Published private(set) var records: [UploadRecord] = []

    private let fileURL: URL = {
        let directory = AppPaths.applicationSupport
        return directory.appendingPathComponent("uploads.json")
    }()

    private init() {
        load()
    }

    func add(_ record: UploadRecord) {
        records.insert(record, at: 0)
        save()
    }

    func remove(_ record: UploadRecord) {
        records.removeAll { $0.id == record.id }
        save()
    }

    /// Deletes the object from its bucket, then forgets the record.
    func deleteRemote(_ record: UploadRecord) async throws {
        let client = try UploadSettings.client(for: record.configuration)
        try await client.deleteObject(key: record.key)
        remove(record)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? decoder.decode([UploadRecord].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
