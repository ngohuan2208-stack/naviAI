import Foundation

enum Redactor {

    private static let sensitiveKeys: Set<String> = [
        "password", "pass", "pwd", "secret", "token", "access_token",
        "refresh_token", "id_token", "api_key", "apikey", "authorization",
        "proxy-authorization", "auth", "session", "sessionid", "phpsessid",
        "cookie", "set-cookie", "x-api-key", "x-auth-token", "x-csrf-token",
        "csrf", "client_secret", "private_key", "credential", "credentials"
    ]

    private static let sensitiveQueryKeys: Set<String> = [
        "token", "access_token", "refresh_token", "apikey", "api_key",
        "key", "password", "secret", "auth", "sessionid", "sid", "sig"
    ]

    private static let mask = "••••••"

    private static let jwtPattern = "eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{4,}"

    private static let bearerPattern = "(?i)(bearer|basic)[ ]+[A-Za-z0-9._~+/=-]{12,}"

    private static let hexPattern = "\\b[a-fA-F0-9]{24,}\\b"

    static func redact(key: String, value: String) -> String {
        guard isSensitiveKey(key) else { return value }
        return mask
    }

    static func isSensitiveKey(_ key: String) -> Bool {
        let lowered = key.lowercased().trimmingCharacters(in: .whitespaces)
        return sensitiveKeys.contains(lowered)
            || lowered.contains("password")
            || lowered.contains("token")
            || lowered.contains("secret")
            || lowered.contains("cookie")
    }

    static func redactURL(_ url: URL) -> String {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        if let items = comps.queryItems {
            comps.queryItems = items.map { item in
                isSensitiveKey(item.name)
                    ? URLQueryItem(name: item.name, value: mask)
                    : item
            }
        }
        return comps.string ?? url.absoluteString
    }

    static func redactHeaders(_ headers: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in headers {
            out[key] = redact(key: key, value: value)
        }
        return out
    }

    static func redactBody(_ body: String, maxLen: Int = 2000) -> String {
        var text = body
        text = text.replacingOccurrences(of: jwtPattern, with: mask, options: .regularExpression)
        text = text.replacingOccurrences(of: bearerPattern, with: mask, options: .regularExpression)
        text = text.replacingOccurrences(of: hexPattern, with: mask, options: .regularExpression)

        text = text.replacingOccurrences(
            of: "(?i)(\"(?:password|pass|secret|token|api[_-]?key|authorization)\"\\s*:\\s*\")([^\"]*)(\")",
            with: "$1\(mask)$3",
            options: .regularExpression)
        if text.count > maxLen {
            text = String(text.prefix(maxLen)) + "… [truncated \(body.count - maxLen) chars]"
        }
        return text
    }

    static func redactText(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: jwtPattern, with: mask, options: .regularExpression)
        t = t.replacingOccurrences(of: bearerPattern, with: mask, options: .regularExpression)
        t = t.replacingOccurrences(of: hexPattern, with: mask, options: .regularExpression)
        return t
    }

    static func redactRequest(url: URL?, headers: [String: String]?, body: String?) ->
        (url: String, headers: [String: String], body: String) {
        let u = url.map { redactURL($0) } ?? "—"
        let h = headers.map { redactHeaders($0) } ?? [:]
        let b = body.map { redactBody($0) } ?? ""
        return (u, h, b)
    }
}
