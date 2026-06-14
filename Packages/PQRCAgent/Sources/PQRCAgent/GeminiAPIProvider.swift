import Foundation

/// Remote inference via the Google Gemini (Generative Language) API
/// (APP-SPEC §9, D3).
///
/// OFF by default. Enabling requires the explicit consent flow: decrypted
/// conversation context is sent to a remote API; signing keys never leave the
/// device (SPEC §13.5), but message content does. The provider sends only the
/// minimal context window (the last 20 entries). The API key lives in the
/// Keychain at the app layer and is injected here.
public struct GeminiAPIProvider: AgentProvider {
    public let apiKey: String
    public let model: String
    private let session: URLSession

    public init(apiKey: String, model: String = "gemini-2.0-flash") {
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
        // The key rides in the header (x-goog-api-key) rather than the query
        // string so it never lands in URL logs.
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        guard let url = URL(string: endpoint) else {
            throw AgentProviderError.unavailable("invalid Gemini endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // Token-based consumption: bound the completion length explicitly.
        let payload: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": user]]]],
            "generationConfig": ["maxOutputTokens": 512],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        // Surface real failures (400 bad key, 404 bad model, 429 rate limit).
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let apiMessage =
                ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw AgentProviderError.unavailable(
                "Gemini API \(http.statusCode): \(apiMessage ?? "request rejected")")
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let candidates = json["candidates"] as? [[String: Any]],
            let content = candidates.first?["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]],
            let text = parts.first?["text"] as? String
        else {
            throw AgentProviderError.unavailable("unexpected API response shape")
        }
        return text
    }
}
