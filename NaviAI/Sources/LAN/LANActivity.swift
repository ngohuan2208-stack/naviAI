import Foundation
import Combine

// MARK: - Activity models

/// A single activity feed line shown on iPhone + every LAN client.
struct ActivityFeedItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var date: Date = Date()
    var message: String
    var kind: ActivityKind = .info

    enum ActivityKind: String, Codable, Equatable {
        case info, action, success, error, stop, task
    }

    var symbol: String {
        switch kind {
        case .info: return "circle"
        case .action: return "hand.point.right"
        case .success: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        case .stop: return "stop.circle"
        case .task: return "bolt"
        }
    }
}

/// The current task card shown in the Activity Center.
struct ActiveTaskCard: Codable, Equatable {
    var title: String = ""
    var continuation: String = ""
    var mode: String = ""
    var isRunning: Bool = false
    var currentStep: String = ""
    var progress: Int = 0          // 0...100
    var completedSteps: Int = 0
    var totalSteps: Int = 0

    /// JSON-safe projection for the LAN remote UI.
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

// MARK: - Realtime Activity Center

/// Single source of truth for live activity. Consumed by:
///  • the iPhone Activity Center UI,
///  • the LAN WebSocket broadcast (all paired clients),
///  • the diagnostics view.
@MainActor
final class LANActivityCenter: ObservableObject {

    static let shared = LANActivityCenter()

    @Published private(set) var currentTask = ActiveTaskCard()
    @Published private(set) var feed: [ActivityFeedItem] = []

    private let maxFeed = 300

    private init() {}

    // MARK: Task lifecycle

    func taskStarted(title: String, continuation: String, mode: String) {
        currentTask = ActiveTaskCard(title: title,
                                     continuation: continuation,
                                     mode: mode,
                                     isRunning: true,
                                     currentStep: "Starting…",
                                     progress: 0,
                                     completedSteps: 0,
                                     totalSteps: 0)
        add(message: title, kind: .task)
        objectWillChange.send()
    }

    func updateCurrent(currentStep: String, progress: Int) {
        currentTask.currentStep = currentStep
        currentTask.progress = min(100, max(0, progress))
        currentTask.completedSteps = currentTask.progress / 5
        objectWillChange.send()
    }

    func taskFinished(title: String) {
        currentTask.isRunning = false
        currentTask.currentStep = "Finished"
        add(message: "Task finished: \(title)", kind: .stop)
        objectWillChange.send()
    }

    func taskStateFrom(task: PersistedAgentTask?) {
        guard let task else {
            currentTask.isRunning = false
            objectWillChange.send()
            return
        }
        currentTask = ActiveTaskCard(title: task.goal,
                                     continuation: task.continuationPrompt,
                                     mode: task.mode,
                                     isRunning: task.status == .running,
                                     currentStep: task.currentStep,
                                     progress: task.progress,
                                     completedSteps: task.stepCount,
                                     totalSteps: AgentWatchdog.shared.maxSteps)
        objectWillChange.send()
    }

    // MARK: Feed

    func addFeed(_ message: String) {
        add(message: message, kind: .info)
    }

    /// Public add with a kind (used by agent loop + automation hooks).
    func add(message: String, kind: ActivityFeedItem.ActivityKind = .info) {
        var clean = message
        for banned in ["sk-", "Bearer ", "x-api-key", "apiKey", "api_key", "password"] {
            if clean.localizedCaseInsensitiveContains(banned) {
                clean = "(credential redacted)"
                break
            }
        }
        if clean.count > 300 { clean = String(clean.prefix(300)) + "…" }
        feed.append(ActivityFeedItem(message: clean, kind: kind))
        if feed.count > maxFeed {
            feed.removeFirst(feed.count - maxFeed)
        }
        objectWillChange.send()
    }

    func clearFeed() {
        feed.removeAll()
        objectWillChange.send()
    }
}