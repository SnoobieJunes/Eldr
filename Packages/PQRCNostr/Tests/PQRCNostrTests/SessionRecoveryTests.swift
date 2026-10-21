// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import Testing

@testable import PQRCCore
@testable import PQRCNostr

/// AC165/AC166 at the shared-messenger layer (the path the iOS app uses): a contact
/// that lost its state re-handshakes. OTP-backed → replaced automatically;
/// last-resort-only → held until the user approves.
@Suite("Stale-session recovery", .serialized)
struct SessionRecoveryTests {
    struct Pair {
        let relay: LocalRelaySimulator
        let alice: Persona
        let bob: Persona
        let bobEvents: EventCollector
    }

    /// Alice ↔ Bob with a two-way session; Bob listening.
    static func established() async throws -> Pair {
        let relay = LocalRelaySimulator()
        let alice = try await Persona.make(name: "A", seedByte: "a7", seed: 71, transports: [await relay.connect()])
        let bob = try await Persona.make(name: "B", seedByte: "b7", seed: 72, transports: [await relay.connect()])
        await alice.messenger.addContact(try bob.asContact())
        await bob.messenger.addContact(try alice.asContact())
        let bobEvents = EventCollector()
        await bobEvents.attach(try await bob.messenger.start())
        let aliceEvents = EventCollector()
        await aliceEvents.attach(try await alice.messenger.start())
        try await alice.messenger.establishSession(
            with: try bob.asContact(), bundle: try await bob.prekeyManager.publicBundle(),
            firstMessage: MessageBody(text: "m0", sentAt: 1))
        _ = await bobEvents.waitForMessages(1)
        try await bob.messenger.send(MessageBody(text: "r0", sentAt: 2), to: alice.identityHex)
        _ = await aliceEvents.waitForMessages(1)
        await alice.messenger.stop()
        return Pair(relay: relay, alice: alice, bob: bob, bobEvents: bobEvents)
    }

    /// Alice "reinstalls": same identity + Nostr key, fresh prekeys, no sessions.
    static func reinstalled(_ p: Pair) async throws -> (PQRCMessenger, EventCollector) {
        let a = p.alice
        let pm = try PrekeyManager(identity: a.identity, randomSource: SeededRandomSource(seed: 99), oneTimeCount: 4)
        let m = try PQRCMessenger(
            identity: a.identity, nostrKeypair: a.nostrKeypair, prekeyManager: pm, identityDH: a.identityDH,
            transports: [await p.relay.connect()], clock: a.clock, randomSource: SeededRandomSource(seed: 98),
            nonceSource: SeededRandomSource(seed: 97), outboundRetryBaseMillis: 2)
        await m.addContact(try p.bob.asContact())
        let ev = EventCollector()
        await ev.attach(try await m.start())
        return (m, ev)
    }

    static func stripOTPs(_ b: PrekeyBundle) -> PrekeyBundle {
        PrekeyBundle(identityPubkey: b.identityPubkey, ikDH: b.ikDH, spk: b.spk, pqpk: b.pqpk,
                     otp: [], otpPQ: [], lrp: b.lrp)
    }

    @Test func otpBackedReHandshake_replacesStaleSession_bothDirections() async throws {
        let p = try await Self.established()
        let (a2, a2Events) = try await Self.reinstalled(p)
        try await a2.establishSession(
            with: try p.bob.asContact(), bundle: try await p.bob.prekeyManager.publicBundle(),
            firstMessage: MessageBody(text: "back", sentAt: 3))
        try await a2.send(MessageBody(text: "back 2", sentAt: 4), to: p.bob.identityHex)
        let got = await p.bobEvents.waitForMessages(3)
        #expect(got.map(\.body.text) == ["m0", "back", "back 2"])
        try await p.bob.messenger.send(MessageBody(text: "welcome", sentAt: 5), to: p.alice.identityHex)
        #expect(await a2Events.waitForMessages(1).map(\.body.text) == ["welcome"])
        #expect(await p.bob.messenger.pendingRetryCount() == 0)
    }

    @Test func lastResortReHandshake_isHeldUntilApproved_thenRecovers() async throws {
        let p = try await Self.established()
        let (a2, a2Events) = try await Self.reinstalled(p)
        let bundle = Self.stripOTPs(try await p.bob.prekeyManager.publicBundle())
        try await a2.establishSession(with: try p.bob.asContact(), bundle: bundle,
            firstMessage: MessageBody(text: "back via lrp", sentAt: 3))
        // Held, surfaced, old session intact.
        let end = Date().addingTimeInterval(5)
        while await p.bob.messenger.pendingReconnectPeers().isEmpty && Date() < end {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await p.bob.messenger.pendingReconnectPeers() == [p.alice.identityHex])
        #expect(await p.bobEvents.all().contains { if case .reconnectRequest(let s) = $0 { return s == p.alice.identityHex } else { return false } })
        #expect(await p.bobEvents.messages().map(\.body.text) == ["m0"])

        #expect(await p.bob.messenger.acceptReconnect(peerIdentityHex: p.alice.identityHex))
        #expect(await p.bobEvents.waitForMessages(2).map(\.body.text) == ["m0", "back via lrp"])
        try await p.bob.messenger.send(MessageBody(text: "welcome", sentAt: 5), to: p.alice.identityHex)
        #expect(await a2Events.waitForMessages(1).map(\.body.text) == ["welcome"])
        // A second approve has nothing to apply.
        #expect(await !p.bob.messenger.acceptReconnect(peerIdentityHex: p.alice.identityHex))
    }

    @Test func declinedReconnect_keepsOldSession() async throws {
        let p = try await Self.established()
        let (a2, _) = try await Self.reinstalled(p)
        try await a2.establishSession(with: try p.bob.asContact(),
            bundle: Self.stripOTPs(try await p.bob.prekeyManager.publicBundle()),
            firstMessage: MessageBody(text: "x", sentAt: 3))
        let end = Date().addingTimeInterval(5)
        while await p.bob.messenger.pendingReconnectPeers().isEmpty && Date() < end {
            try await Task.sleep(for: .milliseconds(20))
        }
        let before = await p.bob.messenger.sessionSnapshot(peerIdentityHex: p.alice.identityHex)?.rootKey
        await p.bob.messenger.declineReconnect(peerIdentityHex: p.alice.identityHex)
        #expect(await p.bob.messenger.pendingReconnectPeers().isEmpty)
        #expect(await !p.bob.messenger.acceptReconnect(peerIdentityHex: p.alice.identityHex))
        #expect(await p.bob.messenger.sessionSnapshot(peerIdentityHex: p.alice.identityHex)?.rootKey == before)
    }
}
