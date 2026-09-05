// MARK: - Console tab

private struct DevConsoleTab: View {
    @ObservedObject var store: DevToolsStore
    @State private var filter = ""

    private var filtered: [DevConsoleEntry] {
        filter.isEmpty ? store.console : store.console.filter {
            $0.message.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter", text: $filter)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                if !filter.isEmpty {
                    Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal)
            .padding(.vertical, 6)

            if store.console.isEmpty {
                Spacer()
                ContentUnavailableView("No console output", systemImage: "terminal",
                                       description: Text("Messages logged by this page appear here."))
                Spacer()
            } else {
                List(filtered.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: entry.level.symbol)
                                .foregroundStyle(color(for: entry.level))
                                .font(.caption)
                            Text(entry.message)
                                .font(.system(.caption, design: .monospaced))
                        }
                        if let src = entry.sourceURL {
                            Text("\(src):\(entry.line ?? 0)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button("Clear console") { store.clearConsole() }
                    .disabled(store.console.isEmpty)
            }
        }
    }

    private func color(for level: DevConsoleEntry.Level) -> Color {
        switch level {
        case .error: return .red
        case .warn: return .orange
        case .info: return .blue
        case .debug: return .purple
        case .log: return .secondary
        }
    }
}

// MARK: - Network tab

private struct DevNetworkTab: View {
    @ObservedObject var store: DevToolsStore

    var body: some View {
        Group {
            if store.network.isEmpty {
                ContentUnavailableView("No requests captured", systemImage: "arrow.left.arrow.right",
                                       description: Text("Requests issued by this page appear here. Headers and bodies are never logged."))
            } else {
                List(store.network.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(entry.method)
                                .font(.caption.bold())
                                .foregroundStyle(.tint)
                            Text(entry.url)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text(entry.statusLabel)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(entry.error != nil ? Color.red :
                                                    (200...299).contains(entry.status ?? 0) ? Color.green : Color.orange)
                        }
                        HStack(spacing: 8) {
                            if let ms = entry.durationMS { Text("\(ms) ms") }
                            if let sz = entry.sizeBytes {
                                Text(ByteCountFormatter.string(fromByteCount: Int64(sz), countStyle: .file))
                            }
                            if let mime = entry.mimeType { Text(mime) }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.plain)
            }
        }
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Button("Clear network log") { store.clearNetwork() }
                    .disabled(store.network.isEmpty)
            }
        }
    }
}

// MARK: - DevTools panel (bottom sheet)

/// The on-device DevTools surface. On iPhone it is a bottom sheet
/// (medium/large detents); on regular-width layouts it can be presented
/// side-by-side by the caller. All data shown is already redacted.
struct DevToolsPanelView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject private var store = DevToolsStore.shared
    @State private var tab: Panel = .console
    @State private var refreshing = false

    enum Panel: String, CaseIterable, Identifiable {
        case console, network, elements, storage
        var id: String { rawValue }
        var label: String {
            switch self {
            case .console: return "Console"
            case .network: return "Network"
            case .elements: return "Elements"
            case .storage: return "Storage"
            }
        }
        var symbol: String {
            switch self {
            case .console: return "terminal"
            case .network: return "arrow.left.arrow.right"
            case .elements: return "curlybraces.square"
            case .storage: return "internaldrive"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Panel", selection: $tab) {
                    ForEach(Panel.allCases) { p in
                        Label(p.label, systemImage: p.symbol).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)

                switch tab {
                case .console: DevConsoleTab(store: store)
                case .network: DevNetworkTab(store: store)
                case .elements: DevElementsTab(store: store, inspector: inspector)
                case .storage: DevStorageTab(store: store, inspector: inspector)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle("DevTools")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        store.isCapturing.toggle()
                    } label: {
                        Image(systemName: store.isCapturing ? "pause.circle" : "record.circle")
                    }
                    .accessibilityLabel(store.isCapturing ? "Pause capture" : "Resume capture")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        refreshing = true
                        Task {
                            await inspector.refreshAll()
                            refreshing = false
                        }
                    } label: {
                        Image(systemName: refreshing ? "arrow.triangle.2.circlepath.rotate" : "arrow.triangle.2.circlepath")
                    }
                    .accessibilityLabel("Refresh page data")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var inspector: DOMInspector {
        DOMInspector(coordinator: app.browser.activeCoordinator)
    }
// MARK: - Elements tab

private struct DevElementsTab: View {
    @ObservedObject var store: DevToolsStore
    let inspector: DOMInspector
    @State private var searchText = ""
    @State private var matchCount: Int?

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Find in page DOM", text: $searchText)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                    Button("Find") {
                        Task {
                            matchCount = await inspector.highlight(matchingText: searchText)
                        }
                    }
                    .disabled(searchText.isEmpty)
                }
                if let matchCount {
                    Text("\(matchCount) element(s) outlined")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if store.domElements.isEmpty {
                ContentUnavailableView("No elements loaded", systemImage: "curlybraces.square",
                                       description: Text("Tap the refresh button to read the page structure."))
            } else {
                ForEach(Array(store.domElements.enumerated()), id: \.offset) { _, el in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(el.label)
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                        if let txt = el.textPreview, !txt.isEmpty {
                            Text(txt)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.leading, CGFloat(min(el.depth, 8)) * 8)
                }
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - Storage tab

private struct DevStorageTab: View {
    @ObservedObject var store: DevToolsStore
    let inspector: DOMInspector

    var body: some View {
        List {
            Section("Cookies") {
                LabeledContent("Cookie count", value: "\(store.cookiesSummary)")
                Text("Values are never displayed — only the count.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            storageSection("localStorage", entries: store.localStorage)
            storageSection("sessionStorage", entries: store.sessionStorage)
        }
        .listStyle(.insetGrouped)
    }

    private func storageSection(_ title: String, entries: [DevStorageEntry]) -> some View {
        Section(title) {
            if entries.isEmpty {
                Text("Empty.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.key)
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                        Text(entry.value)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }
}

    @Environment(\.dismiss) private var dismiss
}