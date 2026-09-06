import Foundation

@MainActor
final class ContextManager {

    static let shared = ContextManager()

    private struct Entry {
        let hash: Int
        let context: WebPageContext
        let date: Date
    }

    private var cache: [String: Entry] = [:]
    private var lastEventKey: String?

    private init() {

    }

    func cachedContext(for url: String) -> WebPageContext? {
        cache[url]?.context
    }

    func handlePageContext(_ context: WebPageContext) -> WebPageContext {
        let key = context.cacheKey
        if let existing = cache[key], existing.hash == context.contentHash {

            return existing.context
        }
        cache[key] = Entry(hash: context.contentHash, context: context, date: Date())
        return context
    }

    func hasChanged(from context: WebPageContext) -> Bool {
        guard let existing = cache[context.cacheKey] else { return true }
        return existing.hash != context.contentHash
    }

    func invalidate(url: String) {
        cache.removeValue(forKey: url)
    }

    func clear() {
        cache.removeAll()
    }

    func deduplicate(_ contexts: [WebPageContext]) -> [WebPageContext] {
        var seenURLs = Set<String>()
        var seenHashes = Set<Int>()
        var out: [WebPageContext] = []
        for c in contexts {
            let key = c.cacheKey
            if seenURLs.contains(key) { continue }
            if seenHashes.contains(c.contentHash % 1_000_000) { continue }
            seenURLs.insert(key)
            seenHashes.insert(c.contentHash % 1_000_000)
            out.append(c)
        }
        return out
    }

    func ranked(_ contexts: [WebPageContext], relevanceTo goal: String) -> [WebPageContext] {
        let terms = goal.lowercased().split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        guard !terms.isEmpty else { return contexts }
        return contexts.enumerated().sorted { a, b in
            let sa = score(a.element, terms: terms)
            let sb = score(b.element, terms: terms)
            if sa != sb { return sa > sb }
            return a.offset < b.offset
        }.map { $0.element }
    }

    private func score(_ c: WebPageContext, terms: [String]) -> Int {
        let haystack = (c.title + " " + c.paragraphs.joined(separator: " ")).lowercased()
        return terms.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
    }

    func contextForModel(_ contexts: [WebPageContext], relevanceTo goal: String, maxChars: Int = 4000) -> String {
        let deduped = deduplicate(contexts)
        let ranked = ranked(deduped, relevanceTo: goal)
        var out: [String] = []
        var used = 0
        for c in ranked {
            let budgetPer = max(600, (maxChars - used) / max(1, ranked.count))
            let text = c.deepReadText(maxChars: budgetPer)
            out.append(text)
            used += text.count
            if used >= maxChars { break }
        }
        return String(out.joined(separator: "\n\n---\n\n").prefix(maxChars))
    }

    func chunk(_ text: String, chunkChars: Int = 2500, overlap: Int = 200) -> [String] {
        guard text.count > chunkChars else { return [text] }
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: min(chunkChars, text.distance(from: start, to: text.endIndex)))
            let piece = String(text[start..<end])
            chunks.append(piece.trimmingCharacters(in: .whitespacesAndNewlines))
            guard end < text.endIndex else { break }

            let nextOffset = min(chunkChars - overlap, text.distance(from: start, to: text.endIndex))
            guard nextOffset > 0 else { break }
            start = text.index(start, offsetBy: nextOffset)
        }
        return chunks.filter { !$0.isEmpty }
    }

    func excerpt(near query: String, in paragraphs: [String], radius: Int = 2) -> String {
        let q = query.lowercased()
        var out: [String] = []
        for (i, p) in paragraphs.enumerated() where p.lowercased().contains(q) {
            let lower = max(0, i - radius)
            let upper = min(paragraphs.count, i + radius + 1)
            for j in lower..<upper where !out.contains(paragraphs[j]) {
                out.append(paragraphs[j])
            }
        }
        return out.joined(separator: "\n")
    }
}
