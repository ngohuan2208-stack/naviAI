import Foundation
import Combine

// MARK: - Conversation store

/// Persistent store for user conversations (the AI chat history). Persists to
/// iOS Application Support as JSON — never API keys, providers or secrets.
@MainActor
final class ConversationStore: ObservableObject {

    static let shared = ConversationStore()

    @Published private(set) var conversations: [Conversation] = []
    /// The conversation the AI panel is currently attached to.
    @Published var activeConversationID: UUID?

    /// Inject an LLM-backed summarizer for long conversations; until then a
    /// safe heuristic fallback compresses the context (offline, no secrets).
    var summarizer: (@MainActor (String) async -> String)? = nil

    private let url: URL
    private let summaryThreshold = 40   // messages

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Conversations", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("conversations.json")
        load()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        conversations = (try? decoder.decode([Conversation].self, from: data)) ?? []
        activeConversationID = conversations.first(where: { !$0.isArchived })?.id
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(conversations) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: CRUD

    var activeConversation: Conversation? {
        conversations.first { $0.id == activeConversationID }
    }

    @discardableResult
    func newConversation(title: String? = nil, copyMessagesFrom existing: Conversation? = nil) -> Conversation {
        var convo = Conversation(title: title ?? "New conversation", createdAt: Date(), updatedAt: Date())
        if let existing, let source = conversations.first(where: { $0.id == existing.id }) {
            convo.messages = source.messages
            convo.title = title ?? source.title
            convo.associatedURLs = source.associatedURLs
            convo.associatedTaskNames = source.associatedTaskNames
        }
        conversations.insert(convo, at: 0)
        activeConversationID = convo.id
        save()
        return convo
    }

    func rename(_ id: UUID, to title: String) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].title = title.isEmpty ? "Conversation" : title
        conversations[idx].updatedAt = Date()
        save()
    }

    func archive(_ id: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].isArchived = true
        if activeConversationID == id { activeConversationID = conversations.first(where: { !$0.isArchived })?.id }
        save()
    }

    @discardableResult
    func unarchive(_ id: UUID) -> Bool {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return false }
        conversations[idx].isArchived = false
        save()
        return true
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if activeConversationID == id { activeConversationID = conversations.first?.id }
        save()
    }

    func deleteAll() {
        conversations.removeAll()
        activeConversationID = nil
        save()
    }
// MARK: Messages

    func append(_ message: ConversationMessage, to id: UUID) {
        // Never persist anything that smells like a credential.
        var m = message
        m.text = Self.redact(message.text)
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].messages.append(m)
        conversations[idx].updatedAt = Date()
        if conversations[idx].title == "New conversation", m.role == .user {
            conversations[idx].title = Conversation.suggestedTitle(from: m.text)
        }
        maybeSummarize(id)
        save()
    }

    func clearMessages(_ id: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].messages.removeAll()
        conversations[idx].updatedAt = Date()
        save()
    }

    // MARK: Search / listing

    func search(_ query: String) -> [Conversation] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return conversations }
        return conversations.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.messages.contains { $0.text.localizedCaseInsensitiveContains(q) }
        }
    }

    /// Conversation history suitable for long-term context handoff.
    func transcript(for id: UUID) -> String {
        guard let convo = conversations.first(where: { $0.id == id }) else { return "" }
        var blocks: [String] = []
        if !convo.summary.isEmpty { blocks.append("[Summary of earlier turns] \(convo.summary)") }
        for msg in convo.messages {
            switch msg.role {
            case .user: blocks.append("User: \(msg.text)")
            case .assistant: blocks.append("Assistant: \(msg.text)")
            }
        }
        let joined = blocks.joined(separator: "\n")
        return joined.count > 12000 ? String(joined.prefix(12000)) + "…" : joined
    }

    /// Copy transcript lines for the AI panel (bounded, compressed).
    func chatHistory(for id: UUID, maxMessages: Int = 30) -> [ConversationMessage] {
        guard let convo = conversations.first(where: { $0.id == id }) else { return [] }
        return Array(convo.messages.suffix(maxMessages))
    }

    // MARK: Summarization

    func setSummary(_ text: String, for id: UUID) {
        guard let idx = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[idx].summary = String(text.prefix(4000))
        save()
    }

    private func maybeSummarize(_ id: UUID) {
        guard let convo = conversations.first(where: { $0.id == id }) else { return }
        let dropped = convo.messages.count - summaryThreshold
        guard dropped >= 10 else { return }
        let tail = Array(convo.messages.prefix(dropped))
        let text = tail.map { "\($0.role == .user ? "U" : "A"): \($0.text)" }.joined(separator: "\n")
        if let summarizer {
            Task {
                let result = await summarizer(text)
                setSummary(result, for: id)
            }
        } else {
            // Offline heuristic fallback: oldest intents + last assistant answer.
            let intents = tail.filter { $0.role == .user }.prefix(8).map { $0.text }
            let lastAnswer = tail.last(where: { $0.role == .assistant })?.text
            var parts = intents
            if let lastAnswer { parts.append("… \(lastAnswer)") }
            setSummary(String("[Earlier] " + parts.joined(separator: " • ").prefix(2000)), for: id)
        }
    }

    private static func redact(_ text: String) -> String {
        for banned in ["sk-", "Bearer ", "x-api-key", "apiKey", "api_key"] {
            if text.localizedCaseInsensitiveContains(banned) {
                return "(credential redacted)"
            }
        }
        return text
    }
}