// SPDX-License-Identifier: AGPL-3.0-only
import CryptoKit
import Foundation
import PQRCAgent
import PQRCCore
import PQRCNostr
import Testing

@testable import EldrChat

/// Two "devices" (Alice + Bob), each its own account, talking over a shared
/// in-process relay — the closest a headless test gets to the real two-device
/// flow the product runs. Exercises: account creation (bootstrap), mutual
/// binding verification + matching safety code, bidirectional 1:1 messaging, an
/// AI window where one side's AI reads the OTHER side's live message, and a
/// shared thread where BOTH people's AIs collaborate (read each other's posts).
/// On-device FoundationModels can't run here, so the eager `DemoAgentProvider`
/// stands in — the only thing that differs on a real device is the provider
/// behind `TetheredAI.provider`.
@Suite("End-to-end two-device flow", .serialized)
struct EndToEndFlowTests {
    private func makePersona(
        _ name: String, seed: UInt64, relay: LocalRelaySimulator, aiName: String
    ) async -> PersonaRuntime {
        await PersonaRuntime(
            displayName: name, transports: [relay.connect()],
            blobStore: LocalBlossomSimulator(),
            ais: [TetheredAI(id: aiName, name: aiName, provider: DemoAgentProvider())],
            randomSource: SeededRandomSource(seed: seed),
            nonceSource: SeededRandomSource(seed: seed &+ 1),
            keychainService: "chat.pqrc.test-e2e-\(name)-\(UUID().uuidString)")
    }

    /// Stand up Alice + Bob, bootstrap both, verify each other, and open the
    /// 1:1 with a first message. Returns the pair and their identity hexes.
    private func establishedPair() async throws -> (
        alice: PersonaRuntime, bob: PersonaRuntime, aliceHex: String, bobHex: String
    ) {
        let relay = LocalRelaySimulator()
        let alice = await makePersona("Alice", seed: 901, relay: relay, aiName: "alice-ai")
        let bob = await makePersona("Bob", seed: 903, relay: relay, aiName: "bob-ai")
        await alice.keychain.deleteAll()
        await bob.keychain.deleteAll()
        _ = try await alice.bootstrap(inMemoryStore: true)
        _ = try await bob.bootstrap(inMemoryStore: true)
        try await alice.addVerifiedPeer(bob)
        try await bob.addVerifiedPeer(alice)
        try await alice.establishWith(bob, firstMessage: "hi Bob")
        try await Task.sleep(for: .milliseconds(300))
        return (alice, bob, await alice.identityHex, await bob.identityHex)
    }

    /// Full happy path: create, verify (codes match), message both ways, then
    /// Alice's AI reads Bob's live message under her window.
    @Test func create_verify_messageBothWays_and_windowAIReadsPeer() async throws {
        let (alice, bob, aliceHex, bobHex) = try await establishedPair()

        // Bob received Alice's first message; Bob replies; Alice receives it.
        try await Task.sleep(for: .milliseconds(150))
        #expect(
            await bob.messages(conversationID: aliceHex).contains { $0.text == "hi Bob" },
            "Bob received Alice's first message")
        try await bob.sendMessage("hey Alice", conversationID: aliceHex)
        try await Task.sleep(for: .milliseconds(300))
        #expect(
            await alice.messages(conversationID: bobHex).contains { $0.text == "hey Alice" },
            "Alice received Bob's reply — messaging works both ways")

        // Verification: both sides derive the SAME 60-digit safety code.
        let codeA = await alice.safetyCode(with: bobHex)
        let codeB = await bob.safetyCode(with: aliceHex)
        #expect(!codeA.isEmpty && codeA == codeB, "safety codes match on both devices")

        // Alice turns on her AI window, Bob sends a message, Alice's AI replies to
        // it — proving her AI READ Bob's message (gained context from the peer).
        try await alice.startAIWindow(conversationID: bobHex, durationSeconds: 15 * 60)
        try await bob.sendMessage("what time is dinner?", conversationID: aliceHex)
        try await Task.sleep(for: .milliseconds(800))
        let aliceAIReplies = await alice.messages(conversationID: bobHex)
            .filter { $0.participantType == .agent && $0.senderIdentity == aliceHex }
        #expect(!aliceAIReplies.isEmpty, "Alice's AI replied during her window")
        #expect(
            aliceAIReplies.contains { $0.text.contains("dinner") },
            "Alice's AI's reply reflects Bob's message — it read the peer's context")

        await alice.shutdown()
        await bob.shutdown()
    }

    /// Shared thread: both people invite their AIs, and the two AIs collaborate —
    /// each reads and responds to the other's posts (and the humans'). The proof
    /// is that Alice's thread ends up holding agent messages authored by BOTH
    /// her AI (senderIdentity == aliceHex) and Bob's AI (== bobHex).
    @Test func sharedThread_bothPeoplesAIsCollaborate() async throws {
        let (alice, bob, aliceHex, bobHex) = try await establishedPair()

        let threadID = try await alice.createThread(
            conversationID: bobHex, title: "Trip planning")
        try await Task.sleep(for: .milliseconds(300))  // let Bob learn the thread

        try await alice.inviteMyAI(threadID: threadID, durationSeconds: 30 * 60)
        try await bob.inviteMyAI(threadID: threadID, durationSeconds: 30 * 60)
        try await Task.sleep(for: .milliseconds(200))

        try await alice.sendMessage(
            "let's pick a city", conversationID: bobHex, threadID: threadID)
        // The AIs ping-pong, bounded by the loop guard (6 consecutive agent turns).
        try await Task.sleep(for: .milliseconds(2000))

        let threadMessages = await alice.messages(threadID: threadID)
        let aliceAI = threadMessages.filter {
            $0.participantType == .agent && $0.senderIdentity == aliceHex
        }
        let bobAI = threadMessages.filter {
            $0.participantType == .agent && $0.senderIdentity == bobHex
        }
        #expect(!aliceAI.isEmpty, "Alice's AI posted in the shared thread")
        #expect(
            !bobAI.isEmpty,
            "Bob's AI posted in the shared thread (Alice received it) — the two AIs collaborated")

        await alice.shutdown()
        await bob.shutdown()
    }

    /// Probe: the curated "Add to AI Context" + bilateral grant path across two
    /// devices in a shared thread. Alice marks her thread message and both grant
    /// thread-scope sharing; Bob's AI context should then surface Alice's marked
    /// message as SHARED context even with no active invite. (Verifies the
    /// cross-device marker mirror + bilateral grant end to end.)
    @Test func markedContext_sharedAcrossDevices_inThread() async throws {
        let (alice, bob, aliceHex, bobHex) = try await establishedPair()

        let threadID = try await alice.createThread(conversationID: bobHex, title: "Budget")
        try await Task.sleep(for: .milliseconds(300))

        try await alice.sendMessage(
            "the budget ceiling is BLUEBIRD", conversationID: bobHex, threadID: threadID)
        try await Task.sleep(for: .milliseconds(300))

        // Alice marks her own thread message as AI context; the marker mirrors to
        // Bob's copy so his AI can treat it as shared (under a grant).
        let aliceMsg = try #require(
            await alice.messages(threadID: threadID)
                .first { $0.text.contains("BLUEBIRD") && $0.senderIdentity == aliceHex },
            "Alice has her own thread message to mark")
        await alice.markAsAIContext(
            messageIDs: [aliceMsg.id], value: true, conversationID: bobHex)
        try await Task.sleep(for: .milliseconds(300))

        // Both humans grant context sharing for this thread scope (each addresses
        // the grant to the OTHER party: Alice's conversation id for Bob is bobHex,
        // Bob's for Alice is aliceHex).
        try await alice.grantAIContext(
            scope: .thread(threadID), durationSeconds: 30 * 60, conversationID: bobHex,
            threadID: threadID)
        try await bob.grantAIContext(
            scope: .thread(threadID), durationSeconds: 30 * 60, conversationID: aliceHex,
            threadID: threadID)
        try await Task.sleep(for: .milliseconds(400))

        // Bob's AI context for the thread should now include Alice's marked line
        // as shared context.
        let bobShared = await bob.contextPreview(conversationID: bobHex, threadID: threadID)
            .filter { $0.shared }
        #expect(
            bobShared.contains { $0.text.contains("BLUEBIRD") },
            "Bob's AI sees Alice's marked message as shared context across devices")

        await alice.shutdown()
        await bob.shutdown()
    }
}
