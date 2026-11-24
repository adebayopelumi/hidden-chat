import Foundation

/// What a reply stream delivers to the chat: answer text, or a status line (e.g. "📄 Reading report.pdf").
enum ChatEvent {
    case text(String)
    case status(String)
}

struct ToolCall {
    let id: String
    let name: String
    let input: [String: Any]
}

struct ToolOutcome {
    let content: String
    var isError = false
}

/// Claude Messages API over raw HTTP (there is no official Swift SDK), streamed, with a local tool loop.
enum Claude {
    static var base = URL(string: "https://api.anthropic.com/v1/")!
    static let apiVersion = "2026-10-21"
    static let defaultModel = "claude-opus-5-5"
    static let maxToolRounds = 15

    /// Models that accept the server-side refusal fallback (`fallbacks: "default"`): if Claude's safety
    /// classifiers decline a request, the API re-runs it on a suitable fallback model in the same call.
    static let fallbackModels: Set<String> = ["claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5", "claude-fable-5-2", "claude-fable-5-1"]
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    static func request(_ path: String, apiKey: String, betas: [String] = []) -> URLRequest {
        var req = URLRequest(url: URL(string: path, relativeTo: base)!)
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if !betas.isEmpty { req.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta") }
        return req
    }

    static func listModels(apiKey: String) async throws -> [String] {
        struct List: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
        let (data, response) = try await URLSession.shared.data(for: request("models?limit=100", apiKey: apiKey))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw AppError(message: OpenAI.errorMessage(status: status, body: String(decoding: data, as: UTF8.self)))
        }
        return try JSONDecoder().decode(List.self, from: data).data.map(\.id)  // newest first
    }

    /// Opens the HTTPS connection ahead of time so the first real question doesn't pay for it.
    static func warmUp(apiKey: String, model: String) {
        guard !apiKey.isEmpty else { return }
        Task.detached(priority: .utility) { _ = try? await URLSession.shared.data(for: request("models/\(model)", apiKey: apiKey)) }
    }

    /// The small, fast model for quick checks ("is this a question?").
    static let checkModel = "claude-haiku-5-5"

    /// A short, non-streamed reply, for quick checks. Thinking is turned off where the model allows it,
    /// so the answer comes back fast; if the model insists on thinking, it retries with thinking kept short.
    static func quickReply(apiKey: String, model: String, system: String, text: String) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16,
            "system": system,
            "messages": [["role": "user", "content": text]],
            "thinking": ["type": "disabled"],
        ]
        for attempt in 0..<2 {
            var req = request("messages", apiKey: apiKey)
            req.httpMethod = "POST"
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                guard reply["stop_reason"] as? String != "refusal" else { return "" }
                let blocks = reply["content"] as? [[String: Any]] ?? []
                return blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
            }
            let message = OpenAI.errorMessage(status: status, body: String(decoding: data, as: UTF8.self))
            if status == 400, attempt == 0, message.lowercased().contains("thinking") {
                body["thinking"] = nil
                body["max_tokens"] = 2048  // thinking counts toward this
                body["output_config"] = ["effort": "low"]
                continue
            }
            throw AppError(message: message)
        }
        return ""
    }

    /// Optional request fields a model turned down once, so later requests leave them out.
    actor Rejected {
        private var fields: [String: Set<String>] = [:]
        func contains(_ model: String, _ field: String) -> Bool { fields[model]?.contains(field) ?? false }
        func add(_ model: String, _ field: String) { fields[model, default: []].insert(field) }
    }
    static let rejected = Rejected()

    /// One user turn: streams Claude's text, and whenever Claude calls tools, runs them with `runTool`
    /// and continues until Claude is done. `system` and `tools` stay fixed for the whole turn, so the
    /// thinking blocks echoed back inside the loop stay valid.
    static func streamTurn(apiKey: String, model: String, system: String, history: [ChatMessage],
                           tools: [[String: Any]],
                           runTool: @escaping (ToolCall) async -> ToolOutcome) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var messages = history.map(wire)
                    var rounds = 0
                    while true {
                        let reply = try await streamOnce(apiKey: apiKey, model: model, system: system, messages: messages,
                                                         tools: tools) { continuation.yield($0) }
                        if reply.stopReason == "refusal" {
                            continuation.yield(.status("Claude declined to answer this."))
                            break
                        }
                        let toolUses = reply.content.filter { $0["type"] as? String == "tool_use" }
                        guard reply.stopReason == "tool_use", !toolUses.isEmpty else {
                            if reply.stopReason == "max_tokens" { continuation.yield(.status("(the reply was cut off)")) }
                            break
                        }
                        rounds += 1
                        if rounds > maxToolRounds {
                            continuation.yield(.status("Stopped after \(maxToolRounds) tool steps."))
                            break
                        }

                        // Run every tool call from this reply, then send all results back in one message.
                        var results: [[String: Any]] = []
                        for block in toolUses {
                            let id = block["id"] as? String ?? ""
                            let name = block["name"] as? String ?? ""
                            if let raw = reply.invalidInputs[id] {
                                let note = String(data: try JSONSerialization.data(withJSONObject: ["INVALID_JSON": raw]), encoding: .utf8) ?? "INVALID_JSON"
                                results.append(["type": "tool_result", "tool_use_id": id, "content": note, "is_error": true])
                                continue
                            }
                            let call = ToolCall(id: id, name: name, input: block["input"] as? [String: Any] ?? [:])
                            continuation.yield(.status(ToolBox.describe(call)))
                            let outcome = await runTool(call)
                            results.append(["type": "tool_result", "tool_use_id": id, "content": outcome.content, "is_error": outcome.isError])
                        }
                        try Task.checkCancellation()
                        messages.append(["role": "assistant", "content": reply.content])
                        messages.append(["role": "user", "content": results])
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A chat message in the Messages API shape (a screenshot goes in as an image block).
    static func wire(_ m: ChatMessage) -> [String: Any] {
        guard let image = m.imageJPEGBase64 else { return ["role": m.role, "content": m.text] }
        return ["role": m.role, "content": [
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": image]],
            ["type": "text", "text": m.text],
        ]]
    }

    private struct Reply {
        var content: [[String: Any]]
        var stopReason: String?
        var invalidInputs: [String: String]  // tool_use id -> raw input that wasn't valid JSON
    }

    /// One request: streams it, emitting text as it arrives, and returns the full assistant content
    /// (thinking blocks with their signatures, text, tool calls) to echo back unchanged.
    private static func streamOnce(apiKey: String, model: String, system: String, messages: [[String: Any]],
                                   tools: [[String: Any]], emit: (ChatEvent) -> Void) async throws -> Reply {
        let bytes = try await open(apiKey: apiKey, model: model, system: system, messages: messages, tools: tools)
        var blocks: [Int: [String: Any]] = [:]
        var toolJSON: [Int: String] = [:]
        var stopReason: String?

        for try await line in bytes.lines {
            guard line.hasPrefix("data:"),
                  let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                  let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            let index = event["index"] as? Int ?? -1
            switch type {
            case "content_block_start":
                guard var block = event["content_block"] as? [String: Any] else { break }
                if block["type"] as? String == "tool_use" { toolJSON[index] = "" }
                if let text = block["text"] as? String, !text.isEmpty { emit(.text(text)) }
                blocks[index] = block
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any] else { break }
                func add(_ key: String, _ piece: String?) {
                    guard var block = blocks[index] else { return }
                    block[key] = (block[key] as? String ?? "") + (piece ?? "")
                    blocks[index] = block
                }
                switch delta["type"] as? String {
                case "text_delta":
                    let piece = delta["text"] as? String ?? ""
                    add("text", piece)
                    emit(.text(piece))
                case "thinking_delta": add("thinking", delta["thinking"] as? String)
                case "signature_delta": add("signature", delta["signature"] as? String)
                case "input_json_delta": toolJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
                default: break
                }
            case "message_delta":
                if let reason = (event["delta"] as? [String: Any])?["stop_reason"] as? String { stopReason = reason }
            case "error":
                let message = (event["error"] as? [String: Any])?["message"] as? String ?? "Claude returned an error."
                throw AppError(message: message)
            default:
                break
            }
        }

        // Tool inputs stream as JSON fragments (eager streaming), so parse them strictly here.
        var invalid: [String: String] = [:]
        for (index, json) in toolJSON {
            let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                blocks[index]?["input"] = [String: Any]()
            } else if let object = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any] {
                blocks[index]?["input"] = object
            } else {
                blocks[index]?["input"] = [String: Any]()
                if let id = blocks[index]?["id"] as? String { invalid[id] = trimmed }
            }
        }

        var content = blocks.keys.sorted().compactMap { blocks[$0] }
        // After a mid-reply fallback to another model, blocks from before the switch that the other model
        // can't use (thinking, tool calls) must not be echoed; the fallback block itself stays in place.
        if let lastFallback = content.lastIndex(where: { $0["type"] as? String == "fallback" }) {
            let drop: Set<String> = ["thinking", "redacted_thinking", "tool_use", "server_tool_use"]
            content = content.enumerated().filter { i, b in i >= lastFallback || !drop.contains(b["type"] as? String ?? "") }.map(\.element)
        }
        return Reply(content: content, stopReason: stopReason, invalidInputs: invalid)
    }

    /// Sends the request; if the model rejects an optional field (effort, fallbacks), retries without it.
    private static func open(apiKey: String, model: String, system: String, messages: [[String: Any]],
                             tools: [[String: Any]]) async throws -> URLSession.AsyncBytes {
        for _ in 0..<3 {
            let sendEffort = !(await rejected.contains(model, "effort"))
            let fallbacksRejected = await rejected.contains(model, "fallbacks")
            let sendFallbacks = fallbackModels.contains(model) && !fallbacksRejected

            var body: [String: Any] = [
                "model": model,
                "max_tokens": 64000,  // thinking counts toward this too
                "stream": true,
                "system": system,
                "messages": messages,
            ]
            if !tools.isEmpty { body["tools"] = tools }
            // Thinking can't be turned off on current models; low effort keeps it short, so answers start sooner.
            if sendEffort { body["output_config"] = ["effort": "low"] }
            if sendFallbacks { body["fallbacks"] = "default" }

            var req = request("messages", apiKey: apiKey, betas: sendFallbacks ? [fallbackBeta] : [])
            req.httpMethod = "POST"
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return bytes }

            var text = ""
            for try await line in bytes.lines { text += line }
            let message = OpenAI.errorMessage(status: status, body: text)
            let lower = message.lowercased()
            if status == 400, sendEffort, lower.contains("effort") { await rejected.add(model, "effort"); continue }
            if status == 400, sendFallbacks, lower.contains("fallback") { await rejected.add(model, "fallbacks"); continue }
            throw AppError(message: message)
        }
        throw AppError(message: "Claude rejected the request.")
    }
}
