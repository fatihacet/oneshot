import Foundation

/// Services that can describe screenshots. Only a local Ollama model: captions from cloud
/// providers were removed, since they sent every screenshot off the Mac.
enum AIProviderKind: String, CaseIterable, Identifiable {
    case none
    case ollama

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Off"
        case .ollama: return "Ollama (on this Mac)"
        }
    }

    var defaultVisionModel: String {
        switch self {
        case .none: return ""
        case .ollama: return "qwen2.5vl"
        }
    }
}

/// Services that can embed text for semantic search.
enum EmbeddingProviderKind: String, CaseIterable, Identifiable {
    case onDevice
    case ollama

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onDevice: return "On-device (Apple)"
        case .ollama: return "Ollama (on this Mac)"
        }
    }

    var defaultModel: String {
        switch self {
        case .onDevice: return ""
        case .ollama: return "nomic-embed-text"
        }
    }
}

/// Which models the history indexer uses, stored in UserDefaults.
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

    static func visionModel(for provider: AIProviderKind) -> String {
        let value = defaults.string(forKey: visionModelKey(provider))?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? provider.defaultVisionModel : value
    }

    static func embeddingModel(for provider: EmbeddingProviderKind) -> String {
        let value = defaults.string(forKey: embeddingModelKey(provider))?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? provider.defaultModel : value
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
        switch provider {
        case .none: return nil
        case .ollama: return OllamaDescriber(baseURL: ollamaBaseURL, model: visionModel(for: provider))
        }
    }

    static func makeEmbedder() -> TextEmbedder {
        switch embeddingProvider {
        case .onDevice: return AppleSentenceEmbedder()
        case .ollama: return OllamaEmbedder(baseURL: ollamaBaseURL, model: embeddingModel(for: .ollama))
        }
    }

    /// Deletes, once, the API keys and model choices of the removed cloud providers (OpenAI,
    /// Anthropic, Google Gemini). A provider choice that no longer exists already reads as Off / On-device.
    static func removeCloudProviderSettings() {
        let doneKey = "ai.cloudProvidersRemoved"
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        for provider in ["openAI", "anthropic", "gemini"] {
            Keychain.set(nil, for: "ai.\(provider).apiKey")
            defaults.removeObject(forKey: "ai.\(provider).visionModel")
            defaults.removeObject(forKey: "ai.\(provider).embeddingModel")
        }
    }
}
