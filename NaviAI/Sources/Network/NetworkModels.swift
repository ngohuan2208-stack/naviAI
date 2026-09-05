import Foundation

// MARK: - Proxy profile

/// A user-defined proxy configuration. Credentials are NEVER persisted in this
/// struct — they live in the iOS Keychain (see ProxyManager.keychainAccount).
struct ProxyProfile: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case http, https, socks5
        var id: String { rawValue }
        var label: String {
            switch self {
            case .http: return "HTTP"
            case .https: return "HTTPS"
            case .socks5: return "SOCKS5"
            }
        }
    }

    var id: UUID = UUID()
    var name: String
    var host: String
    var port: Int
    var kind: Kind = .http
    /// Username is stored here (not secret); password goes to the Keychain.
    var username: String = ""

    var displayEndpoint: String { "\(kind.rawValue)://\(host):\(port)" }

    /// Serialized form used for the import/pool text area: "name|kind|host|port|user".
    var poolLine: String { [name, kind.rawValue, host, String(port), username].joined(separator: "|") }

    static func parse(line: String) -> ProxyProfile? {
        let parts = line.split(separator: "|").map(String.init)
        guard parts.count >= 3 else { return nil }
        let name = parts[0]
        let kind = Kind(rawValue: parts[1]) ?? .http
        let host = parts[2]
        let port = parts.count > 3 ? Int(parts[3]) ?? 0 : 0
        let user = parts.count > 4 ? parts[4] : ""
        guard !name.isEmpty, !host.isEmpty, port > 0, port <= 65535 else { return nil }
        return ProxyProfile(name: name, host: host, port: port, kind: kind, username: user)
    }
}

// MARK: - Rotation policy

enum ProxyRotationMode: String, Codable, CaseIterable, Identifiable {
    case manual            // stick to the selected profile
    case roundRobin        // cycle the pool in order
    case random            // random pick on every switch
    case rotateAfterTask   // advance when a task/run finishes
    case rotateOnFailure   // advance only after a connection failure
    case timedInterval     // advance every N seconds

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manual: return "Manual"
        case .roundRobin: return "Round Robin"
        case .random: return "Random"
        case .rotateAfterTask: return "Rotate after task"
        case .rotateOnFailure: return "Rotate on failure"
        case .timedInterval: return "Timed interval"
        }
    }
}

// MARK: - Proxy pool

/// Ordered pool of proxy profiles with rotation. Persisted via ProxyManager.
@MainActor
final class ProxyPool: ObservableObject {
    @Published var profiles: [ProxyProfile] = []
    @Published var rotation: ProxyRotationMode = .manual
    @Published var rotationIntervalSeconds: Int = 300
    @Published private(set) var current: ProxyProfile?

    private var rotationTimer: Timer?
    private var roundRobinIndex = 0

    // MARK: Pool management

    func setProfiles(_ list: [ProxyProfile]) {
        profiles = list
        if current == nil {
            current = list.first
        }
    }

    func add(_ profile: ProxyProfile) {
        profiles.append(profile)
        if current == nil { current = profile }
    }

    func remove(at offsets: IndexSet) {
        let removedIDs = offsets.map { profiles[$0].id }
        profiles.remove(atOffsets: offsets)
        if let cur = current, removedIDs.contains(cur.id) {
            current = profiles.first
        }
    }

    func select(id: UUID) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        current = profiles[idx]
        roundRobinIndex = idx
    }

    // MARK: Rotation

    func advance(force: Bool = false) {
        guard !profiles.isEmpty else { return }
        guard profiles.count > 1 || force else { return }
        roundRobinIndex = (roundRobinIndex + 1) % profiles.count
        current = profiles[roundRobinIndex]
    }

    /// Random rotation, used by the .random mode.
    func advanceRandom() {
        guard profiles.count > 1 else { return }
        var idx = Int.random(in: 0..<profiles.count)
        if profiles[idx].id == current?.id {
            idx = (idx + 1) % profiles.count
        }
        roundRobinIndex = idx
        current = profiles[idx]
    }

    /// Starts the timer for timed/random rotation (called on launch/persist).
    func startTimedRotation() {
        stopTimedRotation()
        guard rotation == .timedInterval || rotation == .random else { return }
        let seconds = TimeInterval(max(30, rotationIntervalSeconds))
        rotationTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                switch self.rotation {
                case .timedInterval:
                    self.advance()
                case .random:
                    self.advanceRandom()
                default:
                    break
                }
            }
        }
    }

    func stopTimedRotation() {
        rotationTimer?.invalidate()
        rotationTimer = nil
    }
}


/// The full, persisted network configuration.
struct NetworkSettingsSnapshot: Codable, Equatable {
    var profiles: [ProxyProfile] = []
    var poolOrder: [UUID] = []
    var rotation: ProxyRotationMode = .manual
    var rotationIntervalSeconds: Int = 300
    var activeProfileID: UUID?
    var proxyEnabled = false
}

enum NetworkPathKind: String {
    case none, wifi, cellular, wired, loopback, other
}

// MARK: - Network status snapshot

struct NetworkStatusSnapshot: Equatable {
    var internet: Bool = false
    var interface: NetworkPathKind = .none
    var expensive: Bool = false      // cellular / hotspot
    var constrained: Bool = false    // Low Data Mode
    var proxyActive: Bool = false
    var vpnActive: Bool = false
    var dnsResolves: Bool = false
    var latencyMS: Int?
}
