import Foundation
import Combine
import WebKit

// MARK: - DevTools data types

/// One console line from the page or from NaviAI's own JS bridge.
struct DevConsoleEntry: Identifiable, Equatable {
    enum Level: String, Codable, CaseIterable {
        case log, info, warn, error, debug

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .log: return "text.bubble"
            case .info: return "info.circle"
            case .warn: return "exclamationmark.triangle"
            case .error: return "xmark.octagon"
            case .debug: return "ladybug"
            }
        }
    }

    var id: UUID = UUID()
    var level: Level = .log
    var message: String        // already redacted
    var sourceURL: String?
    var line: Int?
    var date: Date = Date()
}

/// One network request captured by the page hook. Secrets redacted BEFORE storing.
struct DevNetworkEntry: Identifiable, Equatable {
    var id: UUID = UUID()
    var method: String
    var url: String            // redacted
    var status: Int?
    var mimeType: String?
    var durationMS: Int?
    var sizeBytes: Int?
    var error: String?
    var date: Date = Date()

    var statusLabel: String {
        if let e = error { return "ERR" }
        return status.map(String.init) ?? "…"
    }
}

/// One localStorage/sessionStorage key-value pair (redacted).
struct DevStorageEntry: Identifiable, Equatable {
    enum Area: String { case local, session }
    var id: String { area.rawValue + "://" + key }
    var area: Area
    var key: String
    var value: String           // redacted, truncated
}

/// Flattened DOM node description for the inspector list.
struct DevDOMSummary: Equatable {
    var tag: String
    var idAttribute: String?
    var classes: String?
    var textPreview: String?
    var childCount: Int
    var depth: Int

    var label: String {
        var s = tag
        if let idAttribute { s += "#\(idAttribute)" }
        if let classes, !classes.isEmpty {
            s += "." + classes.split(separator: " ").joined(separator: ".")
        }
        return s
    }
}

// MARK: - DevTools store

/// Central DevTools state. All page data passes through `Redactor` BEFORE it
/// is stored, so nothing sensitive can leak into history/screenshots/exports.
/// Capture is pull-based: the DevTools panel refreshes from the active page.
@MainActor
final class DevToolsStore: ObservableObject {
    static let shared = DevToolsStore()

    @Published private(set) var console: [DevConsoleEntry] = []
    @Published private(set) var network: [DevNetworkEntry] = []
    @Published private(set) var domElements: [DevDOMSummary] = []
    @Published private(set) var localStorage: [DevStorageEntry] = []
    @Published private(set) var sessionStorage: [DevStorageEntry] = []
    @Published private(set) var cookiesSummary: Int = 0
    @Published var isCapturing = true
    /// The element the user picked in "Select Element" mode (if any).
    @Published private(set) var inspectedElement: ElementInspection?
    /// Last AI/heuristic page diagnosis (Problem / Evidence / Cause / Fix).
    @Published private(set) var diagnosis: DevToolsDiagnosis?

    private enum Limits {
        static let console = 300
        static let network = 200
        static let dom = 150
        static let storage = 150
    }

    private init() {}

    // MARK: Console

    private func appendConsole(_ entry: DevConsoleEntry) {
        guard isCapturing else { return }
        console.append(entry)
        if console.count > Limits.console {
            console.removeFirst(console.count - Limits.console)
        }
    }

    /// Console line pushed from the page user script or the agent.
    func reportConsole(level: String, message: String, source: String?, line: Int?) {
        appendConsole(DevConsoleEntry(
            level: .init(rawValue: level) ?? .log,
            message: Redactor.redactText(message),
            sourceURL: source,
            line: line))
    }

    /// In-page JS exception surfaced by the agent or the user script.
    func reportJSException(_ text: String, url: String?, line: Int?) {
        appendConsole(DevConsoleEntry(
            level: .error,
            message: Redactor.redactText(text),
            sourceURL: url,
            line: line))
    }

    func clearConsole() {
        console.removeAll()
    }

    // MARK: Network

    func recordRequest(
        method: String, url: URL?, status: Int?, mimeType: String?,
        durationMS: Int?, sizeBytes: Int?, error: String?) {
        guard isCapturing else { return }
        let entry = DevNetworkEntry(
            method: method,
            url: url.map { Redactor.redactURL($0) } ?? "—",
            status: status,
            mimeType: mimeType,
            durationMS: durationMS,
            sizeBytes: sizeBytes,
            error: error)
        network.append(entry)
        if network.count > Limits.network {
            network.removeFirst(network.count - Limits.network)
        }
    }

    func clearNetwork() {
        network.removeAll()
    }

    // MARK: DOM

    func setDOMSummaries(_ summaries: [DevDOMSummary]) {
        domElements = Array(summaries.prefix(Limits.dom))
    }

    // MARK: Storage & cookies

    func setStorage(local: [(String, String)], session: [(String, String)]) {
        func map(_ pairs: [(String, String)], _ area: DevStorageEntry.Area) -> [DevStorageEntry] {
            pairs.prefix(Limits.storage).map { key, value in
                let v = Redactor.redact(key: key, value: value)
                let truncated = v.count > 200 ? String(v.prefix(200)) + "…" : v
                return DevStorageEntry(area: area, key: key, value: truncated)
            }
        }
        localStorage = map(local, .local)
        sessionStorage = map(session, .session)
    }

    func setCookies(count: Int) {
        cookiesSummary = count
    }

    // MARK: Element inspection

    func setInspectedElement(_ element: ElementInspection?) {
        inspectedElement = element
    }

    // MARK: Diagnosis

    func setDiagnosis(_ value: DevToolsDiagnosis?) {
        diagnosis = value
    }

    // MARK: Tab lifecycle

    /// Clear per-tab state when switching tabs.
    func clearForTabSwitch() {
        console.removeAll()
        network.removeAll()
        domElements.removeAll()
        localStorage.removeAll()
        sessionStorage.removeAll()
        inspectedElement = nil
        diagnosis = nil
    }
}

// MARK: - Page diagnosis model

/// Structured result of DevTools analysis: Problem / Evidence / Cause / Fix.
struct DevToolsDiagnosis: Identifiable, Equatable {
    enum Source: String, Equatable {
        case llm        // produced by the configured AI provider
        case heuristic  // local, offline rule-based fallback
    }

    var id: UUID = UUID()
    var problem: String
    var evidence: [String]
    var possibleCause: String
    var suggestedFix: String
    var source: Source
    var date: Date = Date()
}

/// Snapshot of everything DevTools knows about the current page, used as
/// input for both the heuristic and the LLM diagnosis. All strings are
/// already redacted by the store before they reach this struct.
struct DiagnosisContext {
    var url: String?
    var title: String?
    var consoleErrors: [String]
    var consoleWarnings: [String]
    var networkFailures: [String]
    var domElementCount: Int
}

// MARK: - DevTools analyzer

/// Turns DevTools page observations into a diagnosis. Prefers the configured
/// AI provider (structured JSON output); falls back to a local heuristic that
/// works fully offline. Never touches credentials: input was already redacted,
/// and no proxy/VPN secrets are ever read here.
@MainActor
enum DevToolsAnalyzer {

    /// Gather the page snapshot from the store. Only safe (redacted) fields.
    static func collectContext(store: DevToolsStore) -> DiagnosisContext {
        let errors = store.console
            .filter { $0.level == .error }
            .prefix(15)
            .map(\.message)
        let warnings = store.console
            .filter { $0.level == .warn }
            .prefix(15)
            .map(\.message)
        let failures = store.network
            .filter { $0.error != nil || (($0.status ?? 0) >= 400) }
            .prefix(15)
            .map { entry in
                var s = "\(entry.method) \(entry.url)"
                if let status = entry.status { s += " \(status)" }
                if let err = entry.error { s += " — \(err)" }
                return s
            }
        return DiagnosisContext(
            url: store.network.first?.url,
            title: nil,
            consoleErrors: Array(errors),
            consoleWarnings: Array(warnings),
            networkFailures: Array(failures),
            domElementCount: store.domElements.count
        )
    }

    /// Local, offline, deterministic diagnosis. Guaranteed non-nil.
    static func heuristicDiagnosis(from ctx: DiagnosisContext) -> DevToolsDiagnosis {
        if !ctx.networkFailures.isEmpty {
            return DevToolsDiagnosis(
                problem: "Some requests are failing on this page.",
                evidence: Array(ctx.networkFailures.prefix(5)),
                possibleCause: analyzeNetworkCause(ctx.networkFailures),
                suggestedFix: "Check the failing endpoint(s): verify server status, the URL/HTTP method, and that the API allows this origin (CORS). Use the Network tab and reload to confirm which request breaks the page.",
                source: .heuristic)
        }
        if !ctx.consoleErrors.isEmpty {
            return DevToolsDiagnosis(
                problem: "JavaScript is throwing errors on this page.",
                evidence: Array(ctx.consoleErrors.prefix(5)),
                possibleCause: "The page's script hit a runtime error or failed to parse the data it received (e.g. JSON, missing variable, unexpected null).",
                suggestedFix: "Share the exact console error. If it mentions 'JSON', 'null' or a function, it is usually a malformed API response or a missing value. Inspect the failing request in the Network tab.",
                source: .heuristic)
        }
        if !ctx.consoleWarnings.isEmpty {
            return DevToolsDiagnosis(
                problem: "The page runs but emits warnings.",
                evidence: Array(ctx.consoleWarnings.prefix(5)),
                possibleCause: "Deprecated APIs, non-secure resources, or non-fatal issues. Likely cosmetic, not a functional break.",
                suggestedFix: "Review the warnings in the Console. Usually safe to ignore unless it concerns a feature that is actually failing for you.",
                source: .heuristic)
        }
        return DevToolsDiagnosis(
            problem: "No obvious page errors were captured.",
            evidence: [],
            possibleCause: "The page appears healthy from what DevTools observed (no console errors or network failures).",
            suggestedFix: "If something still looks wrong: reload and keep DevTools open, or tell Navi what you expected vs what happened so it can inspect further.",
            source: .heuristic)
    }
private static func analyzeNetworkCause(_ failures: [String]) -> String {
        let f = failures.first ?? ""
        if f.contains("401") || f.contains("403") { return "Authentication/authorization failed (HTTP 401/403). The request needs valid credentials, a token, or the right permissions." }
        if f.contains("404") { return "The endpoint was not found (HTTP 404). The URL, path or resource name is likely wrong." }
        if f.contains("500") || f.contains("502") || f.contains("503") { return "The server returned a 5xx error — the backend is failing, overloaded, or misconfigured." }
        if f.contains("429") { return "The server is rate-limiting requests (HTTP 429). Slow down or the service is throttling you." }
        return "The server responded with an error status, or the connection to the endpoint failed."
    }

    // MARK: LLM-assisted diagnosis

    /// Runs the full pipeline on the CURRENT page: collect → (LLM ?: heuristic).
    /// `config`/`apiKey` drive the LLM when a provider is configured; otherwise
    /// the offline heuristic is used. Returns a diagnosis either way.
    static func diagnose(
        store: DevToolsStore,
        config: ProviderConfig?,
        apiKey: String,
        llm: LLMService
    ) async -> DevToolsDiagnosis {
        let ctx = collectContext(store: store)
        guard let config, !apiKey.isEmpty else {
            let d = heuristicDiagnosis(from: ctx)
            store.setDiagnosis(d)
            return d
        }
        if let d = try? await llmDiagnosis(context: ctx, config: config, apiKey: apiKey, llm: llm) {
            store.setDiagnosis(d)
            return d
        }
        let d = heuristicDiagnosis(from: ctx)
        store.setDiagnosis(d)
        return d
    }

    private static func llmDiagnosis(
        context: DiagnosisContext,
        config: ProviderConfig,
        apiKey: String,
        llm: LLMService
    ) async throws -> DevToolsDiagnosis? {
        let system = """
        You are NaviAI's web debugging engine. Analyse the page context and output ONLY valid JSON with exactly these keys:
        {"problem":"...","evidence":["..."],"cause":"...","fix":"..."}.
        Evidence must quote the exact console/network messages. Never invent issues you cannot see. Keep each field under 60 words. Answer in the user's language.
        """
        let prompt = """
        Current page observations:
        URL hint: \(context.url ?? "unknown")
        Page elements loaded: \(context.domElementCount)
        Console errors: \(context.consoleErrors.isEmpty ? "none" : context.consoleErrors.joined(separator: " | "))
        Console warnings: \(context.consoleWarnings.isEmpty ? "none" : context.consoleWarnings.joined(separator: " | "))
        Network failures: \(context.networkFailures.isEmpty ? "none" : context.networkFailures.joined(separator: " | "))

        Diagnose: what is the problem, the evidence, the possible cause, and the suggested fix?
        Respond with the JSON object only.
        """
        let reply = try await llm.complete(config: config, apiKey: apiKey,
                                           history: [.system(system), .userText(prompt)], tools: [])
        guard let raw = reply.text, let d = parseJSON(from: raw) else { return nil }
        return d
    }

    private static func parseJSON(from text: String) -> DevToolsDiagnosis? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = cleaned.firstIndex(of: "{"), let end = cleaned.lastIndex(of: "}") else { return nil }
        let jsonText = String(cleaned[start...end])
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let problem = obj["problem"] as? String, !problem.isEmpty else { return nil }
        let evidence = (obj["evidence"] as? [String]) ?? []
        return DevToolsDiagnosis(
            problem: Redactor.redactText(problem),
            evidence: evidence.map { Redactor.redactText($0) },
            possibleCause: Redactor.redactText(obj["cause"] as? String ?? "Unknown."),
            suggestedFix: Redactor.redactText(obj["fix"] as? String ?? "Investigate further."),
            source: .llm)
    }
}
