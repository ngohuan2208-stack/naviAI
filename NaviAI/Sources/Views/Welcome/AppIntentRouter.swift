import Foundation

// MARK: - App intents (natural language → real actions)

/// One routable intent: id, sample phrasings, and the action it performs.
/// All actions run on the MainActor and only touch public stores.
struct AppIntent: Identifiable {
    enum ID: String {
        case navigate, searchWeb, newTab, newPrivateTab, reopenClosed
        case askAI, generateImage, deepResearch
        case openDevTools, openHistory, openDownloads, openBookmarks
        case openNetwork, openAutomation, openSettings, findInPage
    }

    let id: ID
    let phrases: [String]
    let run: @MainActor (AppModel, String) -> Void
}

// MARK: - Router

enum AppIntentRouter {

    /// Detect the intent behind a free-form command. Returns nil when the text
    /// looks like a plain question/URL — the caller falls back to chat/search.
    static func detect(text: String) -> AppIntent? {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        for intent in allIntents {
            for phrase in intent.phrases {
                if t == phrase || t.hasPrefix(phrase + " ") {
                    return intent
                }
            }
        }
        return nil
    }

    /// Strips the trigger phrase, returning the argument tail (may be empty).
    static func argument(after phrase: String, in text: String) -> String {
        guard !phrase.isEmpty else { return text }
        let lowered = text.lowercased()
        guard lowered.hasPrefix(phrase) else { return text }
        let idx = lowered.index(lowered.startIndex, offsetBy: phrase.count)
        let tail = String(text[idx...])
        return tail.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Intent registry

extension AppIntentRouter {

    static var intents: [AppIntent] {
        [
            AppIntent(id: .navigate, phrases: ["mở", "open", "go to", "đến", "truy cập"]) { app, text in
                let phrase = firstPhrase(matching: text, from: [.navigate]) ?? ""
                let target = argument(after: phrase, in: text)
                guard !target.isEmpty else { return }
                app.browser.showsWelcome = false
                app.browser.loadAddress(target)
            },

            AppIntent(id: .searchWeb, phrases: ["tìm", "search", "search for", "google", "tra cứu"]) { app, text in
                let phrase = firstPhrase(matching: text, from: [.searchWeb]) ?? ""
                let query = argument(after: phrase, in: text)
                guard !query.isEmpty else { return }
                app.browser.showsWelcome = false
                app.browser.loadAddress(query)
            },

            AppIntent(id: .newTab, phrases: ["tab mới", "new tab", "mở tab"]) { app, _ in
                app.browser.showsWelcome = false
                app.browser.newTab(url: nil, activate: true)
            },

            AppIntent(id: .newPrivateTab, phrases: ["tab riêng tư", "private tab", "tab ẩn danh"]) { app, _ in
                app.browser.showsWelcome = false
                app.browser.openPrivateTab()
            },

            AppIntent(id: .reopenClosed, phrases: ["mở lại tab vừa đóng", "reopen closed tab", "khôi phục tab"]) { app, _ in
                app.browser.showsWelcome = false
                app.browser.reopenClosedTab()
            },

            AppIntent(id: .askAI, phrases: ["hỏi", "ask", "ask ai", "chat"]) { app, text in
                let phrase = firstPhrase(matching: text, from: [.askAI]) ?? ""
                let query = argument(after: phrase, in: text)
                app.browser.showsWelcome = false
                app.browser.showsChatPanel = true
                if !query.isEmpty {
                    app.browser.submitPrompt(query)
                }
            },

            AppIntent(id: .generateImage, phrases: ["tạo ảnh", "vẽ", "generate image", "tạo hình", "draw"]) { app, text in
                let phrase = firstPhrase(matching: text, from: [.generateImage]) ?? ""
                let prompt = argument(after: phrase, in: text)
                app.browser.showsWelcome = false
                app.browser.showsImageStudio = true
                if !prompt.isEmpty {
                    NotificationCenter.default.post(name: .imageStudioGenerateRequested, object: prompt)
                }
            },

            AppIntent(id: .deepResearch, phrases: ["nghiên cứu", "research", "deep research"]) { app, text in
                let phrase = firstPhrase(matching: text, from: [.deepResearch]) ?? ""
                let topic = argument(after: phrase, in: text)
                app.browser.showsWelcome = false
                app.browser.showsResearch = true
                if !topic.isEmpty {
                    NotificationCenter.default.post(name: .researchStartRequested, object: topic)
                }
            }
        ]
    }

    /// Which trigger phrase actually matched this text (for arg stripping).
    static func firstPhrase(matching text: String, from ids: [AppIntent.ID]) -> String? {
        let lowered = text.lowercased()
        for intent in intents where ids.contains(intent.id) {
            for phrase in intent.phrases where lowered.hasPrefix(phrase + " ") || lowered == phrase {
                return phrase
            }
        }
        return nil
    }
}

// MARK: - Notification names used by the router

extension Notification.Name {
    static let imageStudioGenerateRequested = Notification.Name("naviai.imageStudio.generateRequested")
    static let researchStartRequested = Notification.Name("naviai.research.startRequested")
}

// MARK: - Surface intents (DevTools, History, Network, …)

extension AppIntentRouter {

    static var surfaceIntents: [AppIntent] {
        [
            AppIntent(id: .openDevTools, phrases: ["devtools", "dev tools", "công cụ nhà phát triển", "inspect"]) { app, _ in
                app.browser.showsWelcome = false
                app.browser.showsDevTools = true
            },

            AppIntent(id: .openHistory, phrases: ["lịch sử", "history", "xem lịch sử"]) { app, _ in
                app.browser.showsWelcome = false
                app.browser.showsHistoryCenter = true
            },

            AppIntent(id: .openDownloads, phrases: ["tải xuống", "downloads", "file đã tải"]) { app, _ in
                app.browser.showsWelcome = false
                app.browser.showsDownloads = true
            },

            AppIntent(id: .openBookmarks, phrases: ["bookmarks", "bookmark", "đánh dấu"]) { app, _ in
                app.browser.showsWelcome = false
                app.browser.showsBookmarks = true
            },

            AppIntent(id: .openNetwork, phrases: ["mạng", "network", "proxy", "vpn", "trạng thái mạng"]) { app, _ in
                app.browser.showsWelcome = false
                app.browser.showsNetworkCenter = true
            },

            AppIntent(id: .openAutomation, phrases: ["automation", "tự động", "tạo automation"]) { app, _ in
                app.browser.showsWelcome = false
                app.browser.showsAutomation = true
            },

            AppIntent(id: .openSettings, phrases: ["cài đặt", "settings", "open settings"]) { app, _ in
                app.browser.showsWelcome = false
                app.browser.showsSettings = true
            },

            AppIntent(id: .findInPage, phrases: ["tìm trong trang", "find in page", "tìm trên trang"]) { app, text in
                let phrase = firstPhrase(matching: text, from: [.findInPage]) ?? ""
                let query = argument(after: phrase, in: text)
                app.browser.showsWelcome = false
                if !query.isEmpty {
                    app.browser.showsFindBar = true
                    app.browser.updateFindQuery(query)
                } else {
                    app.browser.showsFindBar = true
                }
            }
        ]
    }

    /// Full registry: actions first, then surface openers.
    static var allIntents: [AppIntent] {
        intents + surfaceIntents
    }
}