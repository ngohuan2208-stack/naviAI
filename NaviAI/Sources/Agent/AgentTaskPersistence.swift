import Foundation
import Combine

// MARK: - Persisted agent task

/// Durable state of a continuous agent run. Survives suspensions, disconnects
/// and app restarts so the task can be restored and offered for resume.
struct PersistedAgentTask: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var goal: String = ""
    var continuationPrompt: String = ""
    var mode: String = "auto"          // view | interact | auto | debug
    var status: AgentTaskStatus = .running
    var completedSteps: [String] = []
    var pendingSteps: [String] = []
    var constraints: [String] = []
    var progress: Int = 0
    var currentStep: String = ""
    var stepCount: Int = 0
    var transcriptDigest: String = ""
    var stopReason: String? = nil
    var startedAt: Date = Date()
    var updatedAt: Date = Date()

    enum AgentTaskStatus: String, Codable, Equatable {
        case running
        case suspended     // app backgrounded / connection lost
        case completed
        case stopped
        case failed
    }
}

// MARK: - Persistence

/// JSON-file storage for the active/pending agent task (same pattern and
/// directory as AutomationPersistence). No secrets are ever stored here.
struct AgentTaskPersistence {

    static let shared = AgentTaskPersistence()

    private let fm = FileManager.default
    private let taskURL: URL

    private init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("AgentTasks", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        taskURL = dir.appendingPathComponent("active_task.json")
    }

    func load() -> PersistedAgentTask? {
        guard let data = try? Data(contentsOf: taskURL) else { return nil }
        return try? JSONDecoder().decode(PersistedAgentTask.self, from: data)
    }

    func save(_ task: PersistedAgentTask) {
        if let data = try? JSONEncoder().encode(task) {
            try? data.write(to: taskURL, options: .atomic)
        }
    }

    func clear() {
        try? fm.removeItem(at: taskURL)
    }
}

// MARK: - Continuation help

/// Persistent instruction attached to a running task. Compact task state is
/// rebuilt from the persisted task rather than resending the whole transcript.
enum AgentContinuation {

    /// A short, dense summary of the task that resumes exactly where we left
    /// off: goal, completed steps, pending steps, constraints, progress.
    static func compactState(of task: PersistedAgentTask) -> String {
        var parts: [String] = []
        parts.append("TASK GOAL: \(task.goal)")
        if !task.continuationPrompt.isEmpty {
            parts.append("CONTINUATION INSTRUCTION: \(task.continuationPrompt)")
        }
        if !task.completedSteps.isEmpty {
            parts.append("COMPLETED (" + String(task.completedSteps.count) + "):\n"
                + task.completedSteps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        }
        if !task.pendingSteps.isEmpty {
            parts.append("PENDING:\n" + task.pendingSteps.map { "• \($0)" }.joined(separator: "\n"))
        }
        if !task.constraints.isEmpty {
            parts.append("CONSTRAINTS:\n" + task.constraints.map { "• \($0)" }.joined(separator: "\n"))
        }
        parts.append("Progress: \(min(max(task.progress, 0), 100))%")
        return parts.joined(separator: "\n\n")
    }

    /// Decide whether we can keep `history` plus tool results, or must compact.
    /// Returns (keptHistory, compactionNote) using the last `keepLast` messages
    /// plus a compact task-state note — no endless growth, no lost objective.
    static func trimmed(history: [OutboundItem],
                        task: PersistedAgentTask?,
                        keepLast: Int = 14,
                        maxTotal: Int = 44) -> [OutboundItem] {
        guard history.count > maxTotal else {
            // Keep the objective pinned to the front at all times.
            var out = history
            if let task, !task.goal.isEmpty {
                out.removeAll { item in
                    if case .system(let s) = item { return s.contains("TASK OBJECTIVE (persistent)") }
                    return false
                }
                out.insert(.system("TASK OBJECTIVE (persistent): \(task.goal)\n\(AgentContinuation.compactState(of: task))"),
                           at: 0)
            }
            return out
        }
        var out = Array(history.suffix(keepLast))
        if let task {
            let note = "CONTEXT COMPRESSED. Original objective and state:\n"
                + AgentContinuation.compactState(of: task)
            out.insert(.system(note), at: 0)
        }
        return out
    }
}