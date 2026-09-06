import Foundation

enum AgentStopReason: String, Codable, Equatable {
    case success
    case userStopped
    case selfStopped
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

@MainActor
final class AgentWatchdog {

    static let shared = AgentWatchdog()

    var isEnabled = true

    var maxSteps = 80

    var maxDuration: TimeInterval = 10 * 60

    var maxRepeatedActions = 4

    var maxNavigationFailures = 4

    var maxNoProgressRounds = 5

    private(set) var lastSignature = ""
    private var repeatedCount = 0
    private var navigationFailures = 0
    private var noProgressRounds = 0
    private var startedAt = Date()
    private var lastActionDate: Date?
    private var allActionCount = 0

    private init() {}

    func reset() {
        lastSignature = ""
        repeatedCount = 0
        navigationFailures = 0
        noProgressRounds = 0
        allActionCount = 0
        lastActionDate = nil
        startedAt = Date()
    }

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

    func recordNavigationFailure() {
        navigationFailures += 1
        noProgressRounds += 1
    }

    func recordNoProgress() {
        noProgressRounds += 1
    }

    func recordRoundsWithoutAction() {
        noProgressRounds += 1
    }

    func evaluate() -> AgentStopReason? {
        guard isEnabled else { return nil }
        let now = Date()
        if now.timeIntervalSince(startedAt) > maxDuration {
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

    func isOverStepLimit(_ steps: Int) -> Bool {
        steps >= maxSteps
    }

    var actionCount: Int { allActionCount }
    var timeElapsed: TimeInterval { Date().timeIntervalSince(startedAt) }
}
