// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Remote inference via OpenRouter (APP-SPEC §9, D3) — one API key, many models
/// (OpenAI, Anthropic, Google, Llama, …) behind an OpenAI-compatible endpoint.
///
/// OFF by default. Enabling requires the explicit consent flow: decrypted
/// conversation context is sent to a remote API; signing keys never leave the
/// device (SPEC §13.5), but message content does. The provider sends only the
/// minimal context window (the last 20 entries). The API key lives in the
/// Keychain at the app layer and is injected here.
///
/// Wire shape is identical to `OpenAIAPIProvider` (Chat Completions); only the
/// base URL, default model slug, and the optional ranking headers differ.
public struct OpenRouterAPIProvider: AgentProvider {
    public let apiKey: String
    public let model: String
    private let session: URLSession

    /// `model` is an OpenRouter slug ("vendor/model"), e.g. "openai/gpt-4o-mini"
    /// or "anthropic/claude-3.5-haiku". The default is a cheap, broadly-available
    /// model; the user can change it per-AI later.
    public init(apiKey: String, model: String = "openai/gpt-4o-mini") {
        self.apiKey = apiKey
        self.model = model
        self.session = URLSession(configuration: .ephemeral)
    }

    public func draftReply(context: AgentContext) async throws -> Draft {
        let text = try await complete(
            system: context.draftSystemPrompt(),
            user: FoundationModelsAgentProvider.renderTranscript(context))
        return Draft(text: text)
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
        guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
            throw AgentProviderError.unavailable("invalid OpenRouter endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // Optional ranking headers (OpenRouter convention). They identify the app
        // on OpenRouter's dashboards; they carry no conversation content.
        request.setValue("https://eldr.chat", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("EldrChat", forHTTPHeaderField: "X-Title")
        // Token-based consumption: bound the completion length explicitly.
        let payload: [String: Any] = [
            "model": model,
            "max_tokens": 512,
            "messages": openAIChatMessages(system: system, user: user),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)
        // Surface real failures (401 bad key, 404 bad model, 429 rate limit)
        // instead of a generic error, mirroring the other API providers.
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let apiMessage =
                ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw AgentProviderError.unavailable(
                "OpenRouter API \(http.statusCode): \(apiMessage ?? "request rejected")")
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
