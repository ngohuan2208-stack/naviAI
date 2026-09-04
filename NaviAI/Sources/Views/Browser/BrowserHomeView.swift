import SwiftUI
import UIKit
import WebKit

enum SheetContent: String, Identifiable {
    case history, bookmarks, downloads, settings
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
        .fullScreenCover(isPresented: $store.showsChatPanel) {
            AIChatPanelSheet(store: store)
        }
    }

    @ViewBuilder
    private func sheetView(for content: SheetContent) -> some View {
        NavigationStack {
            switch content {
            case .history: HistorySheet(store: store)
            case .bookmarks: BookmarksSheet(store: store)
            case .downloads: DownloadsSheet(store: store)
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
                    ProgressView().controlSize(.small)
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

            Menu {
                Button {
                    store.newTab(url: nil, activate: true)
                } label: {
                    Label("New Tab", systemImage: "plus.square.on.square")
                }
                Button {
                    store.showsChatPanel = true
                } label: {
                    Label("AI Chat", systemImage: "bubble.left.and.bubble.right.fill")
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
