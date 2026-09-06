import Foundation

enum LANProtocol {

    static let protocolVersion = 2

    static let maxInboundMessageBytes = 128 * 1024
    static let maxOutboundMessageBytes = 1 * 1024 * 1024
    static let maxHTTPBodyBytes = 256 * 1024

    enum EventType {
        static let state = "state"
        static let stateRestore = "state.restore"
        static let activity = "activity"
        static let error = "error"
        static let pong = "pong"
    }

    enum CommandType {
        static let ping = "ping"
        static let command = "command"
        static let subscribe = "subscribe"
    }

    struct Message {
        var type: String
        var payload: [String: Any] = [:]
        var seq: Int = 0
    }

    static func encode(type: String, payload: [String: Any], seq: Int = 0) -> Data? {
        var obj: [String: Any] = [
            "p": protocolVersion,
            "t": type,
            "ts": Date().timeIntervalSince1970
        ]
        if seq > 0 { obj["s"] = seq }
        obj["d"] = payload
        guard JSONSerialization.isValidJSONObject(obj) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        guard data.count <= maxOutboundMessageBytes else { return nil }
        return data
    }

    static func decode(_ data: Data) -> Message? {
        guard data.count <= maxInboundMessageBytes else { return nil }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        guard let type = obj["t"] as? String else { return nil }
        let payload = (obj["d"] as? [String: Any]) ?? [:]
        let seq = (obj["s"] as? Int) ?? 0
        return Message(type: type, payload: payload, seq: seq)
    }

    static func checkVersion(_ data: Data) -> Bool {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return (obj["p"] as? Int) == protocolVersion
    }
}

enum LANError: LocalizedError {
    case serverStopped
    case badRequest
    case requestTooLarge
    case unauthorized
    case pairingExpired
    case connectionReset
    case notFound
    case methodNotAllowed
    case rateLimited
    case websocketFailed(String)

    var errorDescription: String? {
        switch self {
        case .serverStopped: return "LAN server is not running."
        case .badRequest: return "Bad request."
        case .requestTooLarge: return "Request is too large."
        case .unauthorized: return "Unauthorized. Pair Navi and reconnect."
        case .pairingExpired: return "Pairing code expired. Ask the phone to generate a new one."
        case .connectionReset: return "Connection reset."
        case .notFound: return "Not found."
        case .methodNotAllowed: return "Method not allowed."
        case .rateLimited: return "Too many requests. Slow down."
        case .websocketFailed(let m): return "WebSocket failed: \(m)"
        }
    }
}
