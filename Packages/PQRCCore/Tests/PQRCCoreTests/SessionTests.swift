import Crypto
import Foundation
import Testing

@testable import PQRCCore

@Suite("Session end-to-end (handshake → conversation)", .tags(.crypto))
struct SessionTests {
    struct Universe {
        let alice: PQRCIdentity
        let bob: PQRCIdentity
        let aliceSession: PQRCSession
        let bobSession: PQRCSession
        let handshakeRumor: RumorContent
        let handshakeFuzzedTimestamp: Int64
        let clock: FixedClock
    }

    /// Full establishment flow the app performs: bundle fetch → PQXDH →
    /// message #0 piggybacked on the handshake rumor (D10) → both sessions live.
    static func establish(seed: UInt64 = 42) async throws -> Universe {
        let clock = FixedClock(now: 1_751_000_000)
        let alice = try PQRCIdentity(seed: hexData(String(repeating: "01", count: 32)))
        let bob = try PQRCIdentity(seed: hexData(String(repeating: "02", count: 32)))
        let aliceRandom = SeededRandomSource(seed: seed)
        let aliceIKDH = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: aliceRandom.bytes(32))
        let bobPrekeys = try PrekeyManager(
            identity: bob, randomSource: SeededRandomSource(seed: seed &+ 1), oneTimeCount: 4)
        let bundle = try await bobPrekeys.publicBundle()
        try bundle.verifySignatures(identityPubkey: bob.publicKeyData)

        let initiation = try PQXDH.initiate(
            myIdentity: alice, myIdentityDH: aliceIKDH, peerBundle: bundle,
            randomSource: aliceRandom)
        let aliceSession = try PQRCSession(
            initiation: initiation, peerIdentityPubkey: bob.publicKeyData,
            clock: clock, randomSource: aliceRandom)

        // Message #0 rides along with the handshake (D10).
        let outgoing = try await aliceSession.encrypt(
            body: MessageBody(text: "hi bob — first contact", sentAt: clock.now()),
            type: .handshake,
            participantType: .human,
            handshake: initiation.message
        )

        // Bob receives, consumes prekeys, responds, decrypts message #0.
        let handshake = try #require(outgoing.rumor.handshake)
        let consumed = try await bobPrekeys.consume(
            spkUsed: handshake.spkUsed, otpUsed: handshake.otpUsed,
            otpPQUsed: handshake.otpPQUsed, lrpUsed: handshake.lrpUsed)
        let response = try PQXDH.respond(
            myIdentityPub: bob.publicKeyData, consumed: consumed, message: handshake)
        let bobSession = PQRCSession(
            response: response, myKEMPrivate: consumed.otpPQ ?? consumed.pqpk,
            peerIdentityPubkey: alice.publicKeyData,
            clock: clock, randomSource: SeededRandomSource(seed: seed &+ 2))
        let firstBody = try await bobSession.decrypt(
            rumor: outgoing.rumor, fuzzedTimestamp: outgoing.fuzzedTimestamp)
        #expect(firstBody.text == "hi bob — first contact")

        return Universe(
            alice: alice, bob: bob, aliceSession: aliceSession, bobSession: bobSession,
            handshakeRumor: outgoing.rumor, handshakeFuzzedTimestamp: outgoing.fuzzedTimestamp,
            clock: clock)
    }

    /// A crafted ratchet header with an out-of-range counter (`n` negative or
    /// >2^32) must be REJECTED, not crash. The AD serializes `n` as UInt32 and
    /// `UInt32(Int)` traps on out-of-range — so without the guard a single
    /// message from an accepted contact would DoS the app (and re-crash on relay
    /// replay). Invariant 12 / SPEC §12: garbage wire input is never fatal.
    @Test func decrypt_outOfRangeHeaderCounter_throwsNotTraps() async throws {
        let u = try await Self.establish()
        let good = try await u.aliceSession.encrypt(
            body: MessageBody(text: "hi", sentAt: u.clock.now()), participantType: .human)
        let h = try #require(good.rumor.header)
        let ct = try #require(good.rumor.ciphertext)
        for badN in [-1, Int(UInt32.max) + 1] {
            let badRumor = RumorContent(
                type: .message, participantType: .human, senderRole: .identity,
                header: RatchetHeader(dh: h.dh, pn: h.pn, n: badN, pq: h.pq), ciphertext: ct)
            await #expect(throws: PQRCError.malformedRumor) {
                _ = try await u.bobSession.decrypt(
                    rumor: badRumor, fuzzedTimestamp: good.fuzzedTimestamp)
            }
        }
        // A bad `pn` is rejected the same way.
        let badPn = RumorContent(
            type: .message, participantType: .human, senderRole: .identity,
            header: RatchetHeader(dh: h.dh, pn: -1, n: h.n, pq: h.pq), ciphertext: ct)
        await #expect(throws: PQRCError.malformedRumor) {
            _ = try await u.bobSession.decrypt(rumor: badPn, fuzzedTimestamp: good.fuzzedTimestamp)
        }

        // And so is a bad PQ-rekey counter. `pq.ctr` is domain-separation input to
        // the rekey chain refresh, which serializes it as UInt32 — and the rekey is
        // applied BEFORE the AEAD open, so without this guard an established peer
        // could trap the process with an unauthenticated header, and re-trap on every
        // relaunch as the relay replays the event.
        for badCtr in [-1, Int(UInt32.max) + 1] {
            let badRekey = PQRekeyHeader(
                ct: Data(repeating: 7, count: 1088), pk: Data(repeating: 8, count: 1184),
                ctr: badCtr, tgt: Data(repeating: 9, count: 32))
            let badRumor = RumorContent(
                type: .message, participantType: .human, senderRole: .identity,
                header: RatchetHeader(dh: h.dh, pn: h.pn, n: h.n, pq: badRekey), ciphertext: ct)
            await #expect(throws: PQRCError.malformedRumor) {
                _ = try await u.bobSession.decrypt(
                    rumor: badRumor, fuzzedTimestamp: good.fuzzedTimestamp)
            }
        }
    }

    @Test func session_fullConversation_bothDirections() async throws {
        let universe = try await Self.establish()
        for i in 0..<6 {
            let fromBob = try await universe.bobSession.encrypt(
                body: MessageBody(text: "bob says \(i)", sentAt: universe.clock.now()),
                participantType: .human)
            let atAlice = try await universe.aliceSession.decrypt(
                rumor: fromBob.rumor, fuzzedTimestamp: fromBob.fuzzedTimestamp)
            #expect(atAlice.text == "bob says \(i)")

            let fromAlice = try await universe.aliceSession.encrypt(
                body: MessageBody(text: "alice says \(i)", sentAt: universe.clock.now()),
                participantType: .human)
            let atBob = try await universe.bobSession.decrypt(
                rumor: fromAlice.rumor, fuzzedTimestamp: fromAlice.fuzzedTimestamp)
            #expect(atBob.text == "alice says \(i)")
        }
    }

    @Test func session_pqRekeyWorksAfterRealHandshake_withOneTimePQPrekey() async throws {
        // Regression: when the handshake consumes a one-time PQ prekey, the
        // initiator's first rekey must target THAT key (the responder's live
        // KEM private), not the medium-lived pqpk. Cross the 50-message
        // boundary in both directions over a real PQXDH establishment.
        let universe = try await Self.establish(seed: 555)
        for i in 0..<30 {
            let fromAlice = try await universe.aliceSession.encrypt(
                body: MessageBody(text: "a\(i)", sentAt: 0), participantType: .human)
            #expect(
                try await universe.bobSession.decrypt(
                    rumor: fromAlice.rumor, fuzzedTimestamp: fromAlice.fuzzedTimestamp
                ).text == "a\(i)")
            let fromBob = try await universe.bobSession.encrypt(
                body: MessageBody(text: "b\(i)", sentAt: 0), participantType: .human)
            #expect(
                try await universe.aliceSession.decrypt(
                    rumor: fromBob.rumor, fuzzedTimestamp: fromBob.fuzzedTimestamp
                ).text == "b\(i)")
        }
        // 61 messages crossed (handshake + 60): at least one rekey happened on
        // each side and both sessions remain converged.
    }

    @Test func session_failedDecryptLeavesStateIntact() async throws {
        let universe = try await Self.establish(seed: 77)
        let message = try await universe.aliceSession.encrypt(
            body: MessageBody(text: "intact", sentAt: 0), participantType: .human)

        // Flipped ciphertext byte fails cleanly; the session survives.
        var tamperedRumor = message.rumor
        var ciphertext = try #require(tamperedRumor.ciphertext)
        ciphertext[ciphertext.startIndex + 5] ^= 0xFF
        tamperedRumor.ciphertext = ciphertext
        await #expect(throws: PQRCError.self) {
            _ = try await universe.bobSession.decrypt(
                rumor: tamperedRumor, fuzzedTimestamp: message.fuzzedTimestamp)
        }
        // Original still decrypts: nothing was committed by the failure.
        let body = try await universe.bobSession.decrypt(
            rumor: message.rumor, fuzzedTimestamp: message.fuzzedTimestamp)
        #expect(body.text == "intact")
    }

    @Test func session_wrongFuzzedTimestampRejected() async throws {
        // The fuzzed created_at is authenticated via AD: a relay that rewrites
        // the wrap timestamp breaks decryption (freshness binding).
        let universe = try await Self.establish(seed: 99)
        let message = try await universe.aliceSession.encrypt(
            body: MessageBody(text: "freshness", sentAt: 0), participantType: .human)
        await #expect(throws: PQRCError.self) {
            _ = try await universe.bobSession.decrypt(
                rumor: message.rumor, fuzzedTimestamp: message.fuzzedTimestamp + 1)
        }
    }

    @Test func session_persistAndRestore_acrossSnapshot() async throws {
        let universe = try await Self.establish(seed: 123)
        // Persist Bob through the encrypted store, restore, continue conversing.
        let store = EncryptedStore(
            randomSource: SeededRandomSource(seed: 9), nonceSource: SeededRandomSource(seed: 10))
        let snapshot = await universe.bobSession.snapshot()
        let blob = try store.seal(try JSONEncoder().encode(snapshot), recordID: "session-bob")

        let restoredSnapshot = try JSONDecoder().decode(
            RatchetSnapshot.self, from: try store.open(blob, recordID: "session-bob"))
        let restoredBob = try PQRCSession(
            snapshot: restoredSnapshot, peerIdentityPubkey: universe.alice.publicKeyData,
            usedLastResortPrekey: false, clock: universe.clock,
            randomSource: SeededRandomSource(seed: 11))

        let fromAlice = try await universe.aliceSession.encrypt(
            body: MessageBody(text: "post-restore", sentAt: 0), participantType: .human)
        let received = try await restoredBob.decrypt(
            rumor: fromAlice.rumor, fuzzedTimestamp: fromAlice.fuzzedTimestamp)
        #expect(received.text == "post-restore")

        let reply = try await restoredBob.encrypt(
            body: MessageBody(text: "restored bob replies", sentAt: 0), participantType: .human)
        let atAlice = try await universe.aliceSession.decrypt(
            rumor: reply.rumor, fuzzedTimestamp: reply.fuzzedTimestamp)
        #expect(atAlice.text == "restored bob replies")
    }

    @Test func session_largeBodiesRouteThroughPointer_notInline() async throws {
        let universe = try await Self.establish(seed: 200)
        // The session layer enforces the inline cap: a >64 KB body cannot be
        // encrypted inline (the app's blob path sends a ContentPointer instead).
        let huge = String(repeating: "x", count: PQRCConstants.inlineSizeLimit + 100)
        await #expect(throws: PQRCError.self) {
            _ = try await universe.aliceSession.encrypt(
                body: MessageBody(text: huge, sentAt: 0), participantType: .human)
        }
        // Pointer body stays tiny and round-trips.
        let pointer = ContentPointer(
            blossomURL: "local://blob/abc123", decryptionKey: Data(repeating: 5, count: 32),
            sha256: String(repeating: "ab", count: 32), sizeBytes: 5_242_880,
            mirrorURLs: ["local://mirror/abc123"])
        let outgoing = try await universe.aliceSession.encrypt(
            body: MessageBody(text: "", sentAt: 0), participantType: .human,
            contentPointer: pointer)
        #expect(outgoing.rumor.contentPointer == pointer)
        _ = try await universe.bobSession.decrypt(
            rumor: outgoing.rumor, fuzzedTimestamp: outgoing.fuzzedTimestamp)
    }
}
