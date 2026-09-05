import Foundation
import Combine
import WebKit

// MARK: - Tab

@MainActor
final class TabItem: ObservableObject, Identifiable {
    let id: UUID
    let coordinator: WebCoordinator
    @Published var title: String = ""
    @Published var url: URL?
    @Published var isLoading: Bool = false

    init(desktopMode: Bool) {
        self.id = UUID()
        self.coordinator = WebCoordinator(tabID: id, desktopMode: desktopMode)
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
    func newTab(url: URL?, activate: Bool = true) -> TabItem {
        let tab = TabItem(desktopMode: settings.desktopModeEnabled)
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
            recordVisit(title: tab.title.isEmpty ? url.absoluteString : tab.title, url: url)
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

    func clearCookies(completion: (() -> Void)? = nil) {
        let dataStore = WKWebsiteDataStore.default()
        let types: Set<String> = [WKWebsiteDataTypeCookies, WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage, WKWebsiteDataTypeIndexedDBDatabases, WKWebsiteDataTypeWebSQLDatabases]
        dataStore.fetchDataRecords(ofTypes: types) { records in
            dataStore.removeData(ofTypes: types, for: records) {
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
    }

    private func restoreTabs() {
        let d = UserDefaults.standard
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

    private func persistSessionTabs() {
        let urls = tabs.compactMap { $0.webView.url?.absoluteString }
        UserDefaults.standard.set(Array(urls.prefix(8)), forKey: Keys.sessionTabs)
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
