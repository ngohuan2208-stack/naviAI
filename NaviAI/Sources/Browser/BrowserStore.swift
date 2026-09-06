import Foundation
import Combine
import WebKit

// MARK: - Tab

@MainActor
final class TabItem: ObservableObject, Identifiable {
    let id: UUID
    let coordinator: WebCoordinator
    /// Whether this tab is part of a private (non-persistent storage) session.
    let isPrivate: Bool
    @Published var title: String = ""
    @Published var url: URL?
    @Published var isLoading: Bool = false

    init(desktopMode: Bool, isPrivate: Bool = false) {
        self.id = UUID()
        self.isPrivate = isPrivate
        self.coordinator = WebCoordinator(tabID: id, desktopMode: desktopMode, ephemeral: isPrivate)
    }

    var webView: WKWebView { coordinator.webView }
}

// MARK: - Agent status

enum AgentStatus: Equatable {
    case idle
    case thinking
    case searching
    case reading
    case navigating
    case clicking
    case typing
    case scrolling
    case waitingForUser
    case done
    case stopped
    case error(String)

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .thinking: return "Thinking…"
        case .searching: return "Searching…"
        case .reading: return "Reading page…"
        case .navigating: return "Navigating…"
        case .clicking: return "Clicking…"
        case .typing: return "Typing…"
        case .scrolling: return "Scrolling…"
        case .waitingForUser: return "Waiting for user…"
        case .done: return "Done"
        case .stopped: return "Stopped"
        case .error: return "Error"
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "circle"
        case .thinking: return "brain.head.profile"
        case .searching: return "magnifyingglass"
        case .reading: return "doc.text"
        case .navigating: return "arrow.up.right.square"
        case .clicking: return "hand.tap"
        case .typing: return "keyboard"
        case .scrolling: return "arrow.down.circle"
        case .waitingForUser: return "person.fill.questionmark"
        case .done: return "checkmark.circle.fill"
        case .stopped: return "stop.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var tintName: String {
        switch self {
        case .thinking, .searching, .reading, .navigating, .clicking, .typing, .scrolling, .waitingForUser: return "accent"
        case .done: return "green"
        case .stopped, .error: return "orange"
        case .idle: return "gray"
        }
    }
}

// MARK: - User prompt / confirmation

enum PromptKind {
    case action
    case captcha
    case clarification
}

struct UserPrompt: Identifiable {
    let id = UUID()
    let kind: PromptKind
    let title: String
    let message: String
    let allowTitle: String
    let denyTitle: String?
}

// MARK: - Cursor state

struct CursorState: Equatable {
    var visible: Bool = false
    var position: CGPoint = .zero
    var label: String?
    var pulseID: Int = 0
    /// Set momentarily while the AI "presses" the button so the mascot can
    /// squash to look like a physical click.
    var isPressing: Bool = false
}

// MARK: - Agent modes

/// The three ways the AI can engage with the browser.
///
/// - `.view`     : AI reads / understands / summarises / translates the current
///                 page. It is strictly READ-ONLY — it never navigates, clicks
///                 or types. Safe to run freely.
/// - `.interact` : AI may control the browser (navigate, click, type, scroll…)
///                 but asks for confirmation before impactful actions.
/// - `.auto`     : AI plans and executes multi-step tasks on its own until it
///                 produces a final answer, with confirmation guardrails for
///                 risky actions.
enum AgentMode: String, CaseIterable, Identifiable {
    case view
    case interact
    case auto
    case debug

    var id: String { rawValue }

    var label: String {
        switch self {
        case .view: return "View"
        case .interact: return "Interact"
        case .auto: return "Auto"
        case .debug: return "Debug"
        }
    }

    var symbol: String {
        switch self {
        case .view: return "eye"
        case .interact: return "hand.tap"
        case .auto: return "bolt"
        case .debug: return "ladybug"
        }
    }

    /// Whether the agent is allowed to touch (navigate/click/type) the page.
    /// View mode is strictly read-only.
    var permitsInteraction: Bool { self != .view }

    /// Extra rules injected into the agent system prompt.
    var systemInstruction: String {
        switch self {
        case .view:
            return """
            OPERATING MODE: VIEW (read-only).
            You are analysing the current page. Use readPage / findText to inspect it.
            You may summarise, explain, translate, extract data or answer questions.
            You must NEVER navigate, click, type, submit, scroll-to-act or change anything.
            If the user asks you to act on the page, explain that they should switch to Interact mode.
            """
        case .interact:
            return """
            OPERATING MODE: INTERACT.
            You may control the browser (navigate, click, type, scroll).
            Before any impactful action (form submit, sending a message, purchasing,
            deleting, changing account or financial info) you must clearly describe
            it — the user will be asked to confirm.
            """
        case .auto:
            return """
            OPERATING MODE: AUTO (multi-step task).
            Break the user's goal into steps and keep going until it is complete.
            Search, open results, read pages, extract data, compare sources and
            finally give a concise, well-structured answer in the user's language.
            Do not stop after a single tool call — pursue the whole goal.
            Before any impactful action (submit form / send / buy / delete / change
            account) describe it clearly and stop for confirmation.
            """
        case .debug:
            return """
            OPERATING MODE: DEBUG (web diagnostics).
            Diagnose why a page is broken. Work through this exact sequence:
            1. OBSERVE — read the page, note the URL/title and what looks broken.
            2. INSPECT DOM — use readPage / findText to understand structure.
            3. INSPECT CONSOLE — surface page JS errors/warnings to the user.
            4. INSPECT NETWORK — note failed HTTP requests (4xx/5xx), CORS, timeouts.
            5. ANALYSE — cross-reference console errors with failed network requests.
            6. EXPLAIN THE PROBLEM — state the concrete Problem.
            7. PROVIDE EVIDENCE — quote the exact console/network error(s).
            8. POSSIBLE CAUSE — most likely root cause, ranked.
            9. SUGGESTED FIX — concrete next steps for the developer/user.
            Always give a structured answer: Problem / Evidence / Possible cause /
            Suggested fix. NEVER claim a diagnosis you did not observe. Do NOT edit
            the page, execute arbitrary JS, or change any file unless the user
            explicitly grants permission and it is within the page scope.
            """
        }
    }
}

// MARK: - Persisted session snapshot

/// A single restored tab: its URL plus a human-friendly title so re-opening a
/// session does not lose the tab labels.
struct StoredTabSession: Codable {
    var url: URL?
    var title: String
}

// MARK: - Browser store

@MainActor
final class BrowserStore: ObservableObject {

    // Injected dependencies
    let settings: SettingsStore
    let providers: ProviderStore
    let llm = LLMService()

    // Tabs & surface
    @Published var tabs: [TabItem] = []
    @Published var activeTabID: UUID?
    @Published var viewportSize: CGSize = .zero
    weak var surface: WebSurfaceView?

    // Chrome
    @Published var addressText: String = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var webIsLoading = false
    @Published var isCurrentBookmarked = false

    // Library
    @Published var history: [PageVisit] = []
    @Published var bookmarks: [BookmarkItem] = []
    @Published var downloads: [DownloadRecord] = []

    // Agent / chat
    @Published var turns: [ChatTurn] = []
    @Published var chatInput: String = ""
    @Published var isAgentRunning = false
    @Published var agentStatus: AgentStatus = .idle
    @Published var activePrompt: UserPrompt?
    @Published var cursor = CursorState()
    @Published var showsChatPanel = false
    @Published var showsWelcome = false
    @Published var showsDevTools = false
    /// Which DevTools panel tab to open ("console", "network", "elements", "storage", "debug").
    @Published var devToolsOpenTab: String = "console"
    @Published var showsNetworkCenter = false
    @Published var showsImageStudio = false
    @Published var showsResearch = false
    @Published var showsHistoryCenter = false
    @Published var showsDownloads = false
    @Published var showsBookmarks = false
    @Published var showsSettings = false
    @Published var showsAutomation = false
    @Published var showsFindBar = false
    @Published var agentMode: AgentMode = .interact
    // Auto-mode progress surfaced to the UI.
    @Published var taskGoal: String = ""
    @Published var agentStep: Int = 0

    // Continuous task runtime (also surfaced on LAN).
    @Published var runningTask: PersistedAgentTask?
    /// Persistent continuation instruction attached to the running task.
    var persistentContinuationPrompt: String = ""
    /// Set by the STOP_SELF tool; the loop stops on the next iteration.
    var stopSelfRequested = false
    /// Non-nil while a captured screenshot is waiting to be merged into the
    /// next LLM request as vision evidence.
    var pendingVisionScreenshot: WebScreenshot?

    // Find in page
    @Published var isFindActive = false
    @Published var findQuery: String = ""

    // Internals
    var agentTask: Task<Void, Never>?
    var apiHistory: [OutboundItem] = []
    // NOTE: internal (not `private`) because the agent loop lives in an
    // extension declared in another file (Agent/AgentLoop.swift), and Swift's
    // `private` scope is file-limited.
    var captchaPrompted = false
    var promptContinuation: CheckedContinuation<Bool, Never>?

    /// Synthetic elements produced by the vision fallback (negative ids).
    /// id -> viewport point (CSS px).
    var visionClickables: [Int: CGPoint] = [:]

    private enum Keys {
        static let history = "lib.history.v1"
        static let bookmarks = "lib.bookmarks.v1"
        static let downloads = "lib.downloads.v1"
        static let sessionTabs = "lib.sessionTabs.v1"
    }

    init(settings: SettingsStore, providers: ProviderStore) {
        self.settings = settings
        self.providers = providers
        loadLibrary()
        restoreTabs()
    }

    // MARK: - Tabs

    var activeTab: TabItem? {
        guard let id = activeTabID else { return nil }
        return tabs.first { $0.id == id }
    }

    var activeCoordinator: WebCoordinator? { activeTab?.coordinator }

    @discardableResult
    func newTab(url: URL?, activate: Bool = true, ephemeral: Bool = false) -> TabItem {
        let tab = TabItem(desktopMode: settings.desktopModeEnabled, isPrivate: ephemeral)
        tabs.append(tab)
        if activate { selectTab(tab.id) }
        let target = url ?? settings.searchEngine.homeURL
        tab.coordinator.load(target)
        tab.url = target
        refreshAddressBar()
        reconcileSurface()
        persistSessionTabs()
        return tab
    }

    func closeTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[idx]
        // Remember closed tabs for "Reopen closed tab" (except private tabs,
        // which must not be restored).
        if !tab.isPrivate {
            ClosedTabStack.push(url: tab.webView.url ?? tab.url, title: tab.title)
        }
        if tab.isPrivate {
            PrivateSessionManager.shared.unregister(tabID: id)
        }
        tab.coordinator.webView.stopLoading()
        if activeTabID == id {
            let newIndex = max(0, idx - 1)
            if tabs.indices.contains(newIndex), newIndex != idx {
                activeTabID = tabs[newIndex].id
            } else if tabs.count > 1 {
                activeTabID = tabs[idx == tabs.count - 1 ? idx - 1 : idx + 1].id
            } else {
                activeTabID = nil
            }
        }
        tabs.remove(at: idx)
        if tabs.isEmpty {
            let fresh = newTab(url: nil, activate: true)
            activeTabID = fresh.id
        }
        if activeTabID == nil { activeTabID = tabs.first?.id }
        syncChrome()
        reconcileSurface()
        persistSessionTabs()
    }

    func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabID = id
        syncChrome()
        reconcileSurface()
    }

    func switchToTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectTab(tabs[index].id)
    }

    func openNewTab(url: URL) {
        _ = newTab(url: url, activate: true)
    }

    // MARK: - Private tabs

    /// Open a new private tab with an isolated, non-persistent data store.
    @discardableResult
    func openPrivateTab(url: URL? = nil) -> TabItem {
        let tab = newTab(url: url ?? settings.searchEngine.homeURL, activate: true, ephemeral: true)
        PrivateSessionManager.shared.register(tabID: tab.id, title: tab.title, url: tab.url?.absoluteString ?? "")
        return tab
    }

    /// Close a single private tab and release its ephemeral data.
    func closePrivateTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        PrivateSessionManager.shared.unregister(tabID: id)
        closeTab(id)
        _ = tab // lifetime fully handled by closeTab
    }

    var isActiveTabPrivate: Bool {
        activeTab?.isPrivate ?? false
    }

    /// Opens a copy of the active tab (same URL, same title).
    func duplicateActiveTab() {
        guard let tab = activeTab, let url = tab.webView.url ?? tab.url else {
            _ = newTab(url: nil, activate: true)
            return
        }
        let dup = newTab(url: url, activate: true)
        dup.title = tab.title
    }

    // MARK: - Navigation

    func loadAddress(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let url = urlFrom(text: trimmed) {
            loadURL(url)
        } else {
            let searchURL = settings.searchEngine.searchURL(for: trimmed)
            loadURL(searchURL)
        }
    }

    func urlFrom(text: String) -> URL? {
        if text.hasPrefix("http://") || text.hasPrefix("https://") {
            return URL(string: text)
        }
        if text.contains(".") && !text.contains(" "),
           let url = URL(string: "https://" + text),
           url.host?.contains(".") == true {
            return url
        }
        return nil
    }

    func loadURL(_ url: URL) {
        guard let coordinator = activeCoordinator else { return }
        if url.scheme != "http" && url.scheme != "https" { return }
        coordinator.load(url)
        addressText = url.absoluteString
        if let tab = activeTab { tab.url = url }
        webIsLoading = true
    }

    func navigateBack() {
        guard let wv = activeTab?.webView, wv.canGoBack else { return }
        wv.goBack()
    }

    func navigateForward() {
        guard let wv = activeTab?.webView, wv.canGoForward else { return }
        wv.goForward()
    }

    func reloadPage() {
        guard let wv = activeTab?.webView else { return }
        wv.reload()
    }

    func stopWebLoading() {
        guard let wv = activeTab?.webView else { return }
        wv.stopLoading()
    }

    // MARK: - Find in page (native WKWebView, iOS 16+)

    func beginFind() {
        isFindActive = true
        findQuery = ""
        activeTab?.webView.find("", configuration: WKFindConfiguration()) { _ in }
    }

    func updateFindQuery(_ text: String) {
        findQuery = text
        // An empty query clears highlights (find takes a non-optional String).
        let config = WKFindConfiguration()
        config.backwards = false
        activeTab?.webView.find(text, configuration: config) { _ in }
    }

    func findNext(_ backwards: Bool = false) {
        guard !findQuery.isEmpty else { return }
        let config = WKFindConfiguration()
        config.backwards = backwards
        activeTab?.webView.find(findQuery, configuration: config) { _ in }
    }

    func endFind() {
        isFindActive = false
        findQuery = ""
        // Clear highlights by searching for an empty string.
        activeTab?.webView.find("", configuration: WKFindConfiguration()) { _ in }
    }

    func requestDesktopSite(_ on: Bool) {
        activeCoordinator?.setDesktopMode(on)
        settings.desktopModeEnabled = on
        reloadPage()
    }

    // MARK: - Surface

    func attach(surface: WebSurfaceView) {
        self.surface = surface
        reconcileSurface()
    }

    func reconcileSurface() {
        surface?.reconcile(tabs: tabs, activeID: activeTabID)
    }

    func surfaceDidLayout(size: CGSize) {
        viewportSize = size
        reconcileSurface()
    }

    // MARK: - Web event handlers (called from WebCoordinator)

    func webChromeDidChange(tabID: UUID) {
        guard tabID == activeTabID else { return }
        syncChrome()
    }

    func webPageDidFinish(tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        let finalURL = tab.webView.url
        tab.title = tab.webView.title ?? (finalURL?.host ?? "")
        tab.url = finalURL
        tab.isLoading = false
        if tabID == activeTabID {
            syncChrome()
        }
        if let url = finalURL, url.scheme == "http" || url.scheme == "https" {
            if tab.isPrivate {
                // Private session: never record history or long-lived records.
                PrivateSessionManager.shared.update(tabID: tabID, title: tab.title, url: url.absoluteString)
            } else {
                recordVisit(title: tab.title.isEmpty ? url.absoluteString : tab.title, url: url)
                // Durable browser history (searchable, deletable, survives
                // relaunches) with session/tab metadata.
                HistoryStore.shared.recordVisit(url: url,
                                                title: tab.title,
                                                sessionID: tab.id,
                                                sessionName: tab.title.isEmpty ? "Tab" : tab.title)
            }
        }
        persistSessionTabs()
        updateBookmarkState()
    }

    func webLoadFailed(tabID: UUID, error: Error) {
        guard tabID == activeTabID else { return }
        if let tab = activeTab { tab.isLoading = false }
        syncChrome()
        appendInfo("Unable to load webpage.")
    }

    func downloadDidComplete(context: DownloadContext) {
        guard let target = context.targetURL else { return }
        let rel = target.lastPathComponent
        let record = DownloadRecord(
            title: context.suggestedFilename,
            relativePath: rel,
            mimeType: context.mime,
            suggestedFilename: context.suggestedFilename
        )
        downloads.insert(record, at: 0)
        persistLibrary()
    }

    func syncChrome() {
        guard let wv = activeTab?.webView else {
            canGoBack = false
            canGoForward = false
            webIsLoading = false
            return
        }
        addressText = wv.url?.absoluteString ?? activeTab?.url?.absoluteString ?? ""
        canGoBack = wv.canGoBack
        canGoForward = wv.canGoForward
        webIsLoading = wv.isLoading
        activeTab?.isLoading = wv.isLoading
        updateBookmarkState()
    }

    private func updateBookmarkState() {
        guard let url = activeTab?.webView.url else {
            isCurrentBookmarked = false
            return
        }
        isCurrentBookmarked = bookmarks.contains { $0.urlString == url.absoluteString }
    }

    private func refreshAddressBar() {
        syncChrome()
    }

    // MARK: - Bookmarks

    func toggleBookmarkCurrent() {
        guard let wv = activeTab?.webView, let url = wv.url, url.scheme == "http" || url.scheme == "https" else { return }
        let urlString = url.absoluteString
        if let idx = bookmarks.firstIndex(where: { $0.urlString == urlString }) {
            bookmarks.remove(at: idx)
        } else {
            bookmarks.insert(BookmarkItem(title: wv.title ?? url.host ?? urlString, urlString: urlString), at: 0)
        }
        persistLibrary()
        updateBookmarkState()
    }

    func removeBookmark(_ item: BookmarkItem) {
        bookmarks.removeAll { $0.id == item.id }
        persistLibrary()
    }

    func openBookmark(_ item: BookmarkItem) {
        if let url = URL(string: item.urlString) {
            loadURL(url)
        }
    }

    func removeHistory(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        persistLibrary()
    }

    func clearHistory() {
        history.removeAll()
        persistLibrary()
    }

    func clearBookmarks() {
        bookmarks.removeAll()
        persistLibrary()
    }

    /// Append imported bookmarks (dedup is done by the caller). Persists.
    func appendBookmarks(_ items: [BookmarkItem]) {
        guard !items.isEmpty else { return }
        bookmarks.insert(contentsOf: items, at: 0)
        persistLibrary()
    }

    func clearLibrary() {
        clearHistory()
        bookmarks.removeAll()
        downloads.removeAll()
        persistLibrary()
    }

    // MARK: - Downloads

    func removeDownload(_ record: DownloadRecord) {
        try? FileManager.default.removeItem(at: record.fileURL)
        downloads.removeAll { $0.id == record.id }
        persistLibrary()
    }

    func clearDownloads() {
        for record in downloads {
            try? FileManager.default.removeItem(at: record.fileURL)
        }
        downloads.removeAll()
        persistLibrary()
    }

    // MARK: - Web data clearing

    private static let siteDataTypes: Set<String> = [
        WKWebsiteDataTypeCookies,
        WKWebsiteDataTypeLocalStorage,
        WKWebsiteDataTypeSessionStorage,
        WKWebsiteDataTypeIndexedDBDatabases,
        WKWebsiteDataTypeWebSQLDatabases,
        WKWebsiteDataTypeServiceWorkerRegistrations,
    ]

    /// Low-level clearing used by both the simple "clear all" action and the
    /// per-site data manager.
    private func removeData(ofTypes types: Set<String>, for records: [WKWebsiteDataRecord], completion: (() -> Void)? = nil) {
        WKWebsiteDataStore.default().removeData(ofTypes: types, for: records) {
            completion?()
        }
    }

    func clearCookies(completion: (() -> Void)? = nil) {
        let dataStore = WKWebsiteDataStore.default()
        dataStore.fetchDataRecords(ofTypes: Self.siteDataTypes) { records in
            dataStore.removeData(ofTypes: Self.siteDataTypes, for: records) {
                completion?()
            }
        }
    }

    func clearCache(completion: (() -> Void)? = nil) {
        let types: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeOfflineWebApplicationCache]
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) {
            completion?()
        }
    }

    // MARK: - Site data (cookies / local storage = signed-in accounts)

    /// Fetches the on-device per-website data records. Records represent the
    /// sites that have cookies / storage, which is what keeps you logged in.
    func fetchSiteData() async -> [WKWebsiteDataRecord] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().fetchDataRecords(ofTypes: Self.siteDataTypes) { records in
                continuation.resume(returning: records)
            }
        }
    }

    func removeSiteData(record: WKWebsiteDataRecord, completion: (() -> Void)? = nil) {
        removeData(ofTypes: Self.siteDataTypes, for: [record], completion: completion)
    }

    func removeAllSiteData(completion: (() -> Void)? = nil) {
        let dataStore = WKWebsiteDataStore.default()
        dataStore.fetchDataRecords(ofTypes: Self.siteDataTypes) { records in
            dataStore.removeData(ofTypes: Self.siteDataTypes, for: records) {
                completion?()
            }
        }
    }

    // MARK: - Library persistence

    private func loadLibrary() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Keys.history), let list = try? JSONDecoder().decode([PageVisit].self, from: data) {
            history = list
        }
        if let data = d.data(forKey: Keys.bookmarks), let list = try? JSONDecoder().decode([BookmarkItem].self, from: data) {
            bookmarks = list
        }
        if let data = d.data(forKey: Keys.downloads), let list = try? JSONDecoder().decode([DownloadRecord].self, from: data) {
            downloads = list
        }
    }

    private func persistLibrary() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(history) { d.set(data, forKey: Keys.history) }
        if let data = try? JSONEncoder().encode(bookmarks) { d.set(data, forKey: Keys.bookmarks) }
        if let data = try? JSONEncoder().encode(downloads) { d.set(data, forKey: Keys.downloads) }
    }

    private func recordVisit(title: String, url: URL) {
        let urlString = url.absoluteString
        if history.first?.urlString == urlString { return }
        history.insert(PageVisit(title: title, urlString: urlString), at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
        persistLibrary()
        // Durable browser history is recorded in webDidFinish via
        // HistoryStore.recordVisit (with session metadata).
    }

    private func restoreTabs() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Keys.sessionTabs),
           let saved = try? JSONDecoder().decode([StoredTabSession].self, from: data) {
            if saved.isEmpty {
                _ = newTab(url: nil, activate: true)
            } else {
                for (i, item) in saved.prefix(8).enumerated() {
                    let tab = newTab(url: item.url, activate: i == 0)
                    tab.title = item.title
                }
            }
        } else {
            // Legacy format: plain array of URL strings.
            let saved = d.stringArray(forKey: Keys.sessionTabs) ?? []
            let urls = saved.compactMap { URL(string: $0) }.prefix(8)
            if urls.isEmpty {
                _ = newTab(url: nil, activate: true)
            } else {
                for (i, url) in urls.enumerated() {
                    let tab = newTab(url: url, activate: i == 0)
                    tab.title = url.host ?? ""
                }
            }
        }
    }

    private func persistSessionTabs() {
        // Private tabs are not part of the restorable session.
        let items = tabs.filter { !$0.isPrivate }.prefix(8).map { tab in
            StoredTabSession(url: tab.webView.url ?? tab.url, title: tab.title.isEmpty ? (tab.webView.url?.host ?? "New Tab") : tab.title)
        }
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Keys.sessionTabs)
        }
    }

    // MARK: - Info helpers

    func appendInfo(_ text: String) {
        turns.append(ChatTurn(role: .assistant, kind: .info, text: text))
    }

    func clearChat() {
        turns.removeAll()
        apiHistory.removeAll()
        if !isAgentRunning { agentStatus = .idle }
    }

    // MARK: - Cursor helpers

    func showCursor(at point: CGPoint, label: String?) {
        cursor.visible = true
        cursor.position = point
        cursor.label = label
    }

    func hideCursor() {
        cursor.visible = false
        cursor.isPressing = false
        cursor.pulseID += 1
    }

    func pulseAt(_ point: CGPoint) {
        cursor.position = point
        cursor.visible = true
        cursor.isPressing = true
        cursor.pulseID += 1
    }

    /// Convert DOM (CSS pixel) coordinates into points inside the web area.
    /// WKWebView lays out in points, so CSS px already match the overlay.
    func point(forX x: Double, y: Double) -> CGPoint {
        CGPoint(x: x, y: y)
    }
}
