import Foundation

// MARK: - OpenAI

struct OpenAIDescriber: ScreenshotDescriber {
    let apiKey: String
    let model: String

    func describe(jpegData: Data) async throws -> ScreenshotDescription {
        let json = try await AIHTTP.postJSON(
            URL(string: "https://api.openai.com/v1/chat/completions")!,
            headers: ["Authorization": "Bearer \(apiKey)"],
            body: [
                "model": model,
                "response_format": ["type": "json_object"],
                "messages": [[
                    "role": "user",
                    "content": [
                        ["type": "text", "text": DescriptionPrompt.text],
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(jpegData.base64EncodedString())"]],
                    ],
                ]],
            ]
        )
        let choices = json["choices"] as? [[String: Any]]
        let content = (choices?.first?["message"] as? [String: Any])?["content"] as? String ?? ""
        return try DescriptionPrompt.parse(content)
    }
}

struct OpenAIEmbedder: TextEmbedder {
    let apiKey: String
    let model: String
    var modelID: String { "openai:\(model)" }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        let json = try await AIHTTP.postJSON(
            URL(string: "https://api.openai.com/v1/embeddings")!,
            headers: ["Authorization": "Bearer \(apiKey)"],
            body: ["model": model, "input": texts.map { String($0.prefix(8000)) }]
        )
        let data = (json["data"] as? [[String: Any]] ?? []).sorted {
            ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0)
        }
        let vectors = data.map { ($0["embedding"] as? [Double] ?? []).map(Float.init) }
        guard vectors.count == texts.count else {
            throw AIProviderError(message: "Unexpected embeddings response.", isFatal: false)
        }
        return vectors
    }
}

// MARK: - Anthropic

struct AnthropicDescriber: ScreenshotDescriber {
    let apiKey: String
    let model: String

    func describe(jpegData: Data) async throws -> ScreenshotDescription {
        let json = try await AIHTTP.postJSON(
            URL(string: "https://api.anthropic.com/v1/messages")!,
            headers: [
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01",
                // Re-runs a request declined by safety classifiers on a suitable fallback model.
                "anthropic-beta": "server-side-fallback-2026-07-01",
            ],
            body: [
                "model": model,
                "max_tokens": 16000,
                "fallbacks": "default",
                "output_config": [
                    "effort": "low",
                    "format": ["type": "json_schema", "schema": DescriptionPrompt.schema],
                ],
                "messages": [[
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": ["type": "base64", "media_type": "image/jpeg", "data": jpegData.base64EncodedString()],
                        ],
                        ["type": "text", "text": DescriptionPrompt.text],
                    ],
                ]],
            ]
        )
        if json["stop_reason"] as? String == "refusal" {
            throw AIProviderError(message: "The model declined to describe this screenshot.", isFatal: false)
        }
        let text = (json["content"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        return try DescriptionPrompt.parse(text)
    }
}

// MARK: - Google Gemini

struct GeminiDescriber: ScreenshotDescriber {
    let apiKey: String
    let model: String

    func describe(jpegData: Data) async throws -> ScreenshotDescription {
        let json = try await AIHTTP.postJSON(
            URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!,
            headers: ["x-goog-api-key": apiKey],
            body: [
                "contents": [[
                    "parts": [
                        ["text": DescriptionPrompt.text],
                        ["inlineData": ["mimeType": "image/jpeg", "data": jpegData.base64EncodedString()]],
                    ],
                ]],
                "generationConfig": ["responseMimeType": "application/json"],
            ]
        )
        let candidates = json["candidates"] as? [[String: Any]]
        let parts = (candidates?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        return try DescriptionPrompt.parse(parts.compactMap { $0["text"] as? String }.joined())
    }
}

struct GeminiEmbedder: TextEmbedder {
    let apiKey: String
    let model: String
    var modelID: String { "gemini:\(model)" }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        let json = try await AIHTTP.postJSON(
            URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):batchEmbedContents")!,
            headers: ["x-goog-api-key": apiKey],
            body: ["requests": texts.map { text in
                ["model": "models/\(model)", "content": ["parts": [["text": String(text.prefix(8000))]]]]
            }]
        )
        let vectors = (json["embeddings"] as? [[String: Any]] ?? []).map {
            ($0["values"] as? [Double] ?? []).map(Float.init)
        }
        guard vectors.count == texts.count else {
            throw AIProviderError(message: "Unexpected embeddings response.", isFatal: false)
        }
        return vectors
    }
}

// MARK: - Ollama (local)

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
