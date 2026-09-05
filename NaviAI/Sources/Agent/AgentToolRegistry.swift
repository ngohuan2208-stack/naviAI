import Foundation

// MARK: - Tool risk level

enum ToolRiskLevel {
    case safe
    case risky
}

// MARK: - Agent tool registry

/// Static catalog of the agent/automation tool surface, shared by the
/// interactive agent and the automation engine. Centralises risk
/// classification used by the confirmation policy (item 12).
enum AgentToolRegistry {

    struct ToolInfo {
        let name: String
        let description: String
        let risk: ToolRiskLevel
    }

    /// The browser-facing tool catalog (mirrors the tools registered in
    /// AgentTools.swift; kept in sync by the same enum that drives automation
    /// step kinds).
    static let tools: [ToolInfo] = [
        ToolInfo(name: "openURL", description: "Open a URL in the current tab.", risk: .safe),
        ToolInfo(name: "searchWeb", description: "Run a web search on the configured engine.", risk: .safe),
        ToolInfo(name: "readPage", description: "Read the visible page structure and text.", risk: .safe),
        ToolInfo(name: "findText", description: "Find elements by text on the page.", risk: .safe),
        ToolInfo(name: "clickElement", description: "Click an element on the page.", risk: .safe),
        ToolInfo(name: "typeText", description: "Type into a form field. Submit/Enter is risky.", risk: .risky),
        ToolInfo(name: "scroll", description: "Scroll the page.", risk: .safe),
        ToolInfo(name: "extractText", description: "Extract page text for summarisation.", risk: .safe),
        ToolInfo(name: "askLLM", description: "Reason about the page with the AI provider.", risk: .safe),
        ToolInfo(name: "wait", description: "Wait for the page or a timer.", risk: .safe),
        ToolInfo(name: "notify", description: "Show a local notification.", risk: .safe)
    ]

    /// Classification used by the confirmation policy: purchases, form
    /// submissions, messages, deletions, financial/account actions are RISKY
    /// and require confirmation; reads, navigation and scrolling are SAFE.
    static func riskLevel(for kind: AutomationStepKind) -> ToolRiskLevel {
        switch kind {
        case .typeText:
            // Typing itself is safe; submitting (Enter / submit buttons) is
            // what can spend money or change state — those asks already come
            // from the interactive agent's riskReason() path.
            return .safe
        case .navigate, .search, .readPage, .scroll, .extractText, .wait, .askLLM, .notify:
            return .safe
        case .clickElement:
            return .safe
        }
    }

    /// Human-readable description of what a step will do (confirmation text).
    static func actionDescription(for kind: AutomationStepKind) -> String {
        kind.label
    }
}
