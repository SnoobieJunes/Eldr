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

    public init(baseURL: String, apiKey: String, model: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        // Local servers (LM Studio) ignore the model name and serve whatever's
        // loaded; Ollama needs a real one — surfaced in Settings.
        self.model = model.isEmpty ? "local-model" : model
        self.session = URLSession(configuration: .ephemeral)
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
            // Self-hosted reasoning models (qwen3, DeepSeek-R1) spend tokens on a
            // `<think>` scratchpad before answering, so give them more room than
            // the hosted (paid) providers — then strip the trace below.
            "max_tokens": 1024,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
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
            let message = choices.first?["message"] as? [String: Any],
            let text = message["content"] as? String
        else {
            throw AgentProviderError.unavailable("unexpected response shape from the server")
        }
        return text.strippingReasoningTrace()
    }
}
