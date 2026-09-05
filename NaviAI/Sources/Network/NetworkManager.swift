import Foundation
import Combine
import Network

// MARK: - App-level network manager

/// One place that owns how NaviAI's own HTTP traffic flows: applies the active
/// proxy dictionary to the shared session configuration, watches the system
/// network path, and measures basic health (DNS + latency).
@MainActor
final class NetworkManager: ObservableObject {
    static let shared = NetworkManager()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "navi.network.monitor")

    @Published private(set) var status = NetworkStatusSnapshot()

    private var proxy: ProxyManager { .shared }
    private var vpn: VPNManager { .shared }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let snapshot = NetworkManager.snapshot(from: path)
            Task { @MainActor in
                self?.apply(path: path, snapshot: snapshot)
            }
        }
        monitor.start(queue: queue)
        applyProxyToSharedSession()
    }

    private func apply(path: NWPath, snapshot: NetworkStatusSnapshot) {
        status = snapshot
        vpn.observe(path: path)
    }

    private static func snapshot(from path: NWPath) -> NetworkStatusSnapshot {
        var s = NetworkStatusSnapshot()
        s.internet = path.status == .satisfied
        if path.usesInterfaceType(.wifi) { s.interface = .wifi }
        else if path.usesInterfaceType(.cellular) { s.interface = .cellular }
        else if path.usesRouteType(.wiredEthernet) || path.usesInterfaceType(.wiredEthernet) { s.interface = .wired }
        else if path.usesInterfaceType(.loopback) { s.interface = .loopback }
        else if path.status == .satisfied { s.interface = .other }
        s.expensive = path.isExpensive
        s.constrained = path.isConstrained
        s.vpnActive = path.usesInterfaceType(.other)
        return s
    }

    // MARK: Proxy application

    /// Routes ALL app-level URLSession traffic through the selected proxy.
    /// Call again after any proxy change.
    func applyProxyToSharedSession() {
        let dict = proxy.connectionProxyDictionary()
        URLSession.shared.configuration.connectionProxyDictionary = dict
        status.proxyActive = dict != nil
    }

    // MARK: Health checks

    /// DNS resolution check: can we open a TCP connection to host:443?
    func checkDNS(host: String = "apple.com") async -> Bool {
        let ok = await Self.canConnect(host: host, port: 443, timeout: 6)
        status.dnsResolves = ok
        return ok
    }

    /// Latency probe: 4 GETs to a fast 204 endpoint, median kept.
    func measureLatency() async -> Int? {
        guard let url = URL(string: "https://www.gstatic.com/generate_204") else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        if let dict = proxy.connectionProxyDictionary() {
            config.connectionProxyDictionary = dict
        }
        let session = URLSession(configuration: config)

        var samples: [Int] = []
        for _ in 0..<4 {
            let start = Date()
            do {
                let (_, resp) = try await session.data(from: url)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<400).contains(code) {
                    samples.append(Int(Date().timeIntervalSince(start) * 1000))
                }
            } catch {
                continue
            }
        }
        guard !samples.isEmpty else {
            status.latencyMS = nil
            return nil
        }
        samples.sort()
        let median = samples[samples.count / 2]
        status.latencyMS = median
        return median
    }

    /// One-tap "run full check" for the Settings screen.
    func runFullCheck() async {
        _ = await checkDNS()
        _ = await measureLatency()
    }

    private static func canConnect(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { cont in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port) ?? 443,
                using: .tcp)
            let box = TimeoutBox()
            connection.stateUpdateHandler = { state in
                guard !box.finished else { return }
                switch state {
                case .ready:
                    box.finished = true
                    connection.cancel()
                    cont.resume(returning: true)
                case .failed, .cancelled:
                    box.finished = true
                    cont.resume(returning: false)
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard !box.finished else { return }
                box.finished = true
                connection.cancel()
                cont.resume(returning: false)
            }
        }
    }
}

/// Tiny thread-safe one-shot flag for connection callbacks.
private final class TimeoutBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _finished = false
    var finished: Bool {
        get { lock.withLock { _finished } }
        set { lock.withLock { _finished = newValue } }
    }
}