// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import PQRCAgent

/// Network-free sanity checks for the token-API providers. These never touch the
/// network (an empty key fails before any request), honoring the "no unit test
/// touches the network" rule — they prove the wiring (consent gate / not-
/// configured fallback), not live inference.
@Suite("API providers")
struct APIProviderTests {
    private func emptyContext() -> AgentContext {
        AgentContext(myIdentityHex: "00", myDisplayName: "Me", transcript: [])
    }

    @Test func openRouter_emptyKey_throwsNotConfigured() async {
        let provider = OpenRouterAPIProvider(apiKey: "")
        await #expect(throws: AgentProviderError.notConfigured) {
            _ = try await provider.draftReply(context: emptyContext())
        }
    }

    @Test func openRouter_defaultModelIsAnOpenRouterSlug() {
        // OpenRouter addresses models as "vendor/model"; the default must be one.
        #expect(OpenRouterAPIProvider(apiKey: "k").model.contains("/"))
    }

    /// The hosted remote providers stay consistent: an empty key is never a live
    /// call, it's the not-configured fallback the app turns into the Demo stub.
    @Test func remoteProviders_emptyKey_allThrowNotConfigured() async {
        let providers: [any AgentProvider] = [
            OpenRouterAPIProvider(apiKey: ""),
            OpenAIAPIProvider(apiKey: ""),
            AnthropicAPIProvider(apiKey: ""),
            GeminiAPIProvider(apiKey: ""),
            GroqAPIProvider(apiKey: ""),
        ]
        for provider in providers {
            await #expect(throws: AgentProviderError.notConfigured) {
                _ = try await provider.draftReply(context: emptyContext())
            }
        }
    }

    /// Self-hosted / custom does NOT require an API key (a local Ollama/LM Studio
    /// has none). A MISSING server URL is the real misconfiguration — surfaced as
    /// `unavailable`, never `notConfigured`.
    @Test func custom_missingURL_isUnavailable_notNotConfigured() async {
        let provider = CustomOpenAIProvider(baseURL: "", apiKey: "", model: "")
        do {
            _ = try await provider.draftReply(context: emptyContext())
            Issue.record("expected an error when the server URL is missing")
        } catch AgentProviderError.notConfigured {
            Issue.record("self-hosted must NOT require an API key")
        } catch AgentProviderError.unavailable {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    /// The custom provider appends `/chat/completions` to a base, and accepts a
    /// full path idempotently — so http://<mac-ip>:11434/v1 just works.
    @Test func custom_endpoint_buildsChatCompletionsURL() {
        #expect(
            CustomOpenAIProvider(baseURL: "http://192.168.1.20:11434/v1", apiKey: "", model: "m")
                .endpoint()?.absoluteString == "http://192.168.1.20:11434/v1/chat/completions")
        #expect(
            CustomOpenAIProvider(baseURL: "http://h/v1/chat/completions/", apiKey: "", model: "m")
                .endpoint()?.absoluteString == "http://h/v1/chat/completions")
        // Bare host:port (the common LM Studio / Ollama setup) → OpenAI default path.
        #expect(
            CustomOpenAIProvider(baseURL: "http://localhost:1337", apiKey: "", model: "m")
                .endpoint()?.absoluteString == "http://localhost:1337/v1/chat/completions")
    }

    /// A reasoning model's `<think>` scratchpad is stripped from the answer that
    /// reaches the chat (qwen3 / DeepSeek-R1 over a self-hosted server), including
    /// a truncated, unclosed block — so the bubble never shows raw chain-of-thought.
    @Test func strippingReasoningTrace_removesThinkBlocks() {
        // Well-formed block: only the answer survives.
        #expect("<think>plan the reply</think>\n\nHello!".strippingReasoningTrace() == "Hello!")
        // Answer can precede the trace too.
        #expect("Answer: 42 <think>double-check</think>".strippingReasoningTrace() == "Answer: 42")
        // Unclosed (length-truncated mid-thought) → nothing usable remains.
        #expect("<think>still reasoning and cut off".strippingReasoningTrace().isEmpty)
        // Alternate spellings and case.
        #expect("<Thinking>x</Thinking>done".strippingReasoningTrace() == "done")
        // A normal model with no trace is returned trimmed, unchanged.
        #expect("  just a normal reply  ".strippingReasoningTrace() == "just a normal reply")
    }

    /// Channel/Harmony-tagged reasoning (gpt-oss, some Gemma QAT builds) — keep
    /// only the final-answer channel, drop the thought/analysis channel.
    @Test func strippingReasoningTrace_handlesChannelFormat() {
        // Gemma-QAT variant: "<|channel>thought … <channel|> ANSWER".
        #expect(
            "<|channel>thought\nweighing options\n<channel|>How about 10am?"
                .strippingReasoningTrace() == "How about 10am?")
        // Real Harmony: analysis channel then final channel.
        #expect(
            "<|channel|>analysis<|message|>reasoning<|channel|>final<|message|>The answer."
                .strippingReasoningTrace() == "The answer.")
        // Thought-only, no final transition → no usable answer (don't dump it).
        #expect("<|channel>thought\nstill thinking, truncated".strippingReasoningTrace().isEmpty)
    }
}
