import SwiftUI

struct HistoryCenterView: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var privateMode = PrivateSessionManager.shared
    @EnvironmentObject var app: AppModel

    @State private var query = ""
    @State private var pendingClear: HistoryStore.ClearRange?
    @State private var pendingClearAllPrivate = false

    private var grouped: [(day: String, entries: [BrowserHistoryEntry])] {
        let matches = history.search(query)
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        var buckets: [(String, [BrowserHistoryEntry])] = []
        for entry in matches {
            let key = formatter.string(from: entry.visitedAt)
            if buckets.last?.0 == key {
                buckets[buckets.count - 1].1.append(entry)
            } else {
                buckets.append((key, [entry]))
            }
        }
        return buckets
    }

    var body: some View {
        List {
            privateSection
            historySections
        }
        .listStyle(.insetGrouped)
        .navigationTitle("History Center")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search history")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(HistoryStore.ClearRange.allCases) { range in
                        Button("Clear \(range.label)", role: .destructive) {
                            pendingClear = range
                        }
                    }
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .alert("Clear history?",
               isPresented: Binding(get: { pendingClear != nil },
                                    set: { if !$0 { pendingClear = nil } })) {
            Button("Clear", role: .destructive) {
                if let range = pendingClear { history.clear(range: range) }
                pendingClear = nil
            }
            Button("Cancel", role: .cancel) { pendingClear = nil }
        } message: {
            Text("Visits in the selected range will be permanently removed.")
        }
        .alert("Close all private tabs?",
               isPresented: $pendingClearAllPrivate) {
            Button("Close All", role: .destructive) {
                privateMode.clearAll(browser: store)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Cookies and site data of private tabs are discarded immediately.")
        }
    }

    @ViewBuilder
    private var privateSection: some View {
        Section("Private Mode") {
            Toggle(isOn: Binding(
                get: { privateMode.privateByDefault },
                set: { privateMode.privateByDefault = $0 }
            )) {
                Label("New tabs are private by default", systemImage: "mask")
            }
            HStack {
                Label("\(privateMode.tabs.count) private tab\(privateMode.tabs.count == 1 ? "" : "s") open",
                      systemImage: "eye.slash")
                    .foregroundStyle(privateMode.isEmpty ? Color.secondary : Color.accentColor)
                Spacer()
                Button("Close All") {
                    pendingClearAllPrivate = true
                }
                .disabled(privateMode.isEmpty)
            }
            Text("Private tabs use an ephemeral WebKit session: visits are never recorded in history and cookies are discarded when closed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var historySections: some View {
        if grouped.isEmpty {
            Section {
                Text(query.isEmpty ? "No history yet." : "No results for “\(query)”.")
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(grouped, id: \.day) { group in
                Section(group.day) {
                    ForEach(group.entries) { entry in
                        Button {
                            if let url = URL(string: entry.url) {
                                store.loadURL(url)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.primary)
                                    .lineLimit(1)
                                Text(entry.host)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        let ids = offsets.compactMap { idx in
                            group.entries.indices.contains(idx) ? group.entries[idx].id : nil
                        }
                        history.delete(entryIDs: Set(ids))
                    }
                }
            }
        }
    }
}
