import Foundation

// MARK: - Versioned LAN protocol

/// The LAN wire protocol between Navi (server) and remote web clients.
///
/// Every message is a JSON object envelope:
///   { "p": protocolVersion, "t": type, "s": seq, "ts": timestamp, "d": payload }
///
/// The protocol is versioned so incompatible clients are rejected at handshake
/// instead of breaking at runtime. Payloads are capped on both directions.
enum LANProtocol {

    /// Bumped when the wire format or state schema changes incompatibly.
    static let protocolVersion = 2

    /// Hard caps (defence in depth — prevents memory blow-up from a malicious
    /// or buggy client).
    static let maxInboundMessageBytes = 128 * 1024
    static let maxOutboundMessageBytes = 1 * 1024 * 1024
    static let maxHTTPBodyBytes = 256 * 1024

    // Outbound event types (server → client).
    enum EventType {
        static let state = "state"                 // full or incremental state
        static let stateRestore = "state.restore"  // full sync after (re)connect
        static let activity = "activity"           // new activity feed item
        static let error = "error"
        static let pong = "pong"
    }

    // Inbound command types (client → server).
    enum CommandType {
        static let ping = "ping"
        static let command = "command"             // execute a browser command
        static let subscribe = "subscribe"         // change event subscription
    }

    // MARK: Envelope

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

    /// Validate protocol version in the envelope (nil = intolerant).
    static func checkVersion(_ data: Data) -> Bool {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return (obj["p"] as? Int) == protocolVersion
    }
}

// MARK: - Errors

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