import Crypto
import Foundation
import Testing

@testable import PQRCCore
@testable import PQRCNostr

/// Cross-launch persistence + message-request acceptance + the protocol-layer
/// gates added with them (review M-1/L-4/L3).
@Suite("Persistence, requests & boundary gates", .tags(.transport))
struct PersistenceAndRequestTests {
    /// Ratchet sessions restored from snapshots keep the conversation going —
    /// the "messages survive relaunch" property at the protocol layer.
    @Test func sessionRestore_acrossMessengerRestart_conversationContinues() async throws {
        let relay = LocalRelaySimulator()
        let alice = try await Persona.make(
            name: "Alice", seedByte: "a1", seed: 1, transports: [await relay.connect()])
        let bob = try await Persona.make(
            name: "Bob", seedByte: "b1", seed: 2, transports: [await relay.connect()])
        await alice.messenger.addContact(try bob.asContact())
        await bob.messenger.addContact(try alice.asContact())

        let bobEvents = EventCollector()
        await bobEvents.attach(try await bob.messenger.start())
        try await alice.messenger.establishSession(
            with: try bob.asContact(), bundle: try await bob.prekeyManager.publicBundle(),
            firstMessage: MessageBody(text: "before restart", sentAt: 1))
        _ = await bobEvents.waitForMessages(1)

        // Bob replies so both directions have ratchet state worth restoring.
        try await bob.messenger.send(
            MessageBody(text: "ack", sentAt: 2), to: alice.identityHex)
        let aliceEvents = EventCollector()
        await aliceEvents.attach(try await alice.messenger.start())
        _ = await aliceEvents.waitForMessages(1)

        // "Relaunch" Bob: a brand-new messenger, contact re-added, session
        // restored from the snapshot — exactly what PersonaRuntime does.
        let snapshot = try #require(
            await bob.messenger.sessionSnapshot(peerIdentityHex: alice.identityHex))
        await bob.messenger.stop()
        let bob2 = try PQRCMessenger(
            identity: bob.identity, nostrKeypair: bob.nostrKeypair,
            prekeyManager: bob.prekeyManager, identityDH: bob.identityDH,
            transports: [await relay.connect()], clock: bob.clock,
            randomSource: SeededRandomSource(seed: 99),
            nonceSource: SeededRandomSource(seed: 100), outboundRetryBaseMillis: 2)
        await bob2.addContact(try alice.asContact())
        try await bob2.restoreSession(with: try alice.asContact(), snapshot: snapshot)
        let bob2Events = EventCollector()
        await bob2Events.attach(try await bob2.start())

        try await alice.messenger.send(
            MessageBody(text: "after restart", sentAt: 3), to: bob.identityHex)
        let received = await bob2Events.waitForMessages(1)
        #expect(received.contains { $0.body.text == "after restart" })
    }

    /// Relay replays of already-processed envelopes are dropped by the seeded
    /// dedupe set — the named `replay_oldEnvelopeRejected` (review L3).
    @Test func replay_oldEnvelopeRejected_viaSeededProcessedIDs() async throws {
        let relay = LocalRelaySimulator()
        let alice = try await Persona.make(
            name: "Alice", seedByte: "a2", seed: 11, transports: [await relay.connect()])
        let bob = try await Persona.make(
            name: "Bob", seedByte: "b2", seed: 12, transports: [await relay.connect()])
        await alice.messenger.addContact(try bob.asContact())
        await bob.messenger.addContact(try alice.asContact())

        let bobEvents = EventCollector()
        await bobEvents.attach(try await bob.messenger.start())
        try await alice.messenger.establishSession(
            with: try bob.asContact(), bundle: try await bob.prekeyManager.publicBundle(),
            firstMessage: MessageBody(text: "only once", sentAt: 1))
        let first = await bobEvents.waitForMessages(1)
        #expect(first.count == 1)

        // Bob "relaunches" with the processed set persisted: the relay will
        // replay the stored envelope to his fresh subscription, and nothing
        // may surface — not a message, not a retry, not a quarantine.
        let processedID = first[0].wrapEventID
        await bob.messenger.stop()
        let bob2 = try PQRCMessenger(
            identity: bob.identity, nostrKeypair: bob.nostrKeypair,
            prekeyManager: bob.prekeyManager, identityDH: bob.identityDH,
            transports: [await relay.connect()], clock: bob.clock,
            randomSource: SeededRandomSource(seed: 13),
            nonceSource: SeededRandomSource(seed: 14), outboundRetryBaseMillis: 2)
        await bob2.addContact(try alice.asContact())
        await bob2.seedProcessedWrapIDs([processedID])
        let bob2Events = EventCollector()
        await bob2Events.attach(try await bob2.start())
        try? await Task.sleep(for: .milliseconds(120))
        #expect(await bob2Events.messages().isEmpty)
        #expect(await bob2.pendingRetryCount() == 0)
    }

    /// D12 acceptance: an unknown sender's envelope is held, the request is
    /// surfaced, and accepting fetches + verifies the sender then replays the
    /// held handshake so the first message materializes.
    @Test func messageRequest_acceptReplaysHeldEnvelope() async throws {
        let relay = LocalRelaySimulator()
        let alice = try await Persona.make(
            name: "Alice", seedByte: "a3", seed: 21, transports: [await relay.connect()])
        let bob = try await Persona.make(
            name: "Bob", seedByte: "b3", seed: 22, transports: [await relay.connect()])
        // Alice publishes 10420/10421 so Bob's accept can verify her.
        try await alice.messenger.announce(relayURLs: ["local://relay"])
        // Alice knows Bob; Bob does NOT know Alice.
        await alice.messenger.addContact(try bob.asContact())

        let bobEvents = EventCollector()
        await bobEvents.attach(try await bob.messenger.start())
        try await alice.messenger.establishSession(
            with: try bob.asContact(), bundle: try await bob.prekeyManager.publicBundle(),
            firstMessage: MessageBody(text: "hi, stranger!", sentAt: 1))

        var waited = 0
        while await bobEvents.all().isEmpty && waited < 5_000 {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
        let requests = await bobEvents.all().compactMap { event -> String? in
            if case .messageRequest(let sender, _) = event { return sender }
            return nil
        }
        #expect(requests == [alice.nostrKeypair.publicKeyHex])
        #expect(await bobEvents.messages().isEmpty, "nothing renders before accept (D12)")

        let contact = try await bob.messenger.acceptRequest(
            senderNostrPubkeyHex: alice.nostrKeypair.publicKeyHex)
        #expect(contact.identityHex == alice.identityHex)
        #expect(contact.raw != nil, "raw binding travels for persistence")
        let received = await bobEvents.waitForMessages(1)
        #expect(received.contains { $0.body.text == "hi, stranger!" })
    }

    /// Review M-1: an ai_window not signed by the sender's binding-verified
    /// human identity key never crosses the protocol boundary — it is dropped
    /// from the message and flagged as a protocol violation.
    @Test func aiWindow_forgedSigner_droppedAndFlaggedAtMessengerBoundary() async throws {
        let relay = LocalRelaySimulator()
        let alice = try await Persona.make(
            name: "Alice", seedByte: "a4", seed: 31, transports: [await relay.connect()])
        let bob = try await Persona.make(
            name: "Bob", seedByte: "b4", seed: 32, transports: [await relay.connect()])
        await alice.messenger.addContact(try bob.asContact())
        await bob.messenger.addContact(try alice.asContact())
        let bobEvents = EventCollector()
        await bobEvents.attach(try await bob.messenger.start())
        try await alice.messenger.establishSession(
            with: try bob.asContact(), bundle: try await bob.prekeyManager.publicBundle(),
            firstMessage: MessageBody(text: "setup", sentAt: 1))
        _ = await bobEvents.waitForMessages(1)

        // Self-consistent signature, wrong signer: an "agent" key announces a
        // window for itself. hasValidSignature() passes (self-referential by
        // design) — the enabledBy ≠ sender-identity check must catch it.
        let mallory = try PQRCIdentity(seed: hexData(String(repeating: "ee", count: 32)))
        let forged = try AIWindowAnnouncement.make(
            activeUntil: 10_000, identity: mallory)
        try await alice.messenger.send(
            MessageBody(text: "with forged window", sentAt: 2),
            to: bob.identityHex, aiWindow: forged)

        let received = await bobEvents.waitForMessages(2)
        let withWindow = try #require(received.first { $0.body.text == "with forged window" })
        #expect(withWindow.aiWindow == nil, "forged window must not surface")
        #expect(
            await bobEvents.violations().contains { $0.contains("ai_window") },
            "forgery is flagged, not silently eaten")

        // Control: a genuine window from Alice's own identity key surfaces.
        let genuine = try AIWindowAnnouncement.make(
            activeUntil: 10_000, identity: alice.identity)
        try await alice.messenger.send(
            MessageBody(text: "with real window", sentAt: 3),
            to: bob.identityHex, aiWindow: genuine)
        let all = await bobEvents.waitForMessages(3)
        let real = try #require(all.first { $0.body.text == "with real window" })
        #expect(real.aiWindow == genuine)
    }

    /// Review L-4: future-version rumors are quarantined legibly instead of
    /// cycling the retry queue until overflow.
    @Test func futureVersionRumor_quarantinedImmediately() async throws {
        let relay = LocalRelaySimulator()
        let alice = try await Persona.make(
            name: "Alice", seedByte: "a5", seed: 41, transports: [await relay.connect()])
        let bob = try await Persona.make(
            name: "Bob", seedByte: "b5", seed: 42, transports: [await relay.connect()])
        await bob.messenger.addContact(try alice.asContact())
        let bobEvents = EventCollector()
        await bobEvents.attach(try await bob.messenger.start())

        var rumor = RumorContent(
            type: .message, participantType: .human, senderRole: .identity,
            header: nil, ciphertext: Data("opaque-to-v1".utf8))
        rumor.version = "2"
        let wrap = try GiftWrap.wrap(
            rumor: rumor, sender: alice.nostrKeypair,
            recipientNostrPubkey: bob.nostrKeypair.publicKeyHex,
            fuzzedTimestamp: 1, randomSource: SeededRandomSource(seed: 43),
            nonceSource: SeededRandomSource(seed: 44))
        _ = try await relay.connect().publish(wrap)

        var waited = 0
        while await bobEvents.all().isEmpty && waited < 5_000 {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
        let quarantines = await bobEvents.all().compactMap { event -> String? in
            if case .quarantined(_, let reason) = event { return reason }
            return nil
        }
        #expect(quarantines.contains { $0.contains("unsupported pqrc_version") })
        #expect(await bob.messenger.pendingRetryCount() == 0, "no retry churn")
    }
}
