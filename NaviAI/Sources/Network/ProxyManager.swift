import Foundation
import Network
import Security

// MARK: - Proxy manager

/// Owns proxy configuration. On iOS, WKWebView traffic cannot be redirected
/// through a user-configured proxy with public API; URLSession CAN, via the
/// `connectionProxyDictionary` on `URLSessionConfiguration`.
///
/// Scope (documented honestly):
///  • AI provider calls (LLMService / ImagePipeline / ProviderStore) — full
///    proxy support through the shared URLSession configuration.
///  • WKWebView page traffic — NOT proxied (WebKit ignores app-level proxy
///    settings on iOS). The UI states this limitation instead of pretending.
@MainActor
final class ProxyManager: ObservableObject {
    static let shared = ProxyManager()

    @Published var enabled = false
    @Published private(set) var lastSwitchAt: Date?
    @Published private(set) var lastTestResult: TestResult?

    struct TestResult: Equatable {
        var success: Bool
        var latencyMS: Int?
        var message: String
    }

    let pool = ProxyPool()
    private let defaults = UserDefaults.standard
    private let keychainPrefix = "navi.proxy."

    private enum Keys {
        static let snapshot = "network.proxy.snapshot.v1"
    }

    private init() {
        load()
    }

    // MARK: Persistence (profiles WITHOUT secrets + rotation prefs)

    private func load() {
        guard let data = defaults.data(forKey: Keys.snapshot),
              let snap = try? JSONDecoder().decode(NetworkSettingsSnapshot.self, from: data) else { return }
        enabled = snap.proxyEnabled
        pool.rotation = snap.rotation
        pool.rotationIntervalSeconds = snap.rotationIntervalSeconds
        pool.setProfiles(snap.profiles)
        if let active = snap.activeProfileID {
            pool.select(id: active)
        }
    }

    func persist() {
        let snap = NetworkSettingsSnapshot(
            profiles: pool.profiles,
            poolOrder: pool.profiles.map(\.id),
            rotation: pool.rotation,
            rotationIntervalSeconds: pool.rotationIntervalSeconds,
            activeProfileID: pool.current?.id,
            proxyEnabled: enabled
        )
        if let data = try? JSONEncoder().encode(snap) {
            defaults.set(data, forKey: Keys.snapshot)
        }
        if pool.rotation == .timedInterval, enabled {
            pool.startTimedRotation()
        } else {
            pool.stopTimedRotation()
        }
    }

    // MARK: Keychain credential storage

    private func account(for id: UUID) -> String { keychainPrefix + id.uuidString }

    func setPassword(_ password: String, for profile: ProxyProfile) {
        guard !password.isEmpty else {
            KeychainService.delete(account: account(for: profile.id))
            return
        }
        try? KeychainService.save(key: password, account: account(for: profile.id))
    }

    func password(for profile: ProxyProfile) -> String {
        KeychainService.read(account: account(for: profile.id)) ?? ""
    }

    func deleteCredentials(for profile: ProxyProfile) {
        KeychainService.delete(account: account(for: profile.id))
    }

// MARK: - Connection proxy dictionary (the ONLY official mechanism)

extension ProxyManager {

    /// Builds the connectionProxyDictionary for a profile, or nil when proxy
    /// is disabled. Used by NetworkManager for all app-level HTTP traffic.
    func connectionProxyDictionary() -> [AnyHashable: Any]? {
        guard enabled, let proxy = pool.current else { return nil }
        return Self.dictionary(for: proxy)
    }

    static func dictionary(for proxy: ProxyProfile) -> [AnyHashable: Any] {
        var dict: [AnyHashable: Any] = [:]
        switch proxy.kind {
        case .http, .https:
            dict[kCFNetworkProxiesHTTPProxy as String] = proxy.host
            dict[kCFNetworkProxiesHTTPPort as String] = proxy.port
            dict[kCFNetworkProxiesHTTPSProxy as String] = proxy.host
            dict[kCFNetworkProxiesHTTPSPort as String] = proxy.port
        case .socks5:
            dict[kCFStreamPropertySOCKSProxyHost as String] = proxy.host
            dict[kCFStreamPropertySOCKSProxyPort as String] = proxy.port
        }
        return dict
    }

    // MARK: Rotation triggers

    func notifyTaskFinished(success: Bool) {
        guard enabled else { return }
        if pool.rotation == .rotateAfterTask || (pool.rotation == .rotateOnFailure && !success) {
            pool.advance()
            lastSwitchAt = Date()
            persist()
        }
    }

    func rotateNow() {
        pool.advance(force: true)
        lastSwitchAt = Date()
        persist()
    }

    // MARK: Test connection

    /// Tests a profile and stores the outcome for the UI.
    @discardableResult
    func testAndRecord(profile: ProxyProfile) async -> TestResult {
        let result = await test(profile: profile)
        lastTestResult = result
        return result
    }

    /// Tests a profile by fetching https://www.gstatic.com/generate_204 through
    /// a temporary session using the profile's proxy dictionary. Credentials
    /// come from the Keychain.
    func test(profile: ProxyProfile) async -> TestResult {
        var dict = Self.dictionary(for: profile)
        if !profile.username.isEmpty {
            let pass = password(for: profile)
            let credential = URLCredential(user: profile.username, password: pass, persistence: .forSession)
            dict[kCFNetworkProxiesHTTPEnable as String] = true
            URLCredentialStorage.shared.setDefaultCredential(credential, for: URLProtectionSpace(
                host: profile.host, port: profile.port, protocol: nil, realm: nil, authenticationMethod: nil))
        }

        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = dict
        config.timeoutIntervalForRequest = 12
        let session = URLSession(configuration: config)

        let start = Date()
        do {
            guard let url = URL(string: "https://www.gstatic.com/generate_204") else {
                return TestResult(success: false, latencyMS: nil, message: "Invalid test URL")
            }
            let (_, response) = try await session.data(from: url)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ok = (200..<300).contains(code) || code == 204
            return TestResult(success: ok,
                              latencyMS: ok ? ms : nil,
                              message: ok ? "Connected via \(profile.displayEndpoint) (\(ms) ms)" : "Unexpected status \(code)")
        } catch {
            return TestResult(success: false, latencyMS: nil,
                              message: "Failed: \(error.localizedDescription)")
        }
    }
}
}