import Foundation

/// One capture in the local history.
public struct HistoryItem: Identifiable, Equatable, Sendable {
    public enum DescriptionState: Int, Sendable {
        /// Waiting for a vision-model description.
        case pending = 0
        case done = 1
        case failed = -1
        /// AI descriptions are turned off.
        case skipped = 2
    }

    public var id: String
    public var createdAt: Date
    /// Image file name inside the history's image folder.
    public var fileName: String
    public var thumbnailName: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var scale: Double
    public var appName: String?
    public var windowTitle: String?
    public var savedPath: String?
    public var uploadLink: String?
    public var ocrText: String?
    public var caption: String?
    public var tags: [String]
    public var isTextRecognized: Bool
    public var descriptionState: DescriptionState
    public var embeddingModel: String?

    public init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        fileName: String,
        thumbnailName: String,
        pixelWidth: Int,
        pixelHeight: Int,
        scale: Double,
        appName: String? = nil,
        windowTitle: String? = nil,
        savedPath: String? = nil,
        uploadLink: String? = nil,
        ocrText: String? = nil,
        caption: String? = nil,
        tags: [String] = [],
        isTextRecognized: Bool = false,
        descriptionState: DescriptionState = .pending,
        embeddingModel: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.fileName = fileName
        self.thumbnailName = thumbnailName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.appName = appName
        self.windowTitle = windowTitle
        self.savedPath = savedPath
        self.uploadLink = uploadLink
        self.ocrText = ocrText
        self.caption = caption
        self.tags = tags
        self.isTextRecognized = isTextRecognized
        self.descriptionState = descriptionState
        self.embeddingModel = embeddingModel
    }

    /// Text used to build the search embedding.
    public var embeddingText: String {
        var parts: [String] = []
        if let caption, !caption.isEmpty { parts.append(caption) }
        if !tags.isEmpty { parts.append(tags.joined(separator: ", ")) }
        if let appName { parts.append(appName) }
        if let windowTitle, !windowTitle.isEmpty { parts.append(windowTitle) }
        if let ocrText, !ocrText.isEmpty { parts.append(String(ocrText.prefix(2000))) }
        return parts.joined(separator: "\n")
    }
}

public struct HistoryFilter: Equatable, Sendable {
    public var since: Date?
    public var appName: String?

    public init(since: Date? = nil, appName: String? = nil) {
        self.since = since
        self.appName = appName
    }
}

public struct IndexingStats: Equatable, Sendable {
    public var total: Int
    public var pendingText: Int
    public var pendingDescriptions: Int
    public var pendingEmbeddings: Int

    public init(total: Int, pendingText: Int, pendingDescriptions: Int, pendingEmbeddings: Int) {
        self.total = total
        self.pendingText = pendingText
        self.pendingDescriptions = pendingDescriptions
        self.pendingEmbeddings = pendingEmbeddings
    }
}

/// Capture history in SQLite with full-text search (FTS5) and embedding-based semantic search.
///
/// Not thread-safe: confine an instance to one actor or queue.
public final class HistoryStore {
    private let db: SQLiteConnection

    private static let columns = """
    c.id, c.created_at, c.file_name, c.thumbnail_name, c.pixel_width, c.pixel_height, c.scale, \
    c.app_name, c.window_title, c.saved_path, c.upload_link, c.ocr_text, c.caption, c.tags, \
    c.ocr_done, c.description_state, c.embedding_model
    """

    public init(url: URL) throws {
        db = try SQLiteConnection(path: url.path)
        try migrate()
    }

    private func migrate() throws {
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute("""
        CREATE TABLE IF NOT EXISTS captures (
            id TEXT PRIMARY KEY,
            created_at REAL NOT NULL,
            file_name TEXT NOT NULL,
            thumbnail_name TEXT NOT NULL,
            pixel_width INTEGER NOT NULL,
            pixel_height INTEGER NOT NULL,
            scale REAL NOT NULL,
            app_name TEXT,
            window_title TEXT,
            saved_path TEXT,
            upload_link TEXT,
            ocr_text TEXT,
            caption TEXT,
            tags TEXT,
            ocr_done INTEGER NOT NULL DEFAULT 0,
            description_state INTEGER NOT NULL DEFAULT 0,
            embedding BLOB,
            embedding_model TEXT
        );
        CREATE INDEX IF NOT EXISTS captures_created_at ON captures(created_at DESC);
        CREATE VIRTUAL TABLE IF NOT EXISTS captures_fts USING fts5(
            ocr_text, caption, tags, app_name, window_title,
            content='captures', content_rowid='rowid', tokenize='unicode61 remove_diacritics 2'
        );
        CREATE TRIGGER IF NOT EXISTS captures_ai AFTER INSERT ON captures BEGIN
            INSERT INTO captures_fts(rowid, ocr_text, caption, tags, app_name, window_title)
            VALUES (new.rowid, new.ocr_text, new.caption, new.tags, new.app_name, new.window_title);
        END;
        CREATE TRIGGER IF NOT EXISTS captures_ad AFTER DELETE ON captures BEGIN
            INSERT INTO captures_fts(captures_fts, rowid, ocr_text, caption, tags, app_name, window_title)
            VALUES ('delete', old.rowid, old.ocr_text, old.caption, old.tags, old.app_name, old.window_title);
        END;
        CREATE TRIGGER IF NOT EXISTS captures_au AFTER UPDATE OF ocr_text, caption, tags, app_name, window_title ON captures BEGIN
            INSERT INTO captures_fts(captures_fts, rowid, ocr_text, caption, tags, app_name, window_title)
            VALUES ('delete', old.rowid, old.ocr_text, old.caption, old.tags, old.app_name, old.window_title);
            INSERT INTO captures_fts(rowid, ocr_text, caption, tags, app_name, window_title)
            VALUES (new.rowid, new.ocr_text, new.caption, new.tags, new.app_name, new.window_title);
        END;
        """)
    }

    // MARK: Writing

    public func insert(_ item: HistoryItem) throws {
        try db.run("""
        INSERT INTO captures (id, created_at, file_name, thumbnail_name, pixel_width, pixel_height, scale,
            app_name, window_title, saved_path, upload_link, ocr_text, caption, tags, ocr_done, description_state)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .text(item.id), .real(item.createdAt.timeIntervalSince1970), .text(item.fileName),
            .text(item.thumbnailName), .integer(Int64(item.pixelWidth)), .integer(Int64(item.pixelHeight)),
            .real(item.scale), SQLValue(item.appName), SQLValue(item.windowTitle), SQLValue(item.savedPath),
            SQLValue(item.uploadLink), SQLValue(item.ocrText), SQLValue(item.caption),
            SQLValue(item.tags.isEmpty ? nil : item.tags.joined(separator: ", ")),
            .integer(item.isTextRecognized ? 1 : 0), .integer(Int64(item.descriptionState.rawValue)),
        ])
    }

    public func updateRecognizedText(id: String, text: String) throws {
        try db.run("UPDATE captures SET ocr_text = ?, ocr_done = 1, embedding_model = NULL WHERE id = ?", [
            .text(text), .text(id),
        ])
    }

    public func updateDescription(id: String, caption: String, tags: [String]) throws {
        try db.run("""
        UPDATE captures SET caption = ?, tags = ?, description_state = 1, embedding_model = NULL WHERE id = ?
        """, [.text(caption), .text(tags.joined(separator: ", ")), .text(id)])
    }

    public func setDescriptionState(id: String, _ state: HistoryItem.DescriptionState) throws {
        try db.run("UPDATE captures SET description_state = ? WHERE id = ?", [.integer(Int64(state.rawValue)), .text(id)])
    }

    /// Moves every capture in `from` states to `to`, e.g. to (re)queue AI descriptions.
    public func setDescriptionState(from states: [HistoryItem.DescriptionState], to state: HistoryItem.DescriptionState) throws {
        guard !states.isEmpty else { return }
        let placeholders = states.map { _ in "?" }.joined(separator: ", ")
        try db.run(
            "UPDATE captures SET description_state = ? WHERE description_state IN (\(placeholders))",
            [.integer(Int64(state.rawValue))] + states.map { .integer(Int64($0.rawValue)) }
        )
    }

    public func updateEmbedding(id: String, vector: [Float], model: String) throws {
        let normalized = VectorMath.normalized(vector)
        try db.run("UPDATE captures SET embedding = ?, embedding_model = ? WHERE id = ?", [
            .blob(VectorMath.data(from: normalized)), .text(model), .text(id),
        ])
    }

    public func setUploadLink(id: String, link: String) throws {
        try db.run("UPDATE captures SET upload_link = ? WHERE id = ?", [.text(link), .text(id)])
    }

    public func setSavedPath(id: String, path: String) throws {
        try db.run("UPDATE captures SET saved_path = ? WHERE id = ?", [.text(path), .text(id)])
    }

    public func delete(id: String) throws {
        try db.run("DELETE FROM captures WHERE id = ?", [.text(id)])
    }

    public func deleteAll() throws {
        try db.run("DELETE FROM captures")
    }

    // MARK: Reading

    public func item(id: String) throws -> HistoryItem? {
        try items(sql: "SELECT \(Self.columns) FROM captures c WHERE c.id = ?", [.text(id)]).first
    }

    public func recent(limit: Int, offset: Int = 0, filter: HistoryFilter = HistoryFilter()) throws -> [HistoryItem] {
        let (clause, values) = Self.filterClause(filter)
        return try items(
            sql: "SELECT \(Self.columns) FROM captures c WHERE 1 = 1\(clause) ORDER BY c.created_at DESC LIMIT ? OFFSET ?",
            values + [.integer(Int64(limit)), .integer(Int64(offset))]
        )
    }

    public func count(filter: HistoryFilter = HistoryFilter()) throws -> Int {
        let (clause, values) = Self.filterClause(filter)
        let statement = try db.prepare("SELECT COUNT(*) FROM captures c WHERE 1 = 1\(clause)", values)
        return try statement.step() ? Int(statement.int(0)) : 0
    }

    public func appNames() throws -> [String] {
        let statement = try db.prepare(
            "SELECT DISTINCT app_name FROM captures WHERE app_name IS NOT NULL ORDER BY app_name COLLATE NOCASE"
        )
        var names: [String] = []
        while try statement.step() {
            if let name = statement.string(0) { names.append(name) }
        }
        return names
    }

    public func items(olderThan date: Date) throws -> [HistoryItem] {
        try items(sql: "SELECT \(Self.columns) FROM captures c WHERE c.created_at < ?", [.real(date.timeIntervalSince1970)])
    }

    public func allItems() throws -> [HistoryItem] {
        try items(sql: "SELECT \(Self.columns) FROM captures c", [])
    }

    public func pendingTextRecognition(limit: Int) throws -> [HistoryItem] {
        try items(
            sql: "SELECT \(Self.columns) FROM captures c WHERE c.ocr_done = 0 ORDER BY c.created_at DESC LIMIT ?",
            [.integer(Int64(limit))]
        )
    }

    public func pendingDescriptions(limit: Int) throws -> [HistoryItem] {
        try items(
            sql: """
            SELECT \(Self.columns) FROM captures c
            WHERE c.ocr_done = 1 AND c.description_state = 0 ORDER BY c.created_at DESC LIMIT ?
            """,
            [.integer(Int64(limit))]
        )
    }

    /// Captures whose text is final (OCR done, description not pending) but that lack an embedding from `model`.
    public func pendingEmbeddings(model: String, limit: Int) throws -> [HistoryItem] {
        try items(
            sql: """
            SELECT \(Self.columns) FROM captures c
            WHERE c.ocr_done = 1 AND c.description_state != 0
              AND (c.embedding_model IS NULL OR c.embedding_model != ?)
            ORDER BY c.created_at DESC LIMIT ?
            """,
            [.text(model), .integer(Int64(limit))]
        )
    }

    public func indexingStats(embeddingModel: String?) throws -> IndexingStats {
        let statement = try db.prepare("""
        SELECT COUNT(*),
               SUM(CASE WHEN ocr_done = 0 THEN 1 ELSE 0 END),
               SUM(CASE WHEN description_state = 0 THEN 1 ELSE 0 END),
               SUM(CASE WHEN embedding_model IS NULL OR embedding_model != ? THEN 1 ELSE 0 END)
        FROM captures
        """, [SQLValue(embeddingModel ?? "")])
        guard try statement.step() else { return IndexingStats(total: 0, pendingText: 0, pendingDescriptions: 0, pendingEmbeddings: 0) }
        return IndexingStats(
            total: Int(statement.int(0)),
            pendingText: Int(statement.int(1)),
            pendingDescriptions: Int(statement.int(2)),
            pendingEmbeddings: embeddingModel == nil ? 0 : Int(statement.int(3))
        )
    }

    // MARK: Search

    /// Hybrid search: FTS5 keyword ranking fused with embedding similarity (reciprocal rank fusion).
    /// - Parameters:
    ///   - queryVector: Embedding of the query from `embeddingModel`, or nil for keyword-only search.
    public func search(
        text: String,
        queryVector: [Float]? = nil,
        embeddingModel: String? = nil,
        filter: HistoryFilter = HistoryFilter(),
        limit: Int = 200
    ) throws -> [HistoryItem] {
        let rrfK = 60.0
        var scores: [String: Double] = [:]
        let (clause, filterValues) = Self.filterClause(filter)

        if let match = Self.ftsQuery(from: text) {
            let statement = try db.prepare("""
            SELECT c.id FROM captures_fts f JOIN captures c ON c.rowid = f.rowid
            WHERE captures_fts MATCH ?\(clause)
            ORDER BY bm25(captures_fts, 1.0, 2.0, 2.0, 1.5, 1.5) LIMIT 200
            """, [.text(match)] + filterValues)
            var rank = 0
            while try statement.step() {
                if let id = statement.string(0) { scores[id, default: 0] += 1 / (rrfK + Double(rank + 1)) }
                rank += 1
            }
        }

        if let queryVector, let embeddingModel, !queryVector.isEmpty {
            let query = VectorMath.normalized(queryVector)
            let statement = try db.prepare("""
            SELECT c.id, c.embedding FROM captures c
            WHERE c.embedding IS NOT NULL AND c.embedding_model = ?\(clause)
            """, [.text(embeddingModel)] + filterValues)
            var similarities: [(id: String, similarity: Float)] = []
            while try statement.step() {
                guard let id = statement.string(0), let data = statement.data(1) else { continue }
                similarities.append((id, VectorMath.dot(query, VectorMath.vector(from: data))))
            }
            similarities.sort { $0.similarity > $1.similarity }
            // Keep the semantic neighbourhood of the best match; distant items are noise.
            let best = similarities.first?.similarity ?? 0
            for (rank, hit) in similarities.prefix(50).enumerated() where hit.similarity > 0 && hit.similarity >= best - 0.2 {
                scores[hit.id, default: 0] += 1 / (rrfK + Double(rank + 1))
            }
        }

        let orderedIDs = scores.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
        guard !orderedIDs.isEmpty else { return [] }
        let placeholders = orderedIDs.map { _ in "?" }.joined(separator: ", ")
        let found = try items(
            sql: "SELECT \(Self.columns) FROM captures c WHERE c.id IN (\(placeholders))",
            orderedIDs.map { .text($0) }
        )
        let byID = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
        return orderedIDs.compactMap { byID[$0] }
    }

    /// Turns free text into an FTS5 query: every word must match, as a prefix.
    public static func ftsQuery(from text: String) -> String? {
        let words = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    // MARK: Helpers

    private static func filterClause(_ filter: HistoryFilter) -> (String, [SQLValue]) {
        var clause = ""
        var values: [SQLValue] = []
        if let since = filter.since {
            clause += " AND c.created_at >= ?"
            values.append(.real(since.timeIntervalSince1970))
        }
        if let appName = filter.appName {
            clause += " AND c.app_name = ?"
            values.append(.text(appName))
        }
        return (clause, values)
    }

    private func items(sql: String, _ values: [SQLValue]) throws -> [HistoryItem] {
        let statement = try db.prepare(sql, values)
        var result: [HistoryItem] = []
        while try statement.step() {
            result.append(HistoryItem(
                id: statement.string(0) ?? "",
                createdAt: Date(timeIntervalSince1970: statement.double(1)),
                fileName: statement.string(2) ?? "",
                thumbnailName: statement.string(3) ?? "",
                pixelWidth: Int(statement.int(4)),
                pixelHeight: Int(statement.int(5)),
                scale: statement.double(6),
                appName: statement.string(7),
                windowTitle: statement.string(8),
                savedPath: statement.string(9),
                uploadLink: statement.string(10),
                ocrText: statement.string(11),
                caption: statement.string(12),
                tags: (statement.string(13) ?? "")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty },
                isTextRecognized: statement.int(14) != 0,
                descriptionState: HistoryItem.DescriptionState(rawValue: Int(statement.int(15))) ?? .pending,
                embeddingModel: statement.string(16)
            ))
        }
        return result
    }
}
