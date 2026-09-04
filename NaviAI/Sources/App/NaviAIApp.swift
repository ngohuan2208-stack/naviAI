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

    init() {
        let settings = SettingsStore()
        let providers = ProviderStore()
        self.settings = settings
        self.providers = providers
        self.browser = BrowserStore(settings: settings, providers: providers)
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppModel
    @State private var settingsTick = 0

    var body: some View {
        Group {
            if app.settings.onboarded {
                MainContainerView()
            } else {
                OnboardingRootView()
            }
        }
        .preferredColorScheme(scheme)
        .tint(.accentColor)
        .onReceive(app.settings.objectWillChange) { _ in
            settingsTick += 1
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
    }
}
