import Foundation
import Combine

// MARK: - Browser history entry

struct BrowserHistoryEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var url: String
    var title: String
    var visitedAt: Date
    /// Session / tab metadata (item 9) — small, anonymous, useful.
    var sessionID: UUID?
    var sessionName: String?

    var host: String {
        URL(string: url)?.host ?? url
    }
}

// MARK: - Browser history store

/// Persistent browser history with search, single delete, multi delete,
/// clear-all and clear-by-time-range. Saved as JSON in Application Support
/// (browsing history is not a credential; API keys stay in the Keychain).
@MainActor
final class HistoryStore: ObservableObject {

    static let shared = HistoryStore()

    @Published private(set) var entries: [BrowserHistoryEntry] = []

    private let url: URL
    private let maxEntries = 2000

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Storage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("browser-history.json")
        load()
    }

    // MARK: Load / save

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([BrowserHistoryEntry].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Recording (called from BrowserStore)

    func recordVisit(url: URL, title: String, sessionID: UUID?, sessionName: String?) {
        guard !url.absoluteString.isEmpty else { return }
        let scheme = url.scheme?.lowercased() ?? ""
        guard ["http", "https"].contains(scheme) else { return }
        // Coalesce a page reload / redirect storm for the exact same URL.
        if let last = entries.last, last.url == url.absoluteString,
           Date().timeIntervalSince(last.visitedAt) < 5 { return }
        entries.append(BrowserHistoryEntry(url: url.absoluteString,
                                           title: title.isEmpty ? url.host ?? url.absoluteString : title,
                                           visitedAt: Date(),
                                           sessionID: sessionID,
                                           sessionName: sessionName))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        save()
    }

    // MARK: Search

    func search(_ query: String) -> [BrowserHistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.url.localizedCaseInsensitiveContains(q) }
    }

    // MARK: Deletion

    func delete(entryID: UUID) {
        entries.removeAll { $0.id == entryID }
        save()
    }

    func delete(entryIDs: Set<UUID>) {
        guard !entryIDs.isEmpty else { return }
        entries.removeAll { entryIDs.contains($0.id) }
        save()
    }

    enum ClearRange: String, CaseIterable, Identifiable {
        case pastHour, today, yesterdayAndToday, week, everything
        var id: String { rawValue }
        var label: String {
            switch self {
            case .pastHour: return "Past hour"
            case .today: return "Today"
            case .yesterdayAndToday: return "Today and yesterday"
            case .week: return "Last 7 days"
            case .everything: return "All time"
            }
        }
        var cutoff: Date? {
            let cal = Calendar.current
            switch self {
            case .pastHour: return Date().addingTimeInterval(-3600)
            case .today: return cal.startOfDay(for: Date())
            case .yesterdayAndToday: return cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))
            case .week: return cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: Date()))
            case .everything: return nil
            }
        }
    }

    func clear(range: ClearRange) {
        guard let cutoff = range.cutoff else {
            entries.removeAll()
            save()
            return
        }
        entries.removeAll { $0.visitedAt >= cutoff }
        save()
    }

    func clearAll() {
        entries.removeAll()
        save()
    }
}
