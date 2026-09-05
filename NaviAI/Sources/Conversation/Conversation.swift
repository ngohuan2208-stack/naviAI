import Foundation

// MARK: - Conversation models

enum ConversationMessageRole: String, Codable {
    case user
    case assistant
}

enum ConversationMessageType: String, Codable {
    case text
    case image
    case file
    case action
    case info
    case toolResult
}

struct ConversationMessage: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var role: ConversationMessageRole
    var type: ConversationMessageType = .text
    var text: String
    var date: Date = Date()
    /// Optional fixed-role metadata (never secrets).
    var note: String = ""
}

struct Conversation: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var messages: [ConversationMessage] = []
    var tags: [String] = []
    var isArchived: Bool = false
    /// Associated tab URLs / task names — purely descriptive, safe.
    var associatedURLs: [String] = []
    var associatedTaskNames: [String] = []
    /// Compact memory summarised when the conversation gets long.
    var summary: String = ""

    var lastActivity: Date { messages.last?.date ?? updatedAt }

    var snippet: String {
        messages.last(where: { $0.type == .text || $0.type == .info })?.text ?? ""
    }

    /// Deterministic, cheap title from the first user message (no LLM needed).
    static func suggestedTitle(from text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = cleaned.split(whereSeparator: { $0 == "\n" || $0 == " " }).joined(separator: " ")
        guard !collapsed.isEmpty else { return "New conversation" }
        return collapsed.count > 48 ? String(collapsed.prefix(48)) + "…" : collapsed
    }
}

// MARK: - Continuation snapshot

/// Everything needed to resume a conversation later (used by the AI panel).
struct ConversationSnapshot: Codable, Equatable {
    var conversationID: UUID
    var apiHistory: [OutboundItem]
}