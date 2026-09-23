import AppKit
import ImageIO
import OneShotCore

/// Observable indexing status for the UI.
@MainActor
final class IndexingStatus: ObservableObject {
    static let shared = IndexingStatus()
    @Published var isIndexing = false
    @Published var lastError: String?
}

/// Background pipeline that enriches history captures for search:
/// 1. on-device text recognition, 2. optional AI description, 3. embedding.
actor HistoryIndexer {
    static let shared = HistoryIndexer()

    private var isRunning = false
    private var wakeRequested = false
    private let service = HistoryService.shared

    /// Starts processing pending work, or makes the running loop do another pass.
    func wake() {
        guard !isRunning else {
            wakeRequested = true
            return
        }
        isRunning = true
        Task { await runLoop() }
    }

    private var isPaused: Bool { Preferences.indexingPaused }

    private func runLoop() async {
        await setIndexing(true)
        repeat {
            wakeRequested = false
            guard !isPaused else { break }
            await recognizeText()
            await describeCaptures()
            await embedCaptures()
        } while wakeRequested && !isPaused
        isRunning = false
        await setIndexing(false)
    }

    // MARK: Steps

    private func recognizeText() async {
        while !isPaused {
            let batch = await service.pendingTextRecognition(limit: 8)
            guard !batch.isEmpty else { return }
            for item in batch {
                guard !isPaused else { return }
                var text = ""
                if let image = Self.loadImage(at: service.imageURL(for: item)) {
                    text = (try? await TextRecognizer.recognizeAllText(in: image)) ?? ""
                }
                await service.updateRecognizedText(id: item.id, text: text)
            }
        }
    }

    private func describeCaptures() async {
        let describer = await MainActor.run { AISettings.makeDescriber() }
        guard let describer else {
            // Descriptions are off: let embeddings proceed without them.
            await service.setDescriptionState(from: [.pending], to: .skipped)
            return
        }
        while !isPaused {
            let batch = await service.pendingDescriptions(limit: 4)
            guard !batch.isEmpty else { return }
            for item in batch {
                guard !isPaused else { return }
                guard let image = Self.loadImage(at: service.imageURL(for: item)),
                      let jpeg = Self.jpegForModel(image) else {
                    await service.setDescriptionState(id: item.id, .failed)
                    continue
                }
                do {
                    let description = try await describer.describe(jpegData: jpeg)
                    await service.updateDescription(id: item.id, caption: description.caption, tags: description.tags)
                    await setError(nil)
                } catch {
                    await setError("Description failed: \(error.localizedDescription)")
                    // Configuration problems affect every capture; stop and retry on the next wake.
                    if (error as? AIProviderError)?.isFatal == true { return }
                    await service.setDescriptionState(id: item.id, .failed)
                }
            }
        }
    }

    private func embedCaptures() async {
        let embedder = await MainActor.run { AISettings.makeEmbedder() }
        while !isPaused {
            let batch = await service.pendingEmbeddings(model: embedder.modelID, limit: 16)
            guard !batch.isEmpty else { return }
            do {
                let vectors = try await embedder.embed(batch.map { $0.embeddingText.isEmpty ? "screenshot" : $0.embeddingText })
                for (item, vector) in zip(batch, vectors) {
                    await service.updateEmbedding(id: item.id, vector: vector, model: embedder.modelID)
                }
                await setError(nil)
            } catch {
                await setError("Embedding failed: \(error.localizedDescription)")
                return
            }
        }
    }

    // MARK: Helpers

    private func setIndexing(_ value: Bool) async {
        await MainActor.run { IndexingStatus.shared.isIndexing = value }
    }

    private func setError(_ message: String?) async {
        await MainActor.run {
            if IndexingStatus.shared.lastError != message { IndexingStatus.shared.lastError = message }
        }
    }

    static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Vision models don't need more than ~1600 px on the long edge.
    static func jpegForModel(_ image: CGImage) -> Data? {
        let scaled = image.resized(toFit: 1568) ?? image
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
