import Foundation
import UIKit

// MARK: - Agent loop (extension of BrowserStore)

extension BrowserStore {

    // MARK: Public entry points (used by the chat bar)

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
        // Release any pending confirmation/captcha dialog.
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

    // MARK: Tool schemas

    func agentToolSpecs() -> [AgentToolSpec] {
        func str(_ title: String, _ desc: String) -> [String: Any] {
            ["type": "string", "title": title, "description": desc]
        }
        let bool = ["type": "boolean"] as [String: Any]
        let int = ["type": "integer"] as [String: Any]

        func schema(_ required: [String], _ props: [String: Any]) -> [String: Any] {
            ["type": "object", "properties": props, "required": required]
        }

        return [
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
            AgentToolSpec(name: "closeTab", description: "Close a tab by index (optional). Without index closes the current tab.", parameters: schema([], ["index": int]))
        ]
    }

    // MARK: Conversation helpers

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

    // MARK: The loop

    private func runAgentSession() async {
        guard let config = providers.activeProvider else {
            finishWith(info: "No AI provider selected. Choose one in Settings.")
            return
        }
        guard let apiKey = providers.apiKey(for: config), !apiKey.isEmpty else {
            finishWith(info: "Please add an API key for \(config.name) in Settings.")
            return
        }

        var stepCount = 0
        let maxSteps = 30

        while true {
            if Task.isCancelled {
                agentStatus = .stopped
                return
            }

            // CAPTCHA guard: never try to solve it, always pause for the human.
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
                if !granted { agentStatus = .stopped; return }
                continue
            }

            agentStatus = .thinking

            // Build the system + conversation for this step.
            let sys = agentSystemPrompt(pageContext: activePageLine() + "\n" + tabListLine())
            let history: [OutboundItem] = [.system(sys)] + apiHistory

            do {
                let reply = try await llm.complete(
                    config: config,
                    apiKey: apiKey,
                    history: history,
                    tools: agentToolSpecs()
                )

                if Task.isCancelled {
                    agentStatus = .stopped
                    return
                }

                // If the model produced text together with tool calls, remember
                // it but continue executing the calls.
                if !reply.toolCalls.isEmpty {
                    for call in reply.toolCalls {
                        if Task.isCancelled { agentStatus = .stopped; return }

                        let actionNote = describeAction(call)
                        if !actionNote.isEmpty {
                            turns.append(ChatTurn(role: .assistant, kind: .action, text: actionNote))
                        }
                        apiHistory.append(.assistantToolCall(id: call.id, name: call.name, argumentsJSON: call.argumentsJSON))

                        let result = await executeTool(named: call.name, argumentsJSON: call.argumentsJSON)
                        apiHistory.append(.toolResult(toolCallID: call.id, content: result))
                        stepCount += 1
                        if stepCount >= maxSteps {
                            finishWith(info: "Reached the maximum number of actions (\(maxSteps)). Please continue with a new request.")
                            return
                        }
                    }
                    continue
                }

                // Final answer (no tool calls).
                if let text = reply.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    turns.append(ChatTurn(role: .assistant, kind: .text, text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
                    apiHistory.append(.assistantText(text.trimmingCharacters(in: .whitespacesAndNewlines)))
                    cursor.visible = false
                    cursor.isPressing = false
                    cursor.label = nil
                    agentStatus = .done
                    return
                }

                // Nothing useful to do.
                turns.append(ChatTurn(role: .assistant, kind: .info, text: "AI needs clarification. Please rephrase or be more specific."))
                agentStatus = .error("AI needs clarification")
                return
            } catch AIError.cancelled {
                agentStatus = .stopped
                return
            } catch {
                let err = (error as? AIError) ?? .network(error)
                turns.append(ChatTurn(role: .assistant, kind: .info, text: err.friendlyMessage))
                agentStatus = .error(err.friendlyMessage)
                return
            }
        }
    }

    private func finishWith(info: String) {
        turns.append(ChatTurn(role: .assistant, kind: .info, text: info))
        cursor.visible = false
        cursor.isPressing = false
        cursor.label = nil
        agentStatus = .done
        isAgentRunning = false
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

        Page context:
        \(pageContext)

        Rules:
        - Always prefer the DOM: read the page with readPage, choose elements by elementId, then act.
        - Use searchWeb to find things, open results with openURL, then readPage again.
        - Never invent content. Only claim something exists if the page really shows it.
        - To reach results lower on a page, scroll and readPage again.
        - If you meet a CAPTCHA or anti-bot challenge, stop and tell the user you need them to solve it. You must NOT try to bypass it.
        - If you are about to send a form/message, purchase, delete data or change account info, mention it clearly - the user will be asked to confirm.
        - When the user's task is complete, stop calling tools and give the final answer in the same language the user used.
        - If you do not understand the request, ask for clarification in your final answer.
        - If an elementId is stale (page changed), call readPage again to refresh the listing.
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
}
