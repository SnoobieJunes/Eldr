import Foundation

/// Remote inference via Groq (APP-SPEC §9, D3) — OpenAI-compatible, very fast
/// inference of open models (Llama/Qwen/GPT-OSS), no-training and no-retention by
/// default with self-serve Zero-Data-Retention. Same opt-in/consent treatment as
/// the other remote backends. Key in the Keychain; only the minimal context
/// window (last N entries) is sent.
public struct GroqAPIProvider: AgentProvider {
    public let apiKey: String
    public let model: String
    private let session: URLSession

    public init(apiKey: String, model: String = "llama-3.1-8b-instant") {
        self.apiKey = apiKey
        self.model = model.isEmpty ? "llama-3.1-8b-instant" : model
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

    private func complete(system: String, user: String) async throws -> String {
        guard !apiKey.isEmpty else { throw AgentProviderError.notConfigured }
        guard let url = URL(string: "https://api.groq.com/openai/v1/chat/completions") else {
            throw AgentProviderError.unavailable("invalid Groq endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let payload: [String: Any] = [
            "model": model,
            "max_tokens": 512,
            "messages": openAIChatMessages(system: system, user: user),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let apiMessage =
                ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw AgentProviderError.unavailable(
                "Groq API \(http.statusCode): \(apiMessage ?? "request rejected")")
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let text = message["content"] as? String
        else {
            throw AgentProviderError.unavailable("unexpected API response shape")
        }
        return text.strippingReasoningTrace()
    }
}
