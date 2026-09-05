import Foundation
import Combine

// MARK: - Memory tiers

/// The four tiers of the memory system. Higher tiers are longer-lived and
/// user-managed; short-term context is derived and never persisted by itself.
enum MemoryTier: String, Codable, CaseIterable, Identifiable {
    case shortTerm      // ephemeral per-session cache (not persisted)
    case session        // this app session
    case conversation   // per-conversation memory / summary
    case longTerm       // user-visible durable preferences & recall

    var id: String { rawValue }

    var label: String {
        switch self {
        case .shortTerm: return "Short-term"
        case .session: return "Session"
        case .conversation: return "Conversation"
        case .longTerm: return "Long-term"
        }
    }
}

// MARK: - Memory item

struct MemoryItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var tier: MemoryTier
    var key: String
    var value: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var isPrivate: Bool = false
}

// MARK: - Memory manager

/// Central manager for all memory tiers. Private-session material is marked
/// `isPrivate` and skipped when building long-term context by default.
@MainActor
final class MemoryManager: ObservableObject {

    static let shared = MemoryManager()

    @Published private(set) var longTerm: [MemoryItem] = []
    @Published private(set) var session: [MemoryItem] = []
    /// In-memory short-term key/value (never persisted, per page/tab).
    private var shortTerm: [MemoryItem] = []
    /// Per-conversation summaries keyed by conversation id.
    private var conversationSummaries: [UUID: String] = [:]

    private let url: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Memory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("memory.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let items = (try? decoder.decode([MemoryItem].self, from: data)) ?? []
        longTerm = items.filter { $0.tier == .longTerm }
        session = items.filter { $0.tier == .session }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let all = longTerm + session
        if let data = try? encoder.encode(all) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Write

    func remember(_ value: String, key: String, tier: MemoryTier, isPrivate: Bool = false) {
        let item = MemoryItem(tier: tier, key: key, value: value, isPrivate: isPrivate)
        switch tier {
        case .shortTerm:
            shortTerm.removeAll { $0.key == key && $0.tier == .shortTerm }
            shortTerm.append(item)
        case .session:
            session.removeAll { $0.key == key }
            session.append(item)
            save()
        case .conversation:
            break // handled via conversationSummaries below
        case .longTerm:
            longTerm.removeAll { $0.key == key }
            longTerm.append(item)
            save()
        }
    }

    /// Conversation-scoped memory: a compressed summary of a conversation.
    func rememberConversation(_ summary: String, for id: UUID) {
        conversationSummaries[id] = String(summary.prefix(4000))
    }

    // MARK: Read

    func read(key: String, tier: MemoryTier) -> String? {
        switch tier {
        case .shortTerm: return shortTerm.first { $0.key == key }?.value
        case .session: return session.first { $0.key == key }?.value
        case .conversation: return nil
        case .longTerm: return longTerm.first { $0.key == key }?.value
        }
    }

    func conversationSummary(for id: UUID) -> String? {
        conversationSummaries[id]
    }

    /// All durable memory, excluding private items (unless includePrivate).
    func all(itemsFor tier: MemoryTier? = nil, includePrivate: Bool = false) -> [MemoryItem] {
        var source: [MemoryItem]
        switch tier {
        case .shortTerm: source = shortTerm
        case .session: source = session
        case .longTerm: source = longTerm
        case .conversation: return []
        case nil: source = shortTerm + session + longTerm
        }
        return includePrivate ? source : source.filter { !$0.isPrivate }
    }

    /// Build the context block handed to the model from long-term + session
    /// memory (compact, leak-safe).
    func memoryContext(includePrivate: Bool = false) -> String {
        let parts = all(itemsFor: .longTerm, includePrivate: includePrivate)
            + all(itemsFor: .session, includePrivate: includePrivate)
        guard !parts.isEmpty else { return "" }
        let lines = parts.map { "\($0.key): \($0.value)" }
        return "[Memory]\n" + lines.joined(separator: "\n")
    }

    // MARK: Delete / clear

    func forget(key: String, tier: MemoryTier) {
        switch tier {
        case .shortTerm: shortTerm.removeAll { $0.key == key }
        case .session: session.removeAll { $0.key == key }
        case .conversation: break
        case .longTerm: longTerm.removeAll { $0.key == key }
        }
        save()
    }

    func clear(tier: MemoryTier) {
        switch tier {
        case .shortTerm: shortTerm.removeAll()
        case .session: session.removeAll()
        case .conversation: conversationSummaries.removeAll()
        case .longTerm: longTerm.removeAll()
        }
        save()
    }
}