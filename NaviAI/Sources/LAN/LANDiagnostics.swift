import Foundation

@MainActor
enum LANDiagnostics {

    static func snapshot() -> [String: Any] {
        let server = LANControlServer.shared
        var payload: [String: Any] = [:]
        payload["serverStatus"] = server.status.label
        payload["serverURL"] = server.serverURL
        payload["uptime"] = Int(server.uptime)
        payload["connectedClients"] = server.connectedSessions.count
        payload["pairedDevices"] = LANDeviceRegistry.shared.devices.map {
            [
                "name": $0.deviceName,
                "lastSeen": $0.lastSeen.timeIntervalSince1970,
                "createdAt": $0.createdAt.timeIntervalSince1970
            ]
        }
        payload["hasActivePin"] = LANPairing.shared.pinExpiresAt != nil
        payload["pinRemaining"] = LANPairing.shared.pinRemainingText
        payload["activityCount"] = LANActivityCenter.shared.feed.count
        payload["screenshotCacheBytes"] = WebScreenshotManager.shared.cachedBytes
        payload["pageContextLatest"] = WebPageContextPipeline.shared.latest?.url
        payload["time"] = Date().timeIntervalSince1970
        return payload
    }
}
