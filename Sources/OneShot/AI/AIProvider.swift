import Foundation
import NaturalLanguage

struct ScreenshotDescription: Equatable {
    var caption: String
    var tags: [String]
}

/// Describes a screenshot for search (caption + tags) with a vision model.
protocol ScreenshotDescriber: Sendable {
    func describe(jpegData: Data) async throws -> ScreenshotDescription
}

/// Turns text into embedding vectors for semantic search.
protocol TextEmbedder: Sendable {
    /// Identifies the vector space; captures embedded with another model are re-embedded.
    var modelID: String { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

struct AIProviderError: LocalizedError {
    var message: String
    /// Errors such as a missing or rejected API key that will fail for every request.
    var isFatal: Bool

    var errorDescription: String? { message }
}

/// Apple's on-device sentence embeddings: free, private and offline.
struct AppleSentenceEmbedder: TextEmbedder {
    let modelID = "apple-nl-sentence-en"

    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            throw AIProviderError(message: "On-device sentence embeddings are unavailable.", isFatal: true)
        }
        return texts.map { text in
            embedding.vector(for: String(text.prefix(1000)))?.map(Float.init) ?? []
        }
    }
}
