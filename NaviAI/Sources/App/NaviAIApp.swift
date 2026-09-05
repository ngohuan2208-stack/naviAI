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
