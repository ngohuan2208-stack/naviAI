import Foundation
import CoreGraphics

// MARK: - Natural interaction engine

/// Central place for the pacing of every automated interaction so the AI acts
/// like a calm human user instead of a machine-gun script:
///
///  • a minimum beat between two consecutive actions (no rapid-fire clicks)
///  • focus a field before typing into it
///  • typing is split into human-sized chunks with micro pauses
///  • waiting for pages / dynamic content to settle before the next action
///
/// This is about *natural, readable UX only*. It does NOT try to defeat
/// CAPTCHAs, anti-bot systems, device/behaviour detection or any other website
/// security mechanism — when a page shows a challenge, the agent stops and
/// asks the user to solve it (see BrowserStore.captchaPrompted handling).
@MainActor
final class InteractionEngine {

    static let shared = InteractionEngine()

    private init() {}

    // MARK: Tuning (kept modest; these are UX pacing values, not evasion)

    /// Minimum pause between two automation/agent actions.
    var interActionDelay: TimeInterval = 0.65
    /// Extra pause after clicking a link/button that navigates.
    var postClickDelay: TimeInterval = 0.9
    /// Extra pause after a form submit / Enter press.
    var postSubmitDelay: TimeInterval = 1.2
    /// Base delay between typed chunks.
    var typingChunkDelay: TimeInterval = 0.09

    private var lastActionDate: Date = .distantPast

    // MARK: Pacing

    /// Ensures a natural, non-rapid-fire rhythm between actions.
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

    /// Split text into human-sized chunks: words kept together, a chunk is
    /// roughly 3–8 characters, longer runs break at spaces.
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
            // Very long single tokens are split hard.
            while current.count > 12 {
                let idx = current.index(current.startIndex, offsetBy: 8)
                chunks.append(String(current[..<idx]))
                current = String(current[idx...])
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Micro pause used between typed chunks (human-like cadence).
    func typingPause() async {
        try? await Task.sleep(nanoseconds: UInt64(typingChunkDelay * 1_000_000_000))
    }

    // MARK: Waiting for pages / dynamic content

    /// Waits until the document is ready and the DOM has been quiet for a
    /// moment (dynamic content finished mutating), bounded by `timeout`.
    /// Returns true when the page settled, false on timeout/cancel.
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
                    // ReadyState complete AND DOM quiet for 700ms => settled.
                    if ready, Date().timeIntervalSince(lastMutation) >= 0.7 {
                        return true
                    }
                }
            } catch {
                // Page may be mid-navigation; keep waiting until the deadline.
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }
}
