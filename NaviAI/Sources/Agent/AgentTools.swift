import Foundation
import UIKit

enum AgentToolError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}

extension BrowserStore {

    func agentEvaluate(_ expr: String) async throws -> Any? {
        guard let coordinator = activeCoordinator else {
            throw AgentToolError.message("No active tab.")
        }
        return try await coordinator.evaluate(expr)
    }

    func decodeJSResult<T: Decodable>(_ value: Any?) throws -> T {
        guard let string = value as? String,
              let data = string.data(using: .utf8) else {
            throw AgentToolError.message("Empty or invalid result from the page.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func fetchSnapshot(maxItems: Int = 60) async throws -> DOMSnapshot {
        agentStatus = .reading
        let value = try await agentEvaluate(BrowserJavaScript.snapshotExpr(maxItems: maxItems))
        return try decodeJSResult(value)
    }

    func fetchSignals() async throws -> BrowserJavaScript.PageSignals {
        let value = try await agentEvaluate(BrowserJavaScript.signalsExpr())
        return try decodeJSResult(value)
    }

    func locateElement(_ id: Int) async throws -> DOMClickResult {
        let value = try await agentEvaluate(BrowserJavaScript.locateExpr(id: id))
        return try decodeJSResult(value)
    }

    func arguments(from json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    private func stringArg(_ args: [String: Any], _ key: String) -> String {
        (args[key] as? String) ?? ""
    }

    private func intArg(_ args: [String: Any], _ key: String) -> Int? {
        (args[key] as? NSNumber)?.intValue ?? (args[key] as? Int)
    }

    func executeTool(named name: String, argumentsJSON: String) async -> String {
        let args = arguments(from: argumentsJSON)

        if !agentMode.permitsInteraction {
            let readOnly = ["readPage", "findText", "capture_web_screenshot"]
            if !readOnly.contains(name) {
                return "Blocked: View mode is read-only. Switch to Interact or Auto mode to perform this action."
            }
        }

        if case .failure(let message) = ToolRegistry.shared.validate(name: name, argumentsJSON: argumentsJSON) {
            return "Invalid tool call: \(message)"
        }
        if let def = ToolRegistry.shared.definition(for: name), def.permission.isRisky {
            let allowed = await PermissionSystem.shared.authorize(def.permission, detail: def.description)
            if !allowed { return "Blocked: \(def.permission.label) was not allowed." }
        }
        switch name {
        case "openURL":
            return await toolOpenURL(urlString: stringArg(args, "url"))
        case "searchWeb":
            return await toolSearchWeb(query: stringArg(args, "query"))
        case "readPage":
            return await toolReadPage()
        case "findText":
            return await toolFindText(query: stringArg(args, "text"))
        case "clickElement":
            if let id = intArg(args, "elementId") {
                return await toolClickElement(id)
            }
            return "clickElement requires an elementId."
        case "typeText":
            if let id = intArg(args, "elementId") {
                let pressEnter = (args["pressEnter"] as? Bool) ?? false
                return await toolTypeText(id, text: stringArg(args, "text"), pressEnter: pressEnter)
            }
            return "typeText requires an elementId."
        case "scroll":
            return await toolScroll(direction: stringArg(args, "direction"), amount: intArg(args, "amount") ?? 700)
        case "goBack":
            return await toolGoBack()
        case "goForward":
            return await toolGoForward()
        case "reload":
            return await toolReload()
        case "openTab":
            return await toolOpenTab(urlString: stringArg(args, "url"))
        case "switchTab":
            if let index = intArg(args, "index") {
                return toolSwitchTab(index)
            }
            return "switchTab requires an index."
        case "closeTab":
            return await toolCloseTab(index: intArg(args, "index"))
        case "screenshot":
            if await captureScreenshot() != nil {
                return "Screenshot captured and attached to the conversation context."
            }
            return "Could not capture a screenshot."
        case "capture_web_screenshot":
            return await toolCaptureWebScreenshot()
        case "stopSelf":
            stopSelfRequested = true
            let reason = stringArg(args, "reason").isEmpty ? "complete" : stringArg(args, "reason")
            return "STOP_SELF requested (\(reason)). Stopping the current task."
        case "generateImage":
            return await toolGenerateImage(prompt: stringArg(args, "prompt"), size: stringArg(args, "size"))
        case "runCode":
            return await toolRunCode(args: args)
        default:
            return "Unknown tool '\(name)'."
        }
    }

    private func afterLoadSummary() async -> String {
        guard let tab = activeTab else { return "No active tab." }
        let title = tab.webView.title ?? tab.title
        let url = tab.webView.url?.absoluteString ?? ""
        return title.isEmpty ? "Loaded \(url)." : "Loaded “\(title)” (\(url))."
    }

    private func toolOpenURL(urlString: String) async -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        var url = urlFrom(text: trimmed)
        if url == nil, trimmed.contains(" ") {
            url = settings.searchEngine.searchURL(for: trimmed)
        }
        guard let target = url else {
            return "Could not build a URL from “\(urlString)”. Provide http:// or https://."
        }
        agentStatus = .navigating
        await moveAICursor(to: CGPoint(x: 20, y: 20), label: "AI navigating…")
        loadURL(target)
        _ = await waitForPageSettle(timeout: 30)
        try? await Task.sleep(nanoseconds: 400_000_000)
        if let tab = activeTab {
            tab.title = tab.webView.title ?? tab.webView.url?.host ?? tab.title
        }
        return await afterLoadSummary()
    }

    private func toolSearchWeb(query: String) async -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return "searchWeb needs a query." }
        agentStatus = .searching
        await moveAICursor(to: CGPoint(x: viewportSize.width / 2, y: 40), label: "AI searching…")
        let target = settings.searchEngine.searchURL(for: q)
        loadURL(target)
        _ = await waitForPageSettle(timeout: 30)
        try? await Task.sleep(nanoseconds: 500_000_000)
        return "Search results for “\(q)” are loaded. Call readPage to read them."
    }

    private func toolReadPage() async -> String {
        agentStatus = .reading
        guard activeCoordinator != nil else { return "No active tab to read." }
        do {
            var snap = try await fetchSnapshot(maxItems: 60)

            if snap.items.isEmpty, !snap.bodyText.isEmpty, isVisionFallbackAvailable {
                let targets = await detectVisionClickables(viewportWidth: snap.viewportWidth,
                                                           viewportHeight: snap.viewportHeight)
                if !targets.isEmpty {
                    snap.items = syntheticItems(from: targets,
                                                viewportWidth: snap.viewportWidth,
                                                viewportHeight: snap.viewportHeight)
                }
            }

            if let sig = try? await fetchSignals(), sig.hasCaptchaFrame || !sig.bodyHint.isEmpty {
                return pageDescription(snap) + "\n\nWARNING: A CAPTCHA / security check is present on this page. You must stop and ask the user to solve it manually. Do not attempt to bypass it."
            }
            return pageDescription(snap)
        } catch {
            return "Could not read the page (still loading or no document yet). Wait and try readPage again."
        }
    }

    private func pageDescription(_ snap: DOMSnapshot) -> String {
        var lines: [String] = []
        lines.append("URL: \(snap.url)")
        lines.append("Title: \(snap.title)")
        let body = snap.bodyText
        if !body.isEmpty {
            let capped = body.count > 6000 ? String(body.prefix(6000)) + "\n…(truncated)" : body
            lines.append("Page text:\n\(capped)")
        } else {
            lines.append("(No readable text on this page.)")
        }
        lines.append("Interactive elements:")
        if snap.items.isEmpty {
            lines.append("  (none found - the page may still be loading or content is below the fold.)")
        } else {
            for item in snap.items {
                var desc = "  [\(item.id)] <\(item.tag)>"
                if !item.text.isEmpty { desc += " \(item.text)" }
                if !item.placeholder.isEmpty { desc += " (placeholder: \(item.placeholder))" }
                if !item.aria.isEmpty { desc += " (aria: \(item.aria))" }
                if !item.href.isEmpty { desc += " → \(item.href)" }
                if item.submit { desc += " [submit]" }
                if item.input { desc += " [input]" }
                lines.append(desc)
            }
        }
        return lines.joined(separator: "\n")
    }

    private func toolFindText(query: String) async -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return "findText needs a query." }
        agentStatus = .reading
        do {
            let value = try await agentEvaluate(BrowserJavaScript.findTextExpr(query: q, max: 8))
            struct FindResult: Codable { var items: [DOMItemInfo] }
            let result: FindResult = try decodeJSResult(value)
            guard !result.items.isEmpty else {
                return "No match for “\(q)” in the visible page. Try readPage to see everything."
            }
            if let first = result.items.first {
                let p = CGPoint(x: first.rect.centerX, y: first.rect.centerY)
                await moveAICursor(to: p, label: "AI reading…")
            }
            let list = result.items.map { "  [\($0.id)] <\($0.tag)> \($0.text)" }.joined(separator: "\n")
            return "Matches for “\(q)” (use elementId to click or type):\n\(list)"
        } catch {
            return "findText failed: \(error.localizedDescription)"
        }
    }

    private func toolClickElement(_ id: Int) async -> String {
        guard activeCoordinator != nil else { return "No active tab." }
        agentStatus = .clicking
        do {

            let located: DOMClickResult
            if id < 0 {
                guard let pt = visionClickables[id] else {
                    return "That element is no longer available. Call readPage to refresh."
                }
                located = DOMClickResult(ok: true, error: nil,
                                         item: DOMItemInfo(id: id, tag: "vision", text: "vision target", name: "", placeholder: "", aria: "", type: "", href: "", role: "button", submit: false, input: false,
                                                           rect: DOMRectInfo(x: pt.x - 12, y: pt.y - 8, w: 24, h: 16)),
                                         atX: pt.x, atY: pt.y)
            } else {
                located = try await locateElement(id)
            }
            guard located.ok else {
                agentStatus = .reading
                return located.error ?? "Cannot click element \(id). The page may have changed - call readPage."
            }
            guard let item = located.item else { return "No info for element \(id)." }

            if let reason = riskReason(for: item, typing: false) {
                agentStatus = .waitingForUser
                let granted = await requestUserDecision(
                    kind: .action,
                    title: "AI wants to perform this action",
                    message: reason,
                    allowTitle: "Allow",
                    denyTitle: "Cancel"
                )
                if !granted {
                    agentStatus = .thinking
                    return "The user cancelled this action. Do not retry unless they ask."
                }
            }

            let cx = located.atX ?? item.rect.centerX
            let cy = located.atY ?? item.rect.centerY
            let point = CGPoint(x: cx, y: cy)

            await InteractionEngine.shared.pauseBetweenActions()
            await moveAICursor(to: point, label: "AI clicking…")
            await tapPulse(at: point)

            agentStatus = .clicking
            let clickExpr = id < 0 ? BrowserJavaScript.clickAtExpr(x: cx, y: cy) : BrowserJavaScript.clickExpr(id: id)
            let clickValue = try await agentEvaluate(clickExpr)
            let clickResult: DOMClickResult = try decodeJSResult(clickValue)
            guard clickResult.ok else {
                return clickResult.error ?? "Click on element \(id) failed."
            }

            try? await Task.sleep(nanoseconds: 700_000_000)
            if activeTab?.webView.isLoading == true {
                _ = await waitForPageSettle(timeout: 30)
            }
            _ = await InteractionEngine.shared.waitUntilPageReady(coordinator: activeCoordinator, timeout: 8)
            try? await Task.sleep(nanoseconds: 300_000_000)

            let clickedText = item.text.isEmpty ? "<\(item.tag)>" : item.text
            AgentActivityLog.shared.add("Clicked " + clickedText)

            InteractionEngine.shared.markAction()
            try? await Task.sleep(nanoseconds: UInt64(InteractionEngine.shared.postClickDelay * 1_000_000_000))
            if activeTab?.webView.isLoading == true {
                _ = await waitForPageSettle(timeout: 30)
            } else {
                _ = await InteractionEngine.shared.waitUntilPageReady(coordinator: activeCoordinator, timeout: 8)
            }
            await InteractionEngine.shared.pauseBetweenActions()

            return "Clicked \(clickedText). If the page changed, call readPage to see the new content."
        } catch {
            return "Click on element \(id) failed: \(error.localizedDescription)"
        }
    }

    private func toolTypeText(_ id: Int, text: String, pressEnter: Bool) async -> String {
        guard activeCoordinator != nil else { return "No active tab." }
        agentStatus = .typing
        do {
            let located: DOMClickResult = try await locateElement(id)
            guard located.ok else {
                agentStatus = .reading
                return located.error ?? "Cannot find element \(id)."
            }
            guard let item = located.item else { return "No info for element \(id)." }

            if let reason = riskReason(for: item, typing: true, pressEnter: pressEnter) {
                agentStatus = .waitingForUser
                let granted = await requestUserDecision(
                    kind: .action,
                    title: "AI wants to type and send",
                    message: reason,
                    allowTitle: "Allow",
                    denyTitle: "Cancel"
                )
                if !granted {
                    agentStatus = .thinking
                    return "The user cancelled this action. Do not retry unless they ask."
                }
            }

            let cx = located.atX ?? item.rect.centerX
            let cy = located.atY ?? item.rect.centerY
            let point = CGPoint(x: cx, y: cy)

            await InteractionEngine.shared.pauseBetweenActions()
            await moveAICursor(to: point, label: "AI typing…")
            await tapPulse(at: point)

            _ = try? await agentEvaluate(BrowserJavaScript.focusExpr(id: id))
            try? await Task.sleep(nanoseconds: 250_000_000)

            let chunks = InteractionEngine.shared.typingChunks(for: text)
            if chunks.isEmpty {
                let typeValue = try await agentEvaluate(BrowserJavaScript.typeExpr(id: id, text: text, enter: pressEnter))
                struct TypeResult: Codable { var ok: Bool; var x: Double?; var y: Double?; var submitted: Bool?; var len: Int? }
                let result: TypeResult = try decodeJSResult(typeValue)
                guard result.ok else {
                    return "Could not type into element \(id). The page may have changed - call readPage."
                }
                await tapPulse(at: point)
                if pressEnter || (result.submitted ?? false) {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    if activeTab?.webView.isLoading == true {
                        _ = await waitForPageSettle(timeout: 30)
                    }
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
                var summary = "Typed \(result.len ?? text.count) characters into \(item.placeholder.isEmpty ? "<\(item.tag)>" : item.placeholder)."
                if result.submitted ?? false {
                    summary += " The form was submitted."
                }
                AgentActivityLog.shared.add("Typed into \(item.placeholder.isEmpty ? "<\(item.tag)>" : item.placeholder)")
                return summary
            }

            var totalLen = 0
            var submitted = false
            for (i, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                let expr = i == 0
                    ? BrowserJavaScript.typeExpr(id: id, text: chunk, enter: false)
                    : BrowserJavaScript.appendTextExpr(id: id, text: chunk)
                let chunkValue = try await agentEvaluate(expr)
                struct ChunkResult: Codable { var ok: Bool; var submitted: Bool?; var len: Int? }
                let chunkResult: ChunkResult = try decodeJSResult(chunkValue)
                guard chunkResult.ok else {
                    return "Could not type into element \(id). The page may have changed - call readPage."
                }
                totalLen = chunkResult.len ?? (totalLen + chunk.count)
                submitted = submitted || (chunkResult.submitted ?? false)
                await InteractionEngine.shared.typingPause()
            }

            await tapPulse(at: point)

            if pressEnter {
                let typeValue = try await agentEvaluate(BrowserJavaScript.typeExpr(id: id, text: "", enter: true))
                struct EnterResult: Codable { var ok: Bool; var submitted: Bool? }
                let enterResult: EnterResult = try decodeJSResult(typeValue)
                submitted = submitted || (enterResult.submitted ?? false)
            }

            if pressEnter || submitted {
                try? await Task.sleep(nanoseconds: 800_000_000)
                if activeTab?.webView.isLoading == true {
                    _ = await waitForPageSettle(timeout: 30)
                }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)

            var summary = "Typed \(totalLen) characters into \(item.placeholder.isEmpty ? "<\(item.tag)>" : item.placeholder)."
            if submitted {
                summary += " The form was submitted."
            }
            AgentActivityLog.shared.add("Typed into \(item.placeholder.isEmpty ? "<\(item.tag)>" : item.placeholder)")
            return summary
        } catch {
            return "Typing into element \(id) failed: \(error.localizedDescription)"
        }
    }

    private func toolScroll(direction: String, amount: Int) async -> String {
        guard activeCoordinator != nil else { return "No active tab." }
        agentStatus = .scrolling
        let dir = direction.lowercased()
        var dx = 0
        var dy = 0
        switch dir {
        case "up": dy = -(abs(amount))
        case "down": dy = abs(amount)
        case "left": dx = -(abs(amount) / 2)
        case "right": dx = abs(amount) / 2
        case "top": dy = -100000
        case "bottom": dy = 100000
        default: return "scroll direction must be up, down, left, right, top or bottom."
        }
        let mid = CGPoint(x: viewportSize.width / 2, y: viewportSize.height * 0.55)
        await moveAICursor(to: mid, label: "AI scrolling…")
        do {
            _ = try await agentEvaluate(BrowserJavaScript.scrollByExpr(dx: dx, dy: dy))
            try? await Task.sleep(nanoseconds: 350_000_000)
            agentStatus = .reading
            return "Scrolled \(dir). Call readPage to see the new content."
        } catch {
            return "Scroll failed: \(error.localizedDescription)"
        }
    }

    private func toolGoBack() async -> String {
        guard let wv = activeTab?.webView, wv.canGoBack else { return "There is no previous page to go back to." }
        agentStatus = .navigating
        wv.goBack()
        _ = await waitForPageSettle(timeout: 25)
        return "Went back. Call readPage to see the content."
    }

    private func toolGoForward() async -> String {
        guard let wv = activeTab?.webView, wv.canGoForward else { return "There is no next page to go forward to." }
        agentStatus = .navigating
        wv.goForward()
        _ = await waitForPageSettle(timeout: 25)
        return "Went forward. Call readPage to see the content."
    }

    private func toolReload() async -> String {
        guard let wv = activeTab?.webView else { return "No active tab." }
        agentStatus = .navigating
        wv.reload()
        _ = await waitForPageSettle(timeout: 25)
        return "Page reloaded. Call readPage to see the content."
    }

    private func toolOpenTab(urlString: String) async -> String {
        var url: URL?
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            url = urlFrom(text: trimmed)
        }
        let tab = newTab(url: url, activate: true)
        try? await Task.sleep(nanoseconds: 600_000_000)
        let idx = tabs.firstIndex(where: { $0.id == tab.id }) ?? 0
        return "Opened new tab \(idx)."
    }

    private func toolSwitchTab(_ index: Int) -> String {
        guard tabs.indices.contains(index) else {
            return "Tab index \(index) is out of range. Open tabs: \(tabListLine())"
        }
        selectTab(tabs[index].id)
        return "Switched to tab \(index): \(tabs[index].title.isEmpty ? "page" : tabs[index].title). Call readPage to see it."
    }

    private func toolCloseTab(index: Int?) async -> String {
        let idx: Int
        if let index {
            guard tabs.indices.contains(index) else { return "Tab index \(index) is out of range." }
            idx = index
        } else {
            guard let current = tabs.firstIndex(where: { $0.id == activeTabID }) else { return "No tab to close." }
            idx = current
        }
        if tabs.count <= 1 {
            return "Cannot close the last tab."
        }
        let title = tabs[idx].title
        closeTab(tabs[idx].id)
        return "Closed tab \(idx) (\(title))."
    }

    private func riskReason(for item: DOMItemInfo, typing: Bool, pressEnter: Bool = false) -> String? {
        guard settings.aiConfirmationEnabled else { return nil }
        let combined = [item.text, item.placeholder, item.aria, item.name]
            .joined(separator: " ")
            .lowercased()
        let isSearch = combined.contains("search") || combined.contains("find") || combined.contains("query")
        if isSearch { return nil }

        let impact = ["buy", "purchase", "checkout", "payment", "pay ", "order", "subscribe", "sign up", "register",
                      "delete", "remove", "post", "publish", "send", "comment", "reply", "donate", "place order",
                      "book now", "reserve", "submit application", "update profile", "save changes", "create account"]
        let hasImpact = impact.contains { combined.contains($0) }
        if hasImpact {
            let what = item.text.isEmpty ? (item.placeholder.isEmpty ? "<\(item.tag)>" : item.placeholder) : item.text
            if typing {
                return "AI wants to type into “\(what)” and send it. This field appears to be a message / impactful form. Allow?"
            }
            return "AI wants to click “\(what)”, which looks like an impactful action (send / post / buy / delete / change account info). Allow?"
        }
        if typing && pressEnter {
            let composer = ["message", "comment", "reply", "post", "chat", "mail", "tweet"]
            let looksComposer = composer.contains { combined.contains($0) }
            if looksComposer {
                return "AI wants to type a message into “\(item.placeholder.isEmpty ? item.aria : item.placeholder)” and press Enter. Allow?"
            }
        }
        return nil
    }

    private func toolCaptureWebScreenshot() async -> String {
        guard let tab = activeTab else { return "No active tab to capture." }
        let shot = await WebScreenshotManager.shared.capture(
            activeTab: tab,
            maxWidth: settings.screenshotMaxWidth,
            quality: 0.6)
        guard let shot else {
            return "Screenshot throttled (captures are rate-limited) or capture failed. Try again shortly."
        }
        if shot.byteCount < 1_500_000 {
            pendingVisionScreenshot = shot
        }
        return "Captured web screenshot: \(shot.pixelWidth)×\(shot.pixelHeight)px, \(shot.byteCount) bytes (JPEG). Merged into vision context when the model supports images."
    }

    private func toolRunCode(args: [String: Any]) async -> String {
        guard let langStr = args["language"] as? String,
              let code = args["code"] as? String else {
            return "runCode requires 'language' and 'code' arguments."
        }
        let langLow = langStr.lowercased()
        guard langLow == "c" || langLow == "javascript" || langLow == "js" else {
            return "runCode supports only 'c' and 'javascript'. Got '\(langStr)'."
        }
        let language: CodeLanguage = langLow == "c" ? .c : .javascript
        let result = await CodeLabStore.shared.run(code: code, language: language)
        var parts: [String] = []
        parts.append("Language: \(result.language.displayName)")
        parts.append("Duration: \(result.durationMs)ms | Exit: \(result.exitCode)")
        if !result.stdout.isEmpty { parts.append("stdout:\n\(result.stdout)") }
        if !result.stderr.isEmpty { parts.append("stderr:\n\(result.stderr)") }
        if result.stdout.isEmpty && result.stderr.isEmpty { parts.append("(no output)") }
        return parts.joined(separator: "\n")
    }

    private func toolGenerateImage(prompt: String, size: String?) async -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "generateImage requires a prompt." }
        do {
            let image = try await ImagePipeline.shared.generate(prompt: trimmed, size: (size?.isEmpty == false) ? size : nil)
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let folder = dir.appendingPathComponent("GeneratedImages", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = "img-" + UUID().uuidString + ".png"
            let fileURL = folder.appendingPathComponent(name)
            try image.data.write(to: fileURL, options: .atomic)
            return "Generated an image from the prompt and saved it at \(fileURL.absoluteString)."
        } catch let e as ImageGenerationError {
            return "Image generation failed: \(e.errorDescription ?? "unknown error")"
        } catch {
            return "Image generation failed: \(error.localizedDescription)"
        }
    }
}

extension BrowserStore {
    func waitForPageSettle(timeout: TimeInterval = 25) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            guard let wv = activeTab?.webView else { return false }
            if !wv.isLoading {
                try? await Task.sleep(nanoseconds: 250_000_000)
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    func moveAICursor(to target: CGPoint, label: String?) async {
        guard settings.aiCursorEnabled else {
            cursor.visible = false
            cursor.label = nil
            return
        }
        cursor.visible = true
        cursor.label = label

        let start = cursor.position
        guard start != target else { return }

        if settings.cursorAnimationsEnabled {
            let distance = hypot(target.x - start.x, target.y - start.y)
            let duration = min(1.1, max(0.2, distance * 0.0016))
            let steps = max(8, Int(duration * 40))
            for step in 1...steps {
                if Task.isCancelled { break }
                let t = Double(step) / Double(steps)
                let eased: Double = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                cursor.position = CGPoint(x: start.x + (target.x - start.x) * eased,
                                          y: start.y + (target.y - start.y) * eased)
                try? await Task.sleep(nanoseconds: UInt64((duration / Double(steps)) * 1_000_000_000))
            }
            cursor.position = target
        } else {
            cursor.position = target
        }
    }

    func tapPulse(at point: CGPoint) async {
        guard settings.aiCursorEnabled else { return }
        cursor.visible = true
        cursor.position = point

        cursor.isPressing = true
        cursor.pulseID += 1
        try? await Task.sleep(nanoseconds: 120_000_000)
        cursor.isPressing = false
        try? await Task.sleep(nanoseconds: 160_000_000)
    }
}
