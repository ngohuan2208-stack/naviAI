import Foundation
import Combine

@MainActor
final class LANPairing: ObservableObject {

    static let shared = LANPairing()

    @Published private(set) var pin: String = ""
    @Published private(set) var pinExpiresAt: Date?

    @Published private(set) var isPaired = false

    private let pinLifetime: TimeInterval = 5 * 60

    enum Keys {
        static let pinHash = "lan.pairing.pinHash"
        static let pinExpiry = "lan.pairing.pinExpiry"
    }

    private init() {
        restore()
    }

    var pinRemainingText: String {
        guard let expires = pinExpiresAt else { return "No PIN" }
        let secs = Int(expires.timeIntervalSince(Date()))
        guard secs > 0 else { return "Expired" }
        return "Expires in \(secs / 60)m \(secs % 60)s"
    }

    func generatePIN() {
        let code = LANSecurity.randomPIN()
        pin = code
        pinExpiresAt = Date().addingTimeInterval(pinLifetime)
        UserDefaults.standard.set(LANSecurity.hash(code), forKey: Keys.pinHash)
        UserDefaults.standard.set(pinExpiresAt, forKey: Keys.pinExpiry)
    }

    func verify(_ candidate: String) -> Bool {
        guard let hash = UserDefaults.standard.string(forKey: Keys.pinHash) else { return false }
        guard let expires = UserDefaults.standard.object(forKey: Keys.pinExpiry) as? Date,
              expires > Date() else {
            pin = ""
            pinExpiresAt = nil
            return false
        }
        guard LANSecurity.constantTimeEquals(hash, LANSecurity.hash(candidate)) else { return false }
        isPaired = true

        rotateAfterPair()
        return true
    }

    func rotateAfterPair() {
        pin = ""
        pinExpiresAt = nil
        UserDefaults.standard.removeObject(forKey: Keys.pinHash)
        UserDefaults.standard.removeObject(forKey: Keys.pinExpiry)
    }

    private func restore() {
        if let expires = UserDefaults.standard.object(forKey: Keys.pinExpiry) as? Date,
           expires > Date() {
            pinExpiresAt = expires
            pin = "••••••"
        }
    }
}
