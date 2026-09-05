import Foundation
import WebKit

// MARK: - DevTools data types

/// One console line from the page or from NaviAI's own JS bridge.
struct DevConsoleEntry: Identifiable, Equatable {
    enum Level: String, Codable, CaseIterable {
        case log, info, warn, error, debug

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .log: return "text.bubble"
            case .info: return "info.circle"
            case .warn: return "exclamationmark.triangle"
            case .error: return "xmark.octagon"
            case .debug: return "ladybug"
            }
        }
    }

    var id: UUID = UUID()
    var level: Level = .log
    var message: String        // already redacted
    var sourceURL: String?
    var line: Int?
    var date: Date = Date()
}

/// One network request captured by the page hook. Secrets redacted BEFORE storing.
struct DevNetworkEntry: Identifiable, Equatable {
    var id: UUID = UUID()
    var method: String
    var url: String            // redacted
    var status: Int?
    var mimeType: String?
    var durationMS: Int?
    var sizeBytes: Int?
    var error: String?
    var date: Date = Date()

    var statusLabel: String {
        if let e = error { return "ERR" }
        return status.map(String.init) ?? "…"
    }
}

/// One localStorage/sessionStorage key-value pair (redacted).
struct DevStorageEntry: Identifiable, Equatable {
    enum Area: String { case local, session }
    var id: String { area.rawValue + "://" + key }
    var area: Area
    var key: String
    var value: String           // redacted, truncated
}

/// Flattened DOM node description for the inspector list.
struct DevDOMSummary: Equatable {
    var tag: String
    var idAttribute: String?
    var classes: String?
    var textPreview: String?
    var childCount: Int
    var depth: Int

    var label: String {
        var s = tag
        if let idAttribute { s += "#\(idAttribute)" }
        if let classes, !classes.isEmpty {
            s += "." + classes.split(separator: " ").joined(separator: ".")
        }
        return s
    }
}

// MARK: - DevTools store

/// Central DevTools state. All page data passes through `Redactor` BEFORE it
/// is stored, so nothing sensitive can leak into history/screenshots/exports.
/// Capture is pull-based: the DevTools panel refreshes from the active page.
@MainActor
final class DevToolsStore: ObservableObject {
    static let shared = DevToolsStore()

    @Published private(set) var console: [DevConsoleEntry] = []
    @Published private(set) var network: [DevNetworkEntry] = []
    @Published private(set) var domElements: [DevDOMSummary] = []
    @Published private(set) var localStorage: [DevStorageEntry] = []
    @Published private(set) var sessionStorage: [DevStorageEntry] = []
    @Published private(set) var cookiesSummary: Int = 0
    @Published var isCapturing = true

    private enum Limits {
        static let console = 300
        static let network = 200
        static let dom = 150
        static let storage = 150
    }

    private init() {}

    // MARK: Console

    private func appendConsole(_ entry: DevConsoleEntry) {
        guard isCapturing else { return }
        console.append(entry)
        if console.count > Limits.console {
            console.removeFirst(console.count - Limits.console)
        }
    }

    /// Console line pushed from the page user script or the agent.
    func reportConsole(level: String, message: String, source: String?, line: Int?) {
        appendConsole(DevConsoleEntry(
            level: .init(rawValue: level) ?? .log,
            message: Redactor.redactText(message),
            sourceURL: source,
            line: line))
    }

    /// In-page JS exception surfaced by the agent or the user script.
    func reportJSException(_ text: String, url: String?, line: Int?) {
        appendConsole(DevConsoleEntry(
            level: .error,
            message: Redactor.redactText(text),
            sourceURL: url,
            line: line))
    }

    func clearConsole() {
        console.removeAll()
    }

    // MARK: Network

    func recordRequest(
        method: String, url: URL?, status: Int?, mimeType: String?,
        durationMS: Int?, sizeBytes: Int?, error: String?) {
        guard isCapturing else { return }
        let entry = DevNetworkEntry(
            method: method,
            url: url.map { Redactor.redactURL($0) } ?? "—",
            status: status,
            mimeType: mimeType,
            durationMS: durationMS,
            sizeBytes: sizeBytes,
            error: error)
        network.append(entry)
        if network.count > Limits.network {
            network.removeFirst(network.count - Limits.network)
        }
    }

    func clearNetwork() {
        network.removeAll()
    }

    // MARK: DOM

    func setDOMSummaries(_ summaries: [DevDOMSummary]) {
        domElements = Array(summaries.prefix(Limits.dom))
    }

    // MARK: Storage & cookies

    func setStorage(local: [(String, String)], session: [(String, String)]) {
        func map(_ pairs: [(String, String)], _ area: DevStorageEntry.Area) -> [DevStorageEntry] {
            pairs.prefix(Limits.storage).map { key, value in
                let v = Redactor.redact(key: key, value: value)
                let truncated = v.count > 200 ? String(v.prefix(200)) + "…" : v
                return DevStorageEntry(area: area, key: key, value: truncated)
            }
        }
        localStorage = map(local, .local)
        sessionStorage = map(session, .session)
    }

    func setCookies(count: Int) {
        cookiesSummary = count
    }

    // MARK: Tab lifecycle

    /// Clear per-tab state when switching tabs.
    func clearForTabSwitch() {
        console.removeAll()
        network.removeAll()
        domElements.removeAll()
        localStorage.removeAll()
        sessionStorage.removeAll()
    }
}