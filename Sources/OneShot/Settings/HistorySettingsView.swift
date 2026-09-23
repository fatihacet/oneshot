import AppKit
import OneShotCore
import SwiftUI

struct HistorySettingsView: View {
    @AppStorage(PrefKey.historyEnabled) private var historyEnabled = true
    @AppStorage(PrefKey.historyRetentionDays) private var retentionDays = 90
    @AppStorage(PrefKey.indexingPaused) private var indexingPaused = false
    @ObservedObject private var status = IndexingStatus.shared
    @State private var captureCount = 0
    @State private var diskUsage: Int64 = 0
    @State private var stats: IndexingStats?
    @State private var isConfirmingClear = false

    private static let retentionChoices: [(title: String, days: Int)] = [
        ("1 week", 7), ("1 month", 30), ("3 months", 90), ("1 year", 365), ("Forever", 0),
    ]

    var body: some View {
        Form {
            Section("History") {
                Toggle("Keep a history of captures", isOn: $historyEnabled)
                Picker("Keep captures for", selection: $retentionDays) {
                    ForEach(Self.retentionChoices, id: \.days) { Text($0.title).tag($0.days) }
                }
                .onChange(of: retentionDays) { _, days in
                    Task {
                        await HistoryService.shared.applyRetention(days: days)
                        await refresh()
                    }
                }
                LabeledContent("Stored") {
                    Text("\(captureCount) captures · \(ByteCountFormatter.string(fromByteCount: diskUsage, countStyle: .file))")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Open History") { HistoryWindowController.shared.show() }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([HistoryService.shared.directory])
                    }
                    Spacer()
                    Button("Clear History…", role: .destructive) { isConfirmingClear = true }
                }
            }

            Section {
                Toggle("Pause indexing", isOn: $indexingPaused)
                    .onChange(of: indexingPaused) { _, paused in
                        if !paused { Task { await HistoryIndexer.shared.wake() } }
                    }
                LabeledContent("Status") {
                    Text(statusText).foregroundStyle(.secondary)
                }
                if let error = status.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Search indexing")
            } footer: {
                Text("Text in screenshots is recognized on this Mac and used for search.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .historyDidChange)) { _ in
            Task { await refresh() }
        }
        .confirmationDialog("Delete all captures from the history?", isPresented: $isConfirmingClear) {
            Button("Delete All", role: .destructive) {
                Task {
                    await HistoryService.shared.deleteAll()
                    await refresh()
                }
            }
        } message: {
            Text("Screenshots you saved elsewhere or uploaded are not affected.")
        }
    }

    private var statusText: String {
        guard let stats else { return "…" }
        if indexingPaused { return "Paused" }
        let pending = stats.pendingText + stats.pendingDescriptions + stats.pendingEmbeddings
        if pending == 0 { return "Up to date" }
        return status.isIndexing ? "Indexing \(pending) remaining…" : "\(pending) waiting"
    }

    private func refresh() async {
        let service = HistoryService.shared
        let model = await MainActor.run { AISettings.makeEmbedder().modelID }
        captureCount = await service.count()
        diskUsage = await service.diskUsage()
        stats = await service.stats(embeddingModel: model)
    }
}
