import CryptoKit
import PQRCAgent
import PQRCCore
import PQRCNostr
import XCTest

/// TEST-PLAN §11 / APP-SPEC §12: pipeline performance, measured with XCTest
/// metrics. First CI run records baselines (xcbaseline artifacts); absolute
/// budgets are asserted as soft warnings on simulators — hardware-honest
/// numbers come from device runs (DEMO.md).
final class PerformancePipelineTests: XCTestCase {
    /// A live sender-side ratchet + Nostr keys, built synchronously from seeds.
    private func makePipeline() throws -> (
        ratchet: DoubleRatchet, sender: NostrKeypair, recipient: NostrKeypair
    ) {
        let material = SeededRandomSource(seed: 43_000)
        return (
            try PQRCFixtures.senderRatchet(seed: 42_000),
            try NostrKeypair(randomSource: material),
            try NostrKeypair(randomSource: material)
        )
    }

    /// Budget: 1 KB message pad+encrypt+wrap < 10 ms (p95).
    func test_sendPipeline_1KB() throws {
        nonisolated(unsafe) var (ratchet, sender, recipient) = try makePipeline()
        let body = MessageBody(text: String(repeating: "a", count: 1024), sentAt: 0)
        let plaintext = try WireJSON.encoder().encode(body)
        let options = XCTMeasureOptions()
        options.iterationCount = 20
        measure(metrics: [XCTClockMetric()], options: options) {
            do {
                let padded = try Padding.pad(plaintext)
                let (header, ciphertext) = try ratchet.encrypt(paddedPlaintext: padded) { header in
                    AssociatedData.build(
                        participantType: .human, n: header.n, fuzzedTimestamp: 1_750_000_000)
                }
                let rumor = RumorContent(
                    type: .message, participantType: .human, senderRole: .identity,
                    header: header, ciphertext: ciphertext)
                _ = try GiftWrap.wrap(
                    rumor: rumor, sender: sender,
                    recipientNostrPubkey: recipient.publicKeyHex,
                    fuzzedTimestamp: 1_750_000_000,
                    randomSource: SystemRandomSource(), nonceSource: SystemNonceSource())
            } catch {
                XCTFail("\(error)")
            }
        }
    }

    /// Budget: 64 KB inline path < 50 ms.
    func test_sendPipeline_64KBInline() throws {
        nonisolated(unsafe) var (ratchet, _, _) = try makePipeline()
        let plaintext = Data(repeating: 0x62, count: 65_000)
        measure(metrics: [XCTClockMetric()]) {
            do {
                let padded = try Padding.pad(plaintext)
                _ = try ratchet.encrypt(paddedPlaintext: padded) { header in
                    AssociatedData.build(
                        participantType: .human, n: header.n, fuzzedTimestamp: 1_750_000_000)
                }
            } catch {
                XCTFail("\(error)")
            }
        }
    }

    /// Budget: 1 MB paste → blob encrypted + stored < 250 ms, UI never blocked.
    func test_blobPath_1MB() async throws {
        let blob = SeededRandomSource(seed: 7).bytes(1_048_576)
        let store = LocalBlossomSimulator()
        let start = Date()
        for _ in 0..<5 {
            _ = try await BlobCipher.encryptAndStore(
                blob, store: store,
                randomSource: SystemRandomSource(), nonceSource: SystemNonceSource())
        }
        let perIteration = Date().timeIntervalSince(start) / 5
        print("PERF: 1 MB blob path \(perIteration * 1000) ms/iteration (budget 250 ms)")
        if perIteration > 0.250 {
            print("PERF SOFT WARNING: 1 MB blob path exceeded the 250 ms budget")
        }
    }

    /// Budget: drain 500 queued envelopes < 3 s.
    func test_drain500Envelopes() async throws {
        // Pre-wrap 500 envelopes for Bob, store them on a relay, then time a
        // fresh subscriber unwrapping + decrypting all of them.
        let relay = LocalRelaySimulator()
        let clock = FixedClock()
        let random = SeededRandomSource(seed: 50_000)
        let alice = try PQRCIdentity(seed: random.bytes(32))
        let bob = try PQRCIdentity(seed: random.bytes(32))
        let aliceIKDH = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: random.bytes(32))
        let bobNostrKey = try NostrKeypair(randomSource: random)
        let aliceNostrKey = try NostrKeypair(randomSource: random)
        let prekeys = try PrekeyManager(identity: bob, randomSource: random, oneTimeCount: 1)
        let bundle = try await prekeys.publicBundle()
        let initiation = try PQXDH.initiate(
            myIdentity: alice, myIdentityDH: aliceIKDH, peerBundle: bundle, randomSource: random)
        let aliceSession = try PQRCSession(
            initiation: initiation, peerIdentityPubkey: bob.publicKeyData,
            clock: clock, randomSource: random)
        let consumed = try await prekeys.consume(
            spkUsed: initiation.message.spkUsed, otpUsed: initiation.message.otpUsed,
            otpPQUsed: initiation.message.otpPQUsed, lrpUsed: initiation.message.lrpUsed)
        let response = try PQXDH.respond(
            myIdentityPub: bob.publicKeyData, consumed: consumed, message: initiation.message)
        let bobSession = PQRCSession(
            response: response, myKEMPrivate: consumed.otpPQ ?? consumed.pqpk,
            peerIdentityPubkey: alice.publicKeyData, clock: clock,
            randomSource: SeededRandomSource(seed: 50_001))
        // Bob must process message #0 first (it advances his ratchet).
        let connection = await relay.connect()
        let first = try await aliceSession.encrypt(
            body: MessageBody(text: "handshake", sentAt: 0), type: .handshake,
            participantType: .human, handshake: initiation.message)
        _ = try await bobSession.decrypt(rumor: first.rumor, fuzzedTimestamp: first.fuzzedTimestamp)
        for i in 0..<500 {
            let outgoing = try await aliceSession.encrypt(
                body: MessageBody(text: "queued #\(i)", sentAt: 0), participantType: .human)
            let wrap = try GiftWrap.wrap(
                rumor: outgoing.rumor, sender: aliceNostrKey,
                recipientNostrPubkey: bobNostrKey.publicKeyHex,
                fuzzedTimestamp: outgoing.fuzzedTimestamp,
                randomSource: SystemRandomSource(), nonceSource: SystemNonceSource())
            _ = try await connection.publish(wrap)
        }

        let start = Date()
        let subscriber = await relay.connect()
        try await subscriber.authenticate(keypair: bobNostrKey, randomSource: SystemRandomSource())
        let stream = await subscriber.subscribe([
            NostrFilter(kinds: [PQRCConstants.giftWrapEventKind], pTags: [bobNostrKey.publicKeyHex])
        ])
        var drained = 0
        for try await event in stream {
            let unwrapped = try GiftWrap.unwrap(event, recipient: bobNostrKey)
            _ = try await bobSession.decrypt(
                rumor: unwrapped.rumor, fuzzedTimestamp: unwrapped.fuzzedTimestamp)
            drained += 1
            if drained == 500 { break }
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(drained, 500)
        print("PERF: drained 500 envelopes in \(elapsed) s (budget 3 s)")
        if elapsed > 3.0 {
            print("PERF SOFT WARNING: 500-envelope drain exceeded the 3 s budget")
        }
    }
}
