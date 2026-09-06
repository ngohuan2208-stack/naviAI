import Foundation
import Combine

@MainActor
final class ProviderStore: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published private(set) var providers: [ProviderConfig] {
        didSet { persist() }
    }
    @Published var activeProviderID: UUID? {
        didSet {
            if let id = activeProviderID {
                defaults.set(id.uuidString, forKey: Keys.active)
            } else {
                defaults.removeObject(forKey: Keys.active)
            }
        }
    }

    @Published var cachedModels: [String: [String]] = [:] {
        didSet { persistCachedModels() }
    }

    @Published var modelFetchErrors: [String: String] = [:]

    private enum Keys {
        static let list = "providers.v1"
        static let active = "providers.active"
        static let cachedPrefix = "providers.models."
    }

    init() {
        if let data = defaults.data(forKey: Keys.list),
           let decoded = try? JSONDecoder().decode([ProviderConfig].self, from: data) {
            self.providers = decoded
        } else {
            self.providers = Self.defaultProviders()
            persist()
        }
        if let idString = defaults.string(forKey: Keys.active),
           let id = UUID(uuidString: idString),
           self.providers.contains(where: { $0.id == id }) {
            self.activeProviderID = id
        } else {
            self.activeProviderID = self.providers.first?.id
        }
        loadCachedModels()
    }

    var activeProvider: ProviderConfig? {
        providers.first { $0.id == activeProviderID }
    }

    func select(_ config: ProviderConfig) {
        activeProviderID = config.id
    }

    func upsert(_ config: ProviderConfig) {
        if let idx = providers.firstIndex(where: { $0.id == config.id }) {
            providers[idx] = config
        } else {
            providers.append(config)
        }
        if activeProviderID == nil { activeProviderID = config.id }
    }

    @discardableResult
    func remove(_ config: ProviderConfig) -> Bool {
        guard let idx = providers.firstIndex(where: { $0.id == config.id }) else { return false }
        providers.remove(at: idx)
        KeychainService.delete(account: config.apiKeyAccount)
        if activeProviderID == config.id {
            activeProviderID = providers.first?.id
        }
        return true
    }

    func makeProvider(of kind: AIProviderKind) -> ProviderConfig {
        let config = ProviderConfig(kind: kind)
        upsert(config)
        return config
    }

    func apiKey(for config: ProviderConfig) -> String? {
        KeychainService.read(account: config.apiKeyAccount)
    }

    func setAPIKey(_ key: String, for config: ProviderConfig) {
        do {
            try KeychainService.save(key: key, account: config.apiKeyAccount)
        } catch {
            NSLog("Keychain save failed: \(error.localizedDescription)")
        }
    }

    func hasKey(for config: ProviderConfig) -> Bool {
        apiKey(for: config)?.isEmpty == false
    }

    var availableModels: [String] {
        guard let id = activeProviderID else { return [] }
        return cachedModels[id.uuidString] ?? []
    }

    func cachedModels(for config: ProviderConfig) -> [String] {
        cachedModels[config.id.uuidString] ?? []
    }

    func applyModels(_ models: [String], for config: ProviderConfig) {
        cachedModels[config.id.uuidString] = models
    }

    func fetchModelIDs(for config: ProviderConfig, apiKeyOverride: String? = nil) async -> Result<[String], AIError> {
        guard config.kind.supportsModelListing else {
            return .failure(.providerError("This provider does not offer a public model listing. Enter the model ID manually."))
        }
        let key = apiKeyOverride ?? apiKey(for: config)
        guard let key, !key.isEmpty else {
            return .failure(.missingAPIKey)
        }
        guard let url = Self.modelsURL(for: config) else {
            return .failure(.invalidBaseURL)
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            if config.kind == .gemini && url.absoluteString.contains("key=") == false {
                var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                var items = comps?.queryItems ?? []
                items.append(URLQueryItem(name: "key", value: key))
                comps?.queryItems = items
                guard let finalURL = comps?.url else { return .failure(.invalidBaseURL) }
                request.url = finalURL
            } else {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.network(URLError(.badServerResponse)))
            }
            guard http.statusCode == 200 else {
                return .failure(Self.mapStatus(http.statusCode))
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(.providerError("Unexpected model list response."))
            }
            if let arr = json["data"] as? [[String: Any]] {
                let ids = arr.compactMap { $0["id"] as? String }.sorted()
                return .success(ids)
            }
            if let ids = json["models"] as? [String] {
                return .success(ids.sorted())
            }
            return .failure(.providerError("Could not parse the provider model list."))
        } catch let e as AIError {
            return .failure(e)
        } catch {
            return .failure(.network(error))
        }
    }

    static func modelsURL(for config: ProviderConfig) -> URL? {
        guard !config.baseURL.isEmpty else { return nil }
        var base = config.baseURL
        while base.hasSuffix("/") { base.removeLast() }
        switch config.kind {
        case .gemini:

            return URL(string: base + "/models")
        case .openAI, .deepseek, .chatGPT, .openRouter:
            return URL(string: base + "/models")
        case .claude:
            return nil
        case .custom:

            return URL(string: base + "/models")
        }
    }

    static func mapStatus(_ code: Int) -> AIError {
        switch code {
        case 401, 403: return .invalidAPIKey
        case 404: return .modelUnavailable
        default: return .providerError("HTTP \(code)")
        }
    }

    static func defaultProviders() -> [ProviderConfig] {
        var list = AIProviderKind.allCases
            .filter { $0 != .custom }
            .map { ProviderConfig(kind: $0) }

        list = list.map { p in
            var copy = p
            copy.supportsVision = p.kind == .openAI || p.kind == .claude || p.kind == .gemini
            return copy
        }
        return list
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(providers) {
            defaults.set(data, forKey: Keys.list)
        }
    }

    private func loadCachedModels() {
        var map: [String: [String]] = [:]
        for config in providers {
            let k = Keys.cachedPrefix + config.id.uuidString
            if let arr = defaults.stringArray(forKey: k) {
                map[config.id.uuidString] = arr
            }
        }
        cachedModels = map
    }

    private func persistCachedModels() {
        for (idString, models) in cachedModels {
            defaults.set(models, forKey: Keys.cachedPrefix + idString)
        }
    }
}
