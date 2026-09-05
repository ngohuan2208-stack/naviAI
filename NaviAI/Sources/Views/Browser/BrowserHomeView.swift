import SwiftUI
import UIKit
import WebKit

enum SheetContent: String, Identifiable {
    case history, bookmarks, downloads, siteData, settings
    var id: String { rawValue }
}

struct BrowserHomeView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        BrowserContentView(store: app.browser)
    }
}

// MARK: - Main content

private struct BrowserContentView: View {
    @ObservedObject var store: BrowserStore
    @EnvironmentObject var app: AppModel

    @State private var activeSheet: SheetContent?
    @State private var addressDraft: String = ""
    @FocusState private var addressFocused: Bool

    private var activeProviderLabel: String {
        guard let p = app.providers.activeProvider else { return "No AI selected" }
        return "\(p.name) · \(p.model)"
    }

    var body: some View {
        VStack(spacing: 0) {
            TabStripView(store: store)
            toolbar
            webArea
            AIChatBarView(store: store)
        }
        .background(Color(.systemBackground))
        .onChange(of: store.addressText) { newValue in
            if !addressFocused { addressDraft = newValue }
        }
        .onChange(of: store.activeTabID) { _ in
            addressDraft = store.addressText
        }
        .onAppear {
            addressDraft = store.addressText
        }
        .sheet(item: $activeSheet) { content in
            sheetView(for: content)
        }
        .sheet(isPresented: $store.showsChatPanel) {
            AIChatPanelSheet(store: store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private func sheetView(for content: SheetContent) -> some View {
        NavigationStack {
            switch content {
            case .history: HistorySheet(store: store)
            case .bookmarks: BookmarksSheet(store: store)
            case .downloads: DownloadsSheet(store: store)
            case .siteData: SiteDataSheet(store: store)
            case .settings: SettingsView()
            }
        }
        .environmentObject(app)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            navButton("chevron.left", enabled: store.canGoBack) { store.navigateBack() }
            navButton("chevron.right", enabled: store.canGoForward) { store.navigateForward() }

            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                TextField("Search or enter address", text: $addressDraft)
                    .font(.subheadline)
                    .autocapitalization(.none)
                    .keyboardType(.webSearch)
                    .disableAutocorrection(true)
                    .focused($addressFocused)
                    .submitLabel(.go)
                    .onSubmit {
                        store.loadAddress(addressDraft)
                        addressFocused = false
                    }
                if store.webIsLoading {
                    Button {
                        store.stopWebLoading()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop loading")
                } else {
                    Button {
                        store.reloadPage()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(.secondarySystemBackground), in: Capsule())
            .onTapGesture { addressFocused = true }

            Button {
                store.toggleBookmarkCurrent()
            } label: {
                Image(systemName: store.isCurrentBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 15))
                    .foregroundStyle(store.isCurrentBookmarked ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.plain)
            .disabled(store.activeTab?.webView.url == nil)

            AgentModePicker(store: store)

            Menu {
                Button {
                    store.newTab(url: nil, activate: true)
                } label: {
                    Label("New Tab", systemImage: "plus.square.on.square")
                }
                Button {
                    store.duplicateActiveTab()
                } label: {
                    Label("Duplicate Tab", systemImage: "doc.on.doc")
                }
                .disabled(store.activeTab?.webView.url == nil)
                Button {
                    store.showsChatPanel = true
                } label: {
                    Label("AI Chat", systemImage: "bubble.left.and.bubble.right.fill")
                }
                NavigationLink {
                    AutomationRootView()
                } label: {
                    Label("Automation", systemImage: "wand.and.stars")
                }
                Button {
                    store.beginFind()
                } label: {
                    Label("Find in Page", systemImage: "magnifyingglass")
                }
                .disabled(store.activeTab?.webView.url == nil)
                Divider()
                Button {
                    if let url = store.activeTab?.webView.url ?? store.activeTab?.url {
                        UIPasteboard.general.string = url.absoluteString
                    }
                } label: {
                    Label("Copy Page URL", systemImage: "doc.on.doc.fill")
                }
                .disabled(store.activeTab?.webView.url == nil)
                if let shareURL = store.activeTab?.webView.url ?? store.activeTab?.url {
                    ShareLink(item: shareURL) {
                        Label("Share Page", systemImage: "square.and.arrow.up")
                    }
                }
                Divider()
                Button {
                    activeSheet = .bookmarks
                } label: {
                    Label("Bookmarks", systemImage: "book")
                }
                Button {
                    activeSheet = .history
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                Button {
                    activeSheet = .downloads
                } label: {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }
                Button {
                    activeSheet = .siteData
                } label: {
                    Label("Site Data (Accounts)", systemImage: "externaldrive.badge.person.crop")
                }
                Divider()
                Toggle(isOn: Binding(
                    get: { app.settings.desktopModeEnabled },
                    set: { store.requestDesktopSite($0) }
                )) {
                    Label("Desktop mode", systemImage: "desktopcomputer")
                }
                Button {
                    activeSheet = .settings
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func navButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 30, height: 30)
                .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.4))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: Web area + overlays

    private var webArea: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                WebKitSurfaceView(store: store)
                    .frame(width: geo.size.width, height: geo.size.height)

                AICursorOverlay(store: store)
                    .frame(width: geo.size.width, height: geo.size.height)

                VStack(alignment: .leading, spacing: 8) {
                    if store.agentStatus != .idle {
                        agentStatusPill
                    }
                    if let prompt = store.activePrompt {
                        PromptCard(prompt: prompt, store: store)
                    }
                    Spacer()
                    if store.isFindActive {
                        FindBarView(store: store)
                    }
                }
                .padding(10)
            }
        }
        .clipped()
    }

    private var agentStatusPill: some View {
        HStack(spacing: 8) {
            if store.agentStatus != .idle {
                Image(systemName: store.agentStatus.symbol)
                Text(store.agentStatus.label)
                    .font(.subheadline.weight(.semibold))
            }
            if store.isAgentRunning {
                Button {
                    store.stopAgent()
                } label: {
                    Label("STOP", systemImage: "stop.fill")
                        .font(.caption.weight(.heavy))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.red, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }
}

// MARK: - SwiftUI wrapper around the web surface

private struct WebKitSurfaceView: UIViewRepresentable {
    let store: BrowserStore

    func makeUIView(context: Context) -> WebSurfaceView {
        let view = WebSurfaceView()
        view.store = store
        store.attach(surface: view)
        return view
    }

    func updateUIView(_ uiView: WebSurfaceView, context: Context) {
        uiView.store = store
        store.reconcileSurface()
    }
}

// MARK: - Prompt / confirmation card

struct PromptCard: View {
    let prompt: UserPrompt
    @ObservedObject var store: BrowserStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: prompt.kind == .captcha ? "person.fill.questionmark" : "exclamationmark.shield.fill")
                    .foregroundStyle(prompt.kind == .captcha ? Color.accentColor : .orange)
                Text(prompt.title)
                    .font(.headline)
            }
            Text(prompt.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                if let deny = prompt.denyTitle {
                    Button {
                        store.resolvePrompt(false)
                    } label: {
                        Text(deny)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Button {
                    store.resolvePrompt(true)
                } label: {
                    Text(prompt.allowTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(maxWidth: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.25))
        )
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

// MARK: - Bottom AI message bar

struct AIChatBarView: View {
    @ObservedObject var store: BrowserStore
    @EnvironmentObject var app: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Button {
                store.showsChatPanel = true
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Color(.secondarySystemBackground), in: Circle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Image(systemName: store.isAgentRunning ? "waveform" : "cursorarrow.motionlines")
                    .font(.system(size: 12))
                    .foregroundStyle(store.isAgentRunning ? Color.accentColor : .secondary)
                TextField("Ask NaviAI…", text: $store.chatInput, axis: .vertical)
                    .font(.subheadline)
                    .lineLimit(1...4)
                    .submitLabel(.send)
                    .onSubmit {
                        submit()
                    }
                if store.isAgentRunning {
                    Button {
                        store.stopAgent()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(alignment: .leading) {
                if app.providers.activeProvider == nil {
                    Text("Set up an AI provider in Settings first")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 24)
                        .allowsHitTesting(false)
                }
            }

            Button {
                submit()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background(canSend ? Color.accentColor : Color(.secondarySystemBackground), in: Circle())
                    .foregroundStyle(canSend ? .white : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var canSend: Bool {
        !store.chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.isAgentRunning
    }

    private func submit() {
        let text = store.chatInput
        store.chatInput = ""
        store.submitPrompt(text)
    }
}

// MARK: - Tab strip

struct TabStripView: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.tabs) { tab in
                    TabChipView(tab: tab, isActive: tab.id == store.activeTabID) {
                        store.selectTab(tab.id)
                    } onClose: {
                        store.closeTab(tab.id)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
    }
}

private struct TabChipView: View {
    @ObservedObject var tab: TabItem
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if isActive {
                Image(systemName: "globe")
                    .font(.system(size: 10))
            }
            Text(tab.title.isEmpty ? "New Tab" : tab.title)
                .font(.caption.weight(isActive ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: 150)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(Color.black.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, isActive ? 10 : 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(isActive ? Color.accentColor : Color(.secondarySystemGroupedBackground), in: Capsule())
        .foregroundStyle(isActive ? Color.white : Color.primary)
        .contentShape(Capsule())
        .onTapGesture(perform: onSelect)
    }
}

// MARK: - Find in page bar

struct FindBarView: View {
    @ObservedObject var store: BrowserStore
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Find in page", text: Binding(
                get: { store.findQuery },
                set: { store.updateFindQuery($0) }
            ))
            .font(.subheadline)
            .autocapitalization(.none)
            .disableAutocorrection(true)
            .focused($focused)
            .submitLabel(.search)
            .onSubmit { store.findNext() }
            .textFieldStyle(.plain)

            Button {
                store.findNext()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .disabled(store.findQuery.isEmpty)

            Button {
                store.findNext(true)
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .disabled(store.findQuery.isEmpty)

            Button {
                store.endFind()
            } label: {
                Text("Done")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .onAppear { focused = true }
    }
}

// MARK: - Agent mode picker (toolbar: [View] [Interact] [Auto])

struct AgentModePicker: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AgentMode.allCases) { mode in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        store.agentMode = mode
                    }
                } label: {
                    Label(mode.label, systemImage: mode.symbol)
                        .labelStyle(.titleAndIcon)
                        .font(.caption2.weight(store.agentMode == mode ? .semibold : .regular))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(store.agentMode == mode ? Color.accentColor.opacity(0.16) : Color.clear,
                                    in: Capsule())
                        .foregroundStyle(store.agentMode == mode ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color(.secondarySystemBackground).opacity(0.6), in: Capsule())
    }
}
