import Foundation
import Combine

struct RealtimePageSnapshot: Codable, Equatable {
    var url: String
    var title: String
    var readyState: String
    var scrollX: Double
    var scrollY: Double
    var viewportWidth: Double
    var viewportHeight: Double
    var visibleText: String
    var headings: [String]
    var links: [PageLinkInfo]
    var buttons: [String]
    var inputs: [RealtimeInputInfo]
    var forms: [RealtimeFormInfo]
    var focused: RealtimeFocusedInfo?
    var fingerprint: String
    var capturedAt: Date

    struct RealtimeInputInfo: Codable, Equatable {
        var type: String
        var name: String
        var placeholder: String
        var label: String
    }

    struct RealtimeFormInfo: Codable, Equatable {
        var action: String
        var method: String
        var fieldCount: Int
    }

    struct RealtimeFocusedInfo: Codable, Equatable {
        var tag: String
        var type: String
        var name: String
        var placeholder: String
        var label: String
        var textLength: Int
    }

    var isLoading: Bool { readyState != "complete" }

    func samePage(as other: RealtimePageSnapshot?) -> Bool {
        guard let other else { return false }
        return url == other.url && fingerprint == other.fingerprint
    }

    func compressedText(maxChars: Int = 9000) -> String {
        var parts: [String] = []
        if !url.isEmpty { parts.append("URL: \(url)") }
        if !title.isEmpty { parts.append("Title: \(title)") }
        let state = readyState.isEmpty ? "complete" : readyState
        parts.append("State: \(state) | Scroll: \(Int(scrollY))px | Viewport: \(Int(viewportWidth))×\(Int(viewportHeight))")
        if let focused {
            parts.append("Focused: \(focused.tag)\(focused.type.isEmpty ? "" : " type=" + focused.type)"
                + (focused.placeholder.isEmpty ? "" : " placeholder=" + focused.placeholder)
                + (focused.name.isEmpty ? "" : " name=" + focused.name))
        }
        if !headings.isEmpty {
            parts.append("Headings: " + headings.prefix(20).joined(separator: " | "))
        }
        let text = visibleText.count > 5500 ? String(visibleText.prefix(5500)) + "…" : visibleText
        if !text.isEmpty { parts.append("Visible text:\n\(text)") }
        if !buttons.isEmpty {
            parts.append("Buttons: " + buttons.prefix(30).joined(separator: ", "))
        }
        if !inputs.isEmpty {
            let rendered = inputs.prefix(20).map { i in
                i.label.isEmpty ? (i.name.isEmpty ? i.placeholder : i.name) : i.label
            }.joined(separator: ", ")
            parts.append("Inputs: " + rendered)
        }
        if !forms.isEmpty {
            let rendered = forms.prefix(5).map { "form(\($0.fieldCount) fields)" }.joined(separator: ", ")
            parts.append("Forms: " + rendered)
        }
        return limit(parts.joined(separator: "\n\n"), maxChars)
    }

    private func limit(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n)) + "…" : s
    }
}

struct ArticleView: Codable, Equatable {
    var url: String
    var title: String
    var byline: String
    var headings: [String]
    var paragraphs: [String]
    var excerpt: String
}

@MainActor
final class WebPageContextPipeline: ObservableObject {

    static let shared = WebPageContextPipeline()

    @Published private(set) var latest: RealtimePageSnapshot?

    private var cache: [String: RealtimePageSnapshot] = [:]
    private var cacheOrder: [String] = []
    private let maxCacheEntries = 12

    private var lastPublishedHash: String?
    private var captureInFlight = false

    private init() {}

    @discardableResult
    func capture(coordinator: WebCoordinator?) async -> RealtimePageSnapshot? {
        guard let coordinator else { return nil }
        let snapshot = await readSnapshot(coordinator: coordinator)
        if let snapshot {
            latest = snapshot
            updateCache(snapshot)
        }
        return snapshot
    }

    func fresh(coordinator: WebCoordinator?) async -> RealtimePageSnapshot? {
        guard let coordinator else { return nil }
        return await readSnapshot(coordinator: coordinator)
    }

    private func readSnapshot(coordinator: WebCoordinator) async -> RealtimePageSnapshot? {

        if captureInFlight { return latest }
        captureInFlight = true
        defer { captureInFlight = false }
        do {
            let value = try await coordinator.evaluate(BrowserJavaScript.realtimeContextExpr())
            guard let json = value as? String,
                  let data = json.data(using: .utf8) else { return nil }
            var snapshot = try JSONDecoder().decode(RealtimePageSnapshot.self, from: data)
            snapshot.capturedAt = Date()
            return snapshot
        } catch {
            return nil
        }
    }

    func hasRealChange(_ snapshot: RealtimePageSnapshot?) -> Bool {
        guard let snapshot else { return false }
        let hash = changeHash(snapshot)
        if hash == lastPublishedHash { return false }
        lastPublishedHash = hash
        return true
    }

    func markPublished(_ snapshot: RealtimePageSnapshot) {
        lastPublishedHash = changeHash(snapshot)
        latest = snapshot
    }

    func extractArticle(coordinator: WebCoordinator?) async -> ArticleView? {
        guard let coordinator else { return nil }
        do {
            let value = try await coordinator.evaluate(BrowserJavaScript.articleExtractionExpr())
            guard let json = value as? String,
                  let data = json.data(using: .utf8) else { return nil }
            return try JSONDecoder().decode(ArticleView.self, from: data)
        } catch {
            return nil
        }
    }

    private func updateCache(_ snapshot: RealtimePageSnapshot) {
        if cache[snapshot.url] == nil {
            cacheOrder.append(snapshot.url)
            if cacheOrder.count > maxCacheEntries {
                let old = cacheOrder.removeFirst()
                cache.removeValue(forKey: old)
            }
        }
        cache[snapshot.url] = snapshot
    }

    func cached(for url: String) -> RealtimePageSnapshot? {
        cache[url]
    }

    private func changeHash(_ s: RealtimePageSnapshot) -> String {
        var hasher = Hasher()
        hasher.combine(s.url)
        hasher.combine(s.fingerprint)
        hasher.combine(Int(s.scrollY))
        hasher.combine(s.focused?.fingerprint ?? "")
        return String(describing: hasher.finalize())
    }

    func reset() {
        lastPublishedHash = nil
        latest = nil
        cache.removeAll()
        cacheOrder.removeAll()
    }
}

private extension RealtimePageSnapshot.RealtimeFocusedInfo {
    var fingerprint: String {
        "\(tag)|\(type)|\(name)|\(placeholder)|\(label)|\(textLength)"
    }
}
