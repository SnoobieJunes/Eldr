import Crypto
import Foundation
import Testing

@testable import PQRCCore
@testable import PQRCNostr

@Suite("Transport simulation (TEST-PLAN §7)", .tags(.transport))
struct TransportTests {
    static func signedEvent(
        _ keypair: NostrKeypair, kind: Int = 1, content: String = "hello",
        createdAt: Int64 = 1_750_000_000, tags: [[String]] = []
    ) throws -> NostrEvent {
        try keypair.sign(
            NostrEvent(
                pubkey: keypair.publicKeyHex, createdAt: createdAt, kind: kind, tags: tags,
                content: content),
            randomSource: SystemRandomSource())
    }

    @Test func simulator_storeAndForward_offlineRecipientReceivesOnConnect() async throws {
        let relay = LocalRelaySimulator()
        let publisher = await relay.connect()
        let keypair = try NostrKeypair(privateKey: hexData(String(repeating: "44", count: 32)))
        let ack = try await publisher.publish(try Self.signedEvent(keypair))
        #expect(ack.accepted)

        // Recipient connects AFTER the publish; the stored event arrives first.
        let lateSubscriber = await relay.connect()
        let stream = await lateSubscriber.subscribe([NostrFilter(kinds: [1])])
        var received: [NostrEvent] = []
        for try await event in stream {
            received.append(event)
            break
        }
        #expect(received.count == 1)
        #expect(received[0].content == "hello")
    }

    @Test func auth_kind1059ServedOnlyToPTaggedAuthedRecipient() async throws {
        let relay = LocalRelaySimulator()
        let recipient = try NostrKeypair(privateKey: hexData(String(repeating: "55", count: 32)))
        let intruder = try NostrKeypair(privateKey: hexData(String(repeating: "66", count: 32)))
        let oneTime = try NostrKeypair(privateKey: hexData(String(repeating: "67", count: 32)))

        let wrap = try Self.signedEvent(
            oneTime, kind: 1059, content: "opaque", tags: [["p", recipient.publicKeyHex]])
        _ = try await (await relay.connect()).publish(wrap)

        let filter = NostrFilter(kinds: [1059], pTags: [recipient.publicKeyHex])

        func drain(_ connection: LocalRelayConnection) async throws -> Int {
            let collector = NostrEventCollector()
            await collector.attach(await connection.subscribe([filter]))
            return await collector.settle().count
        }

        // Unauthenticated: nothing.
        #expect(try await drain(await relay.connect()) == 0)

        // Authenticated as the wrong key: nothing.
        let wrongConnection = await relay.connect()
        try await wrongConnection.authenticate(
            keypair: intruder, randomSource: SystemRandomSource())
        #expect(try await drain(wrongConnection) == 0)

        // Authenticated as the p-tagged recipient: served.
        let rightConnection = await relay.connect()
        try await rightConnection.authenticate(
            keypair: recipient, randomSource: SystemRandomSource())
        #expect(try await drain(rightConnection) == 1)
    }

    @Test func replaceableEvents_latest10420_10421_10050Win() async throws {
        let relay = LocalRelaySimulator()
        let connection = await relay.connect()
        let keypair = try NostrKeypair(privateKey: hexData(String(repeating: "88", count: 32)))
        for kind in [10420, 10421, 10050] {
            _ = try await connection.publish(
                try Self.signedEvent(keypair, kind: kind, content: "old", createdAt: 100))
            _ = try await connection.publish(
                try Self.signedEvent(keypair, kind: kind, content: "new", createdAt: 200))
            // Out-of-date replaceable arriving late does not regress state.
            _ = try await connection.publish(
                try Self.signedEvent(keypair, kind: kind, content: "stale", createdAt: 50))
            let stored = await relay.storedEvents(kind: kind)
            #expect(stored.count == 1, "kind \(kind): exactly one replaceable per pubkey")
            #expect(stored.first?.content == "new", "kind \(kind): latest wins")
        }
    }

    @Test func dedupe_duplicateEnvelopeStoredOnce() async throws {
        let relay = LocalRelaySimulator()
        let connection = await relay.connect()
        let keypair = try NostrKeypair(privateKey: hexData(String(repeating: "99", count: 32)))
        let event = try Self.signedEvent(keypair)
        let first = try await connection.publish(event)
        let second = try await connection.publish(event)
        #expect(first.accepted && second.accepted)
        #expect(second.message?.contains("duplicate") == true)
        #expect(await relay.storedEventCount == 1)
    }

    @Test func multiRelay_oneHealthySuffices() async throws {
        // Publish to two relays; kill one; the messenger still delivers.
        let healthy = LocalRelaySimulator(url: "local://healthy")
        let dead = LocalRelaySimulator(
            url: "local://dead", chaos: ChaosOptions(dropRate: 1.0, seed: 3))
        let clock = FixedClock()
        let alice = try await Persona.make(
            name: "alice", seedByte: "a1", seed: 11,
            transports: [await dead.connect(), await healthy.connect()], clock: clock)
        let bob = try await Persona.make(
            name: "bob", seedByte: "b1", seed: 12,
            transports: [await dead.connect(), await healthy.connect()], clock: clock)
        await alice.messenger.addContact(try bob.asContact())
        await bob.messenger.addContact(try alice.asContact())
        let collector = EventCollector()
        await collector.attach(try await bob.messenger.start())

        try await alice.messenger.establishSession(
            with: try bob.asContact(), bundle: try await bob.prekeyManager.publicBundle(),
            firstMessage: MessageBody(text: "via the healthy relay", sentAt: 0))
        let messages = await collector.waitForMessages(1)
        #expect(messages.first?.body.text == "via the healthy relay")
        await collector.stop()
    }

    // The Blossom/blob-pointer transport tests (round-trip, mirror failover,
    // constant-size pointer envelopes) were removed: the blob path is vestigial and
    // permanently rejected (CLAUDE.md rule 4 — text-only product, no blob server;
    // >64 KB text goes via relay chunking, covered by ChunkingTests and the relay
    // chunk suites). `ptr` stays NIP wire law, so its codec fidelity remains pinned
    // by PQRCCore's PaddingEnvelopeTests + SessionTests.
}
