import CryptoKit
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

    /// "Use 2 demo AI and get them to post to each other": in a solo chat the two
    /// tethered AIs talk to EACH OTHER, not just to me — the second AI runs after
    /// the first has posted, sees that post, and builds on it.
    @Test func soloChat_twoDemoAIs_postToEachOther() async throws {
        let runtime = await makeRuntime(
            "Me",
            ais: [
                TetheredAI(id: "a", name: "calm-otter-naps-111", provider: DemoAgentProvider()),
                TetheredAI(id: "b", name: "wise-finch-soars-222", provider: DemoAgentProvider()),
            ])
        await runtime.keychain.deleteAll()
        _ = try await runtime.bootstrap(inMemoryStore: true)

        let chatID = try await runtime.createSelfChat()
        try await runtime.sendMessage("kick us off", conversationID: chatID)
        try await Task.sleep(for: .milliseconds(500))

        let messages = await runtime.messages(conversationID: chatID)
        let agentReplies = messages.filter { $0.participantType == .agent }
        #expect(agentReplies.count == 2, "both tethered AIs post into the solo chat")
        // Exactly one reply responds to the OTHER AI (the second to run); the
        // first responds to me. That asymmetry is the proof they see each other.
        let buildingOnPeerAI = agentReplies.filter { $0.text.contains("other AI") }
        #expect(
            buildingOnPeerAI.count == 1,
            "the second AI builds on the first AI's post — they post to each other")
    }

    /// A solo GROUP created with no other members (New Group → nobody selected)
    /// behaves like the AI chat: the AI is on from creation, so it sees my
    /// message instead of an empty transcript (the "AI ignored what I said" bug).
    @Test func soloGroup_noOtherMembers_aiSeesMyMessage() async throws {
        let runtime = await makeRuntime(
            "Me",
            ais: [TetheredAI(id: "a", name: "calm-otter-naps-111", provider: DemoAgentProvider())])
        await runtime.keychain.deleteAll()
        _ = try await runtime.bootstrap(inMemoryStore: true)

        let groupID = try await runtime.createGroup(name: "Just me", memberIdentityHexes: [])
        try await runtime.sendMessage("remember the milk", conversationID: groupID)
        try await Task.sleep(for: .milliseconds(400))

        let reply = await runtime.messages(conversationID: groupID)
            .first { $0.participantType == .agent }
        #expect(reply != nil, "the AI replies in a member-less solo group")
        #expect(
            reply?.text.contains("remember the milk") == true,
            "the reply reflects my message — the AI's context is not empty at creation")
    }

    /// "Two AIs not posting when I enable the setting": with Alice's ai_window on,
    /// BOTH of her tethered AIs reply to a peer's message — the window authorizes
    /// every tethered AI, not just one. (agentName is set only on the local copy;
    /// it is never on the wire, so a Set of names is robust to any relay echo.)
    @Test func aiWindow_bothTetheredAIsReplyToPeer() async throws {
        let relay = LocalRelaySimulator()
        let alice = PersonaRuntime(
            displayName: "Alice", transports: [await relay.connect()],
            blobStore: LocalBlossomSimulator(),
            ais: [
                TetheredAI(id: "a1", name: "alice-ai-one", provider: DemoAgentProvider()),
                TetheredAI(id: "a2", name: "alice-ai-two", provider: DemoAgentProvider()),
            ],
            randomSource: SeededRandomSource(seed: 421), nonceSource: SeededRandomSource(seed: 422),
            keychainService: "chat.pqrc.test-window-alice-\(UUID().uuidString)")
        let bob = PersonaRuntime(
            displayName: "Bob", transports: [await relay.connect()],
            blobStore: LocalBlossomSimulator(),
            ais: [TetheredAI(id: "b", name: "bob-ai", provider: DemoAgentProvider())],
            randomSource: SeededRandomSource(seed: 423), nonceSource: SeededRandomSource(seed: 424),
            keychainService: "chat.pqrc.test-window-bob-\(UUID().uuidString)")
        await alice.keychain.deleteAll()
        await bob.keychain.deleteAll()
        _ = try await alice.bootstrap(inMemoryStore: true)
        _ = try await bob.bootstrap(inMemoryStore: true)
        try await alice.addVerifiedPeer(bob)
        try await bob.addVerifiedPeer(alice)
        try await alice.establishWith(bob, firstMessage: "hi")
        try await Task.sleep(for: .milliseconds(250))
        let aliceHex = await alice.identityHex
        let bobHex = await bob.identityHex

        // Alice enables her always-on AI window for the conversation with Bob.
        try await alice.startAIWindow(conversationID: bobHex, durationSeconds: 15 * 60)
        // Bob sends a human message; both of Alice's AIs should reply.
        try await bob.sendMessage("what's the plan?", conversationID: aliceHex)
        try await Task.sleep(for: .milliseconds(800))

        let aliceReplyNames = Set(
            await alice.messages(conversationID: bobHex)
                .filter { $0.participantType == .agent && $0.senderIdentity == aliceHex }
                .compactMap(\.agentName))
        #expect(
            aliceReplyNames == ["alice-ai-one", "alice-ai-two"],
            "both of Alice's tethered AIs reply during her window")

        await alice.shutdown()
        await bob.shutdown()
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

    /// Egress firewall ON (default): a REMOTE AI must never receive my real
    /// display name — only the local "you"/codename.
    @Test func firewall_redactsRealNamesForRemoteAI() async throws {
        let spy = SpyProvider()
        let runtime = await makeRuntime(
            "Alice", ais: [TetheredAI(id: "r", name: "remote-ai", provider: spy, isRemote: true)])
        await runtime.keychain.deleteAll()
        _ = try await runtime.bootstrap(inMemoryStore: true)
        let chatID = try await runtime.createSelfChat()
        try await runtime.sendMessage("secret plan", conversationID: chatID)
        try await Task.sleep(for: .milliseconds(400))

        let names = await spy.capturedNames
        #expect(names.contains("you"), "my real name is replaced with 'you' for a remote AI")
        #expect(!names.contains("Alice"), "real display name must NOT leave the device to a remote AI")
    }

    /// Egress firewall OFF: the real display name is passed through (the warned
    /// trade-off). On-device AIs are unaffected either way.
    @Test func firewall_off_passesRealNames() async throws {
        let spy = SpyProvider()
        let runtime = await makeRuntime(
            "Alice", ais: [TetheredAI(id: "r", name: "remote-ai", provider: spy, isRemote: true)])
        await runtime.keychain.deleteAll()
        _ = try await runtime.bootstrap(inMemoryStore: true)
        await runtime.setFirewallEnabled(false)
        let chatID = try await runtime.createSelfChat()
        try await runtime.sendMessage("hi", conversationID: chatID)
        try await Task.sleep(for: .milliseconds(400))

        let names = await spy.capturedNames
        #expect(names.contains("Alice"), "with the firewall off, the real display name is sent")
    }

    // MARK: - Context profile (instructions / policy / depth / output mode)

    /// Custom per-AI instructions (the persona profile field) reach the provider.
    @Test func customInstructions_reachTheProvider() async throws {
        let spy = SpyProvider()
        let runtime = await makeRuntime(
            "Me", ais: [TetheredAI(id: "a", name: "ai", provider: spy, instructions: "Be a pirate.")])
        await runtime.keychain.deleteAll()
        _ = try await runtime.bootstrap(inMemoryStore: true)
        let chatID = try await runtime.createSelfChat()
        try await runtime.sendMessage("hello", conversationID: chatID)
        try await Task.sleep(for: .milliseconds(400))
        #expect(await spy.capturedInstructions == "Be a pirate.")
    }

    /// "Draft only" output mode: consulted for manual drafts but NEVER auto-posts.
    @Test func draftOnlyAI_neverAutoPosts() async throws {
        let runtime = await makeRuntime(
            "Me",
            ais: [TetheredAI(id: "a", name: "ai", provider: DemoAgentProvider(), outputMode: "draft")])
        await runtime.keychain.deleteAll()
        _ = try await runtime.bootstrap(inMemoryStore: true)
        let chatID = try await runtime.createSelfChat()
        try await runtime.sendMessage("plan my week", conversationID: chatID)
        try await Task.sleep(for: .milliseconds(400))
        let replies = await runtime.messages(conversationID: chatID).filter { $0.participantType == .agent }
        #expect(replies.isEmpty, "a draft-only AI suggests but never auto-posts")
    }

    /// "Off" gather policy: the AI never participates autonomously.
    @Test func offPolicyAI_doesNotParticipate() async throws {
        let runtime = await makeRuntime(
            "Me",
            ais: [TetheredAI(id: "a", name: "ai", provider: DemoAgentProvider(), contextPolicy: "off")])
        await runtime.keychain.deleteAll()
        _ = try await runtime.bootstrap(inMemoryStore: true)
        let chatID = try await runtime.createSelfChat()
        try await runtime.sendMessage("anything", conversationID: chatID)
        try await Task.sleep(for: .milliseconds(400))
        let replies = await runtime.messages(conversationID: chatID).filter { $0.participantType == .agent }
        #expect(replies.isEmpty, "an 'off' AI gathers nothing and never posts")
    }

    /// "Strict" gather policy ignores the live conversation even while active —
    /// only messages explicitly added to context are handed to the model.
    @Test func strictPolicy_ignoresLiveConversation() async throws {
        let spy = SpyProvider()
        let runtime = await makeRuntime(
            "Me", ais: [TetheredAI(id: "a", name: "ai", provider: spy, contextPolicy: "strict")])
        await runtime.keychain.deleteAll()
        _ = try await runtime.bootstrap(inMemoryStore: true)
        let chatID = try await runtime.createSelfChat()
        try await runtime.sendMessage("unmarked live message", conversationID: chatID)
        try await Task.sleep(for: .milliseconds(400))
        #expect(
            await spy.capturedCount == 0,
            "strict policy ingests no live messages — only ones added to context")
    }

    /// Per-conversation override of "off" disables AI here even when the AI's own
    /// policy is active.
    @Test func perConversationOff_suppressesAI() async throws {
        let runtime = await makeRuntime(
            "Me", ais: [TetheredAI(id: "a", name: "ai", provider: DemoAgentProvider())])
        await runtime.keychain.deleteAll()
        _ = try await runtime.bootstrap(inMemoryStore: true)
        let chatID = try await runtime.createSelfChat()
        AppSession.setConversationContextMode("off", conversationID: chatID)
        defer { AppSession.setConversationContextMode(nil, conversationID: chatID) }
        try await runtime.sendMessage("hi", conversationID: chatID)
        try await Task.sleep(for: .milliseconds(400))
        let replies = await runtime.messages(conversationID: chatID).filter { $0.participantType == .agent }
        #expect(
            replies.isEmpty,
            "per-conversation 'off' stops the AI even though its own policy is active")
    }

    /// A skill pinned to a thread (agent-to-agent skills) reaches the AI's
    /// thread-turn system prompt, along with the PQRC guardrail injection.
    @Test func pinnedSkill_reachesThreadTurnContext() async throws {
        let spy = SpyProvider()
        let runtime = await makeRuntime("Me", ais: [TetheredAI(id: "a", name: "ai", provider: spy)])
        await runtime.keychain.deleteAll()
        _ = try await runtime.bootstrap(inMemoryStore: true)
        let chatID = try await runtime.createSelfChat()
        let threadID = try await runtime.createThread(conversationID: chatID, title: "Design")
        AppSession.setThreadSkills(["tech-spec"], threadID: threadID)
        defer { AppSession.setThreadSkills([], threadID: threadID) }
        // Inviting my AI fires a thread turn, which builds the thread context.
        try await runtime.inviteMyAI(threadID: threadID, durationSeconds: 30 * 60)
        try await Task.sleep(for: .milliseconds(400))

        let prompt = await spy.capturedSystemPrompt
        #expect(
            prompt?.contains("scope:thread:\(threadID)") == true,
            "the thread guardrail injection reached the AI")
        #expect(
            prompt?.contains("tech-spec") == true,
            "the pinned skill's contract reached the AI's thread-turn prompt")
    }
}

/// Deniable silos: a silo created under one passphrase persists and reopens with
/// that passphrase's derived key, and a different passphrase is a completely
/// separate, isolated identity. (Each silo has its own keychain service + store,
/// mirroring production where the service is derived from the passphrase, so a
/// wrong passphrase resolves to a different — non-existent — silo, never the real
/// one.)
@Suite("Deniable account silos", .serialized)
struct SiloRuntimeTests {
    @Test func silo_persistsAndReopensWithItsKEK_isolatedFromOthers() async throws {
        let a = SiloKey.derive(passphrase: "alpha-passphrase")
        let b = SiloKey.derive(passphrase: "beta-passphrase")
        let svcA = "chat.pqrc.test-silo-\(a.siloID)"
        let svcB = "chat.pqrc.test-silo-\(b.siloID)"
        let tmp = FileManager.default.temporaryDirectory
        let storeA = tmp.appendingPathComponent("siloA-\(UUID().uuidString).store")
        let storeB = tmp.appendingPathComponent("siloB-\(UUID().uuidString).store")
        KeychainStore(service: svcA).deleteAll()
        KeychainStore(service: svcB).deleteAll()
        defer {
            KeychainStore(service: svcA).deleteAll()
            KeychainStore(service: svcB).deleteAll()
            for url in [storeA, storeB] {
                for suffix in ["", "-wal", "-shm"] {
                    try? FileManager.default.removeItem(
                        at: URL(fileURLWithPath: url.path + suffix))
                }
            }
        }

        func bootIdentity(service: String, kek: SymmetricKey, store: URL) async throws -> String {
            let runtime = await PersonaRuntime(
                displayName: "X", transports: [LocalRelaySimulator().connect()],
                blobStore: LocalBlossomSimulator(),
                ais: [TetheredAI(id: "d", name: "ai", provider: DemoAgentProvider())],
                keychainService: service, siloKEK: kek)
            _ = try await runtime.bootstrap(inMemoryStore: false, storeURL: store)
            let hex = await runtime.identityHex
            await runtime.shutdown()
            return hex
        }

        let hexA1 = try await bootIdentity(service: svcA, kek: a.kek, store: storeA)
        let hexB = try await bootIdentity(service: svcB, kek: b.kek, store: storeB)
        let hexA2 = try await bootIdentity(service: svcA, kek: a.kek, store: storeA)

        #expect(hexA1 == hexA2, "a silo reopens to the same identity with its passphrase key")
        #expect(hexA1 != hexB, "different passphrases are separate, isolated identities")
        #expect(!hexA1.isEmpty)
    }
}

/// Records the transcript display names of the last context it was handed, so
/// tests can assert exactly what would leave the device for a remote AI.
actor SpyProvider: AgentProvider {
    private(set) var capturedNames: [String] = []
    private(set) var capturedInstructions: String?
    private(set) var capturedSummarize = false
    private(set) var capturedCount = 0
    private(set) var capturedSystemPrompt: String?
    private func capture(_ context: AgentContext) {
        capturedNames = context.transcript.map(\.senderDisplayName)
        capturedInstructions = context.instructions
        capturedSummarize = context.summarize
        capturedCount = context.transcript.count
        capturedSystemPrompt = context.systemPromptOverride
    }
    func draftReply(context: AgentContext) async throws -> Draft {
        capture(context)
        return Draft(text: "ok")
    }
    func threadTurn(context: AgentContext) async throws -> AgentTurn? {
        capture(context)
        return AgentTurn(messages: [AgentMessage(text: "ok")])
    }
}
