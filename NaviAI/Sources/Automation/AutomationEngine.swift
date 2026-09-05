import Foundation
import UIKit

// MARK: - Automation engine errors

enum AutomationEngineError: LocalizedError {
    case noProvider
    case noAPIKey
    case noBrowser
    case timeout
    case cancelled
    case riskyActionSkipped
    case stepFailed(String)

    var errorDescription: String? {
        switch self {
        case .noProvider: return "No AI provider selected."
        case .noAPIKey: return "API key missing for the active provider."
        case .noBrowser: return "No active browser tab."
        case .timeout: return "Task timed out."
        case .cancelled: return "Task cancelled."
        case .riskyActionSkipped: return "Risky action skipped (confirmation required)."
        case .stepFailed(let m): return m
        }
    }
}

// MARK: - Run delegate

/// Bridge between the engine and the rest of the app (UI, history,
/// notifications, background handling). Implemented by AutomationScheduler.
@MainActor
protocol AutomationEngineDelegate: AnyObject {
    func engineDidStartRun(_ engine: AutomationEngine, task: AutomationTask, runID: UUID)
    func engine(_ engine: AutomationEngine, task: AutomationTask, runID: UUID, willExecuteStepAt index: Int, step: AutomationStep)
    func engine(_ engine: AutomationEngine, task: AutomationTask, runID: UUID, didLog message: String)
    /// Called when the policy requires a user decision. The run SUSPENDS (the
    /// whole async chain waits) until the user answers in the UI.
    func engine(_ engine: AutomationEngine, task: AutomationTask, runID: UUID, requiresConfirmation message: String, for step: AutomationStep) async -> Bool
    func engine(_ engine: AutomationEngine, task: AutomationTask, runID: UUID, didFinishWith status: AutomationTaskStatus, stepsExecuted: Int, result: String, error: String?, confirmations: [String])
}

// MARK: - Automation engine

/// Executes the steps of an `AutomationTask` against the live browser.
///
/// Real implementation notes:
///  • Browser steps reuse `BrowserStore.executeTool(named:argumentsJSON:)` —
///    the same battle-tested path the interactive agent uses, which already
///    performs natural cursor movement, focus-before-type, page settling and
///    CAPTCHA detection (it stops and asks; it never bypasses protections).
///  • Token optimization: the model is NOT part of step execution — only
///    `askLLM` steps call the provider, and they send only compressed page
///    context (title, URL, trimmed text), never a full DOM dump.
///  • Every run is bounded by `task.maxSteps` and `task.timeout`.
@MainActor
final class AutomationEngine: ObservableObject {

    weak var delegate: AutomationEngineDelegate?
    weak var browser: BrowserStore?

    /// The task currently executing (for the floating status card).
    @Published var runningTaskID: UUID?
    @Published var currentStepIndex: Int = 0
    @Published var currentStepTotal: Int = 0
    @Published var currentSummary: String = ""

    private var runTask: Task<Void, Never>?
    private var timedOut = false

    var isRunning: Bool { runTask != nil }

    // MARK: Control

    func start(task: AutomationTask, trigger: String = "manual", runID: UUID = UUID()) {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.run(task: task, runID: runID, trigger: trigger)
            self.runTask = nil
        }
    }

    func stop() {
        runTask?.cancel()
    }

    // MARK: The run loop

    private func run(task: AutomationTask, runID: UUID, trigger: String) async {
        let startedAt = Date()
        var stepsExecuted = 0
        var confirmations: [String] = []
        var lastPageIndex: Int? = nil
        // Task recovery: when resuming a suspended run, continue AFTER the
        // last persisted step instead of restarting from scratch.
        let startStep = task.pendingRunState?.stepIndex ?? 0

        runningTaskID = task.id
        currentStepIndex = 0
        currentStepTotal = task.steps.count
        currentSummary = task.name
        delegate?.engineDidStartRun(self, task: task, runID: runID)
        delegate?.engine(self, task: task, runID: runID, didLog: "Task started (\(trigger))")

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(task.timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.timedOut = true
            self?.runTask?.cancel()
        }
        defer { timeoutTask.cancel() }

        var finalStatus: AutomationTaskStatus = .completed
        var resultText = "Task finished."
        var errorMessage: String? = nil
        timedOut = false

        do {
            guard browser != nil else { throw AutomationEngineError.noBrowser }
            guard task.steps.isEmpty == false else { throw AutomationEngineError.stepFailed("Task has no steps.") }

            for (index, step) in task.steps.enumerated() {
                if index < startStep { continue }
                try Task.checkCancellation()
                if stepsExecuted >= task.maxSteps {
                    resultText = "Reached the step limit (\(task.maxSteps))."
                    break
                }

                currentStepIndex = index + 1
                currentSummary = step.summary
                delegate?.engine(self, task: task, runID: runID, willExecuteStepAt: index, step: step)
                delegate?.engine(self, task: task, runID: runID, didLog: "\(step.summary)")

                // Confirmation policy (item 12) — risky actions never run
                // silently. ".always" asks for every step; ".riskyActions"
                // only for risky ones; ".never" SKIPS risky steps (it never
                // performs them silently).
                let risk = AgentToolRegistry.riskLevel(for: step.kind)
                let needsAsk = task.confirmationPolicy == .always ||
                               (risk == .risky && task.confirmationPolicy == .riskyActions)
                if needsAsk {
                    delegate?.engine(self, task: task, runID: runID, didLog: "Waiting for user confirmation…")
                    let granted = await delegate?.engine(self, task: task, runID: runID,
                                                         requiresConfirmation: "\(step.summary) — allow this action?",
                                                         for: step) ?? false
                    confirmations.append("\(step.summary): \(granted ? "allowed" : "denied")")
                    if !granted {
                        delegate?.engine(self, task: task, runID: runID, didLog: "User denied the action.")
                        continue
                    }
                } else if risk == .risky, task.confirmationPolicy == .never {
                    delegate?.engine(self, task: task, runID: runID, didLog: "Skipped risky step (policy: never ask).")
                    continue
                }

                let outcome = try await execute(step: step, task: task)
                stepsExecuted += 1

                if let askResult = outcome {
                    // askLLM step produced the final answer.
                    resultText = askResult
                }
                await InteractionEngine.shared.pauseBetweenActions()
            }
        } catch is CancellationError {
            if timedOut {
                finalStatus = .failed
                resultText = "Task timed out."
                errorMessage = AutomationEngineError.timeout.localizedDescription
            } else {
                finalStatus = .cancelled
                resultText = "Task cancelled."
                errorMessage = AutomationEngineError.cancelled.localizedDescription
            }
        } catch let e as AutomationEngineError {
            finalStatus = .failed
            errorMessage = e.localizedDescription
            resultText = "Failed: \(e.localizedDescription)"
        } catch {
            finalStatus = .failed
            errorMessage = error.localizedDescription
            resultText = "Failed: \(error.localizedDescription)"
        }

        if Task.isCancelled && finalStatus == .completed {
            finalStatus = .cancelled
        }

        delegate?.engine(self, task: task, runID: runID,
                         didFinishWith: finalStatus,
                         stepsExecuted: stepsExecuted,
                         result: resultText,
                         error: errorMessage,
                         confirmations: confirmations)
        runningTaskID = nil
        currentSummary = ""
    }

    /// Executes one step. Returns a non-nil string when the step produced the
    /// run's final result (askLLM).
    private func execute(step: AutomationStep, task: AutomationTask) async throws -> String? {
        guard let browser else { throw AutomationEngineError.noBrowser }
        await InteractionEngine.shared.pauseBetweenActions()

        switch step.kind {
        case .wait:
            let seconds = min(60, max(1, Double(step.amount ?? 3)))
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil

        case .notify:
            AutomationNotification.shared.postLocal(title: "Navi AI", body: step.value.isEmpty ? task.name : step.value)
            return nil

        case .askLLM:
            return try await askLLM(task: task, prompt: step.value)

        case .extractText:
            let maxChars = step.amount ?? 4000
            let value = try await browser.agentEvaluate(BrowserJavaScript.readTextExpr(maxChars: maxChars))
            let text = (value as? String) ?? ""
            let excerpt = text.count > 160 ? String(text.prefix(160)) + "…" : text
            if !excerpt.isEmpty {
                delegate?.engine(self, task: task, runID: UUID(), didLog: "Extracted \(text.count) chars: \(excerpt)")
            }
            return nil

        case .navigate, .search, .readPage, .clickElement, .typeText, .scroll:
            let arguments = try stepArguments(for: step, browser: browser)
            guard let toolName = step.kind.toolName else { return nil }
            let output = await browser.executeTool(named: toolName, argumentsJSON: arguments)
            if output.lowercased().contains("blocked") || output.lowercased().hasPrefix("could not") {
                throw AutomationEngineError.stepFailed(output)
            }
            return nil
        }
    }

    // MARK: Step arguments

    /// Builds the tool-call arguments for a step. For click/type steps the
    /// step's `value` is a *text hint*; we resolve it to a live elementId by
    /// running findText against the page (real elements, no blind clicks).
    private func stepArguments(for step: AutomationStep, browser: BrowserStore) throws -> String {
        switch step.kind {
        case .navigate:
            return Self.jsonString(["url": step.value])
        case .search:
            return Self.jsonString(["query": step.value])
        case .readPage, .extractText:
            return "{}"
        case .scroll:
            let dir = step.value.isEmpty ? "down" : step.value
            return Self.jsonString(["direction": dir, "amount": step.amount ?? 700])
        case .clickElement:
            if let id = step.amount {
                return Self.jsonString(["elementId": id])
            }
            let id = try resolveElementID(matching: step.value, preferInput: false, browser: browser)
            return Self.jsonString(["elementId": id])
        case .typeText:
            // Editor contract: `value` = field text hint, `note` = the text to
            // type (falls back to value when created programmatically).
            let text = step.note.isEmpty ? step.value : step.note
            if let id = step.amount {
                return Self.jsonString(["elementId": id, "text": text])
            }
            let id = try resolveElementID(matching: step.value, preferInput: true, browser: browser)
            return Self.jsonString(["elementId": id, "text": text, "pressEnter": false])
        case .wait, .notify, .askLLM:
            return "{}"
        }
    }

    /// Resolves an element text hint (e.g. "Search") to the current elementId
    /// via the page's own findText engine. Refreshed on every run, so stale
    /// ids never accumulate across scheduled runs.
    private func resolveElementID(matching hint: String, preferInput: Bool, browser: BrowserStore) throws -> Int {
        guard !hint.isEmpty else {
            throw AutomationEngineError.stepFailed("Element hint is empty for a click/type step.")
        }
        let blocked = browser.agentMode.permitsInteraction == false
        if blocked {
            throw AutomationEngineError.stepFailed("View mode is read-only; switch to Interact/Auto to automate clicks.")
        }
        let value = try? await browser.agentEvaluate(BrowserJavaScript.findTextExpr(query: hint, max: 8))
        guard let value,
              let data = (value as? String)?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(FindList.self, from: data) else {
            throw AutomationEngineError.stepFailed("Could not search the page for “\(hint)”.")
        }
        let items = decoded.items
        guard !items.isEmpty else {
            throw AutomationEngineError.stepFailed("No element matching “\(hint)” on the page.")
        }
        if preferInput, let input = items.first(where: { $0.input }) {
            return input.id
        }
        return items[0].id
    }

    struct FindList: Codable { var items: [DOMItemInfo] }

    // MARK: Token-optimized LLM step

    /// `askLLM` sends ONLY compressed page context — title, URL, a trimmed
    /// body excerpt and the action summary so far. Never a full DOM dump,
    /// never past screenshots, never API keys.
    private func askLLM(task: AutomationTask, prompt: String) async throws -> String {
        guard let browser else { throw AutomationEngineError.noBrowser }
        guard let config = browser.providers.activeProvider else { throw AutomationEngineError.noProvider }
        guard let key = browser.providers.apiKey(for: config), !key.isEmpty else { throw AutomationEngineError.noAPIKey }

        var pageLine = "No page open."
        if let tab = browser.activeTab {
            let title = tab.title.isEmpty ? "untitled" : tab.title
            let url = tab.webView.url?.absoluteString ?? "about:blank"
            pageLine = "Current page: \(title) (\(url))"
        }

        let sys = """
        You are the reasoning step of a scheduled browser automation. Answer ONLY the user's request using the compressed page context. Be concise (<= 200 words). Never invent content that is not in the context.

        \(pageLine)
        """

        let reply = try await browser.llm.complete(
            config: config,
            apiKey: key,
            history: [.system(sys), .userText(prompt)],
            tools: []
        )
        return reply.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "(no answer)"
    }

    // MARK: JSON helper

    private static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
