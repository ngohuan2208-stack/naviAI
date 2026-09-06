import Foundation
import Combine

// MARK: - Pairing

/// Deviceless PIN pairing. Navi shows a 6-digit code that expires after a few
/// minutes; the remote client enters it once and receives a revocable session
/// token. PINs are stored hashed only.
@MainActor
final class LANPairing: ObservableObject {

    static let shared = LANPairing()

    @Published private(set) var pin: String = ""
    @Published private(set) var pinExpiresAt: Date?

    @Published private(set) var isPaired = false

    /// 5 minutes is plenty of time to type a 6-digit PIN.
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

    /// Generate a fresh PIN (invalidates the previous one).
    func generatePIN() {
        let code = LANSecurity.randomPIN()
        pin = code
        pinExpiresAt = Date().addingTimeInterval(pinLifetime)
        UserDefaults.standard.set(LANSecurity.hash(code), forKey: Keys.pinHash)
        UserDefaults.standard.set(pinExpiresAt, forKey: Keys.pinExpiry)
    }

    /// Validate a client-submitted PIN. Consumes one failed attempt via the
    /// caller's rate limiter. On success pairing state flips and the server
    /// issues a token.
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
        // One-time use: rotation after a successful pair keeps replay useless.
        rotateAfterPair()
        return true
    }

    /// Invalidate the current PIN.
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