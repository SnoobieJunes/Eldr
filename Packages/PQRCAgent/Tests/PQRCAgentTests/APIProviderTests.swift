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

    /// The other remote providers stay consistent: an empty key is never a live
    /// call, it's the not-configured fallback the app turns into the Demo stub.
    @Test func remoteProviders_emptyKey_allThrowNotConfigured() async {
        let providers: [any AgentProvider] = [
            OpenRouterAPIProvider(apiKey: ""),
            OpenAIAPIProvider(apiKey: ""),
            AnthropicAPIProvider(apiKey: ""),
            GeminiAPIProvider(apiKey: ""),
        ]
        for provider in providers {
            await #expect(throws: AgentProviderError.notConfigured) {
                _ = try await provider.draftReply(context: emptyContext())
            }
        }
    }
}
