import Foundation

enum SafariImport {

    static func parseJSON(_ data: Data) -> [ImportedBookmark]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let raw: [[String: Any]]?
        if let dict = root as? [String: Any] {
            raw = dict["bookmarks"] as? [[String: Any]] ?? dict["items"] as? [[String: Any]]
        } else if let array = root as? [[String: Any]] {
            raw = array
        } else {
            raw = nil
        }
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
