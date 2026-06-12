import Crypto
import Foundation
import Testing

@testable import PQRCCore
@testable import PQRCNostr

/// SPEC §10 local-first transport (stretch goal S1): the seal path over
/// MultipeerConnectivity, exercised end-to-end against `LocalLinkSimulator`
/// (no unit test touches real radios — TEST-PLAN §1).
@Suite("Local-first transport (SPEC §10, S1)", .tags(.transport))
struct LocalLinkTests {
    /// One persona with both a relay connection and a started local link.
    struct LinkedPersona {
        let persona: Persona
        let link: MultipeerLinkTransport
        let peerID: NearbyPeerID
        let inbox: EventCollector
    }

    /// Builds Alice and Bob sharing one relay and one local-link hub, with
    /// contacts exchanged and both engines pumping. Co-present by default.
    static func makePair(
        hub: LocalLinkSimulator, relay: LocalRelaySimulator
    ) async throws -> (alice: LinkedPersona, bob: LinkedPersona) {
        let clock = FixedClock(now: 1_753_000_000)
        var pair: [LinkedPersona] = []
        for (name, seedByte, seed) in [("alice", "a1", 901), ("bob", "b2", 902)] {
            let persona = try await Persona.make(
                name: name, seedByte: seedByte, seed: UInt64(seed),
                transports: [await relay.connect()], clock: clock)
            let link = MultipeerLinkTransport(
                identity: persona.identity,
                link: await hub.makeLink(name: name),
                randomSource: SeededRandomSource(seed: UInt64(seed + 50)))
            await persona.messenger.setLocalLink(link)
            pair.append(
                LinkedPersona(
                    persona: persona, link: link, peerID: NearbyPeerID(name),
                    inbox: EventCollector()))
        }
        let (alice, bob) = (pair[0], pair[1])
        await alice.persona.messenger.addContact(try bob.persona.asContact())
        await bob.persona.messenger.addContact(try alice.persona.asContact())
        try await alice.link.start()
        try await bob.link.start()
        await alice.inbox.attach(try await alice.persona.messenger.start())
        await bob.inbox.attach(try await bob.persona.messenger.start())
        return (alice, bob)
    }

    /// Polls until `transport` has proven `identity` reachable (the hello
    /// exchange is async) or the timeout elapses.
    static func waitReachable(
        _ transport: MultipeerLinkTransport, _ identity: Data, present: Bool = true,
        timeoutMillis: Int = 5_000
    ) async -> Bool {
        var waited = 0
        while waited < timeoutMillis {
            if await transport.reachableIdentities().contains(identity) == present {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
        return false
    }

    static func establish(
        _ alice: LinkedPersona, _ bob: LinkedPersona, text: String = "hello over the air"
    ) async throws {
        try await alice.persona.messenger.establishSession(
            with: try bob.persona.asContact(),
            bundle: try await bob.persona.prekeyManager.publicBundle(),
            firstMessage: MessageBody(text: text, sentAt: 0))
    }

    // MARK: - Happy path

    @Test func coPresent_messagesFlowLocally_zeroRelayEnvelopes() async throws {
        let hub = LocalLinkSimulator()
        let relay = LocalRelaySimulator()
        let (alice, bob) = try await Self.makePair(hub: hub, relay: relay)
        #expect(await Self.waitReachable(alice.link, bob.persona.identity.publicKeyData))
        #expect(await Self.waitReachable(bob.link, alice.persona.identity.publicKeyData))

        // Handshake (carrying message #0) and replies all ride the local link.
        try await Self.establish(alice, bob)
        let bobGot = await bob.inbox.waitForMessages(1)
        #expect(bobGot.first?.body.text == "hello over the air")

        try await bob.persona.messenger.send(
            MessageBody(text: "right back at you", sentAt: 1),
            to: alice.persona.identityHex)
        let aliceGot = await alice.inbox.waitForMessages(1)
        #expect(aliceGot.first?.body.text == "right back at you")

        // The whole conversation produced NOTHING for a relay to observe.
        #expect(await relay.storedEvents(kind: PQRCConstants.giftWrapEventKind).isEmpty)
    }

    @Test func wireFormat_localFramesAreSeals_noWrap_fuzzedIntoPast() async throws {
        let hub = LocalLinkSimulator()
        let relay = LocalRelaySimulator()
        let (alice, bob) = try await Self.makePair(hub: hub, relay: relay)
        #expect(await Self.waitReachable(alice.link, bob.persona.identity.publicKeyData))
        try await Self.establish(alice, bob)
        _ = await bob.inbox.waitForMessages(1)

        let payloads = await hub.payloads(from: alice.peerID, to: bob.peerID)
        let seals = payloads.compactMap { data -> NostrEvent? in
            guard let payload = try? WireJSON.decoder().decode(LinkPayload.self, from: data),
                payload.kind == .seal, let sealData = payload.seal
            else { return nil }
            return try? WireJSON.decoder().decode(NostrEvent.self, from: sealData)
        }
        #expect(!seals.isEmpty)
        let now: Int64 = 1_753_000_000
        for seal in seals {
            // SPEC §10: the seal layer, exactly — never a bare rumor (kind
            // 1420), never a wasted gift wrap (kind 1059).
            #expect(seal.kind == PQRCConstants.sealEventKind)
            #expect(seal.tags.isEmpty, "seal tags MUST be empty (SPEC §8.1)")
            #expect(NostrKeypair.verify(seal))
            // Fuzz window: up to 2 days into the PAST, never future (SPEC §8.4).
            #expect(seal.createdAt <= now)
            #expect(seal.createdAt >= now - PQRCConstants.timestampFuzzWindowSeconds)
        }
    }

    @Test func agentMessage_overLocalLink_carriesAgentTypeAndSignature() async throws {
        let hub = LocalLinkSimulator()
        let relay = LocalRelaySimulator()
        let (alice, bob) = try await Self.makePair(hub: hub, relay: relay)
        #expect(await Self.waitReachable(alice.link, bob.persona.identity.publicKeyData))
        try await Self.establish(alice, bob)
        _ = await bob.inbox.waitForMessages(1)

        // SPEC §13.4 is transport-independent: the agent gate must hold on the
        // local path exactly as on the relay path.
        try await alice.persona.messenger.send(
            MessageBody(text: "drafted by AI", sentAt: 2),
            to: bob.persona.identityHex, participantType: .agent)
        let messages = await bob.inbox.waitForMessages(2)
        let agentMessage = try #require(messages.last)
        #expect(agentMessage.participantType == .agent)
        #expect(await bob.inbox.violations().isEmpty)
        #expect(await relay.storedEvents(kind: PQRCConstants.giftWrapEventKind).isEmpty)
    }

    // MARK: - Relay fallback (SPEC §10: automatic when not co-present)

    @Test func notCoPresent_fallsBackToRelay() async throws {
        let hub = LocalLinkSimulator()
        let relay = LocalRelaySimulator()
        let (alice, bob) = try await Self.makePair(hub: hub, relay: relay)
        await hub.setCoPresent(alice.peerID, bob.peerID, false)
        #expect(
            await Self.waitReachable(
                alice.link, bob.persona.identity.publicKeyData, present: false))

        try await Self.establish(alice, bob, text: "via relay then")
        let bobGot = await bob.inbox.waitForMessages(1)
        #expect(bobGot.first?.body.text == "via relay then")
        // Exactly one gift wrap proves the relay carried it.
        #expect(await relay.storedEvents(kind: PQRCConstants.giftWrapEventKind).count == 1)
    }

    @Test func midConversationPartition_fallsBack_thenReturnsLocal() async throws {
        let hub = LocalLinkSimulator()
        let relay = LocalRelaySimulator()
        let (alice, bob) = try await Self.makePair(hub: hub, relay: relay)
        #expect(await Self.waitReachable(alice.link, bob.persona.identity.publicKeyData))
        try await Self.establish(alice, bob)
        _ = await bob.inbox.waitForMessages(1)
        #expect(await relay.storedEvents(kind: PQRCConstants.giftWrapEventKind).isEmpty)

        // Walk out of range: the next message must arrive anyway, via relay.
        await hub.setCoPresent(alice.peerID, bob.peerID, false)
        #expect(
            await Self.waitReachable(
                alice.link, bob.persona.identity.publicKeyData, present: false))
        try await alice.persona.messenger.send(
            MessageBody(text: "out of range", sentAt: 3), to: bob.persona.identityHex)
        let afterPartition = await bob.inbox.waitForMessages(2)
        #expect(afterPartition.last?.body.text == "out of range")
        #expect(await relay.storedEvents(kind: PQRCConstants.giftWrapEventKind).count == 1)

        // Walk back into range: traffic returns to the local link, the relay
        // envelope count stops growing.
        await hub.setCoPresent(alice.peerID, bob.peerID, true)
        #expect(await Self.waitReachable(alice.link, bob.persona.identity.publicKeyData))
        try await alice.persona.messenger.send(
            MessageBody(text: "back in range", sentAt: 4), to: bob.persona.identityHex)
        let afterRejoin = await bob.inbox.waitForMessages(3)
        #expect(afterRejoin.last?.body.text == "back in range")
        #expect(await relay.storedEvents(kind: PQRCConstants.giftWrapEventKind).count == 1)
    }

    // MARK: - Adversarial

    @Test func replayedSeal_isProcessedExactlyOnce() async throws {
        let hub = LocalLinkSimulator()
        let relay = LocalRelaySimulator()
        let (alice, bob) = try await Self.makePair(hub: hub, relay: relay)
        #expect(await Self.waitReachable(alice.link, bob.persona.identity.publicKeyData))
        try await Self.establish(alice, bob)
        _ = await bob.inbox.waitForMessages(1)

        // An attacker (or a flaky radio) re-delivers every frame verbatim.
        for payload in await hub.payloads(from: alice.peerID, to: bob.peerID) {
            await hub.inject(payload, from: alice.peerID, to: bob.peerID)
        }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await bob.inbox.messages().count == 1, "replays must dedupe")
    }

    @Test func tamperedSeal_isDropped_conversationSurvives() async throws {
        let hub = LocalLinkSimulator()
        let relay = LocalRelaySimulator()
        let (alice, bob) = try await Self.makePair(hub: hub, relay: relay)
        #expect(await Self.waitReachable(alice.link, bob.persona.identity.publicKeyData))
        try await Self.establish(alice, bob)
        _ = await bob.inbox.waitForMessages(1)

        // Flip ciphertext bits inside a captured seal and re-deliver it.
        let payloads = await hub.payloads(from: alice.peerID, to: bob.peerID)
        let sealPayload = try #require(
            payloads.first {
                (try? WireJSON.decoder().decode(LinkPayload.self, from: $0))?.kind == .seal
            })
        var payload = try WireJSON.decoder().decode(LinkPayload.self, from: sealPayload)
        var seal = try WireJSON.decoder().decode(NostrEvent.self, from: try #require(payload.seal))
        seal.content = String(seal.content.reversed())
        payload.seal = try WireJSON.encoder().encode(seal)
        await hub.inject(
            try WireJSON.encoder().encode(payload), from: alice.peerID, to: bob.peerID)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await bob.inbox.messages().count == 1, "tampered seal must be dropped")

        // The session is untouched: the next real message still decrypts.
        try await alice.persona.messenger.send(
            MessageBody(text: "still fine", sentAt: 5), to: bob.persona.identityHex)
        let after = await bob.inbox.waitForMessages(2)
        #expect(after.last?.body.text == "still fine")
    }

    @Test func forgedHelloProof_cannotClaimAnotherIdentity() async throws {
        let hub = LocalLinkSimulator()
        let relay = LocalRelaySimulator()
        let (alice, bob) = try await Self.makePair(hub: hub, relay: relay)
        // Real Bob leaves the air; only his identity should now be unreachable.
        await bob.link.stop()
        #expect(
            await Self.waitReachable(
                alice.link, bob.persona.identity.publicKeyData, present: false))

        // Mallory drives a raw link by hand: she answers Alice's hello by
        // claiming BOB's identity but can only sign with her own key.
        let malloryIdentity = try PQRCIdentity(seed: hexData(String(repeating: "33", count: 32)))
        let malloryLink = await hub.makeLink(name: "mallory")
        let malloryEvents = await malloryLink.events()
        let pump = Task {
            for await event in malloryEvents {
                guard case .data(let data, let from) = event,
                    let payload = try? WireJSON.decoder().decode(LinkPayload.self, from: data),
                    payload.kind == .hello, let challenge = payload.challenge
                else { continue }
                let message = LinkPayload.helloProofMessage(
                    identity: bob.persona.identity.publicKeyData,  // the lie
                    challenge: challenge)
                let forged = LinkPayload(
                    kind: .helloProof,
                    identity: bob.persona.identity.publicKeyData,
                    sig: try? malloryIdentity.sign(message))
                if let encoded = try? WireJSON.encoder().encode(forged) {
                    try? await malloryLink.send(encoded, to: from)
                }
            }
        }
        defer { pump.cancel() }
        try await malloryLink.start()

        // The forged proof must never make Bob's identity reachable: the send
        // below routes via relay, and Mallory's link never sees a seal.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(
            !(await alice.link.reachableIdentities())
                .contains(bob.persona.identity.publicKeyData))
        try await Self.establish(alice, bob, text: "for bob only")
        #expect(await relay.storedEvents(kind: PQRCConstants.giftWrapEventKind).count == 1)
        let malloryGot = await hub.payloads(from: alice.peerID, to: NearbyPeerID("mallory"))
        let sealsToMallory = malloryGot.filter {
            (try? WireJSON.decoder().decode(LinkPayload.self, from: $0))?.kind == .seal
        }
        #expect(sealsToMallory.isEmpty, "no message traffic may reach an unproven peer")
        #expect(await alice.link.droppedPayloadCount > 0)
    }

    @Test func unknownLocalSender_landsInMessageRequests() async throws {
        let hub = LocalLinkSimulator()
        let relay = LocalRelaySimulator()
        let (alice, bob) = try await Self.makePair(hub: hub, relay: relay)
        _ = alice  // Alice is idle; this test is Carol → Bob.

        // Carol knows Bob (fetched + verified his binding) but Bob has never
        // heard of Carol. D12: her first contact surfaces as a message request
        // on the local path exactly as it would via relay.
        let clock = FixedClock(now: 1_753_000_000)
        let carol = try await Persona.make(
            name: "carol", seedByte: "c3", seed: 903,
            transports: [await relay.connect()], clock: clock)
        let carolLink = MultipeerLinkTransport(
            identity: carol.identity,
            link: await hub.makeLink(name: "carol"),
            randomSource: SeededRandomSource(seed: 953))
        await carol.messenger.setLocalLink(carolLink)
        await carol.messenger.addContact(try bob.persona.asContact())
        try await carolLink.start()
        _ = try await carol.messenger.start()
        #expect(await Self.waitReachable(carolLink, bob.persona.identity.publicKeyData))

        try await carol.messenger.establishSession(
            with: try bob.persona.asContact(),
            bundle: try await bob.persona.prekeyManager.publicBundle(),
            firstMessage: MessageBody(text: "you don't know me", sentAt: 0))

        var waited = 0
        while await bob.inbox.all().isEmpty && waited < 3_000 {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
        let events = await bob.inbox.all()
        let isRequest = events.contains {
            if case .messageRequest = $0 { return true }
            return false
        }
        #expect(isRequest, "unknown local sender must gate through message requests")
        #expect(await bob.inbox.messages().isEmpty)
    }
}
