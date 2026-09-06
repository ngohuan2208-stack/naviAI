import Foundation
import CryptoKit
import Security

enum LANSecurity {

    private static let tokenAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {

            return UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func randomPIN() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { return "246813" }
        let value = bytes.reduce(0) { ($0 << 8) | Int($1) }
        return String(format: "%06d", value % 1_000_000)
    }

    static func hash(_ token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func isValidToken(_ token: String) -> Bool {
        guard token.count >= 16, token.count <= 128 else { return false }
        return token.unicodeScalars.allSatisfy { tokenAllowed.contains($0) }
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ad = a.data(using: .utf8) ?? Data()
        let bd = b.data(using: .utf8) ?? Data()
        guard ad.count == bd.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ad.count {
            diff |= ad[i] ^ bd[i]
        }
        return diff == 0
    }
}

@MainActor
final class LANRateLimiter {

    static let shared = LANRateLimiter()

    private struct Bucket {
        var count: Int
        var resetAt: Date
    }

    private var buckets: [String: Bucket] = [:]

    private init() {}

    func allow(key: String, maxPerWindow: Int = 20, window: TimeInterval = 60) -> Bool {
        let now = Date()
        var bucket = buckets[key] ?? Bucket(count: 0, resetAt: now.addingTimeInterval(window))
        if now >= bucket.resetAt {
            bucket = Bucket(count: 0, resetAt: now.addingTimeInterval(window))
        }
        guard bucket.count < maxPerWindow else {
            buckets[key] = bucket
            return false
        }
        bucket.count += 1
        buckets[key] = bucket
        if buckets.count > 256 {

            buckets = buckets.filter { $0.value.resetAt > now }
        }
        return true
    }

    func reset() {
        buckets.removeAll()
    }
}
