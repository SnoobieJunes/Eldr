import Crypto
import Foundation
import Testing

@testable import PQRCAgent
@testable import PQRCCore
@testable import PQRCNostr

// Path-2 §8 — the owner-keyed authorization the PQRC watch-along bridge consults
// before every fan-out. The Mac (the engine's own identity) acts only while a PINNED
// OWNER holds a live, signed window/invite. Fail-closed by default; only the owner —
// not the Mac, not a third party — can open the gate.
@Suite("Agent owner gate (Path 2 §8)", .tags(.agent))
struct AgentOwnerGateTests {
    private static func fixture() throws -> (
        engine: AgentEngine, clock: FixedClock, mac: PQRCIdentity, owner: PQRCIdentity,
        stranger: PQRCIdentity
    ) {
        let clock = FixedClock(now: 1_756_000_000)
        let mac = try PQRCIdentity(seed: hexData(String(repeating: "1a", count: 32)))
        let owner = try PQRCIdentity(seed: hexData(String(repeating: "2b", count: 32)))
        let stranger = try PQRCIdentity(seed: hexData(String(repeating: "3c", count: 32)))
        let engine = AgentEngine(myIdentity: mac, clock: clock, sink: SpySink())
        return (engine, clock, mac, owner, stranger)
    }

    @Test func failsClosedWithNoOwnerWindow() async throws {
        let fx = try Self.fixture()
        #expect(await fx.engine.isAuthorizedForOwner(fx.owner.publicKeyData.hexString) == false)
        #expect(
            await fx.engine.isAuthorizedForOwner(
                fx.owner.publicKeyData.hexString, threadID: "t1") == false)
    }

    @Test func ownerWindowOpensConversationGate() async throws {
        let fx = try Self.fixture()
        let ownerHex = fx.owner.publicKeyData.hexString
        let until = fx.clock.now() + 1800
        let window = try AIWindowAnnouncement.make(activeUntil: until, identity: fx.owner)
        try await fx.engine.receiveWindow(window, fromSenderIdentityHex: ownerHex)

        #expect(await fx.engine.isAuthorizedForOwner(ownerHex) == true)
        // A different identity's authorization is NOT the owner's — gate stays closed.
        #expect(
            await fx.engine.isAuthorizedForOwner(fx.stranger.publicKeyData.hexString) == false)
    }

    @Test func ownerWindowExpiryClosesGate() async throws {
        let fx = try Self.fixture()
        let ownerHex = fx.owner.publicKeyData.hexString
        let window = try AIWindowAnnouncement.make(
            activeUntil: fx.clock.now() + 900, identity: fx.owner)
        try await fx.engine.receiveWindow(window, fromSenderIdentityHex: ownerHex)
        #expect(await fx.engine.isAuthorizedForOwner(ownerHex) == true)

        // Advance past expiry: a stale/dropped window must fail closed (the link-drop
        // behavior — the agent stops sending).
        fx.clock.set(window.activeUntil)
        #expect(await fx.engine.isAuthorizedForOwner(ownerHex) == false)
    }

    @Test func ownerInviteOpensThreadScopeOnly() async throws {
        let fx = try Self.fixture()
        let ownerHex = fx.owner.publicKeyData.hexString
        let until = fx.clock.now() + 1800
        let invite = try AIInvite.make(threadID: "t1", activeUntil: until, identity: fx.owner)
        try await fx.engine.receiveInvite(invite, fromSenderIdentityHex: ownerHex)

        #expect(await fx.engine.isAuthorizedForOwner(ownerHex, threadID: "t1") == true)
        // Wrong thread, and conversation scope, both stay closed (an invite is thread-scoped).
        #expect(await fx.engine.isAuthorizedForOwner(ownerHex, threadID: "t2") == false)
        #expect(await fx.engine.isAuthorizedForOwner(ownerHex) == false)
    }

    @Test func strangerWindowDoesNotAuthorizeOwnerGate() async throws {
        // Even if some OTHER human's window is live in the engine, the owner gate keyed
        // to the owner's identity must remain closed — only the pinned owner counts.
        let fx = try Self.fixture()
        let strangerHex = fx.stranger.publicKeyData.hexString
        let window = try AIWindowAnnouncement.make(
            activeUntil: fx.clock.now() + 1800, identity: fx.stranger)
        try await fx.engine.receiveWindow(window, fromSenderIdentityHex: strangerHex)

        #expect(await fx.engine.isAuthorizedForOwner(fx.owner.publicKeyData.hexString) == false)
        // (sanity: the stranger's own window did register)
        #expect(await fx.engine.activeWindow(for: strangerHex) != nil)
    }
}
