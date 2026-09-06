import Foundation
import Combine
import Network

@MainActor
final class VPNManager: ObservableObject {
    static let shared = VPNManager()

    enum ProviderKind: String {
        case none
        case personalVPN
        case packetTunnel
        case contentFilter
    }

    @Published private(set) var configuredProvider: ProviderKind = .none

    @Published private(set) var systemVPNActive: Bool = false

    var externalVPNActive: Bool { systemVPNActive }

    private init() {}

    func observe(path: NWPath) {
        systemVPNActive = path.usesInterfaceType(.other)
    }
}
