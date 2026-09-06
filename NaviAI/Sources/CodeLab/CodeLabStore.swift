import Foundation
import Combine
import JavaScriptCore

public enum CodeLanguage: String, Codable, CaseIterable, Identifiable {
    case javascript, python, swift, c

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .javascript: return "JavaScript"
        case .python: return "Python"
        case .swift: return "Swift"
        case .c: return "C"
        }
    }

    public var fileExtension: String {
        switch self {
        case .javascript: return "js"
        case .python: return "py"
        case .swift: return "swift"
        case .c: return "c"
        }
    }

    public var icon: String {
        switch self {
        case .javascript: return "curlybraces"
        case .python: return "snake.circle"
        case .swift: return "swift"
        case .c: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

public struct CodeSnippet: Identifiable, Codable, Equatable {
    public var id: UUID = UUID()
    public var title: String
    public var language: CodeLanguage
    public var code: String
    public var date: Date = Date()
    public var lastResult: CodeExecutionResult?

    public init(title: String, language: CodeLanguage, code: String) {
        self.title = title
        self.language = language
        self.code = code
    }
}

public struct CodeExecutionResult: Codable, Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int
    public var durationMs: Int
    public var steps: Int
    public var language: CodeLanguage
    public var date: Date = Date()

    public var isSuccess: Bool { exitCode == 0 && stderr.isEmpty }

    public var summary: String {
        if isSuccess { return "✓ \(durationMs)ms" }
        else { return "✗ exit \(exitCode)" }
    }
}

final class JavaScriptRunner {
    static let shared = JavaScriptRunner()
    private init() {}

    struct Result {
        let stdout: String
        let stderr: String
        let exitCode: Int
        let durationMs: Int
    }

    func run(_ code: String) -> Result {
        let start = Date()
        var output = ""
        var errors = ""
        let context = JSContext()!

        let log: @convention(block) (JSValue) -> Void = { value in
            output += value.toString() + "\n"
        }
        context.setObject(log, forKeyedSubscript: "consoleLog" as NSString)
        context.setObject(log, forKeyedSubscript: "consoleError" as NSString)

        context.evaluateScript("""
            var console = {
                log: function() { consoleLog(Array.from(arguments).join(' ')); },
                error: function() { consoleError(Array.from(arguments).join(' ')); },
                warn: function() { consoleLog(Array.from(arguments).join(' ')); }
            };
        """)

        context.exceptionHandler = { _, exc in
            if let msg = exc?.toString() { errors += msg + "\n" }
        }

        context.evaluateScript(code)

        let duration = Int(start.timeIntervalSinceNow * -1000)
        return Result(stdout: output, stderr: errors, exitCode: errors.isEmpty ? 0 : 1, durationMs: duration)
    }
}

@MainActor
final class CodeLabStore: ObservableObject {
    static let shared = CodeLabStore()

    @Published var currentLanguage: CodeLanguage = .c
    @Published var currentCode: String = ""
    @Published var isRunning: Bool = false
    @Published var lastResult: CodeExecutionResult?
    @Published private(set) var history: [CodeSnippet] = []
    @Published private(set) var savedSnippets: [CodeSnippet] = []

    private let historyKey = "codeLab.history.v1"
    private let snippetsKey = "codeLab.snippets.v1"
    private let maxHistory = 50

    private init() {
        load()
        if currentCode.isEmpty {
            currentCode = Self.defaultSnippet(for: .c)
        }
    }

    static func defaultSnippet(for language: CodeLanguage) -> String {
        switch language {
        case .c:
            return """
            #include <stdio.h>

            int main() {
                printf("Hello from NaviAI Code Lab!\\n");
                int n = 10, a = 0, b = 1;
                printf("First %d Fibonacci numbers:\\n", n);
                for (int i = 0; i < n; i++) {
                    printf("%d ", a);
                    int t = a + b; a = b; b = t;
                }
                printf("\\n");
                return 0;
            }
            """
        case .javascript:
            return """
            console.log("Hello from Code Lab!");
            const nums = [1, 2, 3, 4, 5];
            const doubled = nums.map(n => n * 2);
            console.log("Doubled:", doubled);
            console.log("Sum:", doubled.reduce((a, b) => a + b, 0));
            """
        case .python:
            return """
            print("Hello from Code Lab!")
            squares = [x**2 for x in range(10)]
            print("Squares:", squares)
            print("Sum:", sum(squares))
            """
        case .swift:
            return """
            print("Hello from Code Lab!")
            let numbers = Array(1...10)
            let squares = numbers.map { $0 * $0 }
            print("Squares: \\(squares)")
            print("Sum: \\(squares.reduce(0, +))")
            """
        }
    }

    func run(code: String, language: CodeLanguage) async -> CodeExecutionResult {
        isRunning = true
        defer { isRunning = false }

        let result: CodeExecutionResult
        let start = Date()

        switch language {
        case .c:
            let interp = CInterpreter()
            let r = interp.run(code)
            result = CodeExecutionResult(stdout: r.stdout, stderr: r.stderr, exitCode: r.exitCode, durationMs: r.durationMs, steps: r.steps, language: .c)
        case .javascript:
            let r = JavaScriptRunner.shared.run(code)
            result = CodeExecutionResult(stdout: r.stdout, stderr: r.stderr, exitCode: r.exitCode, durationMs: r.durationMs, steps: 0, language: .javascript)
        case .python, .swift:
            let duration = Int(start.timeIntervalSinceNow * -1000)
            result = CodeExecutionResult(stdout: "", stderr: "'\(language.displayName)' interpreter not embedded. Use C or JavaScript.", exitCode: 1, durationMs: duration, steps: 0, language: language)
        }

        lastResult = result
        addToHistory(code: code, language: language, result: result)
        return result
    }

    func runCurrent() async {
        _ = await run(code: currentCode, language: currentLanguage)
    }

    func changeLanguage(_ lang: CodeLanguage) {
        currentLanguage = lang
        currentCode = Self.defaultSnippet(for: lang)
        lastResult = nil
    }

    private func addToHistory(code: String, language: CodeLanguage, result: CodeExecutionResult) {
        var snippet = CodeSnippet(title: "Run \(Date().formatted(date: .omitted, time: .shortened))", language: language, code: code)
        snippet.lastResult = result
        history.insert(snippet, at: 0)
        if history.count > maxHistory { history = Array(history.prefix(maxHistory)) }
        save()
    }

    func clearHistory() { history.removeAll(); save() }
    func deleteHistory(at offsets: IndexSet) { history.remove(atOffsets: offsets); save() }

    func saveSnippet(title: String, code: String, language: CodeLanguage) {
        let snippet = CodeSnippet(title: title, language: language, code: code)
        savedSnippets.insert(snippet, at: 0)
        save()
    }

    func deleteSnippet(at offsets: IndexSet) { savedSnippets.remove(atOffsets: offsets); save() }

    func loadSnippet(_ snippet: CodeSnippet) {
        currentCode = snippet.code
        currentLanguage = snippet.language
        lastResult = nil
    }

    private func save() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(history) { UserDefaults.standard.set(data, forKey: historyKey) }
        if let data = try? encoder.encode(savedSnippets) { UserDefaults.standard.set(data, forKey: snippetsKey) }
    }

    private func load() {
        let decoder = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: historyKey), let items = try? decoder.decode([CodeSnippet].self, from: data) { history = items }
        if let data = UserDefaults.standard.data(forKey: snippetsKey), let items = try? decoder.decode([CodeSnippet].self, from: data) { savedSnippets = items }
    }
}
