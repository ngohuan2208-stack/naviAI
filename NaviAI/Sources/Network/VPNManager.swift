import Foundation
import Combine
import Network

// MARK: - VPN manager (architecture only — NO simulation, NO fake status)

/// NaviAI does NOT ship a working VPN. This type exists to make the Network
/// Extension architecture explicit and to give the UI an honest, testable
/// answer for "is a VPN active?".
///
/// Why there is no fake VPN:
/// • A real Personal VPN requires the `com.apple.developer.networking.vpn.api`
///   entitlement (paid request to Apple) and a provider bundle configured in
///   NetworkExtension.
/// • Simulating a VPN switch in-app would mislead users about what traffic is
///   actually protected, which the project explicitly forbids.
///
/// To make this real later:
///   1. Request the Personal VPN entitlement from Apple.
///   2. Add a Packet Tunnel Provider extension target.
///   3. Implement the tunnel in the extension; store credentials in Keychain.
///   4. Replace this stub with NEVPNManager / NEAppRule usage.
@MainActor
final class VPNManager: ObservableObject {
    static let shared = VPNManager()

    enum ProviderKind: String {
        case none
        case personalVPN   // NEVPNManager, IPsec/IKEv2
        case packetTunnel  // NEPacketTunnelProvider
        case contentFilter // NEFilterProvider — content rules only, not a tunnel
    }

    /// What the app currently integrates: nothing (honest value).
    @Published private(set) var configuredProvider: ProviderKind = .none

    /// Ask the system, not ourselves: whether ANY VPN interface is up. This is
    /// read from the live network path, never invented.
    @Published private(set) var systemVPNActive: Bool = false

    /// DNS server currently observed on the active path (useful for the user
    /// to verify what network they are really on).
    @Published private(set) var dnsServers: [String] = []

    /// True when the user has some VPN from another app active. We surface it
    /// so proxy/VPN state in NaviAI never lies about the traffic path.
    var externalVPNActive: Bool { systemVPNActive }

    private init() {}

    /// Called by NetworkStatusMonitor on every path update.
    func observe(path: NWPath) {
        systemVPNActive = path.usesInterfaceType(.other)
        dnsServers = path.resolvedEndpoints.compactMap { endpoint in
            if case .hostPort(let host, _) = endpoint {
                return "\(host)"
            }
            return nil
        }
    }
}