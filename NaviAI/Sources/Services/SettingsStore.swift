import Foundation
import Combine

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

enum SearchEngine: String, CaseIterable, Identifiable {
    case google, bing, duckduckgo, brave
    var id: String { rawValue }

    var label: String {
        switch self {
        case .google: return "Google"
        case .bing: return "Bing"
        case .duckduckgo: return "DuckDuckGo"
        case .brave: return "Brave"
        }
    }

    func searchURL(for query: String) -> URL {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let template: String
        switch self {
        case .google: template = "https://www.google.com/search?q=\(q)"
        case .bing: template = "https://www.bing.com/search?q=\(q)"
        case .duckduckgo: template = "https://duckduckgo.com/?q=\(q)"
        case .brave: template = "https://search.brave.com/search?q=\(q)"
        }
        return URL(string: template) ?? URL(string: "https://www.google.com")!
    }

    var homeURL: URL {
        switch self {
        case .google: return URL(string: "https://www.google.com")!
        case .bing: return URL(string: "https://www.bing.com")!
        case .duckduckgo: return URL(string: "https://duckduckgo.com")!
        case .brave: return URL(string: "https://search.brave.com")!
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var onboarded: Bool { didSet { defaults.set(onboarded, forKey: Keys.onboarded) } }
    @Published var appearance: AppearanceMode { didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) } }
    @Published var searchEngine: SearchEngine { didSet { defaults.set(searchEngine.rawValue, forKey: Keys.searchEngine) } }

    @Published var aiCursorEnabled: Bool { didSet { defaults.set(aiCursorEnabled, forKey: Keys.cursor) } }
    @Published var cursorAnimationsEnabled: Bool { didSet { defaults.set(cursorAnimationsEnabled, forKey: Keys.cursorAnimations) } }
    @Published var aiConfirmationEnabled: Bool { didSet { defaults.set(aiConfirmationEnabled, forKey: Keys.confirm) } }
    @Published var visionFallbackEnabled: Bool { didSet { defaults.set(visionFallbackEnabled, forKey: Keys.vision) } }
    @Published var desktopModeEnabled: Bool { didSet { defaults.set(desktopModeEnabled, forKey: Keys.desktopMode) } }
    @Published var autoScrollEnabled: Bool { didSet { defaults.set(autoScrollEnabled, forKey: Keys.autoScroll) } }
    @Published var showAgentLabelsEnabled: Bool { didSet { defaults.set(showAgentLabelsEnabled, forKey: Keys.labels) } }

    private enum Keys {
        static let onboarded = "settings.onboarded"
        static let appearance = "settings.appearance"
        static let searchEngine = "settings.searchEngine"
        static let cursor = "settings.cursorEnabled"
        static let cursorAnimations = "settings.cursorAnimations"
        static let confirm = "settings.confirmation"
        static let vision = "settings.visionFallback"
        static let desktopMode = "settings.desktopMode"
        static let autoScroll = "settings.autoScroll"
        static let labels = "settings.agentLabels"
    }

    init() {
        let d = UserDefaults.standard
        self.onboarded = d.object(forKey: Keys.onboarded) as? Bool ?? false
        self.appearance = AppearanceMode(rawValue: d.string(forKey: Keys.appearance) ?? "") ?? .system
        self.searchEngine = SearchEngine(rawValue: d.string(forKey: Keys.searchEngine) ?? "") ?? .google
        self.aiCursorEnabled = d.object(forKey: Keys.cursor) as? Bool ?? true
        self.cursorAnimationsEnabled = d.object(forKey: Keys.cursorAnimations) as? Bool ?? true
        self.aiConfirmationEnabled = d.object(forKey: Keys.confirm) as? Bool ?? true
        self.visionFallbackEnabled = d.object(forKey: Keys.vision) as? Bool ?? true
        self.desktopModeEnabled = d.object(forKey: Keys.desktopMode) as? Bool ?? false
        self.autoScrollEnabled = d.object(forKey: Keys.autoScroll) as? Bool ?? true
        self.showAgentLabelsEnabled = d.object(forKey: Keys.labels) as? Bool ?? true
    }
}
