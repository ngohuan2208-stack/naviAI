import Foundation

final class LLMService {

    func complete(
        config: ProviderConfig,
        apiKey: String,
        history: [OutboundItem],
        tools: [AgentToolSpec]
    ) async throws -> ProviderReply {
        try Task.checkCancellation()
        guard !apiKey.isEmpty else { throw AIError.missingAPIKey }
        guard !config.model.isEmpty else { throw AIError.modelUnavailable }
        guard let url = Self.endpoint(for: config) else { throw AIError.invalidBaseURL }

        let body = config.apiFormat == .anthropic
            ? Self.buildAnthropicBody(model: config.model, history: history, tools: tools)
            : Self.buildOpenAIBody(model: config.model, history: history, tools: tools)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        switch config.apiFormat {
        case .openAI:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AIError.network(URLError(.badServerResponse))
            }
            guard (200..<300).contains(http.statusCode) else {
                throw Self.error(from: http.statusCode, data: data, format: config.apiFormat)
            }
            return try decode(data, format: config.apiFormat)
        } catch let e as AIError {
            throw e
        } catch let e as URLError where e.code == .cancelled {
            throw AIError.cancelled
        } catch {
            throw AIError.network(error)
        }
    }

    func test(config: ProviderConfig, apiKey: String) async -> Result<String, AIError> {
        guard !config.model.isEmpty else { return .failure(.modelUnavailable) }
        guard !apiKey.isEmpty else { return .failure(.missingAPIKey) }
        do {
            let reply = try await complete(
                config: config,
                apiKey: apiKey,
                history: [.system("You are a connectivity test. Reply with exactly the word OK."),
                          .userText("Ping.")],
                tools: []
            )
            let text = reply.text ?? ""
            return .success(text.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch let e as AIError {
            return .failure(e)
        } catch {
            return .failure(.network(error))
        }
    }

    static func endpoint(for config: ProviderConfig) -> URL? {
        var base = config.baseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { return nil }
        switch config.apiFormat {
        case .openAI:
            if base.hasSuffix("/chat/completions") { return URL(string: base) }
            if config.kind == .gemini {
                return URL(string: base + "/openai/chat/completions")
            }
            return URL(string: base + "/chat/completions")
        case .anthropic:
            if base.hasSuffix("/messages") { return URL(string: base) }
            let path = base.hasSuffix("/v1") ? base + "/messages" : base + "/v1/messages"
            return URL(string: path)
        }
    }

    private static func buildOpenAIBody(model: String,
                                        history: [OutboundItem],
                                        tools: [AgentToolSpec]) -> [String: Any] {
        var messages: [[String: Any]] = []

        func pushRole(_ role: String, content: [String: Any]? = nil, contentString: String? = nil,
                      toolCalls: [[String: Any]]? = nil, toolCallID: String? = nil) {
            var msg: [String: Any] = ["role": role]
            if let cs = contentString { msg["content"] = cs }
            if let c = content { msg["content"] = [c] }
            if let tc = toolCalls { msg["tool_calls"] = tc }
            if let id = toolCallID { msg["tool_call_id"] = id }
            messages.append(msg)
        }

        var systemParts: [String] = []
        var pendingToolCalls: [[String: Any]] = []

        func flushToolCalls() {
            guard !pendingToolCalls.isEmpty else { return }
            pushRole("assistant", toolCalls: pendingToolCalls)
            pendingToolCalls = []
        }

        for item in history {
            switch item {
            case .system(let s):
                systemParts.append(s)
            case .userText(let t):
                flushToolCalls()
                pushRole("user", contentString: t)
            case .userVision(let text, let b64, let mime):
                flushToolCalls()
                let content: [String: Any] = [
                    "type": "image_url",
                    "image_url": ["url": "data:\(mime);base64,\(b64)"]
                ]
                let textPart: [String: Any] = ["type": "text", "text": text]
                let msg: [String: Any] = ["role": "user", "content": [textPart, content]]
                messages.append(msg)
            case .assistantText(let t):
                flushToolCalls()
                pushRole("assistant", contentString: t)
            case .assistantToolCall(let id, let name, let argsJSON):
                pendingToolCalls.append([
                    "id": id,
                    "type": "function",
                    "function": ["name": name, "arguments": argsJSON]
                ])
            case .toolResult(let callID, let content):
                flushToolCalls()
                pushRole("tool", contentString: content, toolCallID: callID)
            }
        }
        flushToolCalls()

        if !systemParts.isEmpty {
            messages.insert(["role": "system", "content": systemParts.joined(separator: "\n")], at: 0)
        }

        var body: [String: Any] = [
            "model": model,
            "messages": messages
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { ["type": "function", "function": $0.asDictionary()] }
            body["tool_choice"] = "auto"
        }
        return body
    }

    private static func buildAnthropicBody(model: String,
                                           history: [OutboundItem],
                                           tools: [AgentToolSpec]) -> [String: Any] {
        var systemParts: [String] = []
        var messages: [[String: Any]] = []
        var pendingUserBlocks: [[String: Any]] = []

        func flushUserBlocks() {
            guard !pendingUserBlocks.isEmpty else { return }
            messages.append(["role": "user", "content": pendingUserBlocks])
            pendingUserBlocks = []
        }

        for item in history {
            switch item {
            case .system(let s):
                systemParts.append(s)
            case .userText(let t):
                flushUserBlocks()
                messages.append(["role": "user", "content": t])
            case .userVision(let text, let b64, let mime):
                flushUserBlocks()
                var parts: [[String: Any]] = [["type": "text", "text": text]]
                parts.append(["type": "image",
                              "source": ["type": "base64", "media_type": mime, "data": b64]])
                pendingUserBlocks.append(contentsOf: parts)
            case .assistantText(let t):
                flushUserBlocks()
                messages.append(["role": "assistant", "content": t])
            case .assistantToolCall(let id, let name, let argsJSON):
                flushUserBlocks()
                let input = (try? JSONSerialization.jsonObject(with: Data(argsJSON.utf8))) as? [String: Any] ?? [:]
                messages.append(["role": "assistant",
                                 "content": [["type": "tool_use", "id": id, "name": name, "input": input]]])
            case .toolResult(let callID, let content):
                pendingUserBlocks.append(["type": "tool_result", "tool_use_id": callID, "content": content])
            }
        }
        flushUserBlocks()

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "messages": messages
        ]
        if !systemParts.isEmpty {
            body["system"] = systemParts.joined(separator: "\n")
        }
        if !tools.isEmpty {
            body["tools"] = tools.map { $0.asDictionary() }
        }
        return body
    }

    private func decode(_ data: Data, format: APIMessageFormat) throws -> ProviderReply {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let json = json else {
            throw AIError.providerError("Could not read provider response.")
        }
        switch format {
        case .openAI:
            guard let choices = json["choices"] as? [[String: Any]], let choice = choices.first,
                  let message = choice["message"] as? [String: Any] else {
                if let err = json["error"] as? [String: Any] {
                    let msg = err["message"] as? String ?? "Unknown error"
                    throw AIError.providerError(msg)
                }
                throw AIError.providerError("Empty response.")
            }
            var text = message["content"] as? String
            if text?.isEmpty == true { text = nil }
            var toolCalls: [ToolCallRequest] = []
            if let calls = message["tool_calls"] as? [[String: Any]] {
                for call in calls {
                    guard let fn = call["function"] as? [String: Any],
                          let name = fn["name"] as? String else { continue }
                    let args = fn["arguments"] as? String ?? "{}"
                    toolCalls.append(ToolCallRequest(
                        id: (call["id"] as? String) ?? UUID().uuidString,
                        name: name,
                        argumentsJSON: args
                    ))
                }
            }
            let finish = choice["finish_reason"] as? String
            if text == nil && toolCalls.isEmpty, let m = json["message"] as? String { text = m }
            return ProviderReply(text: text, toolCalls: toolCalls, finishReason: finish)

        case .anthropic:
            var text: String? = nil
            var toolCalls: [ToolCallRequest] = []
            if let content = json["content"] as? [[String: Any]] {
                for block in content {
                    let type = block["type"] as? String ?? ""
                    switch type {
                    case "text":
                        let t = (block["text"] as? String) ?? ""
                        text = (text ?? "") + t
                    case "tool_use":
                        guard let name = block["name"] as? String else { continue }
                        let input = block["input"] ?? [:]
                        let argsData = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)
                        toolCalls.append(ToolCallRequest(
                            id: (block["id"] as? String) ?? UUID().uuidString,
                            name: name,
                            argumentsJSON: String(data: argsData, encoding: .utf8) ?? "{}"
                        ))
                    default:
                        break
                    }
                }
            }
            if text?.isEmpty == true { text = nil }
            let finish = json["stop_reason"] as? String
            return ProviderReply(text: text, toolCalls: toolCalls, finishReason: finish)
        }
    }

    private static func error(from status: Int, data: Data?, format: APIMessageFormat) -> AIError {
        var detail = ""
        if let data = data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let e = json["error"] as? [String: Any] {
                detail = e["message"] as? String ?? ""
            } else if let m = json["message"] as? String {
                detail = m
            }
        }
        if status == 401 || status == 403 {
            return .invalidAPIKey
        }
        if status == 404 {

            return .modelUnavailable
        }
        let detailText = detail.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(detail)"
        return .providerError(detailText)
    }
}
