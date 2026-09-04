import Foundation

// MARK: - History

struct PageVisit: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var urlString: String
    var date: Date = Date()
}

// MARK: - Bookmarks

struct BookmarkItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var urlString: String
    var date: Date = Date()
}

// MARK: - Downloads

struct DownloadRecord: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var relativePath: String   // relative to Documents/Downloads
    var date: Date = Date()
    var mimeType: String = "application/octet-stream"
    var suggestedFilename: String
}

extension DownloadRecord {
    var fileURL: URL {
        URL.documentsDirectory
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(relativePath)
    }

    var fileExists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }
}
