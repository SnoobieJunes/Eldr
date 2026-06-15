import Foundation
import PQRCAgent
import PQRCCore
import PQRCNostr
import Testing

@testable import EldrChat

/// Behavioral coverage for multi-AI tethering and the solo AI chat. On-device
/// FoundationModels can't run in the test environment, so these drive the
/// IDENTICAL engine/runtime path with the eager `DemoAgentProvider` standing in
/// for the on-device model (the only thing that differs on a real device is the
/// provider instance behind `TetheredAI.provider`).
@Suite("Multi-AI & solo chat", .serialized)
struct MultiAIBehaviorTests {
    private func makeRuntime(_ name: String, ais: [TetheredAI]) async -> PersonaRuntime {
        await PersonaRuntime(
            displayName: name, transports: [LocalRelaySimulator().connect()],
            blobStore: LocalBlossomSimulator(), ais: ais,
            randomSource: SeededRandomSource(seed: 401),
            nonceSource: SeededRandomSource(seed: 402),
            keychainService: "chat.pqrc.test-multiai-\(name)-\(UUID().uuidString)")
    }

    /// The "group chat by yourself" staging ground: a solo conversation with no
    /// other humans, where every tethered AI replies to me locally and nothing
    /// is published to a peer.
    @Test func soloChat_eachTetheredAIRepliesToMe_locally() async throws {
        let runtime = await makeRuntime(
            "Me",
            ais: [
                TetheredAI(id: "a", name: "calm-otter-naps-111", provider: DemoAgentProvider()),
                TetheredAI(id: "b", name: "wise-finch-soars-222", provider: DemoAgentProvider()),
            ])
        await runtime.keychain.deleteAll()
        _ = try await runtime.bootstrap(inMemoryStore: true)

        let chatID = try await runtime.createSelfChat()
        try await runtime.sendMessage("plan my week", conversationID: chatID)
        // runSelfAIReplies runs detached; give it room to post both replies.
        try await Task.sleep(for: .milliseconds(400))

        let messages = await runtime.messages(conversationID: chatID)
        let agentReplies = messages.filter { $0.participantType == .agent }
        #expect(agentReplies.count == 2, "both tethered AIs reply to me in the solo chat")
        let names = Set(agentReplies.compactMap(\.agentName))
        #expect(
            names == ["calm-otter-naps-111", "wise-finch-soars-222"],
            "each reply is labeled with its own AI's local codename")
        // Stays local: a human message in a solo conversation is never marked
        // "failed" (no recipients to reach) and there is no peer to publish to.
        let mine = messages.first { $0.participantType == .human }
        #expect(mine?.localStatus != "failed", "solo send stays local, not a failed publish")
    }

    /// By default (no active window/invite) my AI must only ingest messages I
    /// explicitly marked as AI context — never the whole conversation.
    @Test func defaultIngest_onlyMarkedContext_outsideAnActiveWindow() async throws {
        let relay = LocalRelaySimulator()
        let alice = PersonaRuntime(
            displayName: "Alice", transports: [await relay.connect()],
            blobStore: LocalBlossomSimulator(),
            ais: [TetheredAI(id: "a", name: "alice-ai", provider: DemoAgentProvider())],
            randomSource: SeededRandomSource(seed: 411), nonceSource: SeededRandomSource(seed: 412),
            keychainService: "chat.pqrc.test-ingest-alice-\(UUID().uuidString)")
        let bob = PersonaRuntime(
            displayName: "Bob", transports: [await relay.connect()],
            blobStore: LocalBlossomSimulator(),
            ais: [TetheredAI(id: "b", name: "bob-ai", provider: DemoAgentProvider())],
            randomSource: SeededRandomSource(seed: 413), nonceSource: SeededRandomSource(seed: 414),
            keychainService: "chat.pqrc.test-ingest-bob-\(UUID().uuidString)")
        await alice.keychain.deleteAll()
        await bob.keychain.deleteAll()
        _ = try await alice.bootstrap(inMemoryStore: true)
        _ = try await bob.bootstrap(inMemoryStore: true)
        try await alice.addVerifiedPeer(bob)
        try await bob.addVerifiedPeer(alice)
        try await alice.establishWith(bob, firstMessage: "hello")
        try await Task.sleep(for: .milliseconds(200))
        let bobHex = await bob.identityHex

        // With NO active window and nothing marked, the draft context is empty —
        // the AI does not auto-ingest the conversation.
        let emptyDraft = try await alice.draftReply(conversationID: bobHex)
        #expect(
            !emptyDraft.text.contains("hello"),
            "unmarked conversation must not be auto-ingested by default")

        await alice.shutdown()
        await bob.shutdown()
    }
}
