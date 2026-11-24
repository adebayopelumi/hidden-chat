import Foundation

/// One chat turn. A user turn can carry a screenshot, sent as an image part.
struct ChatMessage: Encodable {
    let role: String
    var text: String
    var imageJPEGBase64: String? = nil

    private enum CodingKeys: String, CodingKey { case role, content }
    private struct Part: Encodable {
        struct ImageURL: Encodable { let url: String; let detail: String }
        let type: String
        var text: String? = nil
        var image_url: ImageURL? = nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        if let image = imageJPEGBase64 {
            try c.encode([
                Part(type: "text", text: text),
                Part(type: "image_url", image_url: .init(url: "data:image/jpeg;base64,\(image)", detail: "high")),
            ], forKey: .content)
        } else {
            try c.encode(text, forKey: .content)
        }
    }
}

enum OpenAI {
    static let base = URL(string: "https://api.openai.com/v1/")!

    static func request(_ path: String, apiKey: String) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    /// Pulls `error.message` out of an OpenAI error body, falling back to the raw text.
    static func errorMessage(status: Int, body: String) -> String {
        struct Envelope: Decodable { struct Inner: Decodable { let message: String }; let error: Inner }
        if let data = body.data(using: .utf8),
           let env = try? JSONDecoder().decode(Envelope.self, from: data) {
            return env.error.message
        }
        return "HTTP \(status): \(body.prefix(300))"
    }

    /// Remembers, per model, the fastest reasoning setting the model accepted ("" = parameter left out).
    actor EffortMemory {
        private var byModel: [String: String] = [:]
        func get(_ model: String) -> String? { byModel[model] }
        func set(_ model: String, _ effort: String) { byModel[model] = effort }
    }
    static let efforts = EffortMemory()

    /// Opens the HTTPS connection ahead of time so the first real question doesn't pay for it.
    static func warmUp(apiKey: String, model: String) {
        guard !apiKey.isEmpty else { return }
        Task.detached(priority: .utility) { _ = try? await URLSession.shared.data(for: request("models/\(model)", apiKey: apiKey)) }
    }

    /// Streams the assistant's reply piece by piece.
    static func streamChat(apiKey: String, model: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    struct Body: Encodable {
                        let model: String; let messages: [ChatMessage]; let stream: Bool; let reasoning_effort: String?
                    }
                    struct Chunk: Decodable {
                        struct Choice: Decodable { struct Delta: Decodable { let content: String? }; let delta: Delta }
                        let choices: [Choice]
                    }

                    // Thinking before answering is the biggest delay, so ask for as little as the model allows.
                    // Models differ in what they accept; on a "reasoning" error, step to the next option.
                    var candidates: [String] = []
                    for effort in [await efforts.get(model)].compactMap({ $0 }) + ["none", "minimal", "low", ""]
                    where !candidates.contains(effort) { candidates.append(effort) }

                    var stream: URLSession.AsyncBytes?
                    for (i, effort) in candidates.enumerated() {
                        var req = request("chat/completions", apiKey: apiKey)
                        req.httpMethod = "POST"
                        req.httpBody = try JSONEncoder().encode(Body(model: model, messages: messages, stream: true,
                                                                     reasoning_effort: effort.isEmpty ? nil : effort))
                        let (bytes, response) = try await URLSession.shared.bytes(for: req)
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        if status == 200 {
                            await efforts.set(model, effort)
                            stream = bytes
                            break
                        }
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        let message = errorMessage(status: status, body: body)
                        let aboutEffort = status == 400 && (message.lowercased().contains("reasoning") || message.lowercased().contains("effort"))
                        if !aboutEffort || i == candidates.count - 1 { throw AppError(message: message) }
                    }
                    guard let bytes = stream else { throw AppError(message: "No response from OpenAI.") }

                    // Server-sent events: lines of `data: {json}` ending with `data: [DONE]`.
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        if let data = payload.data(using: .utf8),
                           let chunk = try? JSONDecoder().decode(Chunk.self, from: data),
                           let text = chunk.choices.first?.delta.content {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The same stream as chat events, so the app can treat both providers alike.
    static func events(apiKey: String, model: String, messages: [ChatMessage]) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await piece in streamChat(apiKey: apiKey, model: model, messages: messages) { continuation.yield(.text(piece)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Lists chat-capable model ids available to this API key.
    static func listModels(apiKey: String) async throws -> [String] {
        struct List: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
        let (data, response) = try await URLSession.shared.data(for: request("models", apiKey: apiKey))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw AppError(message: errorMessage(status: status, body: String(decoding: data, as: UTF8.self)))
        }
        let skip = ["image", "audio", "realtime", "tts", "transcribe", "embedding", "search", "moderation", "dall-e", "whisper"]
        return try JSONDecoder().decode(List.self, from: data).data.map(\.id)
            .filter { id in (id.hasPrefix("gpt") || id.hasPrefix("o") || id.hasPrefix("chat")) && !skip.contains { id.contains($0) } }
            .sorted()
    }
}
