import Foundation
import Combine

struct AgentMessage: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var role: AgentRole
    var content: String
    var date: Date = Date()

    enum AgentRole: String, Codable {
        case user, assistant, tool, system
    }
}

struct AgentTool {
    let name: String
    let permission: ToolPermission
    let description: String

    let maxResultChars: Int

    var needsHostPrivileges: Bool {
        permission == .writeFile || name == "run_command" || name == "edit_file"
    }
}

struct AgentTask: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var prompt: String
    var status: AgentTaskStatus = .idle
    var messages: [AgentMessage] = []
    var result: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    enum AgentTaskStatus: String, Codable {
        case idle, running, completed, failed, cancelled
    }
}

protocol AgentProviding {
    var id: String { get }
    var label: String { get }

    var tools: [AgentTool] { get }

    var isRemote: Bool { get }

    func send(_ message: AgentMessage, in session: inout AgentSession) async throws -> AgentMessage
    func cancel()
}

struct AgentSession {
    var id: UUID = UUID()
    var providerID: String
    var transcript: [AgentMessage] = []
    var created: Date = Date()
}

@MainActor
final class RemoteAgentProvider: AgentProviding {

    let id: String
    let label: String
    var endpoint: String
    var model: String
    var apiKeyAccount: String

    var isRemote: Bool { true }

    let tools: [AgentTool] = [
        AgentTool(name: "read_web", permission: .readWeb, description: "Read a web page", maxResultChars: 8000),
        AgentTool(name: "search_web", permission: .search, description: "Search the web", maxResultChars: 4000),
        AgentTool(name: "read_file", permission: .readFile, description: "Read a file (sandboxed scope)", maxResultChars: 12000),
        AgentTool(name: "write_file", permission: .writeFile, description: "Write a file (sandboxed; requires grant)", maxResultChars: 2000),
        AgentTool(name: "run_command", permission: .agent, description: "Run a shell command (sandboxed; requires grant)", maxResultChars: 8000),
        AgentTool(name: "edit_file", permission: .writeFile, description: "Edit a file (sandboxed; requires grant)", maxResultChars: 2000),
        AgentTool(name: "notify", permission: .historyAccess, description: "Post a notification", maxResultChars: 200)
    ]

    private let llm = LLMService()
    private var sessionTask: Task<Void, Never>?

    init(id: String, label: String, endpoint: String, model: String, apiKeyAccount: String) {
        self.id = id
        self.label = label
        self.endpoint = endpoint
        self.model = model
        self.apiKeyAccount = apiKeyAccount
    }

    func send(_ message: AgentMessage, in session: inout AgentSession) async throws -> AgentMessage {
        try Task.checkCancellation()
        session.transcript.append(message)
        guard let config = Self.config(endpoint: endpoint, model: model) else {
            throw AgentProviderError.notConfigured
        }
        guard let key = KeychainService.read(account: apiKeyAccount) else {
            throw AgentProviderError.noAPIKey
        }
        let history = session.transcript.map { (m: AgentMessage) -> OutboundItem in
            switch m.role {
            case .user: return .userText(m.content)
            case .assistant: return .assistantText(m.content)
            case .system: return .system(m.content)
            case .tool: return .system("(tool) \(m.content)")
            }
        }
        let reply = try await llm.complete(config: config, apiKey: key, history: history, tools: [])
        let replyMessage = AgentMessage(role: .assistant, content: reply.text ?? "", date: Date())
        session.transcript.append(replyMessage)
        return replyMessage
    }

    func cancel() {
        sessionTask?.cancel()
    }

    private static func config(endpoint: String, model: String) -> ProviderConfig? {
        var c = ProviderConfig(kind: .custom, name: "Agent", baseURL: endpoint, model: model)
        c.apiFormat = .openAI
        return c.isConfigured ? c : nil
    }
}

@MainActor
final class AgentProviderManager: ObservableObject {

    static let shared = AgentProviderManager()

    struct AgentProviderConfig: Codable, Identifiable, Equatable {
        var id = UUID()
        var kind: String
        var name: String
        var endpoint: String
        var model: String

        var apiKeyAccount: String { "agent-" + id.uuidString }
        var isConfigured: Bool { !endpoint.isEmpty && !model.isEmpty }
    }

    @Published private(set) var providers: [AgentProviderConfig] = []
    @Published var activeProviderID: UUID?

    private let defaults = UserDefaults.standard

    private init() {
        let key = "agents.providers.v1"
        if let data = defaults.data(forKey: key),
           let list = try? JSONDecoder().decode([AgentProviderConfig].self, from: data) {
            providers = list
            activeProviderID = list.first?.id
        }
    }

    var activeProvider: AgentProviderConfig? {
        providers.first { $0.id == activeProviderID }
    }

    func add(name: String, endpoint: String, model: String, apiKey: String) {
        var cfg = AgentProviderConfig(kind: "default",
                                      name: name.isEmpty ? "Remote Agent" : name,
                                      endpoint: endpoint,
                                      model: model)
        providers.append(cfg)
        do {
            try KeychainService.save(key: apiKey, account: cfg.apiKeyAccount)
        } catch {
            NSLog("Keychain save failed: \(error.localizedDescription)")
        }
        activeProviderID = cfg.id
        persist()
    }

    func remove(_ cfg: AgentProviderConfig) {
        providers.removeAll { $0.id == cfg.id }
        KeychainService.delete(account: cfg.apiKeyAccount)
        if activeProviderID == cfg.id { activeProviderID = providers.first?.id }
        persist()
    }

    func setAPIKey(_ key: String, for cfg: AgentProviderConfig) {
        do {
            try KeychainService.save(key: key, account: cfg.apiKeyAccount)
        } catch {
            NSLog("Keychain save failed: \(error.localizedDescription)")
        }
    }

    func hasKey(for cfg: AgentProviderConfig) -> Bool {
        KeychainService.read(account: cfg.apiKeyAccount)?.isEmpty == false
    }

    func makeProvider(from config: AgentProviderConfig) -> AgentProviding {
        RemoteAgentProvider(id: config.id.uuidString,
                            label: config.name,
                            endpoint: config.endpoint,
                            model: config.model,
                            apiKeyAccount: config.apiKeyAccount)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(providers) {
            defaults.set(data, forKey: "agents.providers.v1")
        }
    }

    func sandboxAllows(_ tool: AgentTool, via permissions: PermissionSystem) async -> Bool {
        guard tool.needsHostPrivileges else { return true }
        return await permissions.authorize(tool.permission, detail: "Sandboxed " + tool.name)
    }
}

enum AgentProviderError: LocalizedError {
    case notConfigured
    case noAPIKey

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Agent endpoint not configured."
        case .noAPIKey: return "No API key for this agent integration."
        }
    }
}
