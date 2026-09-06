import Foundation
import UIKit

extension BrowserStore {

    func submitPrompt(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if isAgentRunning {
            appendInfo("The agent is still working. Tap STOP before sending a new request.")
            return
        }
        turns.append(ChatTurn(role: .user, kind: .text, text: text))
        apiHistory.append(.userText(text))
        captchaPrompted = false
        taskGoal = text

        isAgentRunning = true
        agentStatus = .thinking

        let task = Task { [weak self] in
            await self?.runAgentSession()
            self?.isAgentRunning = false
            self?.agentTask = nil
        }
        agentTask = task
    }

    func stopAgent() {
        agentTask?.cancel()

        resolvePrompt(false)
        if isAgentRunning {
            isAgentRunning = false
        }
        if case .idle = agentStatus {} else {
            agentStatus = .stopped
        }
        hideCursor()
        turns.append(ChatTurn(role: .assistant, kind: .info, text: "Agent stopped."))
    }

    func resolvePrompt(_ allow: Bool) {
        if let cont = promptContinuation {
            promptContinuation = nil
            activePrompt = nil
            cont.resume(returning: allow)
        } else {
            activePrompt = nil
        }
    }

    func agentToolSpecs() -> [AgentToolSpec] {
        func str(_ title: String, _ desc: String) -> [String: Any] {
            ["type": "string", "title": title, "description": desc]
        }
        let bool = ["type": "boolean"] as [String: Any]
        let int = ["type": "integer"] as [String: Any]

        func schema(_ required: [String], _ props: [String: Any]) -> [String: Any] {
            ["type": "object", "properties": props, "required": required]
        }

        let all: [AgentToolSpec] = [
            AgentToolSpec(name: "openURL",
                          description: "Open a specific URL (http/https) in the current tab and wait for it to load.",
                          parameters: schema(["url"], ["url": str("url", "The full URL to open, e.g. https://example.com/page")])),
            AgentToolSpec(name: "searchWeb",
                          description: "Search the web using the default search engine and load the results page.",
                          parameters: schema(["query"], ["query": str("query", "The search query")])),
            AgentToolSpec(name: "readPage",
                          description: "Read the current page: URL, title, main text and the list of interactive elements with their elementId. Call this after navigating or before interacting.",
                          parameters: schema([], [:])),
            AgentToolSpec(name: "findText",
                          description: "Find interactive elements on the current page whose text contains the given phrase. Returns elementIds you can clickElement or typeText.",
                          parameters: schema(["text"], ["text": str("text", "Text to look for")])),
            AgentToolSpec(name: "clickElement",
                          description: "Click an element identified by elementId from a readPage/findText listing. The AI mouse will move to the element, animate a click, then click it.",
                          parameters: schema(["elementId"], ["elementId": int])),
            AgentToolSpec(name: "typeText",
                          description: "Type text into a text field identified by elementId. Set pressEnter=true to submit a single-line field with the Enter key.",
                          parameters: schema(["elementId", "text"], [
                            "elementId": int,
                            "text": str("text", "The text to type"),
                            "pressEnter": bool
                          ])),
            AgentToolSpec(name: "scroll",
                          description: "Scroll the page. direction is up, down, left, right, top or bottom. amount is a pixel hint (default 700).",
                          parameters: schema(["direction"], [
                            "direction": str("direction", "up, down, left, right, top or bottom"),
                            "amount": int
                          ])),
            AgentToolSpec(name: "goBack", description: "Go back in history of the current tab.", parameters: schema([], [:])),
            AgentToolSpec(name: "goForward", description: "Go forward in history of the current tab.", parameters: schema([], [:])),
            AgentToolSpec(name: "reload", description: "Reload the current page.", parameters: schema([], [:])),
            AgentToolSpec(name: "openTab", description: "Open a new tab (optionally to a URL) and switch to it.", parameters: schema([], ["url": str("url", "Optional URL")])),
            AgentToolSpec(name: "switchTab", description: "Switch to another open tab by its index (0-based, see the tab list in readPage).", parameters: schema(["index"], ["index": int])),
            AgentToolSpec(name: "closeTab", description: "Close a tab by index (optional). Without index closes the current tab.", parameters: schema([], ["index": int])),
            AgentToolSpec(name: "screenshot",
                          description: "Capture a screenshot of the current page and attach it to the conversation context.",
                          parameters: schema([], [:])),
            AgentToolSpec(name: "capture_web_screenshot",
                          description: "Capture a JPEG screenshot of the currently visible web page (viewport only). Returns dimensions and size. The image is merged into the next model turn as vision evidence when the model supports images. Use sparingly — captures are throttled.",
                          parameters: schema([], [:])),
            AgentToolSpec(name: "stopSelf",
                          description: "Stop the current task. Call this when the objective is complete, impossible, requires missing information, fails repeatedly, or the user's goal has been satisfied.",
                          parameters: schema(["reason"], ["reason": str("reason", "Short reason: complete | impossible | missing_info | repeated_failure | satisfied")])),
            AgentToolSpec(name: "generateImage",
                          description: "Generate an image from a text prompt with the configured image provider. Returns the saved file path.",
                          parameters: schema(["prompt"], [
                            "prompt": str("prompt", "Description of the image to generate"),
                            "size": str("size", "Optional size, e.g. 1024x1024")
                          ]))
        ]

        if !agentMode.permitsInteraction {
            return all.filter { ["readPage", "findText"].contains($0.name) }
        }
        return all
    }

    func activePageLine() -> String {
        guard let tab = activeTab else { return "No tab open." }
        let title = tab.title.isEmpty ? "untitled" : tab.title
        let url = tab.webView.url?.absoluteString ?? "about:blank"
        return "Current tab: [\(title)](\(url))"
    }

    func tabListLine() -> String {
        let list = tabs.enumerated().map { "\($0.offset): \($0.element.title.isEmpty ? ($0.element.webView.url?.absoluteString ?? "new tab") : $0.element.title)" }
        return "Open tabs (index: title):\n" + (list.isEmpty ? "none" : list.joined(separator: "\n"))
    }

    private func runAgentSession() async {
        guard let config = providers.activeProvider else {
            finishWith(info: "No AI provider selected. Choose one in Settings.")
            return
        }
        guard let apiKey = providers.apiKey(for: config), !apiKey.isEmpty else {
            finishWith(info: "Please add an API key for \(config.name) in Settings.")
            return
        }

        let task: PersistedAgentTask
        if let existing = runningTask {
            task = existing
        } else {
            task = PersistedAgentTask(goal: taskGoal, continuationPrompt: persistentContinuationPrompt)
        }
        task.mode = agentMode.rawValue
        task.status = .running
        runningTask = task
        persistTask()

        AgentWatchdog.shared.reset()
        AgentWatchdog.shared.isEnabled = settings.agentWatchdogEnabled
        AgentWatchdog.shared.maxSteps = max(30, settings.agentMaxContinuousSteps)
        stopSelfRequested = false

        var stepCount = 0
        let maxSteps = AgentWatchdog.shared.maxSteps
        agentStep = 0

        while true {
            if Task.isCancelled {
                finishTask(reason: .cancelled)
                return
            }

            if stopSelfRequested {
                finishTask(reason: .selfStopped)
                return
            }
            if let reason = AgentWatchdog.shared.evaluate() {
                finishTask(reason: reason)
                return
            }

            if !captchaPrompted, let signals = try? await fetchSignals(),
               signals.hasCaptchaFrame || !signals.bodyHint.isEmpty {
                captchaPrompted = true
                agentStatus = .waitingForUser
                let granted = await requestUserDecision(
                    kind: .captcha,
                    title: "Human verification required",
                    message: "A CAPTCHA or security check appeared. Solve it manually in the page, then continue. NaviAI never bypasses anti-bot checks.",
                    allowTitle: "I solved it — Continue",
                    denyTitle: "Stop"
                )
                if !granted { finishTask(reason: .userStopped); return }
                continue
            }

            agentStatus = .thinking

            let pageContext = await visiblePageContextText() + "\n" + tabListLine()
            let sys = agentSystemPrompt(pageContext: pageContext)

            var history: [OutboundItem] = [.system(sys)]
            if let task = runningTask, !task.goal.isEmpty {
                history.append(.system("TASK OBJECTIVE (persistent): \(task.goal)\n\(AgentContinuation.compactState(of: task))"))
            }

            history.append(contentsOf: AgentContinuation.trimmed(history: apiHistory, task: runningTask))

            if let shot = pendingVisionScreenshot, isVisionFallbackAvailable {
                history.append(.userVision(
                    text: "Screenshot evidence of the current page (captured at \(shot.capturedAt)). Use it to understand what the user sees.",
                    imageBase64: shot.base64,
                    mimeType: "image/jpeg"))
                pendingVisionScreenshot = nil
            }

            do {
                let reply = try await llm.complete(
                    config: config,
                    apiKey: apiKey,
                    history: history,
                    tools: agentToolSpecs()
                )

                if Task.isCancelled {
                    finishTask(reason: .cancelled)
                    return
                }

                if !reply.toolCalls.isEmpty {
                    for call in reply.toolCalls {
                        if Task.isCancelled { finishTask(reason: .cancelled); return }
                        if stopSelfRequested || call.name == "stopSelf" {
                            finishTask(reason: .selfStopped)
                            return
                        }

                        let actionNote = describeAction(call)
                        if !actionNote.isEmpty {
                            turns.append(ChatTurn(role: .assistant, kind: .action, text: actionNote))
                        }
                        apiHistory.append(.assistantToolCall(id: call.id, name: call.name, argumentsJSON: call.argumentsJSON))

                        let result = await executeTool(named: call.name, argumentsJSON: call.argumentsJSON)
                        apiHistory.append(.toolResult(toolCallID: call.id, content: result))
                        stepCount += 1
                        agentStep = stepCount
                        task.stepCount = stepCount
                        activityStep(actionNote.isEmpty ? "Executing \(call.name)…" : actionNote)
                        trackWatchdog(for: call, result: result)

                        if stopSelfRequested {
                            finishTask(reason: .selfStopped)
                            return
                        }
                        if stepCount >= maxSteps {
                            finishWith(info: "Reached the maximum number of actions (\(maxSteps)). Please continue with a new request.", reason: .maxSteps)
                            return
                        }
                    }
                    continue
                }

                if let text = reply.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    turns.append(ChatTurn(role: .assistant, kind: .text, text: answer))
                    apiHistory.append(.assistantText(answer))
                    cursor.visible = false
                    cursor.isPressing = false
                    cursor.label = nil
                    agentStatus = .done
                    activity("✅ Task complete")
                    finishTask(reason: .success)
                    return
                }

                turns.append(ChatTurn(role: .assistant, kind: .info, text: "AI needs clarification. Please rephrase or be more specific."))
                agentStatus = .error("AI needs clarification")
                finishTask(reason: .unrecoverableError)
                return
            } catch AIError.cancelled {
                finishTask(reason: .cancelled)
                return
            } catch {
                let err = (error as? AIError) ?? .network(error)
                turns.append(ChatTurn(role: .assistant, kind: .info, text: err.friendlyMessage))
                agentStatus = .error(err.friendlyMessage)
                var isNet = false
                if case .network = err { isNet = true }
                finishTask(reason: err == .cancelled ? .cancelled
                                     : (isNet ? .networkFailure : .unrecoverableError))
                return
            }
        }
    }

    private func finishWith(info: String, reason: AgentStopReason = .success) {
        turns.append(ChatTurn(role: .assistant, kind: .info, text: info))
        cursor.visible = false
        cursor.isPressing = false
        cursor.label = nil
        agentStatus = reason.isAutoStop ? .stopped : .done
        isAgentRunning = false
        finishTask(reason: reason)
    }

    private func describeAction(_ call: ToolCallRequest) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(call.argumentsJSON.utf8)) as? [String: Any]) ?? nil
        switch call.name {
        case "openURL":
            return "Opening \(args?["url"] as? String ?? "…")"
        case "searchWeb":
            return "Searching: \(args?["query"] as? String ?? "…")"
        case "readPage":
            return "Reading page…"
        case "findText":
            return "Finding “\(args?["text"] as? String ?? "")” on the page…"
        case "clickElement":
            return "Clicking element \(args?["elementId"] as? Int ?? -1)…"
        case "typeText":
            return "Typing into element \(args?["elementId"] as? Int ?? -1)…"
        case "scroll":
            return "Scrolling \(args?["direction"] as? String ?? "…")…"
        case "goBack":
            return "Going back…"
        case "goForward":
            return "Going forward…"
        case "reload":
            return "Reloading page…"
        case "openTab":
            return "Opening new tab…"
        case "switchTab":
            return "Switching to tab \(args?["index"] as? Int ?? -1)…"
        case "closeTab":
            return "Closing tab…"
        default:
            return "\(call.name)…"
        }
    }

    private func agentSystemPrompt(pageContext: String) -> String {
        """
        You are NaviAI, an AI browser agent running inside a WKWebView on iOS. You control a real browser with tools.

        \(agentMode.systemInstruction)

        Page context:
        \(pageContext)

        Rules:
        - Always prefer the DOM: read the page with readPage, choose elements by elementId, then act.
        - Use searchWeb to find things, open results with openURL, then readPage again.
        - Never invent content. Only claim something exists if the page really shows it.
        - To reach results lower on a page, scroll and readPage again.
        - If you meet a CAPTCHA or anti-bot challenge, stop and tell the user you need them to solve it. You must NOT try to bypass it.
        - If you are about to send a form/message, purchase, delete data or change account info, mention it clearly - the user will be asked to confirm.
        - You run CONTINUOUSLY: observe → think → act → observe, until the objective is complete. Do not stop after one step.
        - When the objective is finished, call stopSelf(reason: "complete") and give the final answer in the user's language.
        - If the task cannot be completed (missing info, impossible, repeated failures), call stopSelf with the matching reason instead of looping forever.
        - Use capture_web_screenshot as visual evidence when you need to see what the user sees; otherwise prefer readPage.
        - If the page changes or an elementId is stale, call readPage again to refresh the listing.

        \(persistentContinuationPrompt.isEmpty ? "" : "CONTINUATION INSTRUCTION FROM USER (keep doing this until otherwise told):\n\(persistentContinuationPrompt)")
        """
    }

    func requestUserDecision(kind: PromptKind, title: String, message: String, allowTitle: String, denyTitle: String?) async -> Bool {
        if kind == .action && !settings.aiConfirmationEnabled {
            return true
        }
        activePrompt = UserPrompt(kind: kind, title: title, message: message, allowTitle: allowTitle, denyTitle: denyTitle)
        return await withCheckedContinuation { cont in
            promptContinuation = cont
        }
    }

    func startContinuousTask(goal: String, continuationPrompt: String = "") {
        let text = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if isAgentRunning {
            appendInfo("The agent is still working. Tap STOP before starting a new task.")
            return
        }
        turns.append(ChatTurn(role: .user, kind: .text, text: text))
        apiHistory.append(.userText(text))
        captchaPrompted = false
        taskGoal = text
        persistentContinuationPrompt = continuationPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        runningTask = nil

        isAgentRunning = true
        agentStatus = .thinking
        activityStart(goal: text, continuation: persistentContinuationPrompt)

        let handle = Task { [weak self] in
            await self?.runAgentSession()
            self?.isAgentRunning = false
            self?.agentTask = nil
        }
        agentTask = handle
    }

    @discardableResult
    func resumeContinuousTask() -> Bool {
        guard let persisted = AgentTaskPersistence.shared.load() else { return false }
        guard persisted.status == .suspended || persisted.status == .running else { return false }
        if isAgentRunning { return false }
        turns.append(ChatTurn(role: .assistant, kind: .info, text: "Resuming previous task: \(persisted.goal)"))
        taskGoal = persisted.goal
        persistentContinuationPrompt = persisted.continuationPrompt
        runningTask = persisted
        runningTask?.status = .running
        isAgentRunning = true
        agentStatus = .thinking
        activity("↩ Resuming task: \(persisted.goal)")
        let handle = Task { [weak self] in
            await self?.runAgentSession()
            self?.isAgentRunning = false
            self?.agentTask = nil
        }
        agentTask = handle
        return true
    }

    func suspendContinuousTask() {
        guard var task = runningTask else { return }
        task.status = .suspended
        task.currentStep = "Paused by app backgrounding"
        task.updatedAt = Date()
        runningTask = task
        AgentTaskPersistence.shared.save(task)
    }

    func clearPersistedTask() {
        AgentTaskPersistence.shared.clear()
    }

    private func persistTask() {
        guard let task = runningTask else { return }
        AgentTaskPersistence.shared.save(task)
    }

    private func finishTask(reason: AgentStopReason) {
        guard var task = runningTask else { return }
        switch reason {
        case .success, .selfStopped:
            task.status = .completed
            task.progress = 100
        case .userStopped, .maxSteps, .timeout, .repeatedAction,
             .repeatedNavigationFailure, .noProgress, .resourceLimit, .cancelled:
            task.status = .stopped
        case .confirmationDenied, .networkFailure, .unrecoverableError:
            task.status = .failed
        }
        task.stopReason = reason.rawValue
        task.updatedAt = Date()
        if task.currentStep.isEmpty {
            task.currentStep = reason.label
        }
        runningTask = task
        AgentTaskPersistence.shared.save(task)
        if reason.isAutoStop {
            turns.append(ChatTurn(role: .assistant, kind: .info,
                                  text: "AI stopped automatically because an abnormal execution state was detected (\(reason.label))."))
        }
        activity(reason.isAutoStop
            ? "⛔ \(reason.label) (automatic safety stop)"
            : "◼ \(reason.label)")
    }

    private func activityStart(goal: String, continuation: String) {
        AgentActivityLog.shared.add("▶ Started task: \(goal)")
        LANActivityCenter.shared.taskStarted(title: goal, continuation: continuation, mode: agentMode.rawValue)
    }

    private func activity(_ message: String) {
        AgentActivityLog.shared.add(message)
        LANActivityCenter.shared.addFeed(message)
    }

    private func activityStep(_ message: String) {
        guard var task = runningTask else { return }
        task.currentStep = message
        task.updatedAt = Date()
        task.progress = min(99, max(1, task.stepCount * 100 / max(1, AgentWatchdog.shared.maxSteps)))
        runningTask = task
        LANActivityCenter.shared.updateCurrent(currentStep: message, progress: task.progress)
        AgentActivityLog.shared.add(message)
        LANActivityCenter.shared.addFeed(message)
    }

    private func trackWatchdog(for call: ToolCallRequest, result: String) {
        let args = arguments(from: call.argumentsJSON)
        var signature = call.name
        if let url = args["url"] as? String {
            signature += ":\(url)"
        } else if let query = args["query"] as? String {
            signature += ":\(query)"
        } else if let elementId = args["elementId"] as? Int {
            signature += ":\(elementId)"
        } else if let text = args["text"] as? String {
            signature += ":\(text)"
        }
        let isNavigation = call.name == "openURL" || call.name == "searchWeb"
            || call.name == "reload" || call.name == "goBack" || call.name == "goForward"
        let low = result.lowercased()
        if isNavigation, low.contains("could not") || low.contains("no active") || low.contains("failed") {
            AgentWatchdog.shared.recordNavigationFailure()
            return
        }
        if low.contains("none found") || low.contains("nothing found") || low.contains("no results") {
            AgentWatchdog.shared.recordNoProgress()
            return
        }
        AgentWatchdog.shared.recordAction(signature: signature, title: describeAction(call))
    }

    private func visiblePageContextText() async -> String {
        guard let coordinator = activeCoordinator else {
            return "Page context: no active tab."
        }
        let snapshot = await WebPageContextPipeline.shared.capture(coordinator: coordinator)
        guard let snapshot else {
            return "Page context: page is still loading or has no readable content."
        }
        return snapshot.compressedText(maxChars: 7000)
    }
}
