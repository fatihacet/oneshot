import Foundation
import OneShotCore
import SQLite3
import Testing

struct HistoryStoreTests {
    private func makeStore() throws -> HistoryStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).sqlite")
        return try HistoryStore(url: url)
    }

    private func item(_ id: String, app: String = "Safari", daysAgo: Double = 0, text: String? = nil) -> HistoryItem {
        HistoryItem(
            id: id,
            createdAt: Date().addingTimeInterval(-daysAgo * 86_400),
            fileName: "\(id).heic",
            thumbnailName: "\(id).jpg",
            pixelWidth: 100,
            pixelHeight: 50,
            scale: 2,
            appName: app,
            ocrText: text,
            isTextRecognized: text != nil
        )
    }

    @Test func insertsAndListsNewestFirst() throws {
        let store = try makeStore()
        try store.insert(item("old", daysAgo: 3))
        try store.insert(item("new"))
        #expect(try store.recent(limit: 10).map(\.id) == ["new", "old"])
        #expect(try store.count() == 2)
    }

    @Test func findsTextByPrefixAndFilters() throws {
        let store = try makeStore()
        try store.insert(item("a", app: "Safari", text: "Stripe dashboard revenue"))
        try store.insert(item("b", app: "Xcode", daysAgo: 10, text: "Build failed: missing module"))
        try store.updateDescription(id: "b", caption: "Xcode build error", tags: ["xcode", "error"])

        #expect(try store.search(text: "strip").map(\.id) == ["a"])
        #expect(try store.search(text: "build error").map(\.id) == ["b"])
        #expect(try store.search(text: "safari").map(\.id) == ["a"])
        #expect(try store.search(text: "build", filter: HistoryFilter(since: Date().addingTimeInterval(-86_400))).isEmpty)
        #expect(try store.search(text: "module", filter: HistoryFilter(appName: "Xcode")).map(\.id) == ["b"])
        #expect(try store.appNames() == ["Safari", "Xcode"])
    }

    @Test func updatesSearchIndexOnChangeAndDelete() throws {
        let store = try makeStore()
        try store.insert(item("a"))
        #expect(try store.search(text: "invoice").isEmpty)
        try store.updateRecognizedText(id: "a", text: "Invoice #42")
        #expect(try store.search(text: "invoice").map(\.id) == ["a"])
        try store.delete(id: "a")
        #expect(try store.search(text: "invoice").isEmpty)
    }

    @Test func ranksBySemanticSimilarity() throws {
        let store = try makeStore()
        for id in ["cat", "dog", "car"] { try store.insert(item(id, text: "")) }
        try store.updateEmbedding(id: "cat", vector: [1, 0.1, 0], model: "m")
        try store.updateEmbedding(id: "dog", vector: [0.8, 0.3, 0], model: "m")
        try store.updateEmbedding(id: "car", vector: [0, 0, 1], model: "m")

        let results = try store.search(text: "", queryVector: [1, 0, 0], embeddingModel: "m")
        #expect(results.map(\.id) == ["cat", "dog"])
        // A different model's vectors are never compared.
        #expect(try store.search(text: "", queryVector: [1, 0, 0], embeddingModel: "other").isEmpty)
    }

    @Test func fusesKeywordAndSemanticMatches() throws {
        let store = try makeStore()
        try store.insert(item("keyword", text: "quarterly report"))
        try store.insert(item("both", text: "quarterly numbers"))
        try store.insert(item("semantic", text: "revenue chart"))
        try store.updateEmbedding(id: "both", vector: [1, 0], model: "m")
        try store.updateEmbedding(id: "semantic", vector: [0.95, 0.1], model: "m")
        try store.updateEmbedding(id: "keyword", vector: [0, 1], model: "m")

        let results = try store.search(text: "quarterly", queryVector: [1, 0], embeddingModel: "m").map(\.id)
        #expect(results.first == "both")
        #expect(Set(results) == ["both", "keyword", "semantic"])
    }

    @Test func tracksIndexingQueues() throws {
        let store = try makeStore()
        try store.insert(item("a"))
        #expect(try store.pendingTextRecognition(limit: 10).map(\.id) == ["a"])
        #expect(try store.pendingImageLabels(limit: 10).map(\.id) == ["a"])
        try store.updateRecognizedText(id: "a", text: "hello")
        #expect(try store.pendingDescriptions(limit: 10).map(\.id) == ["a"])
        // Embeddings wait for the description and the image labels.
        #expect(try store.pendingEmbeddings(model: "m", limit: 10).isEmpty)
        try store.setDescriptionState(from: [.pending], to: .skipped)
        #expect(try store.pendingEmbeddings(model: "m", limit: 10).isEmpty)
        try store.updateImageLabels(id: "a", labels: [])
        #expect(try store.pendingImageLabels(limit: 10).isEmpty)
        #expect(try store.pendingEmbeddings(model: "m", limit: 10).map(\.id) == ["a"])
        try store.updateEmbedding(id: "a", vector: [1, 2], model: "m")
        #expect(try store.pendingEmbeddings(model: "m", limit: 10).isEmpty)
        #expect(try store.pendingEmbeddings(model: "other", limit: 10).map(\.id) == ["a"])

        let stats = try store.indexingStats(embeddingModel: "m")
        #expect(stats == IndexingStats(total: 1, pendingText: 0, pendingLabels: 0, pendingDescriptions: 0, pendingEmbeddings: 0))
    }

    @Test func findsCapturesByImageLabels() throws {
        let store = try makeStore()
        try store.insert(item("photo", text: ""))
        try store.insert(item("page", text: "Meeting notes"))
        try store.updateImageLabels(id: "photo", labels: ["sunset sunrise", "sky", "outdoor"])
        try store.updateImageLabels(id: "page", labels: ["document"])

        #expect(try store.search(text: "sunset").map(\.id) == ["photo"])
        #expect(try store.search(text: "document").map(\.id) == ["page"])
        let photo = try #require(try store.item(id: "photo"))
        #expect(photo.labels == ["sunset sunrise", "sky", "outdoor"])
        #expect(photo.isImageLabeled)
        #expect(photo.embeddingText.contains("sunset sunrise"))
    }

    @Test func relabelingQueuesANewEmbedding() throws {
        let store = try makeStore()
        try store.insert(item("a", text: "hello"))
        try store.setDescriptionState(from: [.pending], to: .skipped)
        try store.updateImageLabels(id: "a", labels: ["screenshot"])
        try store.updateEmbedding(id: "a", vector: [1, 0], model: "m")
        #expect(try store.pendingEmbeddings(model: "m", limit: 10).isEmpty)
        try store.updateImageLabels(id: "a", labels: ["screenshot", "chart"])
        #expect(try store.pendingEmbeddings(model: "m", limit: 10).map(\.id) == ["a"])
    }

    /// A history created before image labels keeps its captures and search index, and queues them for labels.
    @Test func migratesHistoryFromBeforeImageLabels() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-v0-\(UUID().uuidString).sqlite")
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        let originalSchema = """
        CREATE TABLE captures (
            id TEXT PRIMARY KEY, created_at REAL NOT NULL, file_name TEXT NOT NULL, thumbnail_name TEXT NOT NULL,
            pixel_width INTEGER NOT NULL, pixel_height INTEGER NOT NULL, scale REAL NOT NULL,
            app_name TEXT, window_title TEXT, saved_path TEXT, upload_link TEXT, ocr_text TEXT, caption TEXT, tags TEXT,
            ocr_done INTEGER NOT NULL DEFAULT 0, description_state INTEGER NOT NULL DEFAULT 0,
            embedding BLOB, embedding_model TEXT
        );
        CREATE VIRTUAL TABLE captures_fts USING fts5(
            ocr_text, caption, tags, app_name, window_title,
            content='captures', content_rowid='rowid', tokenize='unicode61 remove_diacritics 2'
        );
        CREATE TRIGGER captures_ai AFTER INSERT ON captures BEGIN
            INSERT INTO captures_fts(rowid, ocr_text, caption, tags, app_name, window_title)
            VALUES (new.rowid, new.ocr_text, new.caption, new.tags, new.app_name, new.window_title);
        END;
        INSERT INTO captures (id, created_at, file_name, thumbnail_name, pixel_width, pixel_height, scale,
            app_name, ocr_text, ocr_done, description_state, embedding_model)
        VALUES ('old', 0, 'old.heic', 'old.jpg', 100, 50, 2, 'Safari', 'Invoice 42', 1, 2, 'apple-nl-sentence-en');
        """
        #expect(sqlite3_exec(handle, originalSchema, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)

        let store = try HistoryStore(url: url)
        #expect(try store.search(text: "invoice").map(\.id) == ["old"])
        #expect(try store.pendingImageLabels(limit: 10).map(\.id) == ["old"])
        try store.updateImageLabels(id: "old", labels: ["document"])
        #expect(try store.search(text: "document").map(\.id) == ["old"])
        // The labels change the searchable text, so the capture is embedded again.
        #expect(try store.pendingEmbeddings(model: "apple-nl-sentence-en", limit: 10).map(\.id) == ["old"])

        // Opening again does not rerun the migration.
        let reopened = try HistoryStore(url: url)
        #expect(try reopened.search(text: "document").map(\.id) == ["old"])
        #expect(try reopened.pendingImageLabels(limit: 10).isEmpty)
    }

    @Test func buildsSafeFTSQueries() {
        #expect(HistoryStore.ftsQuery(from: "foo \"bar\" OR baz*") == "\"foo\"* \"bar\"* \"OR\"* \"baz\"*")
        #expect(HistoryStore.ftsQuery(from: "  ,; ") == nil)
    }
}
