import Foundation
import CoreGraphics

@MainActor
final class InteractionEngine {

    static let shared = InteractionEngine()

    private init() {}

    var interActionDelay: TimeInterval = 0.65

    var postClickDelay: TimeInterval = 0.9

    var postSubmitDelay: TimeInterval = 1.2

    var typingChunkDelay: TimeInterval = 0.09

    private var lastActionDate: Date = .distantPast

    func pauseBetweenActions() async {
        let elapsed = Date().timeIntervalSince(lastActionDate)
        let remaining = interActionDelay - elapsed
        if remaining > 0 {
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
        lastActionDate = Date()
    }

    func markAction() {
        lastActionDate = Date()
    }

    func typingChunks(for text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var chunks: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            let piece = String(word)
            if current.isEmpty {
                current = piece
            } else if current.count + piece.count + 1 <= 8 {
                current += " " + piece
            } else {
                chunks.append(current)
                current = piece
            }

            while current.count > 12 {
                let idx = current.index(current.startIndex, offsetBy: 8)
                chunks.append(String(current[..<idx]))
                current = String(current[idx...])
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    func typingPause() async {
        try? await Task.sleep(nanoseconds: UInt64(typingChunkDelay * 1_000_000_000))
    }

    func waitUntilPageReady(coordinator: WebCoordinator?, timeout: TimeInterval = 15) async -> Bool {
        guard let coordinator else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        var lastMutation = Date()
        var lastCount: Int = -1

        while Date() < deadline {
            if Task.isCancelled { return false }
            do {
                let value = try await coordinator.evaluate(BrowserJavaScript.readinessExpr())
                if let dict = value as? [String: Any] {
                    let ready = (dict["ready"] as? String) == "complete"
                    let count = (dict["interactiveCount"] as? Int) ?? -1
                    if count != lastCount {
                        lastCount = count
                        lastMutation = Date()
                    }

                    if ready, Date().timeIntervalSince(lastMutation) >= 0.7 {
                        return true
                    }
                }
            } catch {

            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }
}
