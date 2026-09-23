import AppKit
import SwiftUI

struct AISettingsView: View {
    @AppStorage(AISettings.describeProviderKey) private var describeProvider = AIProviderKind.none.rawValue
    @AppStorage(AISettings.embeddingProviderKey) private var embeddingProvider = EmbeddingProviderKind.onDevice.rawValue
    @AppStorage(AISettings.ollamaURLKey) private var ollamaURL = ""
    @State private var openAIKey = AISettings.apiKey(for: .openAI)
    @State private var anthropicKey = AISettings.apiKey(for: .anthropic)
    @State private var geminiKey = AISettings.apiKey(for: .gemini)
    @State private var testState = TestState.idle

    private enum TestState: Equatable {
        case idle
        case running
        case success(String)
        case failure(String)
    }

    private var provider: AIProviderKind { AIProviderKind(rawValue: describeProvider) ?? .none }
    private var embedding: EmbeddingProviderKind { EmbeddingProviderKind(rawValue: embeddingProvider) ?? .onDevice }

    var body: some View {
        Form {
            Section {
                Picker("Describe screenshots with", selection: $describeProvider) {
                    ForEach(AIProviderKind.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if provider != .none {
                    TextField("Model", text: defaultsBinding(AISettings.visionModelKey(provider)), prompt: Text(provider.defaultVisionModel))
                    if provider.needsAPIKey, AISettings.apiKey(for: provider).isEmpty {
                        Label("Add a \(provider.title) API key below.", systemImage: "key.fill")
                            .foregroundStyle(.orange)
                    }
                    HStack {
                        Button("Test", action: testDescriber)
                            .disabled(testState == .running)
                        testStatus
                        Spacer()
                        Button("Describe Existing Captures") {
                            Task {
                                await HistoryService.shared.setDescriptionState(from: [.skipped, .failed], to: .pending)
                                await HistoryIndexer.shared.wake()
                            }
                        }
                    }
                }
            } header: {
                Text("AI descriptions")
            } footer: {
                Text(provider == .none
                    ? "Optionally let a vision model caption and tag each capture for better search."
                    : provider == .ollama
                    ? "Screenshots stay on this Mac: Ollama runs the model locally."
                    : "Screenshots are sent to \(provider.title) to be described.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Embeddings", selection: $embeddingProvider) {
                    ForEach(EmbeddingProviderKind.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if embedding != .onDevice {
                    TextField("Model", text: defaultsBinding(AISettings.embeddingModelKey(embedding)), prompt: Text(embedding.defaultModel))
                }
            } header: {
                Text("Semantic search")
            } footer: {
                Text("Embeddings let search find captures by meaning. Changing the provider or model re-indexes your history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                SecureField("OpenAI", text: $openAIKey, prompt: Text("sk-…"))
                SecureField("Anthropic", text: $anthropicKey, prompt: Text("sk-ant-…"))
                SecureField("Google Gemini", text: $geminiKey)
                TextField("Ollama server", text: $ollamaURL, prompt: Text(AISettings.defaultOllamaURL))
            } header: {
                Text("API keys")
            } footer: {
                Text("Keys are stored in your Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: describeProvider) { _, _ in settingsChanged() }
        .onChange(of: embeddingProvider) { _, _ in settingsChanged() }
        .onChange(of: ollamaURL) { _, _ in settingsChanged() }
        .onChange(of: openAIKey) { _, key in AISettings.setAPIKey(key, for: .openAI); settingsChanged() }
        .onChange(of: anthropicKey) { _, key in AISettings.setAPIKey(key, for: .anthropic); settingsChanged() }
        .onChange(of: geminiKey) { _, key in AISettings.setAPIKey(key, for: .gemini); settingsChanged() }
    }

    @ViewBuilder
    private var testStatus: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .running:
            ProgressView().controlSize(.small)
        case .success(let caption):
            Label(caption, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .lineLimit(2)
                .help(caption)
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
                .help(message)
        }
    }

    private func defaultsBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { UserDefaults.standard.string(forKey: key) ?? "" },
            set: {
                UserDefaults.standard.set($0, forKey: key)
                settingsChanged()
            }
        )
    }

    private func settingsChanged() {
        testState = .idle
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            await HistoryIndexer.shared.wake()
        }
    }

    private func testDescriber() {
        guard let describer = AISettings.makeDescriber(for: provider) else {
            testState = .failure("Add an API key first.")
            return
        }
        guard let jpeg = Self.sampleImageJPEG() else { return }
        testState = .running
        Task {
            do {
                let description = try await describer.describe(jpegData: jpeg)
                testState = .success(description.caption)
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }

    /// A small rendered "screenshot" used to test the provider.
    private static func sampleImageJPEG() -> Data? {
        let size = CGSize(width: 640, height: 360)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            let title: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 34), .foregroundColor: NSColor.black]
            let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.darkGray]
            ("Quarterly Revenue Report" as NSString).draw(at: CGPoint(x: 40, y: 270), withAttributes: title)
            ("Revenue grew 24% compared to last quarter." as NSString).draw(at: CGPoint(x: 40, y: 210), withAttributes: body)
            NSColor.systemBlue.setFill()
            for (index, height) in [60.0, 90, 120, 150].enumerated() {
                NSRect(x: 40 + Double(index) * 70, y: 40, width: 50, height: height).fill()
            }
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
