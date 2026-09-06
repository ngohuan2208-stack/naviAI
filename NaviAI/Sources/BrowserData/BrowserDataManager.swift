import Foundation

// MARK: - Import models

/// A single bookmark candidate read from an imported file.
struct ImportedBookmark: Codable, Equatable {
    var title: String
    var urlString: String

    var isValidURL: Bool {
        URL(string: urlString)?.host != nil
    }
}

/// Result of one import operation (partial imports included).
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

// MARK: - Manager

/// Orchestrates Browser Data flows (import from Safari / export Navi data).
/// Validation → preview → confirm → import → report. Duplicates, malformed
/// files and unsupported formats are handled gracefully (partial imports).
@MainActor
final class BrowserDataManager {

    static let shared = BrowserDataManager()

    private init() {}

    // MARK: Import

    /// Parse a file dropped by the user (Safari HTML export or Navi JSON).
    /// Returns nil for completely unsupported files.
    func parseImportFile(_ data: Data) -> [ImportedBookmark]? {
        guard !data.isEmpty else { return nil }
        // Try JSON first (Navi's own format).
        if let jsonItems = SafariImport.parseJSON(data) {
            return jsonItems
        }
        // Safari "Export Bookmarks" HTML.
        if let html = String(data: data, encoding: .utf8),
           html.localizedCaseInsensitiveContains("<!DOCTYPE NETSCAPE-Bookmark-file-1>")
            || html.localizedCaseInsensitiveContains("<DT><A") {
            let items = SafariImport.parseBookmarksHTML(html)
            return items.isEmpty ? nil : items
        }
        return nil
    }

    /// Validate + preview an imported file (before the user confirms).
    func preview(_ data: Data) -> (items: [ImportedBookmark], invalidCount: Int) {
        guard let items = parseImportFile(data) else { return ([], 0) }
        let valid = items.filter { $0.isValidURL }
        return (Array(valid.prefix(500)), items.count - valid.count)
    }

    /// Confirm + import into the browser library. Dedups against existing
    /// bookmarks; reports partial results.
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

    // MARK: Export

    /// Build the export JSON (never secrets).
    func buildExport(browser: BrowserStore) -> Data? {
        SafariExport.build(browser: browser)
    }
}