import Foundation
import Combine

// MARK: - Tab group

struct TabGroup: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var tabIDs: [UUID] = []
    var isPinned: Bool = false
    var createdAt: Date = Date()
}

// MARK: - Tab group store

/// Lightweight, persistent storage for tab groups and pinning. Pure data —
/// the browser keeps its own `tabs` array; groups reference tab ids.
@MainActor
final class TabGroupStore: ObservableObject {

    static let shared = TabGroupStore()

    @Published private(set) var groups: [TabGroup] = []

    private let url: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Tabs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("groups.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        groups = (try? JSONDecoder().decode([TabGroup].self, from: data)) ?? []
    }

    private func save() {
        if let data = try? JSONEncoder().encode(groups) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func create(named: String, tabIDs: [UUID] = []) -> TabGroup {
        let group = TabGroup(name: named.isEmpty ? "Group" : named, tabIDs: tabIDs)
        groups.append(group)
        save()
        return group
    }

    func rename(_ id: UUID, to named: String) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[idx].name = named.isEmpty ? "Group" : named
        save()
    }

    func addTab(_ tabID: UUID, to groupID: UUID) {
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        guard !groups[idx].tabIDs.contains(tabID) else { return }
        groups[idx].tabIDs.append(tabID)
        save()
    }

    func removeTab(_ tabID: UUID, from groupID: UUID) {
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[idx].tabIDs.removeAll { $0 == tabID }
        save()
    }

    func delete(_ id: UUID) {
        groups.removeAll { $0.id == id }
        save()
    }
}

// MARK: - Closed-tab stack (reopen last closed tab)

@MainActor
enum ClosedTabStack {
    private static var stack: [(url: URL?, title: String)] = []

    static func push(url: URL?, title: String) {
        stack.append((url, title))
        if stack.count > 20 { stack.removeFirst(stack.count - 20) }
    }

    static func pop() -> (url: URL?, title: String)? {
        stack.popLast()
    }

    static func clear() {
        stack.removeAll()
    }
}

// MARK: - BrowserStore tab ops extension

extension BrowserStore {

    /// Reopen the most recently closed tab (works across the session).
    @discardableResult
    func reopenClosedTab() -> TabItem? {
        guard let closed = ClosedTabStack.pop() else { return nil }
        let tab = newTab(url: closed.url, activate: true)
        tab.title = closed.title
        return tab
    }

    /// Search across open tabs by title or URL.
    func searchTabs(_ query: String) -> [TabItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return tabs }
        return tabs.filter {
            $0.title.lowercased().contains(q)
                || ($0.webView.url?.absoluteString.lowercased().contains(q) ?? false)
                || ($0.url?.absoluteString.lowercased().contains(q) ?? false)
        }
    }

    /// Open a new tab in a given tab group (registers it in the group).
    func openTabInGroup(_ group: TabGroup, url: URL?) {
        let tab = newTab(url: url, activate: true)
        TabGroupStore.shared.addTab(tab.id, to: group.id)
    }
}