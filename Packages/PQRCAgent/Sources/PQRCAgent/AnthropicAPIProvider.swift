import Foundation

/// Remote inference via the Anthropic API (APP-SPEC §9, D3).
///
/// OFF by default. Enabling requires the explicit consent flow: decrypted
/// conversation context is sent to a remote API; signing keys never leave the
/// device (SPEC §13.5), but message content does. The provider sends only the
/// minimal context window (the last 20 entries). The API key lives in the
/// Keychain at the app layer and is injected here.
public struct AnthropicAPIProvider: AgentProvider {
    public let apiKey: String
    public let model: String
    private let session: URLSession

    public init(apiKey: String, model: String = "claude-haiku-4-5-20251001") {
        self.apiKey = apiKey
        self.model = model
        self.session = URLSession(configuration: .ephemeral)
    }

    public func draftReply(context: AgentContext) async throws -> Draft {
        let text = try await complete(
            system:
                "You draft brief, natural message replies for \(context.myDisplayName). Reply with the draft text only.",
            user: FoundationModelsAgentProvider.renderTranscript(context))
        return Draft(text: text)
    }

    public func threadTurn(context: AgentContext) async throws -> AgentTurn? {
        let text = try await complete(
            system:
                "You are \(context.myDisplayName)'s AI in a shared thread with another person's AI. Contribute one short useful message, or reply exactly PASS to stay silent.",
            user: FoundationModelsAgentProvider.renderTranscript(context))
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "PASS" else { return nil }
        return AgentTurn(messages: [AgentMessage(text: trimmed)])
    }

    private func complete(system: String, user: String) async throws -> String {
        guard !apiKey.isEmpty else { throw AgentProviderError.notConfigured }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let payload: [String: Any] = [
            "model": model,
            "max_tokens": 512,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        // Surface real failures (401 bad key, 400 bad model, 429 rate limit)
        // instead of a generic "malformed" — these were invisible before
        // because every caller swallowed the error with `try?`.
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let apiMessage =
                ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw AgentProviderError.unavailable(
                "Anthropic API \(http.statusCode): \(apiMessage ?? "request rejected")")
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"] as? [[String: Any]],
            let text = content.first?["text"] as? String
        else {
            throw AgentProviderError.unavailable("unexpected API response shape")
        }
        return text
    }
}
