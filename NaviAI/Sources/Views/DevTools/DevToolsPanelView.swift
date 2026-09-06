import SwiftUI
import UIKit

private struct DevCodeLabTab: View {
    @ObservedObject private var store = CodeLabStore.shared

    var body: some View {
        CodeLabView(store: store)
    }
}

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

private struct DevNetworkTab: View {
    @ObservedObject var store: DevToolsStore
    @State private var filter = ""

    private var filtered: [DevNetworkEntry] {
        guard !filter.isEmpty else { return store.network }
        return store.network.filter { entry in
            entry.url.localizedCaseInsensitiveContains(filter)
                || entry.method.localizedCaseInsensitiveContains(filter)
                || entry.statusLabel.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter by URL / method / status", text: $filter)
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

            Group {
                if store.network.isEmpty {
                    Spacer()
                    ContentUnavailableView("No requests captured", systemImage: "arrow.left.arrow.right",
                                           description: Text("Requests issued by this page appear here. Headers and bodies are never logged."))
                    Spacer()
                } else {
                    List(filtered.reversed()) { entry in
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

}

private struct DevDebugTab: View {
    @ObservedObject var store: DevToolsStore
    let inspector: DOMInspector
    @EnvironmentObject var app: AppModel
    @State private var running = false

    var body: some View {
        List {
            Section {
                Button {
                    runAnalysis()
                } label: {
                    HStack {
                        if running {
                            ProgressView().controlSize(.small)
                            Text("Analysing page…")
                        } else {
                            Label("Run AI diagnosis", systemImage: "stethoscope")
                        }
                    }
                    .foregroundStyle(.tint)
                }
                .disabled(running)
            } footer: {
                Text("Cross-references console errors, failed network requests and the DOM, then reports Problem / Evidence / Cause / Fix. Uses your AI provider when configured, otherwise an offline heuristic. No sensitive data leaves the device except through your chosen provider.")
            }

            if let diagnosis = store.diagnosis {
                diagnosisSection(diagnosis)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func diagnosisSection(_ d: DevToolsDiagnosis) -> some View {
        Section("Result") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Problem").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(d.problem).font(.subheadline).foregroundStyle(.primary)
            }
            if !d.evidence.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Evidence").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(d.evidence, id: \.self) { ev in
                        Text(ev).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Possible cause").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(d.possibleCause).font(.subheadline)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Suggested fix").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(d.suggestedFix).font(.subheadline)
            }
            LabeledContent("Source", value: d.source == .llm ? "AI" : "Offline heuristic")
        } footer: {
            Text("Diagnosis is informational. Navi will only change code when you explicitly grant permission.")
        }
    }

    private func runAnalysis() {
        running = true
        Task {
            await inspector.refreshAll()
            let config = app.providers.activeProvider
            let key = config.flatMap { app.providers.apiKey(for: $0) } ?? ""
            _ = await DevToolsAnalyzer.diagnose(store: store, config: config, apiKey: key, llm: app.browser.llm)
            running = false
        }
    }
}

struct DevToolsPanelView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject private var store = DevToolsStore.shared
    @State private var tab: Panel = .console
    @State private var refreshing = false
    @Environment(\.dismiss) private var dismiss

    enum Panel: String, CaseIterable, Identifiable {
        case console, network, elements, storage, debug, codeLab
        var id: String { rawValue }
        var label: String {
            switch self {
            case .console: return "Console"
            case .network: return "Network"
            case .elements: return "Elements"
            case .storage: return "Storage"
            case .debug: return "Debug"
            case .codeLab: return "Code Lab"
            }
        }
        var symbol: String {
            switch self {
            case .console: return "terminal"
            case .network: return "arrow.left.arrow.right"
            case .elements: return "curlybraces.square"
            case .storage: return "internaldrive"
            case .debug: return "ladybug"
            case .codeLab: return "chevron.left.forwardslash.chevron.right"
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
                case .debug: DevDebugTab(store: store, inspector: inspector)
                case .codeLab: DevCodeLabTab()
                }
            }
            .onAppear {
                if let requested = Panel(rawValue: app.browser.devToolsOpenTab) {
                    tab = requested
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
}

private struct DevElementsTab: View {
    @ObservedObject var store: DevToolsStore
    let inspector: DOMInspector
    @EnvironmentObject var app: AppModel
    @State private var searchText = ""
    @State private var matchCount: Int?
    @State private var selecting = false
    @State private var pasted = false

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
            Section {
                Button {
                    toggleSelectMode()
                } label: {
                    HStack {
                        Label(selecting ? "Selecting… tap an element on the page" : "Select Element",
                              systemImage: selecting ? "target" : "cursorarrow.click.2")
                        Spacer()
                        if selecting {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                if let el = store.inspectedElement {
                    inspectedSection(el)
                }
            } footer: {
                Text("Choose an element directly on the page to see its tag, selector, attributes, text and bounding box.")
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
        .listStyle(.insetGrouped)
        .onDisappear { Task { await inspector.cancelElementSelection() } }
    }

    private func inspectedSection(_ el: ElementInspection) -> some View {
        Group {
            VStack(alignment: .leading, spacing: 2) {
                Text(el.displayLabel)
                    .font(.system(.subheadline, design: .monospaced).weight(.bold))
                Text("Selector: " + el.selector)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !el.text.isEmpty {
                LabeledContent("Text", value: el.text)
            }
            if let parent = el.parentTag {
                LabeledContent("Parent", value: parent)
            }
            LabeledContent("Children", value: "\(el.childCount)")
            LabeledContent("Bounds", value: el.boundingBox)
            if !el.attributes.isEmpty {
                DisclosureGroup("Attributes (\(el.attributes.count))") {
                    ForEach(Array(el.attributes.keys.sorted()), id: \.self) { key in
                        Text("\(key) = \(el.attributes[key] ?? "")")
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            HStack {
                Button {
                    UIPasteboard.general.string = el.selector
                    pasted = true
                } label: {
                    Label(pasted ? "Copied!" : "Copy selector", systemImage: "doc.on.doc")
                }
                Spacer()
                Button {
                    askNavi(with: el)
                } label: {
                    Label("Ask Navi", systemImage: "sparkles")
                }
            }
            .font(.caption.weight(.semibold))
        }
    }

    private func toggleSelectMode() {
        selecting = true
        Task {
            let started = await inspector.beginElementSelection()
            if !started {
                selecting = false
            }

            for _ in 0..<25 {
                try? await Task.sleep(nanoseconds: 600_000_000)
                if let picked = await inspector.readSelectedElement() {
                    selecting = false
                    return
                }
            }
            selecting = false
        }
    }

    private func askNavi(with el: ElementInspection) {
        app.browser.showsDevTools = false
        app.browser.agentMode = .debug
        app.browser.showsChatPanel = true
        app.browser.submitPrompt("Explain this element on the current page: \(el.displayLabel) (selector \(el.selector)). Text: \(el.text)")
    }
}

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
