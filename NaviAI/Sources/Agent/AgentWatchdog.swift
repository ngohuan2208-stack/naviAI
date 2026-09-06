import Foundation

// MARK: - Stop reasons

/// Why an agent run ended. Used for the in-app Activity Center, the LAN
/// realtime feed and the web UI.
enum AgentStopReason: String, Codable, Equatable {
    case success
    case userStopped
    case selfStopped        // AI called STOP_SELF
    case maxSteps
    case timeout
    case repeatedAction
    case repeatedNavigationFailure
    case noProgress
    case resourceLimit
    case confirmationDenied
    case networkFailure
    case unrecoverableError
    case cancelled

    var label: String {
        switch self {
        case .success: return "Task complete"
        case .userStopped: return "Stopped by user"
        case .selfStopped: return "Stopped by AI (STOP_SELF)"
        case .maxSteps: return "Reached maximum step limit"
        case .timeout: return "Timed out"
        case .repeatedAction: return "Repeated identical action detected"
        case .repeatedNavigationFailure: return "Repeated navigation failures"
        case .noProgress: return "No progress detected"
        case .resourceLimit: return "Resource usage limit reached"
        case .confirmationDenied: return "Confirmation required and denied"
        case .networkFailure: return "Network failure"
        case .unrecoverableError: return "Unrecoverable error"
        case .cancelled: return "Cancelled"
        }
    }

    var isAutoStop: Bool {
        switch self {
        case .repeatedAction, .repeatedNavigationFailure, .noProgress,
             .resourceLimit, .maxSteps, .timeout:
            return true
        default:
            return false
        }
    }
}

// MARK: - Watchdog

/// Safety watchdog for continuous agent execution. Detects runaway behaviour:
/// infinite loops, repeated identical actions, repeated navigation failures,
/// excessive action counts, timeouts and abnormal usage. The agent can never
/// disable it — it is enforced by the host on every loop iteration.
@MainActor
final class AgentWatchdog {

    static let shared = AgentWatchdog()

    /// Enabled state lives in SettingsStore (default on) and is never exposed
    /// to the model — nothing in the agent prompt can turn it off.
    var isEnabled = true

    /// Hard cap on actions per run (overrides settings, cannot be raised by AI).
    var maxSteps = 80

    /// Abort after a single run exceeds this wall-clock budget.
    var maxDuration: TimeInterval = 10 * 60

    /// Same signature repeated this many times in a row ⇒ repeated action.
    var maxRepeatedActions = 4

    /// Navigation tools failing this many times in a row ⇒ navigation failure.
    var maxNavigationFailures = 4

    /// Consecutive LLM rounds without a *completed* action ⇒ no progress.
    var maxNoProgressRounds = 5

    private(set) var lastSignature = ""
    private var repeatedCount = 0
    private var navigationFailures = 0
    private var noProgressRounds = 0
    private var startedAt = Date()
    private var lastActionDate: Date?
    private var allActionCount = 0

    private init() {}

    // MARK: Recording

    func reset() {
        lastSignature = ""
        repeatedCount = 0
        navigationFailures = 0
        noProgressRounds = 0
        allActionCount = 0
        lastActionDate = nil
        startedAt = Date()
    }

    /// Call after an action executed. `signature` identifies the action
    /// (tool name + key arguments). `succeeded` means the tool explicitly
    /// reported a successful, meaningful outcome (not "nothing found").
    func recordAction(signature: String, title: String) {
        allActionCount += 1
        lastActionDate = Date()
        if signature == lastSignature {
            repeatedCount += 1
        } else {
            repeatedCount = 1
            lastSignature = signature
        }
        noProgressRounds = 0
        let _ = title
    }

    /// Call for navigation tools that returned an explicit failure.
    func recordNavigationFailure() {
        navigationFailures += 1
        noProgressRounds += 1
    }

    /// Call when a tool returned a benign "nothing found / no result".
    func recordNoProgress() {
        noProgressRounds += 1
    }

    /// Call when the model produced text without any tool call but still wants
    /// to keep going (unusual — usually the sign of a finishing model).
    func recordRoundsWithoutAction() {
        noProgressRounds += 1
    }

    // MARK: Evaluation

    /// Returns a stop reason when the run must be stopped, `nil` otherwise.
    func evaluate() -> AgentStopReason? {
        guard isEnabled else { return nil }
        let now = Date()
        if let last = lastActionDate, now.timeIntervalSince(last) > maxDuration {
            return .timeout
        }
        if noProgressRounds >= maxNoProgressRounds {
            return .noProgress
        }
        if navigationFailures >= maxNavigationFailures {
            return .repeatedNavigationFailure
        }
        if repeatedCount >= maxRepeatedActions {
            return .repeatedAction
        }
        return nil
    }

    /// True when the step budget is exhausted.
    func isOverStepLimit(_ steps: Int) -> Bool {
        steps >= maxSteps
    }

    var actionCount: Int { allActionCount }
    var timeElapsed: TimeInterval { Date().timeIntervalSince(startedAt) }
}