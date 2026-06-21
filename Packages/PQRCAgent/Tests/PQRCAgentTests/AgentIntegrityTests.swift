import Crypto
import Foundation
import Testing

@testable import PQRCAgent
@testable import PQRCCore
@testable import PQRCNostr

extension Tag {
    @Tag static var agent: Tag
}

/// Spy sink: records everything the engine posts. Used to prove both the
/// silence gates (nothing recorded) and the recording guarantee (everything
/// recorded is a thread message).
actor SpySink: AgentMessageSink {
    private(set) var threadPosts: [(body: MessageBody, threadID: String)] = []
    private(set) var conversationPosts: [MessageBody] = []

    func postAgentMessage(_ body: MessageBody, threadID: String, agentName: String?) async throws {
        threadPosts.append((body, threadID))
    }

    func postAgentReply(_ body: MessageBody, agentName: String?) async throws {
        conversationPosts.append(body)
    }

    var totalPosts: Int { threadPosts.count + conversationPosts.count }
}

func hexData(_ hex: String) -> Data {
    Data(hexString: hex) ?? Data()
}

@Suite("Agent integrity (SPEC §13, TEST-PLAN §6)", .tags(.agent))
struct AgentIntegrityTests {
    static func fixture() throws -> (
        engine: AgentEngine, sink: SpySink, clock: FixedClock,
        alice: PQRCIdentity, bob: PQRCIdentity
    ) {
        let clock = FixedClock(now: 1_756_000_000)
        let alice = try PQRCIdentity(seed: hexData(String(repeating: "a7", count: 32)))
        let bob = try PQRCIdentity(seed: hexData(String(repeating: "b7", count: 32)))
        let sink = SpySink()
        let engine = AgentEngine(myIdentity: alice, clock: clock, sink: sink)
        return (engine, sink, clock, alice, bob)
    }

    static func context(threadID: String? = nil) -> AgentContext {
        AgentContext(
            myIdentityHex: "self", myDisplayName: "Alice",
            transcript: [
                TranscriptEntry(
                    senderIdentityHex: "peer", senderDisplayName: "Bob",
                    participantType: .human, text: "what time works?")
            ],
            threadID: threadID, threadTitle: threadID.map { _ in "Planning" })
    }

    // MARK: silent by default

    @Test func silentByDefault_noAutonomousSendWithoutWindowOrInvite() async throws {
        let fx = try Self.fixture()
        // Eager provider WANTS to send every time; the engine must emit nothing.
        let provider = MockAgentProvider(eager: true)
        let threadPosted = await fx.engine.runThreadTurn(
            provider: provider, context: Self.context(threadID: "t1"), threadID: "t1")
        let windowPosted = await fx.engine.runWindowReply(
            provider: provider, context: Self.context())
        #expect(threadPosted == 0)
        #expect(!windowPosted)
        #expect(await fx.sink.totalPosts == 0, "silence is the default, regardless of provider")
        // Drafting is always allowed — it is private and sends nothing.
        let draft = try await fx.engine.draft(provider: provider, context: Self.context())
        #expect(!draft.text.isEmpty)
        #expect(await fx.sink.totalPosts == 0)
    }

    // MARK: ai_window validation

    @Test func aiWindow_onlyHumanIdentitySignatureAccepted() async throws {
        let fx = try Self.fixture()
        let until = fx.clock.now() + 1800

        // Valid: signed by Bob's human identity key.
        let valid = try AIWindowAnnouncement.make(activeUntil: until, identity: fx.bob)
        try await fx.engine.receiveWindow(
            valid, fromSenderIdentityHex: fx.bob.publicKeyData.hexString)
        #expect(
            await fx.engine.activeWindow(for: fx.bob.publicKeyData.hexString) == until,
            "valid window produces the visible indicator")

        // Agent-signed: an agent cannot self-activate.
        let bobAgent = try AgentKeyDeriver.deriveAgentKey(from: fx.bob)
        let agentForged = AIWindowAnnouncement(
            activeUntil: until,
            enabledBy: fx.bob.publicKeyData,
            sig: try bobAgent.signature(
                for: AIWindowAnnouncement.signatureMessage(
                    activeUntil: until, enabledBy: fx.bob.publicKeyData, threadID: nil)))
        await #expect(throws: AgentEngineError.windowSignatureInvalid) {
            try await fx.engine.receiveWindow(
                agentForged, fromSenderIdentityHex: fx.bob.publicKeyData.hexString)
        }

        // Third-party-signed: Mallory cannot activate Bob's window.
        let mallory = try PQRCIdentity(seed: hexData(String(repeating: "c7", count: 32)))
        let malloryForged = AIWindowAnnouncement(
            activeUntil: until,
            enabledBy: fx.bob.publicKeyData,
            sig: try mallory.sign(
                AIWindowAnnouncement.signatureMessage(
                    activeUntil: until, enabledBy: fx.bob.publicKeyData, threadID: nil)))
        await #expect(throws: AgentEngineError.windowSignatureInvalid) {
            try await fx.engine.receiveWindow(
                malloryForged, fromSenderIdentityHex: fx.bob.publicKeyData.hexString)
        }

        // A window claiming someone else's enabledBy is rejected before crypto.
        let misattributed = try AIWindowAnnouncement.make(activeUntil: until, identity: mallory)
        await #expect(throws: AgentEngineError.windowNotFromHumanIdentity) {
            try await fx.engine.receiveWindow(
                misattributed, fromSenderIdentityHex: fx.bob.publicKeyData.hexString)
        }
    }

    @Test func aiWindow_expiryFailsClosed() async throws {
        let fx = try Self.fixture()
        let announcement = try await fx.engine.startMyWindow(durationSeconds: 1800)
        let provider = MockAgentProvider(eager: true)

        // 1s before expiry: authorized.
        fx.clock.set(announcement.activeUntil - 1)
        #expect(await fx.engine.runWindowReply(provider: provider, context: Self.context()))

        // 1s after expiry: fails closed, no message escapes.
        fx.clock.set(announcement.activeUntil + 1)
        let postedAfter = await fx.engine.runWindowReply(provider: provider, context: Self.context())
        #expect(!postedAfter)
        #expect(await fx.sink.conversationPosts.count == 1)
        await #expect(throws: AgentEngineError.autonomousSendNotAuthorized) {
            try await fx.engine.authorizeAutonomousSend(threadID: nil)
        }
        // The indicator clears too.
        #expect(await fx.engine.activeWindow(for: fx.alice.publicKeyData.hexString) == nil)
    }

    @Test func aiWindow_unboundedDurationRejected() async throws {
        let fx = try Self.fixture()
        await #expect(throws: AgentEngineError.windowDurationUnbounded) {
            _ = try await fx.engine.startMyWindow(durationSeconds: 9_999_999)
        }
        // Incoming announcements beyond the bound are rejected as well.
        let farFuture = try AIWindowAnnouncement.make(
            activeUntil: fx.clock.now() + 86_400 * 30, identity: fx.bob)
        await #expect(throws: AgentEngineError.windowDurationUnbounded) {
            try await fx.engine.receiveWindow(
                farFuture, fromSenderIdentityHex: fx.bob.publicKeyData.hexString)
        }
    }

    // MARK: ai_invite (thread scope)

    @Test func aiInvite_threadScoped_perHumanGating() async throws {
        let fx = try Self.fixture()
        let provider = MockAgentProvider(eager: true)
        // Alice invites HER AI to thread t1.
        _ = try await fx.engine.startMyInvite(threadID: "t1", durationSeconds: 1800)

        // Alice-AI may post in t1...
        let postedT1 = await fx.engine.runThreadTurn(
            provider: provider, context: Self.context(threadID: "t1"), threadID: "t1")
        #expect(postedT1 == 1)
        // ...but not in another thread...
        let postedT2 = await fx.engine.runThreadTurn(
            provider: provider, context: Self.context(threadID: "t2"), threadID: "t2")
        #expect(postedT2 == 0)
        // ...and never in the parent conversation.
        #expect(!(await fx.engine.runWindowReply(provider: provider, context: Self.context())))
        let posts = await fx.sink.threadPosts
        #expect(posts.allSatisfy { $0.threadID == "t1" })
        #expect(posts.allSatisfy { $0.body.thread?.id == "t1" })

        // Per-human gating: Bob's invite state is independent — on BOB's
        // engine, Alice's invite must not authorize Bob's agent.
        let bobSink = SpySink()
        let bobEngine = AgentEngine(myIdentity: fx.bob, clock: fx.clock, sink: bobSink)
        let aliceInvite = try AIInvite.make(
            threadID: "t1", activeUntil: fx.clock.now() + 1800, identity: fx.alice)
        try await bobEngine.receiveInvite(
            aliceInvite, fromSenderIdentityHex: fx.alice.publicKeyData.hexString)
        let bobPosted = await bobEngine.runThreadTurn(
            provider: provider, context: Self.context(threadID: "t1"), threadID: "t1")
        #expect(bobPosted == 0, "one human's invite never activates the other's AI")
        #expect(await bobSink.totalPosts == 0)

        // Withdrawal closes the gate immediately.
        await fx.engine.withdrawMyInvite(threadID: "t1")
        let postedAfterWithdraw = await fx.engine.runThreadTurn(
            provider: provider, context: Self.context(threadID: "t1"), threadID: "t1")
        #expect(postedAfterWithdraw == 0)
    }

    @Test func aiInvite_signatureRules_matchAiWindow() async throws {
        let fx = try Self.fixture()
        let bobAgent = try AgentKeyDeriver.deriveAgentKey(from: fx.bob)
        let until = fx.clock.now() + 900
        // Agent-signed invite rejected (cannot self-activate).
        let forged = AIInvite(
            threadID: "t1", activeUntil: until, enabledBy: fx.bob.publicKeyData,
            sig: try bobAgent.signature(
                for: AIWindowAnnouncement.signatureMessage(
                    activeUntil: until, enabledBy: fx.bob.publicKeyData, threadID: "t1")))
        await #expect(throws: AgentEngineError.windowSignatureInvalid) {
            try await fx.engine.receiveInvite(
                forged, fromSenderIdentityHex: fx.bob.publicKeyData.hexString)
        }
        // An invite signature is thread-bound: replaying it for another thread fails.
        let valid = try AIInvite.make(threadID: "t1", activeUntil: until, identity: fx.bob)
        let crossThread = AIInvite(
            threadID: "t2", activeUntil: until, enabledBy: valid.enabledBy, sig: valid.sig)
        await #expect(throws: AgentEngineError.windowSignatureInvalid) {
            try await fx.engine.receiveInvite(
                crossThread, fromSenderIdentityHex: fx.bob.publicKeyData.hexString)
        }
    }

    // MARK: recording guarantee

    @Test func recordingGuarantee_allAgentOutputIsThreadMessages() async throws {
        let fx = try Self.fixture()
        // Provider returns context-bearing side material; the ONLY way it can
        // surface is as ordinary thread messages through the sink.
        let provider = MockAgentProvider(
            script: MockAgentProvider.Script(threadTurns: [
                AgentTurn(messages: [
                    AgentMessage(text: "summary of my human's notes", isContext: true),
                    AgentMessage(text: "I suggest Tuesday."),
                ])
            ]))
        _ = try await fx.engine.startMyInvite(threadID: "t9", durationSeconds: 900)
        let posted = await fx.engine.runThreadTurn(
            provider: provider, context: Self.context(threadID: "t9"), threadID: "t9")
        #expect(posted == 2)
        let posts = await fx.sink.threadPosts
        #expect(posts.count == 2)
        #expect(await fx.sink.conversationPosts.isEmpty, "no non-thread output path exists")
        #expect(posts.allSatisfy { $0.body.thread?.id == "t9" })
        // Context contributions are visible, prefixed, flagged for the folder glyph.
        #expect(posts[0].body.text == "Context: summary of my human's notes")
        #expect(posts[0].body.isContext == true)
        #expect(posts[1].body.text == "I suggest Tuesday.")
    }

    // MARK: loop guard

    @Test func loopGuard_pausesAfterSixConsecutiveAgentTurns_resumesOnHuman() async throws {
        let fx = try Self.fixture()
        let provider = MockAgentProvider(eager: true)
        _ = try await fx.engine.startMyInvite(threadID: "loop", durationSeconds: 7200)

        var totalPosted = 0
        for _ in 0..<10 {  // both agents babbling: every message is agent-authored
            totalPosted += await fx.engine.runThreadTurn(
                provider: provider, context: Self.context(threadID: "loop"), threadID: "loop")
        }
        #expect(totalPosted == PQRCConstants.agentLoopGuardLimit, "hard cap at 6")
        #expect(await fx.engine.loopGuardActive(threadID: "loop"))

        // A human message resets the counter and the agents resume.
        await fx.engine.recordThreadMessage(threadID: "loop", participantType: .human)
        #expect(!(await fx.engine.loopGuardActive(threadID: "loop")))
        let resumed = await fx.engine.runThreadTurn(
            provider: provider, context: Self.context(threadID: "loop"), threadID: "loop")
        #expect(resumed == 1)
    }

    @Test func loopGuard_countsRemoteAgentMessagesToo() async throws {
        let fx = try Self.fixture()
        let provider = MockAgentProvider(eager: true)
        _ = try await fx.engine.startMyInvite(threadID: "mix", durationSeconds: 7200)
        // 5 remote agent messages observed + 1 local post = 6 -> paused.
        for _ in 0..<5 {
            await fx.engine.recordThreadMessage(threadID: "mix", participantType: .agent)
        }
        let posted = await fx.engine.runThreadTurn(
            provider: provider, context: Self.context(threadID: "mix"), threadID: "mix")
        #expect(posted == 1)
        #expect(await fx.engine.loopGuardActive(threadID: "mix"))
    }

    @Test func loopGuard_configurableThreshold_pausesAtCustomLimit() async throws {
        // A per-account override (DEVIATIONS D14): pause after 3 instead of 6.
        let clock = FixedClock(now: 1_756_000_000)
        let alice = try PQRCIdentity(seed: hexData(String(repeating: "a7", count: 32)))
        let sink = SpySink()
        let engine = AgentEngine(myIdentity: alice, clock: clock, sink: sink, loopGuardLimit: 3)
        let provider = MockAgentProvider(eager: true)
        _ = try await engine.startMyInvite(threadID: "loop", durationSeconds: 7200)

        var totalPosted = 0
        for _ in 0..<10 {
            totalPosted += await engine.runThreadTurn(
                provider: provider, context: Self.context(threadID: "loop"), threadID: "loop")
        }
        #expect(totalPosted == 3, "honors the configured limit, not the default 6")
        #expect(await engine.loopGuardActive(threadID: "loop"))
    }

    @Test func loopGuard_off_neverPauses() async throws {
        // limit <= 0 disables the guard: agents may ping-pong unbounded. Also
        // exercises the live setter path used when the user flips the setting.
        let clock = FixedClock(now: 1_756_000_000)
        let alice = try PQRCIdentity(seed: hexData(String(repeating: "a7", count: 32)))
        let sink = SpySink()
        let engine = AgentEngine(myIdentity: alice, clock: clock, sink: sink, loopGuardLimit: 6)
        await engine.setLoopGuardLimit(0)
        let provider = MockAgentProvider(eager: true)
        _ = try await engine.startMyInvite(threadID: "loop", durationSeconds: 7200)

        var totalPosted = 0
        for _ in 0..<10 {
            totalPosted += await engine.runThreadTurn(
                provider: provider, context: Self.context(threadID: "loop"), threadID: "loop")
        }
        #expect(totalPosted == 10, "guard OFF — no automatic pause")
        #expect(!(await engine.loopGuardActive(threadID: "loop")))
    }
}
