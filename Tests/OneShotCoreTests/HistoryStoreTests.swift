import Foundation
import OneShotCore
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
        try store.updateRecognizedText(id: "a", text: "hello")
        #expect(try store.pendingDescriptions(limit: 10).map(\.id) == ["a"])
        // Embeddings wait for the description.
        #expect(try store.pendingEmbeddings(model: "m", limit: 10).isEmpty)
        try store.setDescriptionState(from: [.pending], to: .skipped)
        #expect(try store.pendingEmbeddings(model: "m", limit: 10).map(\.id) == ["a"])
        try store.updateEmbedding(id: "a", vector: [1, 2], model: "m")
        #expect(try store.pendingEmbeddings(model: "m", limit: 10).isEmpty)
        #expect(try store.pendingEmbeddings(model: "other", limit: 10).map(\.id) == ["a"])

        let stats = try store.indexingStats(embeddingModel: "m")
        #expect(stats == IndexingStats(total: 1, pendingText: 0, pendingDescriptions: 0, pendingEmbeddings: 0))
    }

    @Test func buildsSafeFTSQueries() {
        #expect(HistoryStore.ftsQuery(from: "foo \"bar\" OR baz*") == "\"foo\"* \"bar\"* \"OR\"* \"baz\"*")
        #expect(HistoryStore.ftsQuery(from: "  ,; ") == nil)
    }
}
