import Foundation

// MARK: - Safari / Navi export

/// Builds a safe, self-describing export of supported Navi browser data. The
/// export intentionally NEVER contains API keys, Keychain secrets, passwords,
/// cookies, session tokens or private credentials.
enum SafariExport {

    struct ExportedConversation: Codable {
        var title: String
        var updatedAt: Date
        var messageCount: Int
        var summary: String
        var associatedURLs: [String]
    }

    /// Compose the full export dictionary as JSON data.
    static func build(browser: BrowserStore) -> Data? {
        let conversations = ConversationStore.shared.conversations.prefix(200).map { convo in
            ExportedConversation(title: convo.title,
                                 updatedAt: convo.updatedAt,
                                 messageCount: convo.messages.count,
                                 summary: convo.snippet.prefix(300).description,
                                 associatedURLs: convo.associatedURLs)
        }

        let now = Date()
        var root: [String: Any] = [
            "app": "NaviAI",
            "exportVersion": 1,
            "exportedAt": ISO8601DateFormatter().string(from: now),
            "sources": ["Navi browser data"]
        ]
        root["bookmarks"] = browser.bookmarks.map {
            ["title": $0.title, "url": $0.urlString, "date": ISO8601DateFormatter().string(from: $0.date)]
        }
        root["history"] = browser.history.prefix(1000).map {
            ["title": $0.title, "url": $0.urlString, "date": ISO8601DateFormatter().string(from: $0.date)]
        }
        root["conversations"] = conversations.map { convo in
            [
                "title": convo.title,
                "updatedAt": ISO8601DateFormatter().string(from: convo.updatedAt),
                "messageCount": convo.messageCount,
                "summary": convo.summary,
                "associatedURLs": convo.associatedURLs
            ] as [String: Any]
        }
        root["automation"] = [
            "policy": browser.settings.automationDefaultPolicy.rawValue
        ]
        root["profile"] = [
            "name": BrowserProfileStore.shared.activeProfile.name,
            "displayName": BrowserProfileStore.shared.activeProfile.displayName
        ]

        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return data
    }
}