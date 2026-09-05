import Foundation
import Combine

// MARK: - Private tab manager

/// Tracks private tabs. Real cookie / storage isolation is provided by the
/// WebKit layer (each private tab uses a non-persistent `WKWebsiteDataStore`),
/// so closing the session discards cookies and local storage. NaviAI never
/// claims absolute anonymity — it respects the limits of iOS / WebKit and the
/// websites being visited.
@MainActor
final class PrivateSessionManager: ObservableObject {

    static let shared = PrivateSessionManager()

    struct PrivateTabRecord: Identifiable, Equatable {
        let tabID: UUID
        var title: String
        var url: String
        var id: UUID { tabID }
    }

    @Published private(set) var tabs: [PrivateTabRecord] = []

    /// Whether new tabs should be private by default (session-level toggle).
    @Published var privateByDefault = false {
        didSet {
            UserDefaults.standard.set(privateByDefault, forKey: Self.key)
        }
    }

    private static let key = "private.byDefault"

    private init() {
        privateByDefault = UserDefaults.standard.bool(forKey: Self.key)
    }

    func isPrivate(_ tabID: UUID) -> Bool {
        tabs.contains { $0.tabID == tabID }
    }

    func register(tabID: UUID, title: String = "", url: String = "") {
        guard !isPrivate(tabID) else { return }
        tabs.append(PrivateTabRecord(tabID: tabID, title: title, url: url))
    }

    func update(tabID: UUID, title: String? = nil, url: String? = nil) {
        guard let idx = tabs.firstIndex(where: { $0.tabID == tabID }) else { return }
        if let title { tabs[idx].title = title }
        if let url { tabs[idx].url = url }
    }

    func unregister(tabID: UUID) {
        tabs.removeAll { $0.tabID == tabID }
    }

    /// Close all private tabs. Their non-persistent WebKit stores are
    /// deallocated with the tabs, discarding cookies/localStorage immediately.
    func clearAll(browser: BrowserStore) {
        let ids = tabs.map { $0.tabID }
        for id in ids {
            browser.closePrivateTab(id)
        }
        tabs.removeAll()
    }

    var isEmpty: Bool { tabs.isEmpty }
}