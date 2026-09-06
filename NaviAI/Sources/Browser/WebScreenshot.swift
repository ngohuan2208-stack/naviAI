import Foundation
import UIKit
import WebKit

struct WebScreenshotRequest {

    var maxWidth: Int = 1280

    var quality: CGFloat = 0.6
}

struct WebScreenshot {
    let url: String
    let title: String
    let capturedAt: Date
    let pixelWidth: Int
    let pixelHeight: Int
    let data: Data

    var base64: String { data.base64EncodedString() }

    var byteCount: Int { data.count }
}

@MainActor
final class WebScreenshotManager {

    static let shared = WebScreenshotManager()

    private let memoryBudget = 12 * 1024 * 1024

    private var cache: [UUID: WebScreenshot] = [:]
    private var order: [UUID] = []
    private var lastCaptureDate = Date.distantPast
    private var lastCaptureTabID: UUID?

    private init() {}

    var throttleInterval: TimeInterval = 2.5

    @discardableResult
    func capture(activeTab: TabItem?,
                 maxWidth: Int,
                 quality: CGFloat) async -> WebScreenshot? {
        guard let tab = activeTab, let wv = tab.webView as WKWebView? else { return nil }

        let now = Date()
        if lastCaptureTabID == tab.id, now.timeIntervalSince(lastCaptureDate) < throttleInterval {
            return nil
        }

        let snapshot: UIImage? = await withCheckedContinuation { continuation in
            wv.takeSnapshot(with: nil) { image, _ in
                continuation.resume(returning: image)
            }
        }
        guard let image = snapshot else { return nil }

        var scaled = image
        let cap = max(320, maxWidth)
        if image.size.width > CGFloat(cap) {
            let ratio = CGFloat(cap) / image.size.width
            let newSize = CGSize(width: CGFloat(cap), height: image.size.height * ratio)
            let renderer = UIGraphicsImageRenderer(size: newSize)
            scaled = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
        }

        guard let jpeg = scaled.jpegData(compressionQuality: min(max(quality, 0.3), 0.9)) else {
            return nil
        }

        let shot = WebScreenshot(
            url: tab.webView.url?.absoluteString ?? tab.url?.absoluteString ?? "",
            title: tab.webView.title ?? tab.title,
            capturedAt: now,
            pixelWidth: Int(scaled.size.width),
            pixelHeight: Int(scaled.size.height),
            data: jpeg
        )

        cacheScreenshot(shot)
        lastCaptureDate = now
        lastCaptureTabID = tab.id
        return shot
    }

    private func cacheScreenshot(_ shot: WebScreenshot) {
        let id = UUID()
        cache[id] = shot
        order.append(id)
        var bytes = cache.values.reduce(0) { $0 + $1.byteCount }
        while bytes > memoryBudget, !order.isEmpty {
            let oldest = order.removeFirst()
            if let removed = cache.removeValue(forKey: oldest) {
                bytes -= removed.byteCount
            }
        }
    }

    var cachedCount: Int { cache.count }

    var cachedBytes: Int { cache.values.reduce(0) { $0 + $1.byteCount } }

    func clearCache() {
        cache.removeAll()
        order.removeAll()
    }
}

private extension UIImage {

    var devicePixelWidth: Int { Int(size.width * scale) }
    var devicePixelHeight: Int { Int(size.height * scale) }
}
