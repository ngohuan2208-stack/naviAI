import Foundation

// MARK: - Provider kind

enum AIProviderKind: String, CaseIterable, Codable, Identifiable, Hashable {
    case openAI = "openai"
    case deepseek
    case chatGPT = "chatgpt-compatible"
    case claude
    case gemini
    case openRouter = "openrouter"
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openAI: return "OpenAI"
        case .deepseek: return "DeepSeek"
        case .chatGPT: return "OpenAI-compatible API"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .openRouter: return "OpenRouter"
        case .custom: return "Custom API"
        }
    }

    var symbol: String {
        switch self {
        case .openAI: return "circle.hexagongrid.fill"
        case .deepseek: return "point.3.connected.trianglepath.dotted"
        case .chatGPT: return "network"
        case .claude: return "sparkles"
        case .gemini: return "sparkle"
        case .openRouter: return "arrow.triangle.branch"
        case .custom: return "slider.horizontal.3"
        }
    }

    var accent: String {
        switch self {
        case .openAI, .chatGPT: return "teal"
        case .deepseek: return "indigo"
        case .claude: return "orange"
        case .gemini: return "purple"
        case .openRouter: return "pink"
        case .custom: return "gray"
        }
    }

    var apiFormat: APIMessageFormat {
        switch self {
        case .claude: return .anthropic
        case .openAI, .deepseek, .chatGPT, .gemini, .openRouter: return .openAI
        case .custom: return .openAI
        }
    }

    var isOpenAICompatible: Bool { apiFormat == .openAI }

    var supportsModelListing: Bool {
        switch self {
        case .claude: return false
        default: return true
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openAI, .chatGPT: return "https://api.openai.com/v1"
        case .deepseek: return "https://api.deepseek.com"
        case .claude: return "https://api.anthropic.com"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .custom: return ""
        }
    }

    /// Suggested models. These are *suggestions only* - the user can edit them
    /// or fetch the live list from the provider. NaviAI never asserts that a
    /// model exists unless the provider's own API returned it.
    var defaultModelSuggestions: [String] {
        switch self {
        case .openAI: return ["gpt-4o", "gpt-4o-mini", "o3-mini"]
        case .deepseek: return ["deepseek-chat", "deepseek-reasoner"]
        case .chatGPT: return ["gpt-4o-mini"]
        case .claude: return ["claude-sonnet-4-5", "claude-3-7-sonnet-latest", "claude-3-5-haiku-latest"]
        case .gemini: return ["gemini-2.0-flash", "gemini-2.5-pro"]
        case .openRouter: return ["openrouter/auto"]
        case .custom: return []
        }
    }
}

enum APIMessageFormat: String, Codable {
    case openAI
    case anthropic

    var label: String {
        switch self {
        case .openAI: return "OpenAI chat-completions"
        case .anthropic: return "Anthropic Messages"
        }
    }
}

// MARK: - Provider config

struct ProviderConfig: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var kind: AIProviderKind
    var name: String
    var baseURL: String
    var apiFormat: APIMessageFormat
    var model: String
    var supportsVision: Bool

    init(kind: AIProviderKind, name: String? = nil, baseURL: String? = nil, model: String? = nil, apiFormat: APIMessageFormat? = nil, supportsVision: Bool = false) {
        self.kind = kind
        self.name = name ?? kind.label
        self.baseURL = (baseURL ?? kind.defaultBaseURL).trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiFormat = apiFormat ?? kind.apiFormat
        self.model = model ?? kind.defaultModelSuggestions.first ?? ""
        self.supportsVision = supportsVision
    }

    var apiKeyAccount: String { "apikey-" + id.uuidString }
    var isConfigured: Bool { !model.isEmpty && !baseURL.isEmpty }

    func displayTitle(fallback: String) -> String {
        isConfigured ? "\(name) · \(model.isEmpty ? fallback : model)" : name
    }
}
