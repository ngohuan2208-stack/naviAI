import Foundation
import Combine

// MARK: - Realtime page snapshot (visible state, not the whole DOM)

/// Compact, visible view of the current page produced by in-page JS. This is
/// what the AI and LAN clients observe — never a blind full-DOM dump.
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

    /// Is this snapshot about the same page content as another (cheap dedup)?
    func samePage(as other: RealtimePageSnapshot?) -> Bool {
        guard let other else { return false }
        return url == other.url && fingerprint == other.fingerprint
    }

    /// Token-optimised text for the model (relevant context only).
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

// MARK: - Article view (reading pipeline)

/// Extracted article content for the reading pipeline (Page → relevant content
/// → compact context → AI analysis). Never ships the raw DOM.
struct ArticleView: Codable, Equatable {
    var url: String
    var title: String
    var byline: String
    var headings: [String]
    var paragraphs: [String]
    var excerpt: String
}

// MARK: - Pipeline

/// Real-time WebPage/Visual context pipeline.
///
/// Captures compact visible state in-page, then applies:
/// - relevance filtering (visible interactive/main elements only)
/// - change detection (fingerprint) so only real changes move forward
/// - deduplication (identical content is dropped)
/// - caching (per-URL snapshots) to avoid re-reading unchanged pages
/// - compression (caps + truncation) so AI / LAN never sees the full DOM
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

    // MARK: Capture

    /// Capture the current visible page state from the active tab.
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

    /// Capture without routing through the cache/broadcast bookkeeping.
    func fresh(coordinator: WebCoordinator?) async -> RealtimePageSnapshot? {
        guard let coordinator else { return nil }
        return await readSnapshot(coordinator: coordinator)
    }

    private func readSnapshot(coordinator: WebCoordinator) async -> RealtimePageSnapshot? {
        // Single-flight: never stack concurrent page evaluations.
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

    /// True when the snapshot differs from the last snapshot we pushed out.
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

    // MARK: Article extraction (reading pipeline)

    /// Extract an article from the current page.
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

    // MARK: Caching

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

    // MARK: Dedup / hash

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

// MARK: - Hashable helpers

private extension RealtimePageSnapshot.RealtimeFocusedInfo {
    var fingerprint: String {
        "\(tag)|\(type)|\(name)|\(placeholder)|\(label)|\(textLength)"
    }
}
