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

    @Published var automationNotificationsEnabled: Bool { didSet { defaults.set(automationNotificationsEnabled, forKey: Keys.automationNotifications) } }
    @Published var automationDefaultPolicy: ConfirmationPolicy { didSet { defaults.set(automationDefaultPolicy.rawValue, forKey: Keys.automationPolicy) } }
    @Published var floatingStatusEnabled: Bool { didSet { defaults.set(floatingStatusEnabled, forKey: Keys.floatingStatus) } }

    @Published var agentWatchdogEnabled: Bool { didSet { defaults.set(agentWatchdogEnabled, forKey: Keys.watchdog) } }
    @Published var agentMaxContinuousSteps: Int { didSet { defaults.set(agentMaxContinuousSteps, forKey: Keys.maxSteps) } }

    @Published var screenshotMaxWidth: Int { didSet { defaults.set(screenshotMaxWidth, forKey: Keys.screenshotWidth) } }
    @Published var screenshotMinInterval: Double { didSet { defaults.set(screenshotMinInterval, forKey: Keys.screenshotInterval) } }

    @Published var lanEnabled: Bool { didSet { defaults.set(lanEnabled, forKey: Keys.lanEnabled) } }
    @Published var lanAllowObserve: Bool { didSet { defaults.set(lanAllowObserve, forKey: Keys.lanObserve) } }
    @Published var lanAllowControl: Bool { didSet { defaults.set(lanAllowControl, forKey: Keys.lanControl) } }

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
        static let automationNotifications = "settings.automationNotifications"
        static let automationPolicy = "settings.automationPolicy"
        static let floatingStatus = "settings.floatingStatus"
        static let watchdog = "agent.watchdogEnabled"
        static let maxSteps = "agent.maxContinuousSteps"
        static let screenshotWidth = "agent.screenshotMaxWidth"
        static let screenshotInterval = "agent.screenshotMinInterval"
        static let lanEnabled = "lan.enabled"
        static let lanObserve = "lan.allowObserve"
        static let lanControl = "lan.allowControl"
    }

    init() {
        let d = UserDefaults.standard
        self.onboarded = d.object(forKey: Keys.onboarded) as? Bool ?? false
        self.appearance = AppearanceMode(rawValue: d.string(forKey: Keys.appearance) ?? "") ?? .system
        self.searchEngine = SearchEngine(rawValue: d.string(forKey: Keys.searchEngine) ?? "") ?? .duckduckgo
        self.aiCursorEnabled = d.object(forKey: Keys.cursor) as? Bool ?? true
        self.cursorAnimationsEnabled = d.object(forKey: Keys.cursorAnimations) as? Bool ?? true
        self.aiConfirmationEnabled = d.object(forKey: Keys.confirm) as? Bool ?? true
        self.visionFallbackEnabled = d.object(forKey: Keys.vision) as? Bool ?? true
        self.desktopModeEnabled = d.object(forKey: Keys.desktopMode) as? Bool ?? false
        self.autoScrollEnabled = d.object(forKey: Keys.autoScroll) as? Bool ?? true
        self.showAgentLabelsEnabled = d.object(forKey: Keys.labels) as? Bool ?? true
        self.automationNotificationsEnabled = d.object(forKey: Keys.automationNotifications) as? Bool ?? true
        self.automationDefaultPolicy = ConfirmationPolicy(rawValue: d.string(forKey: Keys.automationPolicy) ?? "") ?? .riskyActions
        self.floatingStatusEnabled = d.object(forKey: Keys.floatingStatus) as? Bool ?? true
        self.agentWatchdogEnabled = d.object(forKey: Keys.watchdog) as? Bool ?? true
        self.agentMaxContinuousSteps = d.object(forKey: Keys.maxSteps) as? Int ?? 80
        self.screenshotMaxWidth = d.object(forKey: Keys.screenshotWidth) as? Int ?? 1280
        self.screenshotMinInterval = d.object(forKey: Keys.screenshotInterval) as? Double ?? 2.5
        self.lanEnabled = d.object(forKey: Keys.lanEnabled) as? Bool ?? false
        self.lanAllowObserve = d.object(forKey: Keys.lanObserve) as? Bool ?? true
        self.lanAllowControl = d.object(forKey: Keys.lanControl) as? Bool ?? true
    }
}
