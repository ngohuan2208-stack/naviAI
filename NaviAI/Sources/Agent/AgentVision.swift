import Foundation
import WebKit
import UIKit

extension BrowserStore {

    var isVisionFallbackAvailable: Bool {
        settings.visionFallbackEnabled
            && providers.activeProvider?.supportsVision == true
    }

    func captureScreenshot() async -> UIImage? {
        guard let wv = activeTab?.webView else { return nil }
        return await withCheckedContinuation { continuation in
            wv.takeSnapshot(with: nil) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    func detectVisionClickables(viewportWidth: Double, viewportHeight: Double) async -> [VisionTarget] {
        guard isVisionFallbackAvailable else { return [] }
        guard let config = providers.activeProvider, let key = providers.apiKey(for: config) else { return [] }
        guard let image = await captureScreenshot(), let png = image.pngData() else { return [] }

        let system = """
        You are an accessibility tool. Given a screenshot of a webpage, list up to 8 UI controls a user could tap to continue a task (links, buttons, inputs, search bars, menu items). Return ONLY a JSON array, no prose. Each item: {"x": <0..1 fraction of width>, "y": <0..1 fraction of height>, "label": "<short text>"}.
        """

        do {
            let reply = try await llm.complete(
                config: config,
                apiKey: key,
                history: [
                    .system(system),
                    .userVision(text: "Describe tappable elements in this screenshot.", imageBase64: png.base64EncodedString(), mimeType: "image/png")
                ],
                tools: []
            )
            guard let text = reply.text else { return [] }
            return parseVisionTargets(text)
        } catch {
            NSLog("Vision fallback failed: \(error.localizedDescription)")
            return []
        }
    }

    private func parseVisionTargets(_ text: String) -> [VisionTarget] {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start < end else { return [] }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var targets: [VisionTarget] = []
        for obj in array {
            if let x = obj["x"] as? Double, let y = obj["y"] as? Double {
                targets.append(VisionTarget(x: min(max(x, 0), 1),
                                            y: min(max(y, 0), 1),
                                            label: (obj["label"] as? String) ?? ""))
            }
        }
        return Array(targets.prefix(8))
    }

    func syntheticItems(from targets: [VisionTarget], viewportWidth: Double, viewportHeight: Double) -> [DOMItemInfo] {
        visionClickables.removeAll()
        var items: [DOMItemInfo] = []
        let w = viewportWidth > 1 ? viewportWidth : 390
        let h = viewportHeight > 1 ? viewportHeight : 700
        for (i, target) in targets.enumerated() {
            let id = -(i + 1)
            let px = target.x * w
            let py = target.y * h
            visionClickables[id] = CGPoint(x: px, y: py)
            items.append(DOMItemInfo(
                id: id,
                tag: "vision",
                text: target.label,
                name: "",
                placeholder: "",
                aria: "",
                type: "",
                href: "",
                role: "button",
                submit: false,
                input: false,
                rect: DOMRectInfo(x: px - 12, y: py - 8, w: 24, h: 16)
            ))
        }
        return items
    }
}

struct VisionTarget {
    var x: Double
    var y: Double
    var label: String
}
