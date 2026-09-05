import Foundation
import Combine

// MARK: - Search provider abstraction

/// A search capability the AI can call. Separated from both the browser UI
/// search bar (which uses `SearchEngine` in SettingsStore) and the agent so
/// extra providers (API-backed, meta-search, others) can be added later.
protocol SearchProviding {
    var id: String { get }
    var label: String { get }
    /// Whether this provider can return results directly (API) or must be
    /// navigated to (HTML results page read by the agent).
    var isHierarchical: Bool { get }
    func resultsURL(for query: String) -> URL?
}

/// Concrete HTML-based search engines. The agent opens the results URL and
/// reads the page — reliable and provider-agnostic.
enum SearchProviderKind: String, CaseIterable, Identifiable, SearchProviding {
    case duckduckgo
    case google
    case bing
    case brave

    var id: String { rawValue }

    var label: String {
        switch self {
        case .duckduckgo: return "DuckDuckGo"
        case .google: return "Google"
        case .bing: return "Bing"
        case .brave: return "Brave"
        }
    }

    var isHierarchical: Bool { false }

    func resultsURL(for query: String) -> URL? {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let template: String
        switch self {
        case .duckduckgo: template = "https://duckduckgo.com/?q=\(q)"
        case .google: template = "https://www.google.com/search?q=\(q)"
        case .bing: template = "https://www.bing.com/search?q=\(q)"
        case .brave: template = "https://search.brave.com/search?q=\(q)"
        }
        return URL(string: template)
    }
}

// MARK: - Search manager

/// Resolves "which search provider the AI uses" (defaults to DuckDuckGo). The
/// browser UI keeps its own address-bar engine; the AI uses this one.
@MainActor
final class SearchManager: ObservableObject {

    static let shared = SearchManager()

    @Published var kind: SearchProviderKind = .duckduckgo {
        didSet {
            UserDefaults.standard.set(kind.rawValue, forKey: self.key)
        }
    }

    private let key = "search.provider"

    private init() {
        if let raw = UserDefaults.standard.string(forKey: key),
           let k = SearchProviderKind(rawValue: raw) {
            kind = k
        }
    }

    var provider: SearchProviding { kind }

    func resultsURL(for query: String) -> URL? {
        provider.resultsURL(for: query)
    }
}

// MARK: - Search result model

/// A lightweight parsed search result (title, url, snippet). The agent can
/// fill this from the DOM of a results page.
struct SearchResult: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var url: String
    var snippet: String
}