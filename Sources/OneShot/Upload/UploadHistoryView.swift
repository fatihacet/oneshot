import AppKit
import OneShotCore
import SwiftUI

@MainActor
final class UploadHistoryWindowController {
    static let shared = UploadHistoryWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: UploadHistoryView()))
            window.title = "Upload History"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(CGSize(width: 760, height: 440))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct UploadHistoryView: View {
    @ObservedObject private var history = UploadHistory.shared
    @State private var selection = Set<UploadRecord.ID>()
    @State private var pendingDelete: [UploadRecord] = []
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if history.records.isEmpty {
                ContentUnavailableView(
                    "No Uploads Yet",
                    systemImage: "icloud.and.arrow.up",
                    description: Text("Uploaded screenshots appear here.")
                )
            } else {
                table
            }
        }
        .frame(minWidth: 560, minHeight: 280)
        .confirmationDialog(
            pendingDelete.count == 1 ? "Delete this upload from the bucket?" : "Delete \(pendingDelete.count) uploads from the bucket?",
            isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })
        ) {
            Button("Delete", role: .destructive) { deleteRemote(pendingDelete) }
        } message: {
            Text("Links to these files will stop working.")
        }
        .alert("Could not delete", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var table: some View {
        Table(history.records, selection: $selection) {
            TableColumn("Date") { record in
                Text(record.date, format: .dateTime.year().month(.abbreviated).day().hour().minute())
            }
            .width(min: 120, ideal: 150)
            TableColumn("Name") { record in
                Text(record.fileName).lineLimit(1)
            }
            TableColumn("Size") { record in
                Text(ByteCountFormatter.string(fromByteCount: Int64(record.byteCount), countStyle: .file))
                    .monospacedDigit()
            }
            .width(70)
            TableColumn("Link") { record in
                Text(record.link)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
        }
        .contextMenu(forSelectionType: UploadRecord.ID.self) { ids in
            let records = self.records(for: ids)
            if records.count == 1, let record = records.first {
                Button("Copy Link") { copyLink(record) }
                Button("Open in Browser") { openLink(record) }
                Divider()
            }
            Button("Delete from Bucket…") { pendingDelete = records }
            Button("Remove from History") { records.forEach(history.remove) }
        } primaryAction: { ids in
            records(for: ids).first.map(openLink)
        }
    }

    private func records(for ids: Set<UploadRecord.ID>) -> [UploadRecord] {
        history.records.filter { ids.contains($0.id) }
    }

    /// Presigned links expire, so they are re-signed with the current credentials.
    private func freshLink(for record: UploadRecord) -> String {
        guard record.configuration.linkStyle == .presigned,
              let client = try? UploadSettings.client(for: record.configuration),
              let url = try? client.link(for: record.key) else { return record.link }
        return url.absoluteString
    }

    private func copyLink(_ record: UploadRecord) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(freshLink(for: record), forType: .string)
        Toast.show("Link copied", symbol: "link")
    }

    private func openLink(_ record: UploadRecord) {
        if let url = URL(string: freshLink(for: record)) { NSWorkspace.shared.open(url) }
    }

    private func deleteRemote(_ records: [UploadRecord]) {
        pendingDelete = []
        Task {
            for record in records {
                do {
                    try await history.deleteRemote(record)
                } catch {
                    errorMessage = "\(record.fileName): \(error.localizedDescription)"
                    return
                }
            }
            Toast.show(records.count == 1 ? "Upload deleted" : "\(records.count) uploads deleted", symbol: "trash")
        }
    }
}
