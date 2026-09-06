import Foundation

struct PageVisit: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var urlString: String
    var date: Date = Date()
}

struct BookmarkItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var urlString: String
    var date: Date = Date()
}

struct DownloadRecord: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var relativePath: String
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
