import Foundation

struct ChatMessage {
    let role: String
    let content: String
}

/// A reply plus whether it actually came from the model. Failures are still spoken — that's
/// how the app stays demoable with no LLM installed — but they must not be recorded as
/// assistant turns, or the next request feeds "No LLM reachable…" back as prior context.
struct BrainReply {
    let text: String
    let isFailure: Bool

    static func ok(_ text: String) -> BrainReply { BrainReply(text: text, isFailure: false) }
    static func failure(_ text: String) -> BrainReply { BrainReply(text: text, isFailure: true) }
}

protocol AgentBrain {
    func reply(to userText: String, history: [ChatMessage]) async throws -> BrainReply
}

/// Talks to any OpenAI-compatible /chat/completions endpoint. Defaults (via AppSettings)
/// to a local Ollama instance, which needs no API key at all — genuinely free. Settings
/// can point this at OpenAI, Gemini, or any other OpenAI-schema-compatible provider instead.
/// (Anthropic's native API isn't OpenAI-schema-compatible, so Claude only works here behind
/// a compatibility proxy.)
///
/// Config is injected rather than read from AppSettings inside `reply`, so this stays a
/// plain value usable off the main actor.
struct OpenAICompatibleBrain: AgentBrain {
    let baseURL: String
    let model: String
    let apiKey: String?

    private struct RequestBody: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        let model: String
        let messages: [Message]
        let stream = false
    }
    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct Msg: Decodable { let content: String? }
            let message: Msg
        }
        let choices: [Choice]
    }

    /// Keeps the prompt bounded so a long session can't grow the request without limit.
    private static let maxHistoryMessages = 20

    func reply(to userText: String, history: [ChatMessage]) async throws -> BrainReply {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmedBase + "/chat/completions") else {
            return .failure("Agent brain URL is invalid: \(baseURL). Fix it in Settings.")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 120 // local models on a cold start can be slow

        let recent = history.suffix(Self.maxHistoryMessages)
        let messages = recent.map { RequestBody.Message(role: $0.role, content: $0.content) }
            + [RequestBody.Message(role: "user", content: userText)]
        req.httpBody = try JSONEncoder().encode(RequestBody(model: model, messages: messages))

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard 200..<300 ~= http.statusCode else {
                let body = String(data: data, encoding: .utf8) ?? ""
                // Surface the provider's own message — usually "model not found" or a bad key,
                // both of which the user can act on.
                return .failure("Agent brain returned \(http.statusCode): \(body.prefix(200))")
            }
            let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
            guard let text = decoded.choices.first?.message.content, !text.isEmpty else {
                return .failure("Agent brain returned an empty reply.")
            }
            return .ok(text)
        } catch where error.isCancellation {
            throw CancellationError()
        } catch {
            return .failure("No LLM reachable at \(trimmedBase) — install Ollama (brew install ollama && ollama pull \(model)) or set a different OpenAI-compatible provider in Settings.")
        }
    }
}
