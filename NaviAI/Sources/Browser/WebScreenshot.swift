import Foundation
import UIKit
import WebKit

// MARK: - Screenshot request

/// What the AI / remote client asked for. Only the visible web-view viewport is
/// ever captured (the official `WKWebView.takeSnapshot` API) — never the full
/// iPhone screen.
struct WebScreenshotRequest {
    /// Largest edge in pixels after scaling (0 = keep capture size).
    var maxWidth: Int = 1280
    /// JPEG quality 0...1 (recommended 0.6).
    var quality: CGFloat = 0.6
}

// MARK: - WebScreenshot

/// A bounded, cached screenshot of a web page. `data` holds the JPEG bytes that
/// are safe to embed or transmit.
struct WebScreenshot {
    let url: String
    let title: String
    let capturedAt: Date
    let pixelWidth: Int
    let pixelHeight: Int
    let data: Data

    var base64: String { data.base64EncodedString() }

    /// Rough amount of compressed bytes (used by memory accounting).
    var byteCount: Int { data.count }
}

// MARK: - WebScreenshotManager

/// Captures the **web content viewport** only and enforces hard limits so that
/// AI / realtime vision never causes excessive RAM or LAN bandwidth:
///
/// - resolution cap (`settings.screenshotMaxWidth`)
/// - JPEG compression (`quality 0.6`)
/// - frequency throttle (min interval per tab, default 2.5 s)
/// - memory cap (keeps only the N most recent screenshots)
///
/// Everything runs on the main actor (WKWebView must be touched on main).
@MainActor
final class WebScreenshotManager {

    static let shared = WebScreenshotManager()

    /// Max total resident JPEG bytes for cached screenshots (≈12 MB).
    private let memoryBudget = 12 * 1024 * 1024

    /// Screenshots are only kept for short-lived vision/context use.
    private var cache: [UUID: WebScreenshot] = [:]
    private var order: [UUID] = []
    private var lastCaptureDate = Date.distantPast
    private var lastCaptureTabID: UUID?

    private init() {}

    /// The minimum allowed period between two captures on the same tab.
    var throttleInterval: TimeInterval = 2.5

    /// Capture the currently visible web content. Returns `nil` when there is
    /// no active tab, the page is not ready, the throttle says no, or the
    /// capture fails.
    @discardableResult
    func capture(activeTab: TabItem?,
                 maxWidth: Int,
                 quality: CGFloat) async -> WebScreenshot? {
        guard let tab = activeTab, let wv = tab.webView as WKWebView? else { return nil }

        // Frequency limit.
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
            let newSize = CGSize(width: cap, height: image.size.height * ratio)
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

// MARK: - UIImage scaling helper

private extension UIImage {
    /// Pixel size of the captured image.
    var devicePixelWidth: Int { Int(size.width * scale) }
    var devicePixelHeight: Int { Int(size.height * scale) }
}