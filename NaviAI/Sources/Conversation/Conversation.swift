import Foundation

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

    var associatedURLs: [String] = []
    var associatedTaskNames: [String] = []

    var summary: String = ""

    var lastActivity: Date { messages.last?.date ?? updatedAt }

    var snippet: String {
        messages.last(where: { $0.type == .text || $0.type == .info })?.text ?? ""
    }

    static func suggestedTitle(from text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let collapsed = cleaned.split(whereSeparator: { $0 == "\n" || $0 == " " }).joined(separator: " ")
        guard !collapsed.isEmpty else { return "New conversation" }
        return collapsed.count > 48 ? String(collapsed.prefix(48)) + "…" : collapsed
    }
}

struct ConversationSnapshot: Codable, Equatable {
    var conversationID: UUID
    var apiHistory: [OutboundItem]
}
