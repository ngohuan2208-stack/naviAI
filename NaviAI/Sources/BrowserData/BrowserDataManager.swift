import Foundation

struct ImportedBookmark: Codable, Equatable {
    var title: String
    var urlString: String

    var isValidURL: Bool {
        URL(string: urlString)?.host != nil
    }
}

struct ImportReport: Codable, Equatable {
    var importedBookmarks = 0
    var skippedDuplicates = 0
    var invalidEntries = 0
    var message = ""

    var summary: String {
        "Imported \(importedBookmarks) bookmark(s)"
            + (skippedDuplicates > 0 ? ", skipped \(skippedDuplicates) duplicate(s)" : "")
            + (invalidEntries > 0 ? ", ignored \(invalidEntries) invalid entrie(s)" : "")
            + "."
    }
}

@MainActor
final class BrowserDataManager {

    static let shared = BrowserDataManager()

    private init() {}

    func parseImportFile(_ data: Data) -> [ImportedBookmark]? {
        guard !data.isEmpty else { return nil }

        if let jsonItems = SafariImport.parseJSON(data) {
            return jsonItems
        }

        if let html = String(data: data, encoding: .utf8),
           html.localizedCaseInsensitiveContains("<!DOCTYPE NETSCAPE-Bookmark-file-1>")
            || html.localizedCaseInsensitiveContains("<DT><A") {
            let items = SafariImport.parseBookmarksHTML(html)
            return items.isEmpty ? nil : items
        }
        return nil
    }

    func preview(_ data: Data) -> (items: [ImportedBookmark], invalidCount: Int) {
        guard let items = parseImportFile(data) else { return ([], 0) }
        let valid = items.filter { $0.isValidURL }
        return (Array(valid.prefix(500)), items.count - valid.count)
    }

    func confirmImport(_ items: [ImportedBookmark], into browser: BrowserStore) -> ImportReport {
        var report = ImportReport()
        let existing = Set(browser.bookmarks.map { $0.urlString })
        var added: [BookmarkItem] = []
        for item in items {
            if !item.isValidURL {
                report.invalidEntries += 1
                continue
            }
            if existing.contains(item.urlString) {
                report.skippedDuplicates += 1
                continue
            }
            added.append(BookmarkItem(title: item.title.isEmpty ? (URL(string: item.urlString)?.host ?? item.urlString) : item.title,
                                      urlString: item.urlString))
            report.importedBookmarks += 1
        }
        browser.appendBookmarks(added)
        report.message = report.summary
        return report
    }

    func buildExport(browser: BrowserStore) -> Data? {
        SafariExport.build(browser: browser)
    }
}
