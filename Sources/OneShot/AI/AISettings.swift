import Foundation

/// Which AI services the history indexer uses.
@MainActor
enum AISettings {
    /// Whether new captures get a vision-model description.
    static var describesCaptures: Bool { makeDescriber() != nil }

    static func makeDescriber() -> ScreenshotDescriber? { nil }

    static func makeEmbedder() -> TextEmbedder { AppleSentenceEmbedder() }
}
