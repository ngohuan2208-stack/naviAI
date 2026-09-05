import SwiftUI

@main
struct NaviAIApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    var settings: SettingsStore
    let providers: ProviderStore
    let browser: BrowserStore
    let automation: AutomationScheduler

    init() {
        let settings = SettingsStore()
        let providers = ProviderStore()
        self.settings = settings
        self.providers = providers
        self.browser = BrowserStore(settings: settings, providers: providers)
        self.automation = AutomationScheduler(browser: browser)

        // Dependency injection for the image pipeline: the active provider and
        // its Keychain key are resolved through the existing stores.
        ImagePipeline.shared.activeProvider = { [weak providers] in providers?.activeProvider }
        ImagePipeline.shared.apiKeyFor = { [weak providers] config in
            providers?.apiKey(for: config)
        }

        // LLM-backed conversation summarizer (graceful fallback inside the
        // store when no provider is configured).
        let llm = LLMService()
        ConversationStore.shared.summarizer = { [weak providers] text in
            guard let config = providers?.activeProvider,
                  let key = providers?.apiKey(for: config) else { return "" }
            let system = "Summarize the following conversation history into compact bullet points (max 200 words) preserving facts, decisions and open questions. Output only the summary."
            let reply = try? await llm.complete(config: config, apiKey: key,
                                                history: [.system(system), .userText(text)], tools: [])
            return reply?.text ?? ""
        }

        // Deep research drives the browser.
        DeepResearchEngine.shared.browser = browser
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var settingsTick = 0

    var body: some View {
        Group {
            if app.settings.onboarded {
                MainContainerView()
            } else {
                OnboardingRootView()
            }
        }
        .environmentObject(app.automation)
        .environmentObject(app.automation.engine)
        .preferredColorScheme(scheme)
        .tint(.accentColor)
        .onReceive(app.settings.objectWillChange) { _ in
            settingsTick += 1
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                AutomationNotification.shared.requestPermissionOnce()
                app.automation.restoreAfterBackground()
            case .background:
                // Persist task state / current step / progress so the run can
                // be offered for resume on the next launch (iOS background
                // limits mean the run itself cannot continue unbounded).
                app.automation.persistForBackground()
            default:
                break
            }
        }
    }

    private var scheme: ColorScheme? {
        _ = settingsTick
        switch app.settings.appearance {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
}

struct MainContainerView: View {
    var body: some View {
        BrowserHomeView()
            // Confirmation alerts + resume prompt + floating task card live
            // above the browser; purely functional, never decorative.
            .overlay {
                AutomationOverlays()
            }
    }
}
