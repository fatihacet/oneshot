import Foundation

// Ollama runs vision and embedding models locally, so screenshots never leave the Mac.

struct OllamaDescriber: ScreenshotDescriber {
    let baseURL: URL
    let model: String

    func describe(jpegData: Data) async throws -> ScreenshotDescription {
        let json = try await AIHTTP.postJSON(
            baseURL.appendingPathComponent("api/chat"),
            body: [
                "model": model,
                "stream": false,
                "format": "json",
                "messages": [[
                    "role": "user",
                    "content": DescriptionPrompt.text,
                    "images": [jpegData.base64EncodedString()],
                ]],
            ],
            timeout: 300
        )
        let content = (json["message"] as? [String: Any])?["content"] as? String ?? ""
        return try DescriptionPrompt.parse(content)
    }
}

struct OllamaEmbedder: TextEmbedder {
    let baseURL: URL
    let model: String
    var modelID: String { "ollama:\(model)" }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        let json = try await AIHTTP.postJSON(
            baseURL.appendingPathComponent("api/embed"),
            body: ["model": model, "input": texts.map { String($0.prefix(8000)) }],
            timeout: 300
        )
        let vectors = (json["embeddings"] as? [[Double]] ?? []).map { $0.map(Float.init) }
        guard vectors.count == texts.count else {
            throw AIProviderError(message: "Unexpected embeddings response.", isFatal: false)
        }
        return vectors
    }
}
