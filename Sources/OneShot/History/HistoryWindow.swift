import AppKit
import OneShotCore
import SwiftUI

@MainActor
final class HistoryWindowController {
    static let shared = HistoryWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: HistoryBrowserView()))
            window.title = "History"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(CGSize(width: 1100, height: 700))
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("OneShotHistoryWindow")
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

enum HistoryDateRange: String, CaseIterable, Identifiable {
    case any = "Any Time"
    case today = "Today"
    case week = "Last 7 Days"
    case month = "Last 30 Days"
    case year = "Last Year"

    var id: String { rawValue }

    var since: Date? {
        let calendar = Calendar.current
        switch self {
        case .any: return nil
        case .today: return calendar.startOfDay(for: Date())
        case .week: return calendar.date(byAdding: .day, value: -7, to: Date())
        case .month: return calendar.date(byAdding: .day, value: -30, to: Date())
        case .year: return calendar.date(byAdding: .year, value: -1, to: Date())
        }
    }
}

@MainActor
final class HistoryBrowserModel: ObservableObject {
    @Published var query = "" { didSet { scheduleReload(debounce: true) } }
    @Published var dateRange = HistoryDateRange.any { didSet { scheduleReload() } }
    @Published var appName: String? { didSet { scheduleReload() } }
    @Published private(set) var items: [HistoryItem] = []
    @Published private(set) var appNames: [String] = []
    @Published private(set) var totalCount = 0
    @Published private(set) var isSearching = false
    @Published var selection: HistoryItem.ID?

    private let service = HistoryService.shared
    private var reloadTask: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .historyDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReload(debounce: true) }
        }
        scheduleReload()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var selectedItem: HistoryItem? {
        items.first { $0.id == selection }
    }

    func scheduleReload(debounce: Bool = false) {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    private func reload() async {
        let filter = HistoryFilter(since: dateRange.since, appName: appName)
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        isSearching = !text.isEmpty
        let results: [HistoryItem]
        if text.isEmpty {
            results = await service.recent(limit: 1000, filter: filter)
        } else {
            let embedder = AISettings.makeEmbedder()
            // Semantic search is a bonus: keyword search still works if embedding the query fails.
            let vector = try? await embedder.embed([text]).first
            results = await service.search(
                text: text, queryVector: vector, embeddingModel: embedder.modelID, filter: filter
            )
        }
        guard !Task.isCancelled else { return }
        items = results
        if let selection, !results.contains(where: { $0.id == selection }) { self.selection = nil }
        appNames = await service.appNames()
        totalCount = await service.count()
    }

    // MARK: Actions

    func capture(for item: HistoryItem) -> Capture? {
        guard let image = HistoryIndexer.loadImage(at: service.imageURL(for: item)) else {
            Toast.show("The image file is missing", symbol: "exclamationmark.triangle.fill")
            return nil
        }
        var capture = Capture(
            image: image, scale: CGFloat(max(item.scale, 1)), sourceRect: nil,
            appName: item.appName, windowTitle: item.windowTitle
        )
        capture.historyID = item.id
        return capture
    }

    func copy(_ item: HistoryItem) {
        guard let capture = capture(for: item) else { return }
        ImageExporter.copyToClipboard(capture)
        Toast.show("Copied to clipboard")
    }

    func copyText(_ item: HistoryItem) {
        guard let text = item.ocrText, !text.isEmpty else {
            Toast.show("No text in this capture", symbol: "text.magnifyingglass")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Toast.show("Copied \(text.count) characters", symbol: "text.viewfinder")
    }

    func pin(_ item: HistoryItem) {
        guard let capture = capture(for: item) else { return }
        PinManager.shared.pin(capture)
    }

    func upload(_ item: HistoryItem) {
        guard let capture = capture(for: item) else { return }
        Uploader.shared.upload(capture)
    }

    func annotate(_ item: HistoryItem) {
        guard let capture = capture(for: item) else { return }
        AnnotationEditorWindowController.shared.open(capture)
    }

    func openBackgroundTool(_ item: HistoryItem) {
        guard let capture = capture(for: item) else { return }
        BackgroundToolWindowController.shared.open(capture)
    }

    func open(_ item: HistoryItem) {
        NSWorkspace.shared.open(fileURL(for: item))
    }

    func revealInFinder(_ item: HistoryItem) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL(for: item)])
    }

    func save(_ item: HistoryItem) {
        guard let capture = capture(for: item) else { return }
        do {
            let url = try ImageExporter.save(capture)
            HistoryRecorder.noteSaved(capture, at: url)
            Toast.show("Saved to \(url.deletingLastPathComponent().lastPathComponent)")
        } catch {
            Toast.show("Could not save: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
        }
    }

    func delete(_ item: HistoryItem) {
        if selection == item.id { selection = nil }
        Task { await service.delete(item) }
    }

    /// The user's saved copy if it still exists, otherwise the history's own file.
    private func fileURL(for item: HistoryItem) -> URL {
        if let path = item.savedPath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return service.imageURL(for: item)
    }
}

// MARK: - Views

struct HistoryBrowserView: View {
    @StateObject private var model = HistoryBrowserModel()
    @ObservedObject private var status = IndexingStatus.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                grid
                if let item = model.selectedItem {
                    Divider()
                    HistoryInspector(item: item, model: model)
                        .frame(width: 320)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 460)
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search text, apps, descriptions…", text: $model.query)
                    .textFieldStyle(.plain)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            Picker("Date", selection: $model.dateRange) {
                ForEach(HistoryDateRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .frame(width: 140)

            Picker("App", selection: $model.appName) {
                Text("All Apps").tag(String?.none)
                Divider()
                ForEach(model.appNames, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .labelsHidden()
            .frame(width: 160)
        }
        .padding(12)
    }

    @ViewBuilder
    private var grid: some View {
        if model.items.isEmpty {
            ContentUnavailableView(
                model.isSearching ? "No Results" : "No Captures Yet",
                systemImage: model.isSearching ? "magnifyingglass" : "photo.on.rectangle.angled",
                description: Text(model.isSearching
                    ? "Try other words, or wait for indexing to finish."
                    : "Screenshots you take appear here.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 14)], spacing: 14) {
                    ForEach(model.items) { item in
                        HistoryCell(item: item, isSelected: model.selection == item.id)
                            .onTapGesture(count: 2) { model.open(item) }
                            .onTapGesture { model.selection = item.id }
                            .contextMenu { HistoryActionsMenu(item: item, model: model) }
                            .onDrag {
                                NSItemProvider(contentsOf: HistoryService.shared.imageURL(for: item)) ?? NSItemProvider()
                            }
                    }
                }
                .padding(14)
            }
            // Without this the scroll view sizes to the grid's narrowest layout once the inspector
            // shares the row, and the whole row shrinks to the window's minimum width.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDeleteCommand {
                if let item = model.selectedItem { model.delete(item) }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(model.isSearching ? "\(model.items.count) results" : "\(model.totalCount) captures")
            Spacer()
            if Preferences.indexingPaused {
                Text("Indexing paused")
            } else if status.isIndexing {
                ProgressView().controlSize(.small)
                Text("Indexing…")
            }
            if let error = status.lastError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(error)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct HistoryCell: View {
    let item: HistoryItem
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HistoryThumbnail(item: item)
                .frame(height: 140)
                .frame(maxWidth: .infinity)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isSelected ? 3 : 1)
                )
            Text(item.appName ?? "Unknown App")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(item.caption ?? item.windowTitle ?? item.createdAt.formatted(.relative(presentation: .named)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .contentShape(Rectangle())
    }
}

/// Loads a thumbnail from disk off the main thread.
private struct HistoryThumbnail: View {
    let item: HistoryItem
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .task(id: item.id) {
            let url = HistoryService.shared.thumbnailURL(for: item)
            image = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: url) }.value
        }
    }
}

private struct HistoryActionsMenu: View {
    let item: HistoryItem
    let model: HistoryBrowserModel

    var body: some View {
        Button("Copy") { model.copy(item) }
        Button("Copy Text") { model.copyText(item) }
        Button("Pin to Screen") { model.pin(item) }
        Button("Annotate…") { model.annotate(item) }
        Button("Add Background…") { model.openBackgroundTool(item) }
        if UploadSettings.isConfigured {
            Button("Upload") { model.upload(item) }
        }
        Divider()
        Button("Open") { model.open(item) }
        Button("Save to Folder") { model.save(item) }
        Button("Show in Finder") { model.revealInFinder(item) }
        Divider()
        Button("Delete from History", role: .destructive) { model.delete(item) }
    }
}

private struct HistoryInspector: View {
    let item: HistoryItem
    @ObservedObject var model: HistoryBrowserModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HistoryThumbnail(item: item)
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack {
                    Button("Copy") { model.copy(item) }
                    Button("Pin") { model.pin(item) }
                    Menu("More") { HistoryActionsMenu(item: item, model: model) }
                        .fixedSize()
                }

                if let caption = item.caption, !caption.isEmpty {
                    section("Description") { Text(caption).textSelection(.enabled) }
                }
                if !item.tags.isEmpty {
                    section("Tags") {
                        Text(item.tags.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                section("Details") {
                    VStack(alignment: .leading, spacing: 4) {
                        detail("App", item.appName)
                        detail("Window", item.windowTitle)
                        detail("Captured", item.createdAt.formatted(date: .abbreviated, time: .shortened))
                        detail("Size", "\(item.pixelWidth) × \(item.pixelHeight) px")
                        detail("Saved", item.savedPath.map { ($0 as NSString).abbreviatingWithTildeInPath })
                        if let link = item.uploadLink, let url = URL(string: link) {
                            HStack(alignment: .top) {
                                Text("Link").foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                                Link(link, destination: url).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    .font(.caption)
                }
                if let text = item.ocrText, !text.isEmpty {
                    section("Recognized Text") {
                        Text(text)
                            .font(.caption)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if !item.isTextRecognized {
                    Text("Recognizing text…").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private func detail(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top) {
                Text(label).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                Text(value).textSelection(.enabled)
            }
        }
    }
}
