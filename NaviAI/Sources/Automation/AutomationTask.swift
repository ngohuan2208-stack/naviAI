import Foundation

enum AutomationStepKind: String, Codable, CaseIterable, Identifiable {
    case navigate
    case search
    case readPage
    case clickElement
    case typeText
    case scroll
    case extractText
    case wait
    case askLLM
    case notify

    var id: String { rawValue }

    var label: String {
        switch self {
        case .navigate: return "Open URL"
        case .search: return "Search web"
        case .readPage: return "Read page"
        case .clickElement: return "Click element"
        case .typeText: return "Type text"
        case .scroll: return "Scroll"
        case .extractText: return "Extract text"
        case .wait: return "Wait"
        case .askLLM: return "Ask AI"
        case .notify: return "Send notification"
        }
    }

    var symbol: String {
        switch self {
        case .navigate: return "link"
        case .search: return "magnifyingglass"
        case .readPage: return "doc.text"
        case .clickElement: return "hand.tap"
        case .typeText: return "keyboard"
        case .scroll: return "arrow.down.circle"
        case .extractText: return "text.quote"
        case .wait: return "clock"
        case .askLLM: return "brain.head.profile"
        case .notify: return "bell"
        }
    }

    var toolName: String? {
        switch self {
        case .navigate: return "openURL"
        case .search: return "searchWeb"
        case .readPage: return "readPage"
        case .clickElement: return "clickElement"
        case .typeText: return "typeText"
        case .scroll: return "scroll"
        default: return nil
        }
    }
}

struct AutomationStep: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var kind: AutomationStepKind

    var value: String = ""

    var amount: Int?

    var note: String = ""

    var summary: String {
        switch kind {
        case .navigate: return "Open \(value)"
        case .search: return "Search “\(value)”"
        case .readPage: return "Read current page"
        case .clickElement: return "Click “\(value)”"
        case .typeText: return "Type into “\(value)”" + (note.isEmpty ? "" : " — “\(note.prefix(32))”")
        case .scroll: return "Scroll \(value.isEmpty ? "down" : value)"
        case .extractText: return "Extract page text"
        case .wait: return "Wait \(amount ?? 3)s"
        case .askLLM: return "Ask AI: \(value.prefix(48))"
        case .notify: return "Notify: \(value.prefix(48))"
        }
    }
}

struct AutomationSchedule: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case runOnce
        case repeat_

        var id: String { rawValue }
        var label: String {
            switch self {
            case .runOnce: return "Run once"
            case .repeat_: return "Repeat"
            }
        }
    }

    var kind: Kind = .runOnce

    var intervalSeconds: TimeInterval = 600

    var delaySeconds: TimeInterval = 10

    var startTime: String? = nil
    var endTime: String? = nil

    var maxRuns: Int? = nil

    var endDate: Date? = nil

    static let presetIntervals: [TimeInterval] = [10, 30, 60, 300, 600, 1800, 3600]

    var intervalLabel: String {
        let s = Int(intervalSeconds)
        if s < 60 { return "every \(s) sec" }
        if s < 3600 { return "every \(s / 60) min" }
        if s < 86_400 { return "every \(s / 3600) h" }
        return "every \(s / 86_400) d"
    }

    var delayLabel: String {
        let s = Int(delaySeconds)
        if s < 60 { return "in \(s) sec" }
        if s < 3600 { return "in \(s / 60) min" }
        return "in \(s / 3600) h"
    }

    static func parseClock(_ text: String?) -> (h: Int, m: Int)? {
        guard let text, !text.isEmpty else { return nil }
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
        return (parts[0], parts[1])
    }
}

struct RetryPolicy: Codable, Equatable {

    var maxRetries: Int = 0

    var retryDelaySeconds: TimeInterval = 30

    static let none = RetryPolicy()
}

enum ConfirmationPolicy: String, Codable, CaseIterable, Identifiable {

    case always

    case riskyActions

    case never

    var id: String { rawValue }

    var label: String {
        switch self {
        case .always: return "Always ask"
        case .riskyActions: return "Ask for risky actions"
        case .never: return "Never ask (skip risky)"
        }
    }
}

enum AutomationTaskStatus: String, Codable {
    case scheduled
    case running
    case paused
    case completed
    case failed
    case cancelled
    case suspended

    var label: String {
        switch self {
        case .scheduled: return "Scheduled"
        case .running: return "Running"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .suspended: return "Suspended"
        }
    }

    var symbol: String {
        switch self {
        case .scheduled: return "calendar.badge.clock"
        case .running: return "play.circle.fill"
        case .paused: return "pause.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle.fill"
        case .suspended: return "moon.zzz.fill"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }
}

struct AutomationTask: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var description: String = ""
    var steps: [AutomationStep] = []
    var schedule: AutomationSchedule = AutomationSchedule()
    var timeout: TimeInterval = 600
    var maxSteps: Int = 40
    var retryPolicy: RetryPolicy = .none
    var confirmationPolicy: ConfirmationPolicy = .riskyActions
    var status: AutomationTaskStatus = .scheduled
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var lastRun: Date? = nil
    var nextRun: Date? = nil
    var runCount: Int = 0

    var pendingRunState: PendingRunState? = nil

    struct PendingRunState: Codable, Equatable {
        var stepIndex: Int
        var startedAt: Date
        var trigger: String
    }

    var hasBound: Bool {
        schedule.maxRuns != nil || schedule.endDate != nil || schedule.kind == .runOnce ||
        AutomationSchedule.parseClock(schedule.endTime) != nil
    }

    static func == (lhs: AutomationTask, rhs: AutomationTask) -> Bool {
        lhs.id == rhs.id && lhs.updatedAt == rhs.updatedAt && lhs.status == rhs.status
    }
}

struct AutomationRun: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var taskID: UUID
    var taskName: String
    var startTime: Date
    var endTime: Date
    var status: AutomationTaskStatus
    var stepsExecuted: Int
    var totalSteps: Int
    var result: String
    var error: String?
    var userConfirmations: [String] = []
    var trigger: String = "manual"

    var duration: TimeInterval { endTime.timeIntervalSince(startTime) }

    var durationLabel: String {
        let s = Int(duration)
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }
}
