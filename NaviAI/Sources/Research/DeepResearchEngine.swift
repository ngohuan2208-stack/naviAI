import Foundation
import Combine

struct DeepResearchSource: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var url: String
    var excerpt: String
}

struct DeepResearchReport: Codable, Identifiable, Equatable {
    var id = UUID()
    var question: String
    var report: String
    var sources: [DeepResearchSource]
    var createdAt: Date = Date()
}

@MainActor
final class DeepResearchEngine: ObservableObject {

    static let shared = DeepResearchEngine()

    enum Stage: Equatable {
        case idle, planning, searching, reading(Int, Int), synthesizing, done
    }

    @Published private(set) var reports: [DeepResearchReport] = []
    @Published var isRunning = false
    @Published private(set) var progress = ""
    @Published private(set) var stage: Stage = .idle

    weak var browser: BrowserStore?

    private var researchTask: Task<Void, Never>?
    private let maxSources = 5

    private init() {}

    func stop() {
        researchTask?.cancel()
        isRunning = false
    }

    func clearReports() {
        reports.removeAll()
    }

    func deleteReports(at offsets: IndexSet) {
        reports.remove(atOffsets: offsets)
    }

    func run(_ question: String) {
        guard let browser else { return }
        researchTask?.cancel()
        researchTask = Task { [weak self] in
            guard let self, let browser else { return }
            isRunning = true
            stage = .planning
            progress = "Planning…"
            let plan = await planQueries(for: question, browser: browser)

            var sources: [DeepResearchSource] = []
            var contexts: [WebPageContext] = []

            stage = .searching
            for (qi, q) in plan.prefix(3).enumerated() {
                if Task.isCancelled { break }
                progress = "Searching (\(qi + 1)/\(min(plan.count, 3)))…"
                await openSearch(for: q, browser: browser)
                await browser.waitForPageSettle(timeout: 20)
                let links = await resultLinks(browser: browser)
                for url in links.prefix(2) {
                    if Task.isCancelled { break }
                    if contexts.count >= maxSources { break }
                    stage = .reading(contexts.count + 1, maxSources)
                    progress = "Reading \(URL(string: url)?.host ?? url)"
                    await browser.loadURL(url)
                    await browser.waitForPageSettle(timeout: 25)
                    if let ctx = await browser.deepReadContext() {
                        contexts.append(ContextManager.shared.handlePageContext(ctx))
                        sources.append(DeepResearchSource(title: ctx.titleOrHost,
                                                          url: ctx.url,
                                                          excerpt: ctx.summary))
                    }
                }
            }

            stage = .synthesizing
            progress = "Synthesizing…"
            let deduped = ContextManager.shared.deduplicate(contexts)
            let reportText = await synthesize(question: question, contexts: deduped, browser: browser)
            stage = .done
            isRunning = false
            progress = ""

            if !reportText.isEmpty {
                let report = DeepResearchReport(question: question,
                                                report: reportText,
                                                sources: Array(sources.prefix(maxSources)))
                reports.insert(report, at: 0)
            }
        }
    }

    private func planQueries(for question: String, browser: BrowserStore) async -> [String] {
        guard let config = browser.providers.activeProvider,
              let key = browser.providers.apiKey(for: config) else {
            return [question]
        }
        let system = """
        You plan a web research. Output ONLY a JSON array of 2-4 short, distinct search queries \
        covering the user's question. No prose. Example: ["query one", "query two"].
        """
        do {
            let reply = try await browser.llm.complete(
                config: config, apiKey: key,
                history: [.system(system), .userText(question)], tools: [])
            return parseQueries(reply.text ?? "")
        } catch {
            return [question]
        }
    }

    private func parseQueries(_ text: String) -> [String] {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end else {
            return [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [String] else {
            return [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        return arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func openSearch(for query: String, browser: BrowserStore) async {
        if let url = SearchManager.shared.resultsURL(for: query) {
            await browser.loadURL(url)
        } else {
            _ = await browser.executeTool(named: "searchWeb", argumentsJSON: Self.json(["query": query]))
        }
    }

    private func resultLinks(browser: BrowserStore) async -> [String] {
        guard let value = try? await browser.agentEvaluate(BrowserJavaScript.topLinksExpr(max: 12)),
              let raw = value as? String else { return [] }
        let cleaned = raw.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        return cleaned.split(separator: ",").map(String.init)
    }

    private func synthesize(question: String, contexts: [WebPageContext], browser: BrowserStore) async -> String {
        guard let config = browser.providers.activeProvider,
              let key = browser.providers.apiKey(for: config) else { return "" }
        let contextBlock = ContextManager.shared.contextForModel(contexts, relevanceTo: question, maxChars: 6000)
        let sourceList = contexts.map { "• \($0.titleOrHost) — \($0.url)" }.joined(separator: "\n")
        let system = """
        You are a research assistant. Answer the user's question using ONLY the provided web content. \
        Clearly attribute claims to their source (e.g. "According to <site> …"). If sources conflict, say so. \
        Structure your answer with a short summary, key findings, and a conclusion. \
        Do NOT invent facts not present in the sources.
        """
        let user = "Question: \(question)\n\nSources:\n\(sourceList)\n\nWeb content:\n\(contextBlock)"
        do {
            let reply = try await browser.llm.complete(config: config, apiKey: key,
                                                       history: [.system(system), .userText(user)], tools: [])
            return reply.text ?? ""
        } catch {
            return "Research interrupted: \(error.localizedDescription)"
        }
    }

    private static func json(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

extension BrowserStore {

    func deepReadContext() async -> WebPageContext? {
        guard let value = try? await agentEvaluate(BrowserJavaScript.deepStructureExpr()),
              let s = value as? String,
              let data = s.data(using: .utf8),
              let structure = try? JSONDecoder().decode(WebPageStructure.self, from: data) else {
            return nil
        }
        return WebPageContext.from(structure: structure)
    }
}
