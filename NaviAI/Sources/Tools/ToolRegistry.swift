import Foundation

// MARK: - Tool definition

/// A validated, permission-aware description of an executable tool.
struct ToolDefinition {
    let name: String
    let permission: ToolPermission
    let description: String
    let required: [String]
}

// MARK: - Tool registry

/// Unified catalog of every tool the model / agent / automation may call.
/// The model never calls a tool directly — every call goes through here so it
/// is (a) known, (b) schema-validated and (c) routed to the caller for a
/// permission check before execution.
@MainActor
final class ToolRegistry {

    static let shared = ToolRegistry()

    private(set) var definitions: [String: ToolDefinition] = [:]

    private init() {
        registerDefaults()
    }

    /// Register (or override) a tool definition.
    func register(_ definition: ToolDefinition) {
        definitions[definition.name] = definition
    }

    func definition(for name: String) -> ToolDefinition? {
        definitions[name]
    }

    var allNames: [String] { Array(definitions.keys).sorted() }

    /// Validate a tool call: known name + all required arguments present.
    func validate(name: String, argumentsJSON: String) -> Result<ToolDefinition, String> {
        guard let def = definitions[name] else {
            return .failure("Unknown tool: \(name)")
        }
        if def.required.isEmpty { return .success(def) }
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure("Invalid arguments for \(name)")
        }
        for key in def.required where obj[key] == nil {
            return .failure("Missing required argument '\(key)' for \(name)")
        }
        return .success(def)
    }

    /// Validate + authorize in one step (the funnel the browser uses).
    /// Returns the definition when allowed; throws a user-safe message otherwise.
    func authorize(name: String, argumentsJSON: String, via permissions: PermissionSystem) async throws -> ToolDefinition {
        let def = try validate(name: name, argumentsJSON: argumentsJSON).get()
        let allowed = await permissions.authorize(def.permission, detail: def.description)
        guard allowed else {
            throw ToolRegistryError.denied(def.permission)
        }
        return def
    }

    private func registerDefaults() {
        let steps: [ToolDefinition] = [
            .init(name: "openURL", permission: .navigate, description: "Open a URL in the current tab and wait for it to load.", required: ["url"]),
            .init(name: "searchWeb", permission: .search, description: "Search the web with the configured engine.", required: ["query"]),
            .init(name: "readPage", permission: .readWeb, description: "Read the current page: structure, text and interactive elements.", required: []),
            .init(name: "findText", permission: .readWeb, description: "Find interactive elements whose text contains a phrase.", required: ["text"]),
            .init(name: "clickElement", permission: .click, description: "Click an element identified by elementId.", required: ["elementId"]),
            .init(name: "typeText", permission: .type, description: "Type into an element identified by elementId.", required: ["elementId"]),
            .init(name: "scroll", permission: .scroll, description: "Scroll the page in a direction.", required: []),
            .init(name: "goBack", permission: .navigate, description: "Go back one page.", required: []),
            .init(name: "goForward", permission: .navigate, description: "Go forward one page.", required: []),
            .init(name: "reload", permission: .navigate, description: "Reload the current page.", required: []),
            .init(name: "openTab", permission: .tabManage, description: "Open a new tab.", required: []),
            .init(name: "switchTab", permission: .tabManage, description: "Switch to a tab by index.", required: ["index"]),
            .init(name: "closeTab", permission: .tabManage, description: "Close the active tab.", required: []),
            .init(name: "extractText", permission: .extract, description: "Extract the visible text of the page.", required: []),
            .init(name: "screenshot", permission: .screenshot, description: "Capture a screenshot of the current page.", required: []),
            .init(name: "generateImage", permission: .imageGenerate, description: "Generate an image from a text prompt.", required: ["prompt"]),
            .init(name: "wait", permission: .wait, description: "Pause briefly.", required: []),
            .init(name: "notify", permission: .historyAccess, description: "Post a local notification.", required: [])
        ]
        for step in steps { definitions[step.name] = step }
    }
}

enum ToolRegistryError: Error, LocalizedError {
    case denied(ToolPermission)

    var errorDescription: String? {
        switch self {
        case .denied(let permission):
            return "Denied: \(permission.label) was not allowed."
        }
    }
}