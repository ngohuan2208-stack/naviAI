import Foundation
import Combine

// MARK: - Persisted session token

/// A revocable LAN session. Only the token *hash* is persisted; the raw token
/// lives in the client and in the in-memory registry.
struct StoredLANToken: Codable, Equatable {
    var tokenHash: String
    var deviceID: UUID
    var deviceName: String
    var createdAt: Date
    var lastSeen: Date
}

// MARK: - Connected LAN session

/// One live client connection. Identity is persistent: a returning client that
/// reconnects with the same token resumes the same session (no re-pairing).
@MainActor
final class LANSession: ObservableObject, Identifiable {

    let id: UUID
    var tokenHash: String
    var deviceName: String
    var platform: String
    var canControl: Bool

    @Published var isConnected: Bool
    var socket: LANWebSocket?
    var seq: Int = 0
    var lastSeen: Date = Date()

    init(id: UUID = UUID(),
         tokenHash: String,
         deviceName: String,
         platform: String = "web",
         canControl: Bool = true,
         isConnected: Bool = true) {
        self.id = id
        self.tokenHash = tokenHash
        self.deviceName = deviceName
        self.platform = platform
        self.canControl = canControl
        self.isConnected = isConnected
    }
}

// MARK: - Device registry (paired + online)

/// Registry of paired devices and their online/offline presence. Persisted so
/// a temporary disconnect is never a re-pairing event.
@MainActor
final class LANDeviceRegistry: ObservableObject {

    static let shared = LANDeviceRegistry()

    @Published private(set) var devices: [StoredLANToken] = []

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let tokens = "lan.devices.tokens.v1"
    }

    private init() {
        if let data = defaults.data(forKey: Keys.tokens),
           let list = try? JSONDecoder().decode([StoredLANToken].self, from: data) {
            devices = list
        }
    }

    /// Upsert a token record (existing device updated, new device added).
    @discardableResult
    func register(token: String, deviceName: String, platform: String = "web") -> StoredLANToken {
        let deviceID = UUID()
        let record = StoredLANToken(tokenHash: LANSecurity.hash(token),
                                    deviceID: deviceID,
                                    deviceName: deviceName,
                                    createdAt: Date(),
                                    lastSeen: Date())
        if let idx = devices.firstIndex(where: { $0.tokenHash == record.tokenHash }) {
            devices[idx] = record
        } else {
            devices.append(record)
            if devices.count > 16 {
                devices.removeFirst(devices.count - 16)
            }
        }
        persist()
        return record
    }

    func touch(_ token: String) {
        let hash = LANSecurity.hash(token)
        if let idx = devices.firstIndex(where: { $0.tokenHash == hash }) {
            devices[idx].lastSeen = Date()
            persist()
        }
    }

    func find(hash: String) -> StoredLANToken? {
        devices.first { $0.tokenHash == hash }
    }

    /// True when the token is known and inside its validity window.
    func isValid(token: String) -> Bool {
        guard LANSecurity.isValidToken(token) else { return false }
        let hash = LANSecurity.hash(token)
        guard let record = find(hash: hash) else {
            // Unknown token — reject (no replay of old tokens after revoke).
            return false
        }
        // Sessions do not expire on their own; revocation is explicit.
        return record.tokenHash == hash
    }

    func revoke(_ tokenHash: String) {
        devices.removeAll { $0.tokenHash == tokenHash }
        persist()
    }

    func revokeAll() {
        devices.removeAll()
        persist()
    }

    func clearAll() {
        revokeAll()
        UserDefaults.standard.removeObject(forKey: Keys.tokens)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(devices) {
            defaults.set(data, forKey: Keys.tokens)
        }
    }
}