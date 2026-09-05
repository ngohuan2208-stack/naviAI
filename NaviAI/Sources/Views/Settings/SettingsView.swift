import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @State private var providerTarget: ProviderConfig?
    @State private var clearAction: ClearAction?

    enum ClearAction: String, Identifiable {
        case history, bookmarks, downloads, cookies, cache
        var id: String { rawValue }
        var title: String {
            switch self {
            case .history: return "Clear history"
            case .bookmarks: return "Clear bookmarks"
            case .downloads: return "Clear downloads"
            case .cookies: return "Clear cookies & site data"
            case .cache: return "Clear cache"
            }
        }
        var message: String {
            switch self {
            case .cookies: return "You will be signed out of websites and their local data will be removed."
            default: return "This cannot be undone."
            }
        }
    }

    var body: some View {
        Form {
            Section {
                ForEach(app.providers.providers) { provider in
                    Button {
                        providerTarget = provider
                    } label: {
                        HStack {
                            ProviderRow(provider: provider, hasKey: app.providers.hasKey(for: provider))
                            if provider.id == app.providers.activeProviderID {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    let custom = app.providers.makeProvider(of: .custom)
                    providerTarget = custom
                } label: {
                    Label("Add Custom API", systemImage: "plus.circle")
                }
            } header: {
                Text("AI Providers")
            } footer: {
                Text("API keys are stored securely in the iOS Keychain.")
            }

            Section("AI Agent") {
                Toggle("AI cursor", isOn: $app.settings.aiCursorEnabled)
                Toggle("Cursor animation", isOn: $app.settings.cursorAnimationsEnabled)
                    .disabled(!app.settings.aiCursorEnabled)
                Toggle("Confirm impactful actions", isOn: $app.settings.aiConfirmationEnabled)
                Toggle("Show agent status labels", isOn: $app.settings.showAgentLabelsEnabled)
                Toggle("Auto-scroll while reading", isOn: $app.settings.autoScrollEnabled)
            }

            Section("Browser") {
                Picker("Search engine", selection: $app.settings.searchEngine) {
                    ForEach(SearchEngine.allCases) { engine in
                        Text(engine.label).tag(engine)
                    }
                }
                Toggle("Desktop mode", isOn: Binding(
                    get: { app.settings.desktopModeEnabled },
                    set: { newValue in app.browser.requestDesktopSite(newValue) }
                ))
            }

            Section("Network & Developer") {
                NavigationLink {
                    NetworkCenterView()
                } label: {
                    Label("Network & Proxy", systemImage: "antenna.radiowaves.left.and.right")
                }
                Button {
                    app.browser.showsDevTools = true
                } label: {
                    Label("DevTools (this page)", systemImage: "wrench.and.screwdriver")
                }
            }

            Section {
                Button { clearAction = .history } label: { Label("Clear history", systemImage: "clock.arrow.circlepath") }
                Button { clearAction = .bookmarks } label: { Label("Clear bookmarks", systemImage: "book") }
                Button { clearAction = .downloads } label: { Label("Clear downloads", systemImage: "arrow.down.circle") }
                Button { clearAction = .cookies } label: { Label("Clear cookies & site data", systemImage: "cookie") }
                Button { clearAction = .cache } label: { Label("Clear cache", systemImage: "internaldrive") }
            } header: {
                Text("Privacy & Data")
            } footer: {
                Text("NaviAI never uploads your browsing history anywhere. Requests go only to the AI provider you chose, with just the page context the agent needs.")
            }

            Section("Appearance") {
                Picker("Appearance", selection: $app.settings.appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("About NaviAI") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Model", value: app.providers.activeProvider?.model ?? "—")
                VStack(alignment: .leading, spacing: 6) {
                    Text("NaviAI is your AI-powered browser. The little mouse you see is the AI cursor - watch it move, click and type for you.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
        .sheet(item: $providerTarget) { provider in
            NavigationStack {
                ProviderConfigView(config: provider)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { providerTarget = nil }
                        }
                    }
            }
        }
        .confirmationDialog(clearAction?.title ?? "", isPresented: Binding(
            get: { clearAction != nil },
            set: { if !$0 { clearAction = nil } }
        ), titleVisibility: .visible) {
            Button(clearAction?.title ?? "Clear", role: .destructive) { perform(clearAction) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(clearAction?.message ?? "")
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func perform(_ action: ClearAction?) {
        guard let action else { return }
        switch action {
        case .history: app.browser.clearHistory()
        case .bookmarks: app.browser.clearBookmarks()
        case .downloads: app.browser.clearDownloads()
        case .cookies: app.browser.clearCookies()
        case .cache: app.browser.clearCache()
        }
        clearAction = nil
    }
}
