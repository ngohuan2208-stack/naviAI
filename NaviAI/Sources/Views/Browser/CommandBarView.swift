import SwiftUI

// MARK: - Command bar (command palette)

/// A keyboard-first command palette: type a query, get one "go to" action plus
/// matching app commands and open tabs. Purely functional — every action maps
/// to an existing BrowserStore API.
struct CommandBarView: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    private struct Command: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let symbol: String
        let action: () -> Void
    }

    private var trimmed: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var commands: [Command] {
        var list: [Command] = []

        if !trimmed.isEmpty {
            list.append(Command(id: "open-url",
                                title: "Go to “\(trimmed)”",
                                subtitle: "Open in the current tab",
                                symbol: "globe") {
                store.loadAddress(trimmed)
                dismiss()
            })
        }

        list.append(Command(id: "new-tab",
                            title: "New Tab",
                            subtitle: "Open a blank tab",
                            symbol: "plus.square.on.square") {
            store.newTab(url: nil, activate: true)
            dismiss()
        })

        list.append(Command(id: "new-private-tab",
                            title: "New Private Tab",
                            subtitle: "Ephemeral session, not saved to history",
                            symbol: "mask") {
            store.openPrivateTab(url: trimmed.isEmpty ? nil : URL(string: trimmed))
            dismiss()
        })

        list.append(Command(id: "reopen",
                            title: "Reopen Last Closed Tab",
                            subtitle: "Restores the most recently closed tab",
                            symbol: "arrow.uturn.backward.square") {
            store.reopenClosedTab()
            dismiss()
        })

        list.append(Command(id: "ai-chat",
                            title: "Open AI Chat",
                            subtitle: "Continue the conversation with the agent",
                            symbol: "bubble.left.and.bubble.right.fill") {
            store.showsChatPanel = true
            dismiss()
        })

        if store.activeTab?.webView.url != nil {
            list.append(Command(id: "find",
                                title: "Find in Page",
                                subtitle: "Search text on the current page",
                                symbol: "magnifyingglass") {
                store.beginFind()
                dismiss()
            })
        }

        // Matching open tabs (title or URL).
        let matches = store.searchTabs(trimmed).prefix(6)
        for tab in matches {
            let isPrivate = tab.isPrivate
            list.append(Command(id: "tab-\(tab.id.uuidString)",
                                title: tab.title.isEmpty ? "Untitled tab" : tab.title,
                                subtitle: (isPrivate ? "Private · " : "Tab · ")
                                    + (tab.webView.url?.host ?? tab.url?.host ?? "about:blank"),
                                symbol: isPrivate ? "mask" : "square.on.square") {
                    store.selectTab(tab.id)
                    dismiss()
                })
        }

        return list
    }

    // MARK: Body (see below)
}

// MARK: - Command bar UI

extension CommandBarView {
    var body: some View {
        NavigationStack {
            List {
                inputSection
                resultsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Command Bar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onAppear { focused = true }
    }

    private var inputSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .foregroundStyle(.secondary)
                TextField("Search or type a command…", text: $query)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .submitLabel(.go)
                    .onSubmit { runFirst() }
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listRowBackground(Color(.secondarySystemBackground))
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        if commands.isEmpty {
            Section {
                Text("No matching commands.")
                    .foregroundStyle(.secondary)
            }
        } else {
            Section("Commands") {
                ForEach(commands) { command in
                    Button {
                        command.action()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: command.symbol)
                                .frame(width: 22)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(command.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Color.primary)
                                Text(command.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func runFirst() {
        guard let first = commands.first else { return }
        first.action()
    }
}
