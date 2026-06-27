import Foundation

/// Remote inference via ANY OpenAI-compatible Chat Completions endpoint — most
/// importantly a SELF-HOSTED model on a machine you control (Ollama / LM Studio /
/// vLLM), but also any vendor exposing the OpenAI shape (Mistral, DeepSeek, …).
///
/// The base URL and model are user-supplied; the API key is OPTIONAL — local
/// servers usually have none, in which case no `Authorization` header is sent
/// (so it does NOT throw `notConfigured` on an empty key, unlike the hosted
/// providers). Content still leaves the app to a server, so it gets the same
/// consent/firewall default as other remote backends; the user can turn the
/// firewall off for a server they fully control (e.g. their own Mac).
public struct CustomOpenAIProvider: AgentProvider {
    public let baseURL: String
    public let apiKey: String
    public let model: String
    private let session: URLSession

    public init(baseURL: String, apiKey: String, model: String, requestTimeoutSeconds: Double? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        // Local servers (LM Studio) ignore the model name and serve whatever's
        // loaded; Ollama needs a real one — surfaced in Settings.
        self.model = model.isEmpty ? "local-model" : model
        let configuration = URLSessionConfiguration.ephemeral
        // A self-hosted endpoint can hang (a wedged model, an unreachable LAN host).
        // An explicit per-AI timeout (Settings ▸ AI) bounds the wait; nil/≤0 keeps the
        // URLSession default. Cloud providers manage their own timeouts.
        if let requestTimeoutSeconds, requestTimeoutSeconds > 0 {
            configuration.timeoutIntervalForRequest = requestTimeoutSeconds
            configuration.timeoutIntervalForResource = requestTimeoutSeconds
        }
        self.session = URLSession(configuration: configuration)
    }

    public func draftReply(context: AgentContext) async throws -> Draft {
        Draft(
            text: try await complete(
                system: context.draftSystemPrompt(),
                user: FoundationModelsAgentProvider.renderTranscript(context)))
    }

    public func threadTurn(context: AgentContext) async throws -> AgentTurn? {
        let text = try await complete(
            system: context.turnSystemPrompt(),
            user: FoundationModelsAgentProvider.renderTranscript(context))
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "PASS" else { return nil }
        return AgentTurn(messages: [AgentMessage(text: trimmed)])
    }

    /// Be forgiving about how much of the OpenAI path the user typed, so LM
    /// Studio / Ollama / vLLM all "just work" from a host:port:
    ///  - full  ".../chat/completions" → used as-is
    ///  - base  ".../v1"               → append "/chat/completions"
    ///  - bare  "http://host:port"     → append "/v1/chat/completions"
    ///  - other path                   → append "/chat/completions"
    func endpoint() -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/chat/completions") { return URL(string: base) }
        if base.hasSuffix("/v1") { return URL(string: base + "/chat/completions") }
        if let u = URL(string: base), u.path.isEmpty || u.path == "/" {
            return URL(string: base + "/v1/chat/completions")
        }
        return URL(string: base + "/chat/completions")
    }

    private func complete(system: String, user: String) async throws -> String {
        guard let url = endpoint() else {
            throw AgentProviderError.unavailable(
                "Set this AI's server URL in Settings ▸ AI (e.g. http://192.168.1.20:11434/v1).")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let payload: [String: Any] = [
            "model": model,
            // Self-hosted reasoning models (qwen3, DeepSeek-R1, gemma-QAT) spend tokens
            // on a private `<think>`/channel scratchpad BEFORE answering, so give them
            // generous room. A tight cap means the model burns the whole budget
            // reasoning and is truncated (finish_reason "length") before writing a
            // single token of answer — which used to vanish silently (now surfaced
            // below). 1024 was hitting exactly that on chatty reasoning models.
            "max_tokens": 4096,
            "messages": openAIChatMessages(system: system, user: user),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let apiMessage =
                ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw AgentProviderError.unavailable(
                "Server \(http.statusCode): \(apiMessage ?? "request rejected"). Check the URL/model and that the server is reachable.")
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let text = message["content"] as? String
        else {
            throw AgentProviderError.unavailable("unexpected response shape from the server")
        }
        let answer = text.strippingReasoningTrace()
        // The reported silent failure: a reasoning model spends its ENTIRE budget
        // thinking and is cut off (finish_reason "length") before writing an answer,
        // so the stripped text is empty. Treating that the same as "had nothing to
        // say" left the chat mysteriously silent. Surface it instead so the user knows
        // WHY — and can fix it (the cause is the model, not the chat).
        if answer.isEmpty, (first["finish_reason"] as? String) == "length" {
            throw AgentProviderError.unavailable(
                "Your AI ran out of room while reasoning and was cut off before it "
                    + "answered. Use a model that reasons less, raise its max output "
                    + "tokens, or shorten the conversation it has to read.")
        }
        return answer
    }
}
