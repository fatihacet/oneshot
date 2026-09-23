import Foundation

/// Services that can describe screenshots.
enum AIProviderKind: String, CaseIterable, Identifiable {
    case none
    case openAI
    case anthropic
    case gemini
    case ollama

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Off"
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        case .ollama: return "Ollama (on this Mac)"
        }
    }

    var needsAPIKey: Bool { self == .openAI || self == .anthropic || self == .gemini }

    var defaultVisionModel: String {
        switch self {
        case .none: return ""
        case .openAI: return "gpt-5-mini"
        case .anthropic: return "claude-opus-5"
        case .gemini: return "gemini-2.5-flash"
        case .ollama: return "qwen2.5vl"
        }
    }
}

/// Services that can embed text for semantic search.
enum EmbeddingProviderKind: String, CaseIterable, Identifiable {
    case onDevice
    case openAI
    case gemini
    case ollama

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onDevice: return "On-device (Apple)"
        case .openAI: return "OpenAI"
        case .gemini: return "Google Gemini"
        case .ollama: return "Ollama (on this Mac)"
        }
    }

    var defaultModel: String {
        switch self {
        case .onDevice: return ""
        case .openAI: return "text-embedding-3-small"
        case .gemini: return "gemini-embedding-001"
        case .ollama: return "nomic-embed-text"
        }
    }

    var keyProvider: AIProviderKind {
        switch self {
        case .onDevice: return .none
        case .openAI: return .openAI
        case .gemini: return .gemini
        case .ollama: return .ollama
        }
    }
}

/// Which AI services the history indexer uses. Keys live in the Keychain, the rest in UserDefaults.
@MainActor
enum AISettings {
    static let describeProviderKey = "ai.describeProvider"
    static let embeddingProviderKey = "ai.embeddingProvider"
    static let ollamaURLKey = "ai.ollama.baseURL"
    static let defaultOllamaURL = "http://localhost:11434"

    private static var defaults: UserDefaults { .standard }

    static var describeProvider: AIProviderKind {
        get { AIProviderKind(rawValue: defaults.string(forKey: describeProviderKey) ?? "") ?? .none }
        set { defaults.set(newValue.rawValue, forKey: describeProviderKey) }
    }

    static var embeddingProvider: EmbeddingProviderKind {
        get { EmbeddingProviderKind(rawValue: defaults.string(forKey: embeddingProviderKey) ?? "") ?? .onDevice }
        set { defaults.set(newValue.rawValue, forKey: embeddingProviderKey) }
    }

    static func visionModelKey(_ provider: AIProviderKind) -> String { "ai.\(provider.rawValue).visionModel" }
    static func embeddingModelKey(_ provider: EmbeddingProviderKind) -> String { "ai.\(provider.rawValue).embeddingModel" }
    static func apiKeyAccount(_ provider: AIProviderKind) -> String { "ai.\(provider.rawValue).apiKey" }

    static func visionModel(for provider: AIProviderKind) -> String {
        let value = defaults.string(forKey: visionModelKey(provider))?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? provider.defaultVisionModel : value
    }

    static func embeddingModel(for provider: EmbeddingProviderKind) -> String {
        let value = defaults.string(forKey: embeddingModelKey(provider))?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? provider.defaultModel : value
    }

    static func apiKey(for provider: AIProviderKind) -> String {
        Keychain.string(for: apiKeyAccount(provider)) ?? ""
    }

    static func setAPIKey(_ key: String, for provider: AIProviderKind) {
        Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: apiKeyAccount(provider))
    }

    static var ollamaBaseURL: URL {
        let value = defaults.string(forKey: ollamaURLKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return URL(string: value.isEmpty ? defaultOllamaURL : value) ?? URL(string: defaultOllamaURL)!
    }

    /// Whether new captures get a vision-model description.
    static var describesCaptures: Bool { makeDescriber() != nil }

    static func makeDescriber() -> ScreenshotDescriber? {
        makeDescriber(for: describeProvider)
    }

    static func makeDescriber(for provider: AIProviderKind) -> ScreenshotDescriber? {
        let model = visionModel(for: provider)
        let key = apiKey(for: provider)
        if provider.needsAPIKey, key.isEmpty { return nil }
        switch provider {
        case .none: return nil
        case .openAI: return OpenAIDescriber(apiKey: key, model: model)
        case .anthropic: return AnthropicDescriber(apiKey: key, model: model)
        case .gemini: return GeminiDescriber(apiKey: key, model: model)
        case .ollama: return OllamaDescriber(baseURL: ollamaBaseURL, model: model)
        }
    }

    /// The configured embedder, falling back to on-device embeddings when a key is missing.
    static func makeEmbedder() -> TextEmbedder {
        let provider = embeddingProvider
        let model = embeddingModel(for: provider)
        let key = apiKey(for: provider.keyProvider)
        switch provider {
        case .onDevice: return AppleSentenceEmbedder()
        case .openAI: return key.isEmpty ? AppleSentenceEmbedder() : OpenAIEmbedder(apiKey: key, model: model)
        case .gemini: return key.isEmpty ? AppleSentenceEmbedder() : GeminiEmbedder(apiKey: key, model: model)
        case .ollama: return OllamaEmbedder(baseURL: ollamaBaseURL, model: model)
        }
    }
}
