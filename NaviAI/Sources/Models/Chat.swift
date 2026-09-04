import Foundation

// MARK: - Display transcript

enum ChatRole: String, Codable {
    case user
    case assistant
}

enum TurnKind: String, Codable {
    case text        // normal message (user or assistant final answer)
    case action      // assistant describing an agent action (rendered compact)
    case info        // system info / errors
    case toolResult  // internal, compact display
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

// MARK: - Wire-level messages (what is actually sent to the model)

/// The outbound history used by the agent loop. Encode is handled per-format
/// inside LLMService.
enum OutboundItem: Equatable {
    case system(String)
    case userText(String)
    /// user message containing an inline screenshot (vision)
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

/// Result returned from a single model call.
struct ProviderReply: Equatable {
    var text: String?
    var toolCalls: [ToolCallRequest]
    var finishReason: String?
}

// MARK: - Tool schema (OpenAI-style function schema; converted for Anthropic)

struct AgentToolSpec {
    var name: String
    var description: String
    var parameters: [String: Any]   // JSON-Schema object

    func asDictionary() -> [String: Any] {
        [
            "name": name,
            "description": description,
            "parameters": parameters
        ]
    }
}

// MARK: - Errors

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

    /// User-facing friendly message used in the UI.
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
