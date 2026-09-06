import Foundation
import Network
import Combine
import UIKit
import CryptoKit

// MARK: - HTTP connection helper

/// Reads HTTP requests and writes HTTP responses on one NWConnection. Read and
/// write both happen on the server queue; async continuations bridge the
/// callback API.
final class LANHTTPConnection {

    private let connection: NWConnection
    private var buffer = Data()

    init(connection: NWConnection) {
        self.connection = connection
    }

    private func receiveChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { data, _, isComplete, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(returning: Data())
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
    }

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    func readRequest() async throws -> LANHTTPRequest {
        var head: Data
        while true {
            if let range = buffer.range(of: Self.headerTerminator) {
                head = Data(buffer[..<range.lowerBound])
                buffer.removeSubrange(..<range.upperBound)
                break
            }
            if buffer.count > 64 * 1024 {
                throw LANError.requestTooLarge
            }
            let chunk = try await receiveChunk()
            if chunk.isEmpty {
                throw LANError.connectionReset
            }
            buffer.append(chunk)
        }

        var lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw LANError.badRequest }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { throw LANError.badRequest }
        let method = String(parts[0])
        let rawURL = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[key.lowercased()] = value
            }
        }

        var query: [String: String] = [:]
        let path: String
        if let qIndex = rawURL.firstIndex(of: "?") {
            path = String(rawURL[..<qIndex])
            let queryString = String(rawURL[rawURL.index(after: qIndex)...])
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard !kv.isEmpty else { continue }
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                query[key] = value
            }
        } else {
            path = rawURL
        }

        // Body (Content-Length).
        var body = Data()
        if let lengthText = headers["content-length"], let length = Int(lengthText), length > 0 {
            guard length <= LANProtocol.maxHTTPBodyBytes else { throw LANError.requestTooLarge }
            while buffer.count < length {
                let chunk = try await receiveChunk()
                if chunk.isEmpty { throw LANError.connectionReset }
                buffer.append(chunk)
            }
            body = Data(buffer.prefix(length))
            buffer.removeFirst(length)
        }

        return LANHTTPRequest(method: method, path: path, rawURL: rawURL, query: query, headers: headers, body: body)
    }

    func send(data: Data, contentType: String, status: Int = 200) async {
        let reason = HTTPReason.status(status)
        let head = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(data.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: keep-alive\r\n"
            + "\r\n"
        var out = Data(head.utf8)
        out.append(data)
        await sendRaw(out)
    }

    func sendJSON(_ payload: [String: Any], status: Int = 200) async {
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        await send(data: data, contentType: "application/json; charset=utf-8", status: status)
    }

    func sendWebSocketUpgrade(accept: String) async {
        let head = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n"
            + "\r\n"
        await sendRaw(Data(head.utf8))
    }

    private func sendRaw(_ data: Data) async {
        await withCheckedContinuation { cont in
            connection.send(content: data,
                            contentContext: .finalMessage,
                            isComplete: true,
                            completion: .contentProcessed { _ in
                                cont.resume()
                            })
        }
    }

    /// Bytes already read past the current HTTP request head (handed to a
    /// WebSocket on upgrade so no frame is lost).
    var leftoverBuffer: Data { buffer }
}

enum HTTPReason {
    static func status(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Unknown"
        }
    }
// MARK: - LAN Control Server

/// The LAN server that turns the iPhone into "Navi + LAN server" and lets PCs,
/// tablets and other phones act as pure web clients. Real implementation using
/// NWListener + hand-rolled HTTP/WebSocket (RFC 6455); no third-party code.
///
/// Implemented here:
///  • HTTP serving of the remote Navi web UI + JSON API
///  • WebSocket realtime channel (multi-device, versioned state)
///  • PIN pairing → revocable session tokens
///  • path lockdown (no traversal), rate limiting, hard payload caps
///  • throttled realtime state broadcasts with change detection
@MainActor
final class LANControlServer: ObservableObject {

    static let shared = LANControlServer()

    static let port: UInt16 = 8765
    static let serviceType = "_navi._tcp."

    enum ServerStatus: Equatable {
        case stopped
        case starting
        case running
        case failed(String)

        var label: String {
            switch self {
            case .stopped: return "Off"
            case .starting: return "Starting…"
            case .running: return "Running"
            case .failed: return "Error"
            }
        }
    }

    @Published private(set) var status: ServerStatus = .stopped
    @Published private(set) var connectedSessions: [LANSession] = []
    @Published private(set) var serverURL: String = ""
    @Published private(set) var lastError: String?

    private var listener: NWListener?
    private var sessions: [LANSession] = []
    private let serverQueue = DispatchQueue(label: "navi.lan.server")
    private weak var browser: BrowserStore?
    private var pollTask: Task<Void, Never>?
    private var startupDate = Date()
    private var lastBroadcastHash = ""
    private var pagePollDate = Date.distantPast
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]

    private init() {}

    var uptime: TimeInterval { Date().timeIntervalSince(startupDate) }

    // MARK: Public lifecycle

    func start(browser: BrowserStore) {
        self.browser = browser
        guard status != .running else { return }
        guard listener == nil else { return }
        status = .starting
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: Self.port) else {
                status = .failed("Invalid port")
                return
            }
            let listener = try NWListener(using: params, on: nwPort)
            listener.service = NWListener.Service(name: UIDevice.current.name,
                                                  type: Self.serviceType,
                                                  domain: nil)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.status = .running
                        self.serverURL = self.computeDisplayURL()
                        self.lastError = nil
                        self.startPolling()
                    case .failed(let error):
                        self.status = .failed(error.localizedDescription)
                        self.lastError = error.localizedDescription
                    case .cancelled:
                        self.status = .stopped
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }
                self.handleNewConnection(connection)
            }
            listener.start(queue: serverQueue)
            self.listener = listener
            startupDate = Date()
        } catch {
            status = .failed(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        for (_, task) in connectionTasks { task.cancel() }
        connectionTasks.removeAll()
        for session in sessions {
            session.socket?.close()
            session.socket = nil
        }
        sessions.removeAll()
        connectedSessions.removeAll()
        sessionByHash.removeAll()
        listener?.cancel()
        listener = nil
        status = .stopped
        serverURL = ""
    }

    /// Convenience for the settings UI: start/stop toggle.
    func toggle(browser: BrowserStore) {
        if status == .running {
            stop()
        } else {
            start(browser: browser)
        }
    }

    // MARK: Client accounting

    private(set) var sessionByHash: [String: LANSession] = [:]

    func session(forTokenHash hash: String) -> LANSession? {
        sessionByHash[hash]
    }

    private func registerSession(_ session: LANSession) {
        sessions.append(session)
        sessionByHash[session.tokenHash] = session
        connectedSessions = sessions
    }

    private func removeSession(_ session: LANSession) {
        session.isConnected = false
        sessions.removeAll { $0.id == session.id }
        connectedSessions = sessions
        if sessionByHash[session.tokenHash]?.id == session.id {
            sessionByHash.removeValue(forKey: session.tokenHash)
        }
    }
// MARK: Display helpers

    private func computeDisplayURL() -> String {
        var address = "localhost"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return "http://localhost:\(Self.port)" }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let current = ptr {
            let family = current.pointee.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: current.pointee.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("pdp_ip") {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(current.pointee.ifa_addr,
                                socklen_t(current.pointee.ifa_addr.pointee.sa_len),
                                &host, socklen_t(host.count),
                                nil, 0, NI_NUMERICHOST)
                    let ip = String(cString: host)
                    if !ip.isEmpty && !ip.hasPrefix("169.254") {
                        address = ip
                        break
                    }
                }
            }
            ptr = current.pointee.ifa_next
        }
        return "http://\(address):\(Self.port)"
    }

    // MARK: Connection handling

    private func handleNewConnection(_ connection: NWConnection) {
        let id = UUID()
        let task = Task { [weak self] in
            await self?.serve(connection: connection)
            connection.cancel()
        }
        connectionTasks[id] = task
        Task { @MainActor [weak self] in
            self?.connectionTasks[id] = nil
        }
    }

    private func serve(connection: NWConnection) async {
        connection.start(queue: serverQueue)
        let http = LANHTTPConnection(connection: connection)
        var keepGoing = true
        while keepGoing {
            do {
                let request = try await http.readRequest()
                let result = await route(request, http: http, connection: connection)
                switch result {
                case .continueLoop:
                    keepGoing = true
                case .closeConnection:
                    keepGoing = false
                case .handedOff:
                    // WebSocket upgrade: the connection now belongs to the
                    // LANWebSocket — never cancel it from here.
                    keepGoing = false
                    return
                }
            } catch LANError.requestTooLarge {
                await http.sendJSON(["error": "Payload too large"], status: 413)
                keepGoing = false
            } catch LANError.connectionReset {
                keepGoing = false
            } catch {
                keepGoing = false
            }
        }
        connection.cancel()
    }

    private enum RouteResult {
        case continueLoop
        case closeConnection
        case handedOff
    }

    // MARK: Routing

    private func route(_ request: LANHTTPRequest, http: LANHTTPConnection, connection: NWConnection) async -> RouteResult {
        // Path traversal lockdown: only exact known paths are served.
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            await http.send(data: Data(LANWebUI.html.utf8), contentType: "text/html; charset=utf-8")
            return .continueLoop
        case ("GET", "/app.css"):
            await http.send(data: Data(LANWebUI.css.utf8), contentType: "text/css; charset=utf-8")
            return .continueLoop
        case ("GET", "/app.js"):
            await http.send(data: Data(LANWebUI.js.utf8), contentType: "application/javascript; charset=utf-8")
            return .continueLoop
        case ("GET", "/favicon.ico"):
            await http.send(data: Data(), contentType: "image/x-icon")
            return .continueLoop
        case ("GET", "/api/status"):
            await http.sendJSON(Self.publicStatus())
            return .continueLoop
        case ("POST", "/api/pair"):
            await handlePair(request: request, http: http, connection: connection)
            return .continueLoop
        case ("GET", "/api/screenshot"):
            await handleScreenshot(request: request, http: http)
            return .continueLoop
        case ("POST", "/api/command"):
            await handleHTTPCommand(request: request, http: http, connection: connection)
            return .continueLoop
        case ("GET", "/ws"):
            await handleWebSocketUpgrade(request: request, http: http, connection: connection)
            return .handedOff
        default:
            await http.sendJSON(["error": "Not found"], status: 404)
            return .continueLoop
        }
    }

    private static func publicStatus() -> [String: Any] {
        [
            "ok": true,
            "name": "NaviAI",
            "version": LANProtocol.protocolVersion,
            "status": LANControlServer.shared.status.label,
            "clients": LANControlServer.shared.connectedSessions.count,
            "needsPin": LANPairing.shared.pinExpiresAt != nil,
            "ts": Date().timeIntervalSince1970
        ]
    }
// MARK: Pairing, commands, screenshot, websocket

    private func handlePair(request: LANHTTPRequest, http: LANHTTPConnection, connection: NWConnection) async {
        let remote = remoteKey(connection)
        guard LANRateLimiter.shared.allow(key: "pair:" + remote, maxPerWindow: 10, window: 300) else {
            await http.sendJSON(["error": "Too many pairing attempts"], status: 429)
            return
        }
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
        guard let pin = body?["pin"] as? String else {
            await http.sendJSON(["error": "Missing pin"], status: 400)
            return
        }
        let deviceName = (body?["deviceName"] as? String) ?? "Web client"
        guard LANPairing.shared.verify(pin) else {
            await http.sendJSON(["error": "Invalid or expired PIN"], status: 403)
            return
        }
        let token = LANSecurity.randomToken()
        LANDeviceRegistry.shared.register(token: token, deviceName: deviceName, platform: "web")
        await http.sendJSON(["ok": true, "token": token, "name": deviceName])
    }

    private func handleHTTPCommand(request: LANHTTPRequest, http: LANHTTPConnection, connection: NWConnection) async {
        let remote = remoteKey(connection)
        guard LANRateLimiter.shared.allow(key: "cmd:" + remote, maxPerWindow: 40, window: 60) else {
            await http.sendJSON(["error": "Too many commands"], status: 429)
            return
        }
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
        guard let token = body?["token"] as? String else {
            await http.sendJSON(["error": "Missing token"], status: 401)
            return
        }
        guard LANDeviceRegistry.shared.isValid(token: token) else {
            await http.sendJSON(["error": "Unauthorized"], status: 401)
            return
        }
        let command = (body?["command"] as? String) ?? ""
        let args = (body?["args"] as? [String: Any]) ?? [:]
        LANDeviceRegistry.shared.touch(token)
        let result = await execute(command: command, args: args, tokenHash: LANSecurity.hash(token))
        var payload = result.payload
        payload["command"] = command
        await http.sendJSON(payload, status: (result.type == "error" ? 400 : 200))
    }

    private func handleScreenshot(request: LANHTTPRequest, http: LANHTTPConnection) async {
        guard let token = request.query["token"], LANDeviceRegistry.shared.isValid(token: token) else {
            await http.sendJSON(["error": "Unauthorized"], status: 401)
            return
        }
        guard let browser, settingsAllowObserve() else {
            await http.sendJSON(["error": "Observation disabled on Navi"], status: 403)
            return
        }
        guard LANRateLimiter.shared.allow(key: "shot:" + LANSecurity.hash(token), maxPerWindow: 6, window: 30) else {
            await http.sendJSON(["error": "Screenshot rate limit"], status: 429)
            return
        }
        let shot = await WebScreenshotManager.shared.capture(
            activeTab: browser.activeTab,
            maxWidth: browser.settings.screenshotMaxWidth,
            quality: 0.6)
        if let shot {
            await http.send(data: shot.data, contentType: "image/jpeg")
        } else {
            await http.sendJSON(["error": "Screenshot unavailable (page loading or throttled)"], status: 503)
        }
    }

    private func handleWebSocketUpgrade(request: LANHTTPRequest, http: LANHTTPConnection, connection: NWConnection) async {
        guard let token = request.query["token"], LANDeviceRegistry.shared.isValid(token: token) else {
            await http.sendJSON(["error": "Unauthorized"], status: 401)
            return
        }
        guard let remote = addressOf(request: request) else {
            await http.sendJSON(["error": "Unknown client"], status: 400)
            return
        }
        guard LANRateLimiter.shared.allow(key: "ws:" + remote, maxPerWindow: 12, window: 120) else {
            await http.sendJSON(["error": "Too many connection attempts"], status: 429)
            return
        }
        guard let key = request.header("sec-websocket-key") else {
            await http.sendJSON(["error": "Missing WebSocket key"], status: 400)
            return
        }
        let accept = LANWebSocket.acceptValue(for: key)
        await http.sendWebSocketUpgrade(accept: accept)
        attachWebSocket(connection: connection, token: token, preloaded: http.leftoverBuffer)
    }

    private func addressOf(request: LANHTTPRequest) -> String? {
// MARK: WebSocket session lifecycle

    private func attachWebSocket(connection: NWConnection, token: String, preloaded: Data) {
        let socket = LANWebSocket(connection: connection, preloaded: preloaded)
        let tokenHash = LANSecurity.hash(token)

        socket.onMessage = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.handleSocketMessage(text, tokenHash: tokenHash)
            }
        }
        socket.onClose = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let session = self.sessionByHash[tokenHash] {
                    self.removeSession(session)
                }
            }
        }
        socket.onError = { error in
            NSLog("LAN WebSocket error: \(error.localizedDescription)")
        }
        socket.start()

        let record = LANDeviceRegistry.shared.find(hash: tokenHash)
        let session = LANSession(tokenHash: tokenHash,
                                 deviceName: record?.deviceName ?? "Web client",
                                 platform: "web",
                                 canControl: true)
        session.socket = socket
        session.lastSeen = Date()
        registerSession(session)

        // Full state restore on connect — a disconnecting client reconnects
        // with the same token and immediately goes from "Synchronizing…" to
        // "State restored".
        if let snapshot = browser?.remoteStateSnapshot(),
           let data = try? JSONSerialization.data(withJSONObject: snapshot),
           let text = String(data: data, encoding: .utf8) {
            send(to: session, type: LANProtocol.EventType.stateRestore, payloadData: text)
        }
    }

    private func handleSocketMessage(_ text: String, tokenHash: String) {
        guard let socketSession = sessionByHash[tokenHash] else { return }
        guard let data = text.data(using: .utf8) else { return }
        guard let msg = LANProtocol.decode(data) else {
            send(to: socketSession, type: LANProtocol.EventType.error, payload: ["error": "Malformed message"])
            return
        }
        guard LANProtocol.checkVersion(data) else {
            send(to: socketSession, type: LANProtocol.EventType.error, payload: ["error": "Protocol version mismatch"])
            return
        }
        socketSession.lastSeen = Date()
        switch msg.type {
        case LANProtocol.CommandType.ping:
            send(to: socketSession, type: LANProtocol.EventType.pong, payload: [:])
        case LANProtocol.CommandType.command:
            let command = (msg.payload["command"] as? String) ?? ""
            let args = (msg.payload["args"] as? [String: Any]) ?? [:]
            let result = await execute(command: command, args: args, tokenHash: tokenHash)
            send(to: socketSession, type: result.type, payload: result.payload)
        case LANProtocol.CommandType.subscribe:
            // Subscriptions are all-or-nothing in this version; state events
            // are always delivered.
            send(to: socketSession, type: LANProtocol.EventType.state, payload: browser?.remoteStateSnapshot() ?? [:])
        default:
            send(to: socketSession, type: LANProtocol.EventType.error, payload: ["error": "Unknown message type"])
        }
    }
// MARK: - Command dispatcher (server-side)

extension LANControlServer {

    typealias LANCommandResult = (type: String, payload: [String: Any])

    /// Execute a remote command. Observe commands require `lanAllowObserve`;
    /// control commands require `lanAllowControl`; sensitive effects still pass
    /// through the on-device confirmation flow.
    func execute(command: String, args: [String: Any], tokenHash: String) async -> (type: String, payload: [String: Any]) {
        guard let browser else {
            return err("Browser not ready")
        }
        let isControl = Self.controlCommands.contains(command)
        if isControl {
            guard browser.settings.lanAllowControl else {
                return err("Remote control is disabled on Navi (Settings → LAN Control)")
            }
        } else {
            guard browser.settings.lanAllowObserve else {
                return err("Remote observation is disabled on Navi (Settings → LAN Control)")
            }
        }

        switch command {
        case "state":
            return ok(browser.remoteStateSnapshot())
        case "navigate":
            guard let url = args["url"] as? String, !url.isEmpty else { return err("navigate needs a url") }
            browser.loadAddress(url)
            return ok(["message": "Opening \(url)"])
        case "search":
            guard let query = args["query"] as? String, !query.isEmpty else { return err("search needs a query") }
            browser.loadAddress(query)
            return ok(["message": "Searching \(query)"])
        case "home":
            browser.loadURL(browser.settings.searchEngine.homeURL)
            return ok(["message": "Going home"])
        case "reload":
            browser.reloadPage()
            return ok(["message": "Reloading"])
        case "back":
            browser.navigateBack()
            return ok(["message": "Going back"])
        case "forward":
            browser.navigateForward()
            return ok(["message": "Going forward"])
        case "openTab":
            let raw = (args["url"] as? String) ?? ""
            if raw.isEmpty {
                _ = browser.newTab(url: nil, activate: true)
            } else if let url = browser.urlFrom(text: raw) {
                _ = browser.newTab(url: url, activate: true)
            } else {
                _ = browser.newTab(url: browser.settings.searchEngine.searchURL(for: raw), activate: true)
            }
            return ok(["message": "Opened new tab"])
        case "switchTab":
            guard let index = args["index"] as? Int else { return err("switchTab needs an index") }
            browser.switchToTab(at: index)
            return ok(["message": "Switched to tab \(index)"])
        case "closeTab":
            if let index = args["index"] as? Int {
                guard browser.tabs.indices.contains(index) else { return err("No tab at index \(index)") }
                browser.closeTab(browser.tabs[index].id)
            } else if let tabID = browser.activeTabID {
                browser.closeTab(tabID)
            }
            return ok(["message": "Closed tab"])
        case "scroll":
            let dy = (args["dy"] as? Int) ?? 700
            if let tab = browser.activeTab {
                _ = try? await tab.coordinator.evaluate(BrowserJavaScript.scrollByExpr(dx: 0, dy: dy))
            }
            return ok(["message": "Scrolled"])
        case "read":
            let snap = await WebPageContextPipeline.shared.fresh(coordinator: browser.activeCoordinator)
            let text = snap?.compressedText(maxChars: 6000) ?? "No readable content yet."
            return ok(["text": text])
        case "readArticle":
            let article = await WebPageContextPipeline.shared.extractArticle(coordinator: browser.activeCoordinator)
            if let article {
                return ok([
                    "url": article.url,
                    "title": article.title,
                    "byline": article.byline,
                    "headings": article.headings,
                    "paragraphs": article.paragraphs,
                    "excerpt": article.excerpt
                ])
            }
            return err("No article content found on this page")

    // MARK: Broadcasting

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await self?.pollOnce()
            }
        }
    }

    private func pollOnce() async {
        await refreshPageContextIfNeeded()
        broadcastStateIfChanged()
    }

    private func refreshPageContextIfNeeded() async {
        guard let browser, !sessions.isEmpty else { return }
        let now = Date()
        guard now.timeIntervalSince(pagePollDate) >= 1.0 else { return }
        pagePollDate = now
        guard browser.activeCoordinator != nil else { return }
        _ = await WebPageContextPipeline.shared.capture(coordinator: browser.activeCoordinator)
    }

    private func broadcastStateIfChanged() {
        guard !sessions.isEmpty, let browser else { return }
        let snapshot = browser.remoteStateSnapshot()
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot) else { return }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash != lastBroadcastHash else { return }
        lastBroadcastHash = hash
        guard let text = String(data: data, encoding: .utf8) else { return }
        for session in sessions {
            send(to: session, type: LANProtocol.EventType.state, payloadData: text)
        }
    }

    // MARK: Send helpers

    private func send(to session: LANSession, type: String, payload: [String: Any]) {
        guard let socket = session.socket else { return }
        session.seq += 1
        if let data = LANProtocol.encode(type: type, payload: payload, seq: session.seq),
           let text = String(data: data, encoding: .utf8) {
            socket.send(text: text)
        }
    }

    private func send(to session: LANSession, type: String, payloadData: String) {
        guard let socket = session.socket else { return }
        session.seq += 1
        guard let data = LANProtocol.encode(type: type, payload: ["state": payloadData], seq: session.seq),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(text: text)
    }
        request.headers["x-forwarded-for"] ?? request.headers["remote-addr"]
    }

    private func settingsAllowObserve() -> Bool {
        browser?.settings.lanAllowObserve ?? false
    }
case "agent.start":
            guard let goal = args["goal"] as? String, !goal.isEmpty else { return err("agent.start needs a goal") }
            let continuation = (args["continuation"] as? String) ?? ""
            browser.startContinuousTask(goal: goal, continuationPrompt: continuation)
            return ok(["message": "Agent started", "goal": goal])
        case "agent.stop":
            browser.stopAgent()
            return ok(["message": "Agent stopped"])
        case "agent.resume":
            let resumed = browser.resumeContinuousTask()
            return resumed ? ok(["message": "Task resumed"]) : err("No resumable task")
        case "clickText":
            guard let text = args["text"] as? String, !text.isEmpty else { return err("clickText needs text") }
            return await browser.clickTextFromRemote(text)
        case "typeText":
            guard let target = args["target"] as? String else { return err("typeText needs target") }
            guard let text = args["text"] as? String else { return err("typeText needs text") }
            return await browser.typeTextFromRemote(target: target, text: text)
        default:
            return err("Unknown command '\(command)'")
        }
    }

    private static let controlCommands: Set<String> = [
        "navigate", "search", "home", "reload", "back", "forward",
        "openTab", "switchTab", "closeTab", "scroll",
        "agent.start", "agent.stop", "agent.resume", "clickText", "typeText"
    ]

    private func ok(_ payload: [String: Any]) -> (String, [String: Any]) {
        var p = payload
        p["ok"] = true
        return ("command.result", p)
    }

    private func err(_ message: String) -> (String, [String: Any]) {
        ("error", ["ok": false, "error": message])
    }
}

// MARK: - Remote-facing browser actions

extension BrowserStore {

    /// Full aggregate state delivered to LAN clients (versioned + throttled).
    func remoteStateSnapshot() -> [String: Any] {
        var snapshot: [String: Any] = [:]

        var meta: [String: Any] = [:]
        meta["version"] = LANProtocol.protocolVersion
        meta["ts"] = Date().timeIntervalSince1970
        meta["deviceName"] = UIDevice.current.name
        meta["appVersion"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        meta["allowObserve"] = settings.lanAllowObserve
        meta["allowControl"] = settings.lanAllowControl
        meta["clients"] = LANControlServer.shared.connectedSessions.count
        meta["uptime"] = LANControlServer.shared.uptime
        let profile = BrowserProfileStore.shared.activeProfile
        meta["profile"] = ["id": profile.id.uuidString, "displayName": profile.displayTitle]

        var browser: [String: Any] = [:]
        let tab = activeTab
        browser["url"] = tab?.webView.url?.absoluteString ?? tab?.url?.absoluteString ?? ""
        browser["title"] = tab?.title ?? ""
        browser["isLoading"] = webIsLoading
        browser["canGoBack"] = tab?.webView.canGoBack ?? false
        browser["canGoForward"] = tab?.webView.canGoForward ?? false
        browser["isPrivate"] = isActiveTabPrivate
        var tabsArray: [[String: Any]] = []
        for (index, item) in tabs.enumerated() {
            tabsArray.append([
                "index": index,
                "id": item.id.uuidString,
                "title": item.title.isEmpty ? "Untitled" : item.title,
                "url": item.webView.url?.absoluteString ?? item.url?.absoluteString ?? "",
                "active": item.id == activeTabID,
                "isPrivate": item.isPrivate
            ])
        }
        browser["tabs"] = tabsArray
        browser["activeTabIndex"] = tabs.firstIndex(where: { $0.id == activeTabID }) ?? 0
var page: [String: Any] = [:]
        if let snap = WebPageContextPipeline.shared.latest {
            page["url"] = snap.url
            page["title"] = snap.title
            page["readyState"] = snap.readyState
            page["scrollY"] = snap.scrollY
            page["viewportWidth"] = snap.viewportWidth
            page["viewportHeight"] = snap.viewportHeight
            page["visibleText"] = snap.visibleText
            page["headings"] = snap.headings
            page["links"] = snap.links.map { ["text": $0.text, "href": $0.href] }
            page["buttons"] = snap.buttons
            page["inputCount"] = snap.inputs.count
            page["formCount"] = snap.forms.count
            page["focused"] = snap.focused.map { ["tag": $0.tag, "type": $0.type, "name": $0.name, "placeholder": $0.placeholder, "label": $0.label] }
        }

        var agent: [String: Any] = [:]
        agent["status"] = agentStatus.label
        agent["isRunning"] = isAgentRunning
        agent["goal"] = taskGoal
        agent["step"] = agentStep
        if let task = runningTask {
            agent["task"] = taskToRemoteJSON(task)
        }

        var activity: [String: Any] = [:]
        activity["current"] = LANActivityCenter.shared.currentTask.toRemoteJSON()
        activity["feed"] = LANActivityCenter.shared.feed.suffix(50).map {
            ["id": $0.id.uuidString, "date": $0.date.timeIntervalSince1970, "message": $0.message, "kind": $0.kind.rawValue]
        }

        snapshot["meta"] = meta
        snapshot["browser"] = browser
        snapshot["page"] = page
        snapshot["agent"] = agent
        snapshot["activity"] = activity
        return snapshot
    }

    private func taskToRemoteJSON(_ task: PersistedAgentTask) -> [String: Any] {
        [
            "id": task.id.uuidString,
            "goal": task.goal,
            "continuation": task.continuationPrompt,
            "mode": task.mode,
            "status": task.status.rawValue,
            "currentStep": task.currentStep,
            "progress": task.progress,
            "stepCount": task.stepCount,
            "completedSteps": task.completedSteps,
            "pendingSteps": task.pendingSteps,
            "constraints": task.constraints,
            "stopReason": task.stopReason ?? ""
        ]
    }

    /// Click the first visible element whose text contains `text`.
    func clickTextFromRemote(_ text: String) async -> (String, [String: Any]) {
        do {
            let findResult = try await agentEvaluate(BrowserJavaScript.findTextExpr(query: text, max: 1))
            guard let items = findResult as? [[String: Any]], let first = items.first,
                  let id = first["id"] as? Int else {
                return ("error", ["ok": false, "error": "No visible element matching “\(text)”"])
            }
            let clickResult = try await agentEvaluate(BrowserJavaScript.clickExpr(id: id))
            return ("command.result", ["ok": true, "message": "Clicked “\(text)”", "result": clickResult ?? ""])
        } catch {
            return ("error", ["ok": false, "error": "Click failed"])
        }
    }

    /// Type into the first visible input whose placeholder/label/name contains
    /// `target`. Enter/submit stays confirmation-gated on the phone.
    func typeTextFromRemote(target: String, text: String) async -> (String, [String: Any]) {
        let low = target.lowercased()
        do {
            let snap = try await fetchSnapshot(maxItems: 40)
            guard let first = snap.items.first(where: {
                $0.input && ($0.placeholder.lowercased().contains(low)
                    || $0.text.lowercased().contains(low)
                    || $0.name.lowercased().contains(low))
            }) else {
                return ("error", ["ok": false, "error": "No input matching “\(target)”"])
            }
            let typed = try await agentEvaluate(BrowserJavaScript.typeExpr(id: first.id, text: text, enter: false))
            return ("command.result", ["ok": true, "message": "Typed into “\(target)”", "result": typed ?? ""])
        } catch {
            return ("error", ["ok": false, "error": "Typing failed"])
        }
    }
}

// MARK: - Codable → Any helpers

private extension ActiveTaskCard {
    func toRemoteJSON() -> [String: Any] {
        [
            "title": title,
            "continuation": continuation,
            "mode": mode,
            "isRunning": isRunning,
            "currentStep": currentStep,
            "progress": progress,
            "completedSteps": completedSteps,
            "totalSteps": totalSteps
        ]
    }
}
}