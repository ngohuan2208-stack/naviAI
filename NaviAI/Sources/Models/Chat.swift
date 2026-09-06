import Foundation

enum ChatRole: String, Codable {
    case user
    case assistant
}

enum TurnKind: String, Codable {
    case text
    case action
    case info
    case toolResult
}

struct ChatTurn: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var role: ChatRole
    var kind: TurnKind = .text
    var text: String
    var date: Date = Date()

    init(role: ChatRole, kind: TurnKind = .text, text: String) {
        self.role = role
        self.kind = kind
        self.text = text
    }
}

enum OutboundItem: Equatable {
    case system(String)
    case userText(String)

    case userVision(text: String, imageBase64: String, mimeType: String)
    case assistantText(String)
    case assistantToolCall(id: String, name: String, argumentsJSON: String)
    case toolResult(toolCallID: String, content: String)
}

struct ToolCallRequest: Equatable {
    var id: String
    var name: String
    var argumentsJSON: String
}

struct ProviderReply: Equatable {
    var text: String?
    var toolCalls: [ToolCallRequest]
    var finishReason: String?
}

struct AgentToolSpec {
    var name: String
    var description: String
    var parameters: [String: Any]

    func asDictionary() -> [String: Any] {
        [
            "name": name,
            "description": description,
            "parameters": parameters
        ]
    }
}

enum AIError: LocalizedError {
    case noActiveProvider
    case missingAPIKey
    case invalidBaseURL
    case invalidAPIKey
    case modelUnavailable
    case providerError(String)
    case network(Error)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noActiveProvider: return "No AI provider selected. Choose one in Settings."
        case .missingAPIKey: return "No API key configured for this provider."
        case .invalidBaseURL: return "Invalid API base URL."
        case .invalidAPIKey: return "Invalid API key."
        case .modelUnavailable: return "Model unavailable."
        case .providerError(let m): return m
        case .network(let e): return "Network error: \(e.localizedDescription)"
        case .cancelled: return "Cancelled"
        }
    }

    var friendlyMessage: String {
        switch self {
        case .invalidAPIKey: return "Invalid API key."
        case .modelUnavailable: return "Model unavailable."
        case .noActiveProvider: return "No AI provider selected."
        case .missingAPIKey: return "Please add an API key for this provider."
        case .network: return "Network error. Check your connection."
        case .providerError: return "AI provider error."
        default: return errorDescription ?? "AI provider error."
        }
    }
}

extension AIError: Equatable {
    static func == (lhs: AIError, rhs: AIError) -> Bool {
        lhs.localizedDescription == rhs.localizedDescription
    }
}
