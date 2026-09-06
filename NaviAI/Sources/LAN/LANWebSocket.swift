import Foundation
import Network
import CryptoKit

// MARK: - Server-side WebSocket (RFC 6455)

/// A minimal, correct server-side WebSocket over an already-upgraded raw TCP
/// `NWConnection`. Handles text/binary frames, continuation frames, ping/pong
/// keep-alive, close handshake and strict size limits. Server frames are
/// always unmasked (per spec); client frames are unmasked on read.
final class LANWebSocket {

    enum Opcode: UInt8 {
        case continuation = 0x0
        case text = 0x1
        case binary = 0x2
        case close = 0x8
        case ping = 0x9
        case pong = 0xA
    }

    static let maxMessageBytes = 1 * 1024 * 1024

    private let connection: NWConnection

    private var isClosed = false
    private var buffer = Data()
    private var fragmented: Data?
    private var fragmentedOpcode: UInt8 = LANWebSocket.Opcode.text.rawValue

    /// Received complete text messages.
    var onMessage: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onError: ((Error) -> Void)?

    init(connection: NWConnection, preloaded: Data = Data()) {
        self.connection = connection
        self.buffer = preloaded
    }

    func start() {
        // NOTE: the underlying connection is already started by the HTTP
        // server and its callbacks arrive on the server's queue. We must NOT
        // call `connection.start` again here.
        if !buffer.isEmpty { processBuffer() }
        receive()
    }

    // MARK: Sending

    func send(text: String) {
        guard let data = text.data(using: .utf8) else { return }
        sendFrame(opcode: Opcode.text.rawValue, payload: data)
    }

    func send(binary data: Data) {
        sendFrame(opcode: Opcode.binary.rawValue, payload: data)
    }

    func ping() {
        sendFrame(opcode: Opcode.ping.rawValue, payload: Data("n".utf8))
    }

    func close() {
        sendFrame(opcode: Opcode.close.rawValue, payload: Data([0x03, 0xE8]))
        teardown()
    }

    private func sendFrame(opcode: UInt8, payload: Data) {
        guard !isClosed else { return }
        var header = Data()
        let finBit: UInt8 = 0x80
        header.append(finBit | opcode)
        let len = payload.count
        if len < 126 {
            header.append(UInt8(len))
        } else if len <= 0xFFFF {
            header.append(126)
            header.append(UInt8((len >> 8) & 0xFF))
            header.append(UInt8(len & 0xFF))
        } else {
            header.append(127)
            var len64 = UInt64(len).bigEndian
            withUnsafeBytes(of: &len64) { raw in
                header.append(contentsOf: raw)
            }
        }
        var out = header
        out.append(payload)
        connection.send(content: out,
                        contentContext: .finalMessage,
                        isComplete: true,
                        completion: .contentProcessed { _ in })
// MARK: Receiving

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.processBuffer()
            }
            if isComplete {
                self.teardown()
                return
            }
            if let error {
                self.onError?(error)
                self.teardown()
                return
            }
            self.receive()
        }
    }

    private func processBuffer() {
        while let frame = tryParseFrame() {
            guard frame.payload.count <= Self.maxMessageBytes else {
                sendClose(1009)
                return
            }
            switch frame.opcode {
            case Opcode.pong.rawValue:
                continue
            case Opcode.ping.rawValue:
                sendFrame(opcode: Opcode.pong.rawValue, payload: frame.payload)
            case Opcode.close.rawValue:
                sendClose(1000)
                teardown()
                return
            case Opcode.text.rawValue, Opcode.binary.rawValue:
                fragmented = frame.payload
                fragmentedOpcode = frame.opcode
                if frame.fin {
                    let payload = fragmented ?? Data()
                    deliver(payload, opcode: frame.opcode)
                    fragmented = nil
                }
            case Opcode.continuation.rawValue:
                var acc = fragmented ?? Data()
                acc.append(frame.payload)
                if acc.count > Self.maxMessageBytes {
                    sendClose(1009)
                    return
                }
                fragmented = acc
                if frame.fin {
                    deliver(acc, opcode: fragmentedOpcode)
                    fragmented = nil
                }
            default:
                sendClose(1002)
                return
            }
        }
    }

    private func deliver(_ data: Data, opcode: UInt8) {
        if opcode == Opcode.binary.rawValue {
            // Binary inbound is not part of our protocol; ignore safely.
            return
        }
        guard let text = String(data: data, encoding: .utf8) else { return }
        onMessage?(text)
    }

    private func tryParseFrame() -> (fin: Bool, opcode: UInt8, payload: Data)? {
        guard buffer.count >= 2 else { return nil }
        let b0 = buffer[buffer.startIndex]
        let b1 = buffer[buffer.startIndex + 1]
        let fin = (b0 & 0x80) != 0
        let opcode = b0 & 0x0F
        let masked = (b1 & 0x80) != 0
        var len = Int(b1 & 0x7F)
        var headerLength = 2

        if len == 126 {
            guard buffer.count >= 4 else { return nil }
            len = (Int(buffer[buffer.startIndex + 2]) << 8) | Int(buffer[buffer.startIndex + 3])
            headerLength = 4
        } else if len == 127 {
            guard buffer.count >= 10 else { return nil }
            var value: UInt64 = 0
            for i in 0..<8 {
                value = (value << 8) | UInt64(buffer[buffer.startIndex + 2 + i])
            }
            guard value <= UInt64(Self.maxMessageBytes) else { return nil }
            len = Int(value)
            headerLength = 10
        }

        var maskKey: [UInt8]?
        if masked {
            guard buffer.count >= headerLength + 4 else { return nil }
            maskKey = Array(buffer[buffer.startIndex + headerLength ..< buffer.startIndex + headerLength + 4])
            headerLength += 4
        }

        guard buffer.count >= headerLength + len else { return nil }
        var payload = Data(buffer[buffer.startIndex + headerLength ..< buffer.startIndex + headerLength + len])
        buffer.removeFirst(headerLength + len)

        if let key = maskKey {
            for i in 0..<payload.count {
                payload[i] = payload[i] ^ key[i % 4]
            }
        }
        return (fin, opcode, payload)
    }

    private func sendClose(_ code: UInt16) {
        var d = Data()
        d.append(UInt8((code >> 8) & 0xFF))
        d.append(UInt8(code & 0xFF))
        sendFrame(opcode: Opcode.close.rawValue, payload: d)
    }

    private func teardown() {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        onClose?()
    }
}

// MARK: - Handshake helper

extension LANWebSocket {
    /// Compute the `Sec-WebSocket-Accept` value for the handshake.
    static func acceptValue(for secWebSocketKey: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let combined = (secWebSocketKey + magic).data(using: .utf8) ?? Data()
        let digest = Insecure.SHA1.hash(data: combined)
        return Data(digest).base64EncodedString()
    }
}

// MARK: - Lightweight HTTP head for the handshake route

struct LANHTTPRequest {
    var method: String
    var path: String              // path without query
    var rawURL: String            // original path + query
    var query: [String: String]
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}
    }