import Foundation

// MARK: - Deep page structure (mirror of __navi.deepStructure() JSON)

struct PageLinkInfo: Codable, Equatable {
    var text: String
    var href: String
}

struct PageInputInfo: Codable, Equatable {
    var name: String
    var type: String
    var placeholder: String
    var label: String
}

struct PageFormInfo: Codable, Equatable {
    var action: String
    var method: String
    var inputs: [PageInputInfo]
}

struct PageTableInfo: Codable, Equatable {
    var headers: [String]
    var rows: [[String]]
}

/// Real semantic structure of a page, gathered in-page by injected JS.
struct WebPageStructure: Codable, Equatable {
    var url: String
    var title: String
    var meta: [String: String]
    var headings: [String]
    var paragraphs: [String]
    var links: [PageLinkInfo]
    var buttons: [String]
    var inputs: [PageInputInfo]
    var forms: [PageFormInfo]
    var tables: [PageTableInfo]
    var lists: [String]
    var bodyExcerpt: String
    var mainContent: String
}

// MARK: - Enriched page context

/// A memory-friendly, token-optimised view of a page the agent can actually
/// reason over. Holds source metadata plus lazily computed, compressed text.
struct WebPageContext: Equatable {
    let url: String
    let title: String
    let headings: [String]
    let paragraphs: [String]
    let links: [PageLinkInfo]
    let buttons: [String]
    let inputs: [PageInputInfo]
    let forms: [PageFormInfo]
    let tables: [PageTableInfo]
    let lists: [String]
    let meta: [String: String]
    let bodyText: String
    let capturedAt: Date

    /// Quick identity used for dedup/caching.
    var cacheKey: String { url }
    var contentHash: Int {
        var hasher = Hasher()
        hasher.combine(title)
        for p in paragraphs.prefix(20) { hasher.combine(p) }
        hasher.combine(bodyText.count)
        return hasher.finalize()
    }

    var host: String { URL(string: url)?.host ?? url }
    var titleOrHost: String { title.isEmpty ? host : title }

    /// Deep read: everything relevant, already compressed. Used by Deep Read
    /// and Research so the model never sees a raw full DOM dump.
    func deepReadText(maxChars: Int = 12000) -> String {
        var parts: [String] = []
        if !title.isEmpty { parts.append("Title: \(title)") }
        if !url.isEmpty { parts.append("URL: \(url)") }
        if !meta.isEmpty {
            let pairs = meta.prefix(20).map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            parts.append("Metadata: \(pairs)")
        }
        if !headings.isEmpty {
            parts.append("Headings:\n" + headings.map { "• \($0)" }.joined(separator: "\n"))
        }
        if !paragraphs.isEmpty {
            let joined = paragraphs.joined(separator: "\n")
            parts.append("Content:\n" + limit(joined, maxChars / 2))
        }
        if !tables.isEmpty {
            for (i, t) in tables.enumerated() {
                parts.append("Table \(i + 1):\n" + tableText(t))
            }
        }
        if !lists.isEmpty {
            parts.append("Lists:\n" + limit(lists.joined(separator: "\n"), 2000))
        }
        if !forms.isEmpty {
            for f in forms {
                let inputs = f.inputs.map { $0.label.isEmpty ? ($0.name.isEmpty ? $0.placeholder : $0.name) : $0.label }
                parts.append("Form to \(f.action.isEmpty ? "?" : f.action) fields: \(inputs.joined(separator: ", "))")
            }
        }
        if !buttons.isEmpty {
            parts.append("Buttons: " + buttons.prefix(40).joined(separator: ", "))
        }
        if !links.isEmpty {
            let top = links.prefix(40).map { $0.text.isEmpty ? $0.href : $0.text }.joined(separator: ", ")
            parts.append("Links: " + limit(top, 2000))
        }
        return limit(parts.filter { !$0.isEmpty }.joined(separator: "\n\n"), maxChars)
    }

    /// Compact one-line summary for list/compare contexts.
    var summary: String {
        let firstP = paragraphs.first ?? ""
        let excerpt = firstP.count > 160 ? String(firstP.prefix(160)) + "…" : firstP
        return "[\(titleOrHost)] \(excerpt)"
    }

    /// Extract titles/URLs for source attribution.
    var source: (title: String, url: String) { (titleOrHost, url) }

    private func limit(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n)) + "…" : s
    }

    private func tableText(_ t: PageTableInfo) -> String {
        var lines: [String] = []
        if !t.headers.isEmpty { lines.append(t.headers.joined(separator: " | ")) }
        for row in t.rows.prefix(12) {
            lines.append(row.joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
    }

    static func from(structure: WebPageStructure) -> WebPageContext {
        WebPageContext(url: structure.url,
                       title: structure.title,
                       headings: structure.headings,
                       paragraphs: structure.paragraphs,
                       links: structure.links,
                       buttons: structure.buttons,
                       inputs: structure.inputs,
                       forms: structure.forms,
                       tables: structure.tables,
                       lists: structure.lists,
                       meta: structure.meta,
                       bodyText: structure.bodyExcerpt,
                       capturedAt: Date())
    }
}