import Foundation

enum ToolRiskLevel {
    case safe
    case risky
}

enum AgentToolRegistry {

    struct ToolInfo {
        let name: String
        let description: String
        let risk: ToolRiskLevel
    }

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
        ToolInfo(name: "notify", description: "Show a local notification.", risk: .safe),
        ToolInfo(name: "capture_web_screenshot", description: "Capture the visible page as a JPEG (viewport only).", risk: .safe),
        ToolInfo(name: "runCode", description: "Execute a code snippet in the Code Lab sandbox (C or JavaScript).", risk: .safe),
        ToolInfo(name: "stopSelf", description: "Stop the current task.", risk: .safe)
    ]

    static func riskLevel(for kind: AutomationStepKind) -> ToolRiskLevel {
        switch kind {
        case .typeText:

            return .safe
        case .navigate, .search, .readPage, .scroll, .extractText, .wait, .askLLM, .notify:
            return .safe
        case .clickElement:
            return .safe
        }
    }

    static func actionDescription(for kind: AutomationStepKind) -> String {
        kind.label
    }
}
