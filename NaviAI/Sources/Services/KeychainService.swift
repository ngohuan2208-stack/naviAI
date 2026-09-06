import Foundation
import Security

enum KeychainService {
    private static let serviceName = "com.naviai.app.keys"
    private static let accessGroup: String? = nil

    static func save(key: String, account: String) throws {
        let data = Data(key.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(baseQuery as CFDictionary)

        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.osStatus(status)
        }
    }

    static func read(account: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    static func wipeAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum KeychainError: Error {
    case osStatus(OSStatus)
}
