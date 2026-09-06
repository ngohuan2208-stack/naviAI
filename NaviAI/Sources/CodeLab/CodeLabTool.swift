import Foundation

struct CodeLabTool {
    static let name = "runCode"
    static let description = "Execute a code snippet in the NaviAI Code Lab sandbox. Supports 'c' (via embedded interpreter) and 'javascript' (via JavaScriptCore). Use this when the user asks to run, test, or demonstrate code, or when an algorithm/performance explanation benefits from actual execution."

    struct Args: Codable {
        var language: String
        var code: String
    }

    static func call(_ rawArgs: [String: Any]) async -> (String, String) {
        guard let langStr = rawArgs["language"] as? String,
              let code = rawArgs["code"] as? String else {
            return ("error", "Missing 'language' or 'code' argument")
        }

        let lang: CodeLanguage
        switch langStr.lowercased() {
        case "c": lang = .c
        case "javascript", "js": lang = .javascript
        case "python", "py": lang = .python
        case "swift": lang = .swift
        default:
            return ("error", "Unsupported language: \(langStr). Use 'c' or 'javascript'.")
        }

        let store = CodeLabStore.shared
        let result = await store.run(code: code, language: lang)

        var parts: [String] = []
        parts.append("Language: \(lang.displayName)")
        parts.append("Exit code: \(result.exitCode)")
        parts.append("Duration: \(result.durationMs)ms")
        if !result.stdout.isEmpty {
            parts.append("--- stdout ---\n\(result.stdout)")
        }
        if !result.stderr.isEmpty {
            parts.append("--- stderr ---\n\(result.stderr)")
        }
        if result.stdout.isEmpty && result.stderr.isEmpty {
            parts.append("(no output)")
        }

        return ("codeLab.result", parts.joined(separator: "\n"))
    }
}
