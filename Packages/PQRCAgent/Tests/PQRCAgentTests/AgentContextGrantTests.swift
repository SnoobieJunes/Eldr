import Crypto
import Foundation
import Testing

@testable import PQRCAgent
@testable import PQRCCore

/// Context-sharing grant (DEVIATIONS N24): the *consume* axis. These prove it
/// stays inside invariant 9 — human-signed, bounded, fail-closed, and never
/// widens the *send* axis.
@Suite("AI context sharing grant", .tags(.agent))
struct AgentContextGrantTests {
    static func fixture() throws -> (
        engine: AgentEngine, clock: FixedClock, alice: PQRCIdentity, bob: PQRCIdentity
    ) {
        let clock = FixedClock(now: 1_756_000_000)
        let alice = try PQRCIdentity(seed: hexData(String(repeating: "a7", count: 32)))
        let bob = try PQRCIdentity(seed: hexData(String(repeating: "b7", count: 32)))
        let engine = AgentEngine(myIdentity: alice, clock: clock, sink: SpySink())
        return (engine, clock, alice, bob)
    }

    static let scope = AIContextGrant.Scope.thread("t1")

    @Test func bidirectionalGrantsRequired() async throws {
        let fx = try Self.fixture()
        // Only my grant: not authorized (the peer hasn't opted in).
        _ = try await fx.engine.startMyContextGrant(scope: Self.scope, durationSeconds: 1800)
        #expect(await fx.engine.contextSharingAuthorized(scope: Self.scope) == false)

        // Peer grants too: now authorized in both directions.
        let bobGrant = try AIContextGrant.make(
            scope: Self.scope, activeUntil: fx.clock.now() + 1800, identity: fx.bob)
        try await fx.engine.receiveContextGrant(
            bobGrant, fromSenderIdentityHex: fx.bob.publicKeyData.hexString)
        #expect(await fx.engine.contextSharingAuthorized(scope: Self.scope) == true)
    }

    @Test func peerGrantAloneIsNotEnough() async throws {
        let fx = try Self.fixture()
        let bobGrant = try AIContextGrant.make(
            scope: Self.scope, activeUntil: fx.clock.now() + 1800, identity: fx.bob)
        try await fx.engine.receiveContextGrant(
            bobGrant, fromSenderIdentityHex: fx.bob.publicKeyData.hexString)
        // I never granted → default-deny.
        #expect(await fx.engine.contextSharingAuthorized(scope: Self.scope) == false)
    }

    @Test func expiryFailsClosed() async throws {
        let fx = try Self.fixture()
        let mine = try await fx.engine.startMyContextGrant(scope: Self.scope, durationSeconds: 1800)
        let bobGrant = try AIContextGrant.make(
            scope: Self.scope, activeUntil: mine.activeUntil, identity: fx.bob)
        try await fx.engine.receiveContextGrant(
            bobGrant, fromSenderIdentityHex: fx.bob.publicKeyData.hexString)
        #expect(await fx.engine.contextSharingAuthorized(scope: Self.scope) == true)

        // Advance past expiry: no timer involved — evaluated on access.
        fx.clock.set(mine.activeUntil + 1)
        #expect(await fx.engine.contextSharingAuthorized(scope: Self.scope) == false)
        #expect(await fx.engine.activeContextGrant(
            scope: Self.scope, identityHex: fx.alice.publicKeyData.hexString) == nil)
    }

    @Test func onlyHumanIdentitySignatureAccepted() async throws {
        let fx = try Self.fixture()
        let until = fx.clock.now() + 1800

        // Agent-signed: an agent cannot self-activate a grant.
        let bobAgent = try AgentKeyDeriver.deriveAgentKey(from: fx.bob)
        let agentForged = AIContextGrant(
            scope: Self.scope, activeUntil: until, enabledBy: fx.bob.publicKeyData,
            sig: try bobAgent.signature(
                for: AIContextGrant.signatureMessage(
                    scope: Self.scope, activeUntil: until, enabledBy: fx.bob.publicKeyData)))
        await #expect(throws: AgentEngineError.windowSignatureInvalid) {
            try await fx.engine.receiveContextGrant(
                agentForged, fromSenderIdentityHex: fx.bob.publicKeyData.hexString)
        }

        // enabledBy claims someone else: rejected before crypto.
        let misattributed = try AIContextGrant.make(
            scope: Self.scope, activeUntil: until, identity: fx.alice)
        await #expect(throws: AgentEngineError.windowNotFromHumanIdentity) {
            try await fx.engine.receiveContextGrant(
                misattributed, fromSenderIdentityHex: fx.bob.publicKeyData.hexString)
        }
    }

    @Test func domainSeparationNoCrossReplay() async throws {
        let fx = try Self.fixture()
        let until = fx.clock.now() + 1800
        // A signature made over the ai_window/ai_invite domain must NOT validate
        // as a context grant (distinct domain string).
        let crossSig = try fx.bob.sign(
            AIWindowAnnouncement.signatureMessage(
                activeUntil: until, enabledBy: fx.bob.publicKeyData, threadID: "t1"))
        let forged = AIContextGrant(
            scope: Self.scope, activeUntil: until, enabledBy: fx.bob.publicKeyData, sig: crossSig)
        #expect(forged.hasValidSignature() == false)
    }

    @Test func durationBounded() async throws {
        let fx = try Self.fixture()
        await #expect(throws: AgentEngineError.windowDurationUnbounded) {
            try await fx.engine.startMyContextGrant(scope: Self.scope, durationSeconds: 99)
        }
        // A received grant claiming MORE than the 24h max window/grant duration is
        // rejected. (The cap rose from 2h to 24h when the 8h/24h "My AI responds"
        // windows were added — AgentEngine.maxWindowDuration; send side still validates
        // by the exact allowed set, receive side by this hard cap.)
        let tooLong = try AIContextGrant.make(
            scope: Self.scope, activeUntil: fx.clock.now() + 25 * 60 * 60, identity: fx.bob)
        await #expect(throws: AgentEngineError.windowDurationUnbounded) {
            try await fx.engine.receiveContextGrant(
                tooLong, fromSenderIdentityHex: fx.bob.publicKeyData.hexString)
        }
    }

    @Test func grantDoesNotWidenSend() async throws {
        let fx = try Self.fixture()
        // Both sides granted context sharing...
        _ = try await fx.engine.startMyContextGrant(scope: Self.scope, durationSeconds: 1800)
        let bobGrant = try AIContextGrant.make(
            scope: Self.scope, activeUntil: fx.clock.now() + 1800, identity: fx.bob)
        try await fx.engine.receiveContextGrant(
            bobGrant, fromSenderIdentityHex: fx.bob.publicKeyData.hexString)
        // ...but with NO invite, autonomous send still fails closed (consume ≠ send).
        await #expect(throws: AgentEngineError.autonomousSendNotAuthorized) {
            try await fx.engine.authorizeAutonomousSend(threadID: "t1")
        }
    }

    @Test func axesAreIndependentlyGranted() async throws {
        let fx = try Self.fixture()
        let bobHex = fx.bob.publicKeyData.hexString
        let humanScope = AIContextGrant.Scope.thread("t1", axis: AIContextGrant.Scope.humanAxis)
        let aiScope = AIContextGrant.Scope.thread("t1", axis: AIContextGrant.Scope.aiAxis)

        // Both sides grant the HUMAN axis only (step 1: their words).
        _ = try await fx.engine.startMyContextGrant(scope: humanScope, durationSeconds: 1800)
        let bobHuman = try AIContextGrant.make(
            scope: humanScope, activeUntil: fx.clock.now() + 1800, identity: fx.bob)
        try await fx.engine.receiveContextGrant(bobHuman, fromSenderIdentityHex: bobHex)
        // Human axis authorized; AI axis still default-deny (the 2-step split).
        #expect(await fx.engine.contextSharingAuthorized(scope: humanScope) == true)
        #expect(await fx.engine.contextSharingAuthorized(scope: aiScope) == false)

        // Both grant the AI axis too (step 2: their AI): now independently authorized.
        _ = try await fx.engine.startMyContextGrant(scope: aiScope, durationSeconds: 1800)
        let bobAI = try AIContextGrant.make(
            scope: aiScope, activeUntil: fx.clock.now() + 1800, identity: fx.bob)
        try await fx.engine.receiveContextGrant(bobAI, fromSenderIdentityHex: bobHex)
        #expect(await fx.engine.contextSharingAuthorized(scope: aiScope) == true)

        // Withdrawing the AI axis leaves the human axis intact (independence).
        await fx.engine.withdrawMyContextGrant(scope: aiScope)
        #expect(await fx.engine.contextSharingAuthorized(scope: aiScope) == false)
        #expect(await fx.engine.contextSharingAuthorized(scope: humanScope) == true)
    }

    @Test func axisLessGrantIsHumanAxis() async throws {
        let fx = try Self.fixture()
        let bobHex = fx.bob.publicKeyData.hexString
        // A grant carrying no axis (older client, default) is the HUMAN axis only.
        let legacyScope = AIContextGrant.Scope.thread("t1")  // axis defaults to "human"
        _ = try await fx.engine.startMyContextGrant(scope: legacyScope, durationSeconds: 1800)
        let bobLegacy = try AIContextGrant.make(
            scope: legacyScope, activeUntil: fx.clock.now() + 1800, identity: fx.bob)
        try await fx.engine.receiveContextGrant(bobLegacy, fromSenderIdentityHex: bobHex)
        #expect(
            await fx.engine.contextSharingAuthorized(
                scope: .thread("t1", axis: AIContextGrant.Scope.humanAxis)) == true)
        #expect(
            await fx.engine.contextSharingAuthorized(
                scope: .thread("t1", axis: AIContextGrant.Scope.aiAxis)) == false)
    }

    @Test func mockEchoesSharedContext() async throws {
        let provider = MockAgentProvider()
        let context = AgentContext(
            myIdentityHex: "self", myDisplayName: "Alice",
            transcript: [
                TranscriptEntry(
                    senderIdentityHex: "peer", senderDisplayName: "Bob",
                    participantType: .human, text: "ship date is Friday", isSharedContext: true)
            ])
        let draft = try await provider.draftReply(context: context)
        #expect(draft.text.contains("The quick brown fox jumped over the lazy dog"))
        #expect(draft.text.contains("ctx: ship date is Friday"))
    }
}
