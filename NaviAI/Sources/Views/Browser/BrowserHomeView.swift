import SwiftUI
import UIKit
import WebKit

enum SheetContent: String, Identifiable {
    case history, historyCenter, bookmarks, downloads, siteData, settings, commandBar
    var id: String { rawValue }
}

struct BrowserHomeView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ZStack {
            BrowserContentView(store: app.browser)
                .opacity(app.browser.showsWelcome ? 0 : 1)
                .scaleEffect(app.browser.showsWelcome ? 0.98 : 1)
                .allowsHitTesting(!app.browser.showsWelcome)

            if app.browser.showsWelcome {
                WelcomeLaunchView()
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 1.02)),
                        removal: .opacity.combined(with: .scale(scale: 0.98))
                    ))
                    .zIndex(10)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: app.browser.showsWelcome)
    }
}

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
        .sheet(isPresented: $store.showsCommandBar) {
            sheetView(for: .commandBar)
        }
        .sheet(isPresented: $store.showsChatPanel) {
            AIChatPanelSheet(store: store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $store.showsDevTools) {
            DevToolsPanelView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $store.showsResearch) {
            NavigationStack { ResearchView() }
                .presentationDetents([.large])
        }
        .sheet(isPresented: $store.showsImageStudio) {
            NavigationStack { ImageStudioView() }
                .presentationDetents([.large])
        }
        .sheet(isPresented: $store.showsAutomation) {
            NavigationStack { AutomationRootView() }
                .presentationDetents([.large])
        }
        .sheet(isPresented: $store.showsNetworkCenter) {
            NavigationStack { NetworkCenterView() }
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $store.showsSettings) {
            NavigationStack { SettingsView() }
        }
    }

    @ViewBuilder
    private func sheetView(for content: SheetContent) -> some View {
        NavigationStack {
            switch content {
            case .history: HistorySheet(store: store)
            case .historyCenter: HistoryCenterView(store: store)
            case .bookmarks: BookmarksSheet(store: store)
            case .downloads: DownloadsSheet(store: store)
            case .siteData: SiteDataSheet(store: store)
            case .settings: SettingsView()
            case .commandBar: CommandBarView(store: store)
            }
        }
        .environmentObject(app)
    }

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
                    store.openPrivateTab(url: nil)
                } label: {
                    Label("New Private Tab", systemImage: "mask")
                }
                Button {
                    store.reopenClosedTab()
                } label: {
                    Label("Reopen Last Closed Tab", systemImage: "arrow.uturn.backward.square")
                }
                Button {
                    activeSheet = .commandBar
                } label: {
                    Label("Command Bar", systemImage: "command")
                }
                NavigationLink {
                    ResearchView()
                } label: {
                    Label("Deep Research", systemImage: "sparkMagnifyingglass")
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
                    activeSheet = .historyCenter
                } label: {
                    Label("History Center", systemImage: "clock.badge.arrow.down")
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
                    .pulsingWhileActive(store.isAgentRunning)
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
                .buttonStyle(BouncyButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.accentColor.opacity(store.isAgentRunning ? 0.5 : 0), lineWidth: 1.5)
        }
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: store.isAgentRunning)
    }
}

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
        .transition(.scale(scale: 0.92).combined(with: .opacity))
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: prompt.id)
    }
}

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
                    .pulsingWhileActive(store.isAgentRunning)
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
                    .buttonStyle(BouncyButtonStyle())
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.accentColor.opacity(store.isAgentRunning ? 0.4 : 0), lineWidth: 1.5)
            }
            .overlay(alignment: .leading) {
                if app.providers.activeProvider == nil {
                    Text("Set up an AI provider in Settings first")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 24)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.2), value: store.isAgentRunning)

            Button {
                submit()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background(canSend ? Color.accentColor : Color(.secondarySystemBackground), in: Circle())
                    .foregroundStyle(canSend ? .white : Color.secondary)
            }
            .buttonStyle(BouncyButtonStyle())
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
        .scaleEffect(isActive ? 1.04 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isActive)
        .contentShape(Capsule())
        .onTapGesture(perform: onSelect)
    }
}

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
