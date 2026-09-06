import Foundation

// MARK: - Safari import

/// Parses the two formats a user can legally get out of Safari / iOS:
///  1. Safari's HTML bookmark export (Safari → File → Export Bookmarks),
///  2. Navi's own JSON export.
///
/// It only touches files the user explicitly picked with the system document
/// picker. It NEVER opens Safari's private databases or bypasses the sandbox.
enum SafariImport {

    /// Parse { "bookmarks": [...] } or bare [...] JSON.
    static func parseJSON(_ data: Data) -> [ImportedBookmark]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let raw = root["bookmarks"] as? [[String: Any]] ?? root["items"] as? [[String: Any]]
        guard let list = raw else { return nil }
        var out: [ImportedBookmark] = []
        for entry in list {
            let title = (entry["title"] as? String) ?? ""
            let url = (entry["url"] as? String) ?? (entry["urlString"] as? String) ?? ""
            if !url.isEmpty {
                out.append(ImportedBookmark(title: title, urlString: url))
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Parse a Netscape bookmark HTML export (Safari's export format).
    static func parseBookmarksHTML(_ html: String) -> [ImportedBookmark] {
        var out: [ImportedBookmark] = []
        let pattern = "<DT><A[^>]*HREF=\"([^\"]+)\"[^>]*>(.*?)</A>"
        let regex = try? NSRegularExpression(pattern: pattern,
                                             options: [.caseInsensitive, .dotMatchesLineSeparators])
        guard let regex else { return [] }
        let ns = html as NSString
        regex.enumerateMatches(in: html, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            guard match.numberOfRanges == 3 else { return }
            var href = ns.substring(with: match.range(at: 1))
            var title = ns.substring(with: match.range(at: 2))
            href = href.trimmingCharacters(in: .whitespacesAndNewlines)
            title = title.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
            if let decoded = href.removingPercentEncoding {
                href = decoded
            }
            guard !href.isEmpty else { return }
            out.append(ImportedBookmark(title: title, urlString: href))
        }
        return out
    }
}