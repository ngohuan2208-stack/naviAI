import Foundation
import Combine

// MARK: - Agent activity entry

/// One timestamped line of what the agent did, e.g.
/// "12:30:02 — Opened search page". Persisted (bounded) so the activity
/// screen and per-run timelines survive relaunches.
struct AgentActivityEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var date: Date
    var message: String

    var timeLabel: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}

// MARK: - Agent activity log

/// Global, append-mostly log. IMPORTANT: never log API keys, provider
/// configuration or other sensitive credentials — callers only pass human
/// readable action descriptions, and the store strips anything that smells
/// like a credential as a belt-and-braces measure.
@MainActor
final class AgentActivityLog: ObservableObject {

    static let shared = AgentActivityLog()

    @Published private(set) var entries: [AgentActivityEntry] = []

    private let persist = AutomationPersistence.shared
    private let maxEntries = 800
    private let maxAge: TimeInterval = 7 * 86_400

    private init() {
        entries = persist.loadActivity().pruned(maxAge: maxAge)
    }

    func add(_ message: String) {
        var clean = message
        // Defense in depth: never persist credentials.
        for banned in ["sk-", "Bearer ", "x-api-key", "apiKey", "api_key", "password"] {
            if clean.localizedCaseInsensitiveContains(banned) {
                clean = "(credential redacted)"
                break
            }
        }
        if clean.count > 300 { clean = String(clean.prefix(300)) + "…" }
        entries.append(AgentActivityEntry(date: Date(), message: clean))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        persist.saveActivity(entries.suffix(200).map { $0 })
    }

    func entriesBetween(_ start: Date, _ end: Date) -> [AgentActivityEntry] {
        entries.filter { $0.date >= start && $0.date <= end }
    }

    func clear() {
        entries.removeAll()
        persist.saveActivity([])
    }
}

private extension Array where Element == AgentActivityEntry {
    func pruned(maxAge: TimeInterval) -> [AgentActivityEntry] {
        let cutoff = Date().addingTimeInterval(-maxAge)
        return filter { $0.date >= cutoff }
    }
}
