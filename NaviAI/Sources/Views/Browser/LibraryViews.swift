import SwiftUI
import WebKit

struct HistorySheet: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if store.history.isEmpty {
                ContentUnavailable("No history yet", systemImage: "clock.arrow.circlepath", message: "Pages you visit appear here. History never leaves your device.")
            } else {
                List {
                    ForEach(store.history) { visit in
                        Button {
                            if let url = URL(string: visit.urlString) {
                                store.loadURL(url)
                                dismiss()
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(visit.title).font(.body)
                                Text(visit.urlString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    .onDelete { store.removeHistory(at: $0) }
                }
            }
        }
        .navigationTitle("History")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !store.history.isEmpty {
                    Button("Clear") { store.clearHistory() }
                }
            }
        }
    }
}

struct BookmarksSheet: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if store.bookmarks.isEmpty {
                ContentUnavailable("No bookmarks", systemImage: "book", message: "Tap the bookmark icon in the toolbar to save the current page.")
            } else {
                List {
                    ForEach(store.bookmarks) { item in
                        Button {
                            if let url = URL(string: item.urlString) {
                                store.loadURL(url)
                                dismiss()
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.body)
                                Text(item.urlString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .foregroundStyle(.primary)
                        .swipeActions {
                            Button(role: .destructive) { store.removeBookmark(item) } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Bookmarks")
    }
}

struct DownloadsSheet: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        Group {
            if store.downloads.isEmpty {
                ContentUnavailable("No downloads", systemImage: "arrow.down.circle", message: "Files downloaded in the browser are saved to the app's Downloads folder.")
            } else {
                List {
                    ForEach(store.downloads) { record in
                        HStack(spacing: 12) {
                            Image(systemName: fileIcon(for: record.mimeType))
                                .font(.title3)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.title).font(.body).lineLimit(1)
                                Text(record.fileURL.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if record.fileExists {
                                ShareLink(item: record.fileURL) {
                                    Image(systemName: "square.and.arrow.up")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { store.removeDownload(record) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !store.downloads.isEmpty {
                    Button("Clear") { store.clearDownloads() }
                }
            }
        }
    }

    private func fileIcon(for mime: String) -> String {
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("video/") { return "film" }
        if mime.hasPrefix("audio/") { return "music.note" }
        if mime == "application/pdf" { return "doc.richtext" }
        return "doc"
    }
}

private struct ContentUnavailable: View {
    let title: String
    let systemImage: String
    let message: String

    init(_ title: String, systemImage: String, message: String) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Site data (cookies / storage = signed-in accounts)

struct SiteDataSheet: View {
    @ObservedObject var store: BrowserStore

    @State private var records: [WKWebsiteDataRecord] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var clearingAll = false

    var body: some View {
        Group {
            if let errorMessage {
                ContentUnavailable("Couldn't load site data",
                                   systemImage: "exclamationmark.triangle",
                                   message: errorMessage)
            } else if isLoading {
                ProgressView("Loading site data…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if records.isEmpty {
                ContentUnavailable("No stored data",
                                   systemImage: "shield.checkered",
                                   message: "Sites you visit store cookies and storage here, which keeps you signed in. This list will fill as you browse.")
            } else {
                List {
                    ForEach(records, id: \.self) { record in
                        HStack(spacing: 12) {
                            Image(systemName: "globe")
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.displayName)
                                    .font(.body)
                                Text(typeSummary(for: record))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                remove(record)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .navigationTitle("Site Data")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !records.isEmpty {
                    Button("Clear All", role: .destructive) {
                        clearingAll = true
                    }
                    .confirmationDialog("This signs you out of every site and removes their local storage.", isPresented: $clearingAll, titleVisibility: .visible) {
                        Button("Clear all site data", role: .destructive) { clearAll() }
                        Button("Cancel", role: .cancel) {}
                    }
                }
            }
        }
        .task {
            await reload()
        }
    }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        let result = await store.fetchSiteData()
        records = result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        isLoading = false
    }

    private func remove(_ record: WKWebsiteDataRecord) {
        store.removeSiteData(record: record)
        records.removeAll { $0 == record }
    }

    private func clearAll() {
        let count = records.count
        store.removeAllSiteData()
        records.removeAll()
        if count > 0 {
            // Sign-out feedback.
            store.appendInfo("Cleared site data for \(count) site\(count == 1 ? "" : "s").")
        }
    }

    private func typeSummary(for record: WKWebsiteDataRecord) -> String {
        // Human summary of which data a site has stored.
        var parts: [String] = []
        if record.dataTypes.contains(WKWebsiteDataTypeCookies) { parts.append("Cookies") }
        if record.dataTypes.contains(WKWebsiteDataTypeLocalStorage) { parts.append("Local storage") }
        if record.dataTypes.contains(WKWebsiteDataTypeSessionStorage) { parts.append("Session") }
        if record.dataTypes.contains(WKWebsiteDataTypeIndexedDBDatabases) { parts.append("IndexedDB") }
        if record.dataTypes.contains(WKWebsiteDataTypeWebSQLDatabases) { parts.append("WebSQL") }
        if record.dataTypes.contains(WKWebsiteDataTypeServiceWorkerRegistrations) { parts.append("Service worker") }
        return parts.isEmpty ? "Cached data" : parts.joined(separator: " · ")
    }
}
