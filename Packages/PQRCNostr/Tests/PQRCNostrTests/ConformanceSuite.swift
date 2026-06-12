import Crypto
import Foundation
import Testing

@testable import PQRCCore
@testable import PQRCNostr

/// The transport conformance suite (TEST-PLAN §7 `swapPoint_transportConformanceSuite`).
///
/// Runs the behavioral contract of `RelayTransport` against ANY factory.
/// Today the factory yields `LocalRelayConnection`s over one simulator; when
/// the real Nostr network client exists, pointing this factory at it is the
/// ACCEPTANCE GATE for the swap — nothing above the protocol may change.
enum TransportConformance {
    /// Factory: connections to the SAME logical relay.
    static func run(
        makeConnection: @escaping @Sendable () async -> any RelayTransport
    ) async throws {
        let keypair = try NostrKeypair(privateKey: hexData(String(repeating: "e1", count: 32)))
        let recipient = try NostrKeypair(privateKey: hexData(String(repeating: "e2", count: 32)))

        // 1. publish -> OK ack with the event id.
        let publisher = await makeConnection()
        let event = try keypair.sign(
            NostrEvent(
                pubkey: keypair.publicKeyHex, createdAt: 1_750_000_000, kind: 1, tags: [],
                content: "conformance"),
            randomSource: SystemRandomSource())
        let ack = try await publisher.publish(event)
        #expect(ack.accepted)
        #expect(ack.eventID == event.id)

        // 2. Invalidly signed events are refused.
        var forged = event
        forged.content = "tampered"
        forged.id = forged.computedID()
        let forgedAck = try? await publisher.publish(forged)
        #expect(forgedAck == nil || forgedAck?.accepted == false)

        // 3. Store-and-forward: a later subscriber sees the stored event.
        let subscriber = await makeConnection()
        let stream = await subscriber.subscribe([NostrFilter(kinds: [1])])
        var got: NostrEvent?
        for try await received in stream {
            got = received
            break
        }
        #expect(got?.id == event.id)

        // 4. Gift wraps are withheld from non-AUTHed readers and served to the
        //    AUTHed p-tagged recipient.
        let oneTime = try NostrKeypair(privateKey: hexData(String(repeating: "e3", count: 32)))
        let wrap = try oneTime.sign(
            NostrEvent(
                pubkey: oneTime.publicKeyHex, createdAt: 1_750_000_001,
                kind: PQRCConstants.giftWrapEventKind,
                tags: [["p", recipient.publicKeyHex]], content: "opaque"),
            randomSource: SystemRandomSource())
        _ = try await publisher.publish(wrap)

        let unauthed = await makeConnection()
        let unauthedCollector = NostrEventCollector()
        await unauthedCollector.attach(
            await unauthed.subscribe([
                NostrFilter(
                    kinds: [PQRCConstants.giftWrapEventKind], pTags: [recipient.publicKeyHex])
            ]))
        let unauthedSeen = await unauthedCollector.settle()
        #expect(unauthedSeen.isEmpty, "kind-1059 must be AUTH-gated")

        let authed = await makeConnection()
        try await authed.authenticate(keypair: recipient, randomSource: SystemRandomSource())
        let authedStream = await authed.subscribe([
            NostrFilter(kinds: [PQRCConstants.giftWrapEventKind], pTags: [recipient.publicKeyHex])
        ])
        var authedGot = false
        for try await received in authedStream {
            authedGot = received.id == wrap.id
            break
        }
        #expect(authedGot, "AUTHed recipient must receive their envelope")

        // 5. Replaceable semantics.
        for createdAt in [Int64(10), Int64(20)] {
            _ = try await publisher.publish(
                try keypair.sign(
                    NostrEvent(
                        pubkey: keypair.publicKeyHex, createdAt: createdAt,
                        kind: PQRCConstants.bindingEventKind, tags: [], content: "\(createdAt)"),
                    randomSource: SystemRandomSource()))
        }
        let replaceableCollector = NostrEventCollector()
        await replaceableCollector.attach(
            await (await makeConnection()).subscribe([
                NostrFilter(
                    kinds: [PQRCConstants.bindingEventKind], authors: [keypair.publicKeyHex])
            ]))
        let replaceables = await replaceableCollector.settle()
        #expect(replaceables.count == 1)
        #expect(replaceables.first?.content == "20", "latest replaceable wins")
    }
}

@Suite("Transport swap point", .tags(.transport))
struct ConformanceSuiteTests {
    /// Always-on, network-free: the simulator must keep passing the contract.
    @Test func swapPoint_transportConformanceSuite() async throws {
        let relay = LocalRelaySimulator()
        try await TransportConformance.run {
            await relay.connect()
        }
    }

    /// The REAL swap gate: `NostrWebSocketTransport` against an in-process
    /// `pqrc-relay` (`NostrRelayServer`) over 127.0.0.1. Touches a loopback
    /// socket, so it is opt-in per the CLAUDE.md "no unit test touches the
    /// network" rule:
    ///   PQRC_LOOPBACK_TESTS=1 swift test --package-path Packages/PQRCNostr
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PQRC_LOOPBACK_TESTS"] == "1"))
    func swapPoint_webSocketLoopbackConformance() async throws {
        let relay = LocalRelaySimulator(url: "ws://127.0.0.1:0")
        let server = NostrRelayServer(relay: relay, port: 0)  // ephemeral port
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let url = URL(string: "ws://127.0.0.1:\(port)")!
        try await TransportConformance.run {
            await NostrWebSocketTransport(url: url).connect()
        }
    }

    /// Acceptance gate against a deployed relay (e.g. wss://relay.lerants.com).
    /// Requires the relay to implement NIP-42 AUTH with anchor-relay kind-1059
    /// gating (SPEC §9.1) — a vanilla public relay will fail step 4, and that
    /// failure is the point of the gate. Opt-in:
    ///   PQRC_RELAY_URL=wss://relay.lerants.com swift test --package-path Packages/PQRCNostr
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PQRC_RELAY_URL"] != nil))
    func swapPoint_deployedRelayConformance() async throws {
        let relayURL = try #require(
            URL(string: ProcessInfo.processInfo.environment["PQRC_RELAY_URL"] ?? ""))
        try await TransportConformance.run {
            await NostrWebSocketTransport(url: relayURL).connect()
        }
    }
}
