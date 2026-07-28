// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import Testing

@testable import PQRCCore

// MARK: - Deterministic ratchet fixtures

enum RatchetFixture {
    static let sk = hexData(String(repeating: "5e", count: 32))

    /// Builds an Alice/Bob ratchet pair sharing SK, with all keys from seeds.
    static func pair(
        aliceSeed: UInt64 = 100, bobSeed: UInt64 = 200
    ) throws -> (alice: DoubleRatchet, bob: DoubleRatchet) {
        let material = SeededRandomSource(seed: 9999)
        let bobRatchetPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: material.bytes(32))
        let aliceKEM = try MLKEM768.PrivateKey(seedRepresentation: material.bytes(64), publicKey: nil)
        let bobKEM = try MLKEM768.PrivateKey(seedRepresentation: material.bytes(64), publicKey: nil)

        let dummyHandshake = HandshakeMessage(
            suite: PQRCConstants.handshakeSuite, ik: Data(), ikDH: Data(),
            ikDHSig: Data(), ek: Data(),
            kemCT: Data(), kemPK: aliceKEM.publicKey.rawRepresentation,
            spkUsed: Data(), otpUsed: nil, otpPQUsed: nil, lrpUsed: false
        )
        let initiation = PQXDH.InitiationResult(
            sharedSecret: SymmetricKey(data: sk),
            message: dummyHandshake,
            myKEMPrivate: aliceKEM,
            peerRatchetPubkey: bobRatchetPriv.publicKey.rawRepresentation,
            peerKEMPubkey: bobKEM.publicKey.rawRepresentation
        )
        let response = PQXDH.ResponseResult(
            sharedSecret: SymmetricKey(data: sk),
            initiatorIdentityPub: Data(),
            myRatchetPrivate: bobRatchetPriv,
            peerKEMPubkey: aliceKEM.publicKey.rawRepresentation,
            usedLastResort: false
        )
        let alice = try DoubleRatchet(
            initiatorWith: initiation, randomSource: SeededRandomSource(seed: aliceSeed))
        let bob = DoubleRatchet(
            responderWith: response, myKEMPrivate: bobKEM,
            randomSource: SeededRandomSource(seed: bobSeed))
        return (alice, bob)
    }

    static func ad(n: Int) -> Data {
        AssociatedData.build(participantType: .human, n: n, fuzzedTimestamp: 1_750_000_000)
    }

    static func encrypt(_ ratchet: inout DoubleRatchet, _ text: String) throws -> (RatchetHeader, Data) {
        let padded = try Padding.pad(Data(text.utf8))
        return try ratchet.encrypt(paddedPlaintext: padded) { header in ad(n: header.n) }
    }

    static func decrypt(_ ratchet: inout DoubleRatchet, _ header: RatchetHeader, _ ciphertext: Data) throws -> String {
        let padded = try ratchet.decrypt(header: header, ciphertext: ciphertext, associatedData: ad(n: header.n))
        return String(decoding: try Padding.unpad(padded), as: UTF8.self)
    }
}

// MARK: - Frozen vectors

struct RatchetChainVector: Codable {
    struct Message: Codable {
        let direction: String  // "a2b" | "b2a"
        let plaintext: String
        let dh: String
        let pn: Int
        let n: Int
        let messageKey: String
        let ciphertext: String
    }
    let sk: String
    let messages: [Message]
}

struct PQRekeyVector: Codable {
    struct Message: Codable {
        let n: Int
        let hasRekey: Bool
        let header: String  // wire JSON of the full header
        let ciphertext: String
        let plaintext: String
    }
    let sk: String
    /// The rekey refreshes the active CHAIN immediately; the root fold is
    /// deferred to the next DH boundary (NIP-XX §6), so in this one-way
    /// transcript the root is identical before/after while the chain rotates.
    let bobChainBeforeRekey: String
    let bobChainAfterRekey: String
    let bobRootAtRekey: String
    let messages: [Message]
}

@Suite("Double Ratchet: FS, PCS, PQ rekey (SPEC §5–6)", .tags(.crypto))
struct RatchetTests {

    // MARK: Vector: 40-message interleaved transcript

    static func makeChainVector() throws -> RatchetChainVector {
        var (alice, bob) = try RatchetFixture.pair()
        var messages: [RatchetChainVector.Message] = []
        // 10 rounds of (A sends 2, B sends 2) = 40 messages, DH ratchet every turnover.
        for round in 0..<10 {
            for burst in 0..<2 {
                let text = "a2b round \(round) msg \(burst)"
                let ckBefore = alice.cks!  // message key derives from the chain key pre-advance
                let (header, ciphertext) = try RatchetFixture.encrypt(&alice, text)
                let (mk, _) = DoubleRatchet.kdfChainKey(ckBefore)
                _ = try RatchetFixture.decrypt(&bob, header, ciphertext)
                messages.append(
                    .init(
                        direction: "a2b", plaintext: text, dh: header.dh.hex, pn: header.pn,
                        n: header.n, messageKey: mk.rawData.hex, ciphertext: ciphertext.hex))
            }
            for burst in 0..<2 {
                let text = "b2a round \(round) msg \(burst)"
                let ckBefore = bob.cks!
                let (header, ciphertext) = try RatchetFixture.encrypt(&bob, text)
                let (mk, _) = DoubleRatchet.kdfChainKey(ckBefore)
                _ = try RatchetFixture.decrypt(&alice, header, ciphertext)
                messages.append(
                    .init(
                        direction: "b2a", plaintext: text, dh: header.dh.hex, pn: header.pn,
                        n: header.n, messageKey: mk.rawData.hex, ciphertext: ciphertext.hex))
            }
        }
        return RatchetChainVector(sk: RatchetFixture.sk.hex, messages: messages)
    }

    @Test func ratchet_interleavedConversation_matchesVectors() throws {
        let vector: RatchetChainVector = try Vectors.loadOrGenerate(
            "ratchet_chain.json", generate: Self.makeChainVector)
        #expect(vector.messages.count == 40)

        // Full replay from seeds must reproduce every header, message key and
        // ciphertext byte-for-byte (everything in this transcript is deterministic).
        var (alice, bob) = try RatchetFixture.pair()
        var index = 0
        for round in 0..<10 {
            for burst in 0..<2 {
                let expected = vector.messages[index]
                index += 1
                let ckBefore = alice.cks!
                let (header, ciphertext) = try RatchetFixture.encrypt(
                    &alice, "a2b round \(round) msg \(burst)")
                let (mk, _) = DoubleRatchet.kdfChainKey(ckBefore)
                #expect(header.dh.hex == expected.dh)
                #expect(header.pn == expected.pn)
                #expect(header.n == expected.n)
                #expect(header.pq == nil, "no rekey inside a 40-message conversation")
                #expect(mk.rawData.hex == expected.messageKey)
                #expect(ciphertext.hex == expected.ciphertext)
                #expect(try RatchetFixture.decrypt(&bob, header, ciphertext) == expected.plaintext)
            }
            for burst in 0..<2 {
                let expected = vector.messages[index]
                index += 1
                let ckBefore = bob.cks!
                let (header, ciphertext) = try RatchetFixture.encrypt(
                    &bob, "b2a round \(round) msg \(burst)")
                let (mk, _) = DoubleRatchet.kdfChainKey(ckBefore)
                #expect(header.dh.hex == expected.dh)
                #expect(mk.rawData.hex == expected.messageKey)
                #expect(ciphertext.hex == expected.ciphertext)
                #expect(try RatchetFixture.decrypt(&alice, header, ciphertext) == expected.plaintext)
            }
        }
    }

    // MARK: Forward secrecy

    @Test func forwardSecrecy_oldCiphertextsUndecryptableAfterAdvance() throws {
        var (alice, bob) = try RatchetFixture.pair()
        let ckBefore = alice.cks!
        let (usedMK, _) = DoubleRatchet.kdfChainKey(ckBefore)
        let (header, ciphertext) = try RatchetFixture.encrypt(&alice, "burn after reading")
        #expect(try RatchetFixture.decrypt(&bob, header, ciphertext) == "burn after reading")

        // The consumed message key is erased from both live state and the
        // persisted snapshot of both sides.
        for snapshot in [alice.makeSnapshot(), bob.makeSnapshot()] {
            let blob = try JSONEncoder().encode(snapshot)
            #expect(!blob.hexString.contains(usedMK.rawData.hex), "message key must not persist")
            #expect(snapshot.cks != ckBefore.rawData, "spent chain key must have advanced")
        }

        // Re-feeding the earlier ciphertext into current state fails (replay).
        var replayTarget = bob
        #expect(throws: PQRCError.self) {
            _ = try RatchetFixture.decrypt(&replayTarget, header, ciphertext)
        }
    }

    // MARK: Post-compromise security

    @Test func postCompromiseSecurity_snapshotCannotReadFuture() throws {
        var (alice, bob) = try RatchetFixture.pair()
        // Warm-up exchange.
        var (header, ciphertext) = try RatchetFixture.encrypt(&alice, "hello bob")
        _ = try RatchetFixture.decrypt(&bob, header, ciphertext)

        // COMPROMISE: full clone of Bob's state. The attacker has all current
        // secrets but only their own entropy from here on.
        var stolenBob = try DoubleRatchet(
            snapshot: bob.makeSnapshot(), randomSource: SeededRandomSource(seed: 666_666))

        // Pre-heal message is readable by the clone (expected: FS protects the
        // past, PCS needs a round-trip to heal the future).
        (header, ciphertext) = try RatchetFixture.encrypt(&alice, "still compromised")
        var stolenCopy = stolenBob
        #expect(try RatchetFixture.decrypt(&stolenCopy, header, ciphertext) == "still compromised")
        _ = try RatchetFixture.decrypt(&bob, header, ciphertext)

        // HEAL: one full round-trip from Bob's perspective. Bob's reply still
        // uses his pre-steal ratchet key; the healing entropy is the FRESH key
        // Bob generates when he next receives Alice's new ratchet key, which
        // reaches Alice on his second reply. Anything Alice keys to that fresh
        // key is unreadable by the clone.
        let (reply1Header, reply1Ciphertext) = try RatchetFixture.encrypt(&bob, "bob replies (pre-heal key)")
        _ = try RatchetFixture.decrypt(&alice, reply1Header, reply1Ciphertext)
        var (header2, ciphertext2) = try RatchetFixture.encrypt(&alice, "alice ratchets")
        _ = try RatchetFixture.decrypt(&bob, header2, ciphertext2)  // Bob mints fresh DH here
        // The clone tracks the same public traffic up to this point (expected:
        // healing has not completed yet).
        var tracker = stolenBob
        _ = try? RatchetFixture.decrypt(&tracker, reply1Header, reply1Ciphertext)
        _ = try? RatchetFixture.decrypt(&tracker, header2, ciphertext2)
        stolenBob = tracker

        let (reply2Header, reply2Ciphertext) = try RatchetFixture.encrypt(&bob, "bob heals with fresh key")
        _ = try RatchetFixture.decrypt(&alice, reply2Header, reply2Ciphertext)
        (header2, ciphertext2) = try RatchetFixture.encrypt(&alice, "post-heal secret")

        // The clone replayed identical wire traffic but lacks Bob's
        // post-compromise DH private key: the healed message is unreachable.
        #expect(throws: PQRCError.self) {
            _ = try RatchetFixture.decrypt(&stolenBob, header2, ciphertext2)
        }
        // The honest Bob reads it fine.
        #expect(try RatchetFixture.decrypt(&bob, header2, ciphertext2) == "post-heal secret")
    }

    // MARK: PQ rekey

    static func makeRekeyVector() throws -> PQRekeyVector {
        var (alice, bob) = try RatchetFixture.pair(aliceSeed: 300, bobSeed: 400)
        var messages: [PQRekeyVector.Message] = []
        var chainBefore = Data()
        var chainAfter = Data()
        var rootAtRekey = Data()
        for i in 0..<52 {
            let text = "one-way message \(i)"
            let (header, ciphertext) = try RatchetFixture.encrypt(&alice, text)
            if header.pq != nil { chainBefore = bob.makeSnapshot().ckr ?? Data() }
            _ = try RatchetFixture.decrypt(&bob, header, ciphertext)
            if header.pq != nil {
                chainAfter = bob.makeSnapshot().ckr ?? Data()
                rootAtRekey = bob.makeSnapshot().rootKey
            }
            let headerJSON = try WireJSON.encoder().encode(header)
            messages.append(
                .init(
                    n: header.n, hasRekey: header.pq != nil,
                    header: String(decoding: headerJSON, as: UTF8.self),
                    ciphertext: ciphertext.hex, plaintext: text))
        }
        return PQRekeyVector(
            sk: RatchetFixture.sk.hex,
            bobChainBeforeRekey: chainBefore.hex,
            bobChainAfterRekey: chainAfter.hex,
            bobRootAtRekey: rootAtRekey.hex,
            messages: messages)
    }

    @Test func pqRekey_firesAtExactly50_rotatesRoot_andHealsQuantumCompromise() throws {
        let vector: PQRekeyVector = try Vectors.loadOrGenerate(
            "pq_rekey.json", generate: Self.makeRekeyVector)

        // Boundary shape: the rekey KEM ciphertext is present exactly on the
        // 50th message (n = 49) and absent everywhere else.
        for message in vector.messages {
            #expect(message.hasRekey == (message.n == PQRCConstants.pqRekeyInterval - 1))
        }

        // Receiver replay from frozen bytes: Bob (rebuilt from seeds) must
        // decrypt the entire frozen stream and reproduce the frozen chain keys.
        var (_, bob) = try RatchetFixture.pair(aliceSeed: 300, bobSeed: 400)
        for message in vector.messages {
            let header = try WireJSON.decoder().decode(
                RatchetHeader.self, from: Data(message.header.utf8))
            if header.pq != nil {
                #expect((bob.makeSnapshot().ckr ?? Data()).hex == vector.bobChainBeforeRekey)
            }
            let plaintext = try RatchetFixture.decrypt(&bob, header, hexData(message.ciphertext))
            #expect(plaintext == message.plaintext)
            if header.pq != nil {
                #expect((bob.makeSnapshot().ckr ?? Data()).hex == vector.bobChainAfterRekey)
                #expect(
                    bob.makeSnapshot().rootKey.hex == vector.bobRootAtRekey,
                    "root fold is deferred to the next DH boundary")
                #expect(bob.makeSnapshot().pendingInboundRootFolds.count == 1)
            }
        }
        #expect(vector.bobChainBeforeRekey != vector.bobChainAfterRekey, "rekey must rotate the chain")

        // The deferred root fold lands at the next DH boundary, identically on
        // both sides, and the pending queues drain.
        var (liveA, liveB) = try RatchetFixture.pair(aliceSeed: 305, bobSeed: 405)
        for i in 0..<52 {  // crosses the rekey at message 50
            let (header, ciphertext) = try RatchetFixture.encrypt(&liveA, "w\(i)")
            _ = try RatchetFixture.decrypt(&liveB, header, ciphertext)
        }
        let rootBeforeBoundary = liveA.makeSnapshot().rootKey
        #expect(liveA.makeSnapshot().pendingOutboundRootFolds.count == 1)
        let (replyHeader, replyCiphertext) = try RatchetFixture.encrypt(&liveB, "reply")
        _ = try RatchetFixture.decrypt(&liveA, replyHeader, replyCiphertext)  // A's DH step: fold applies
        let (pingHeader, pingCiphertext) = try RatchetFixture.encrypt(&liveA, "ping")  // A's new chain
        #expect(try RatchetFixture.decrypt(&liveB, pingHeader, pingCiphertext) == "ping")
        #expect(liveA.makeSnapshot().rootKey != rootBeforeBoundary, "fold applied at the boundary")
        #expect(liveA.makeSnapshot().pendingOutboundRootFolds.isEmpty, "A's fold drained")
        #expect(liveB.makeSnapshot().pendingInboundRootFolds.isEmpty, "B applied the same fold")
        // Position-synchronized: several more round-trips keep decrypting
        // (any root desync would fail at the first post-fold DH step).
        for i in 0..<3 {
            let (h1, c1) = try RatchetFixture.encrypt(&liveB, "rt-b\(i)")
            #expect(try RatchetFixture.decrypt(&liveA, h1, c1) == "rt-b\(i)")
            let (h2, c2) = try RatchetFixture.encrypt(&liveA, "rt-a\(i)")
            #expect(try RatchetFixture.decrypt(&liveB, h2, c2) == "rt-a\(i)")
        }

        // Quantum-compromise healing: clone the SENDER's full state just before
        // the rekey. The clone holds every classical secret (equivalent to
        // "broken X25519": there are no DH steps in this one-way stream), but
        // not Bob's ML-KEM private key — so it cannot derive post-rekey keys.
        var (liveAlice, liveBob) = try RatchetFixture.pair(aliceSeed: 500, bobSeed: 600)
        var wire: [(RatchetHeader, Data)] = []
        var stolenAlice: DoubleRatchet?
        for i in 0..<52 {
            if i == 48 {
                stolenAlice = try DoubleRatchet(
                    snapshot: liveAlice.makeSnapshot(),
                    randomSource: SeededRandomSource(seed: 777_777))
            }
            let (header, ciphertext) = try RatchetFixture.encrypt(&liveAlice, "m\(i)")
            wire.append((header, ciphertext))
        }
        var clone = try #require(stolenAlice)
        // Message 48 (index 48, pre-rekey) IS derivable by the clone (no healing yet):
        let (mk48, next48) = DoubleRatchet.kdfChainKey(clone.cks!)
        clone.cks = next48
        let opened = try DoubleRatchet.aeadOpen(
            messageKey: mk48, ciphertext: wire[48].1, ad: RatchetFixture.ad(n: 48))
        #expect(String(decoding: try Padding.unpad(opened), as: UTF8.self) == "m48")

        // Message 49 is the 50th message: it carries the rekey and is already
        // encrypted under the KEM-refreshed chain. From here on, every key the
        // clone can reach (continuing the old chain) fails — it cannot
        // decapsulate the rekey without Bob's ML-KEM private key.
        #expect(wire[49].0.pq != nil)
        for i in 49...51 {
            let (mk, next) = DoubleRatchet.kdfChainKey(clone.cks!)
            clone.cks = next
            #expect(throws: PQRCError.self, "post-rekey message \(i) must be unreachable") {
                _ = try DoubleRatchet.aeadOpen(
                    messageKey: mk, ciphertext: wire[i].1, ad: RatchetFixture.ad(n: i))
            }
        }
        // The honest receiver reads everything.
        for (i, (header, ciphertext)) in wire.enumerated() {
            #expect(try RatchetFixture.decrypt(&liveBob, header, ciphertext) == "m\(i)")
        }
    }

    @Test func pqRekey_messageCounterSpansBothDirections() throws {
        // 25 each way = 50 total; the 50th processed message (a send) carries the rekey.
        var (alice, bob) = try RatchetFixture.pair(aliceSeed: 310, bobSeed: 410)
        var rekeysSeen = 0
        for i in 0..<25 {
            let (h1, c1) = try RatchetFixture.encrypt(&alice, "a\(i)")
            if h1.pq != nil { rekeysSeen += 1 }
            _ = try RatchetFixture.decrypt(&bob, h1, c1)
            let (h2, c2) = try RatchetFixture.encrypt(&bob, "b\(i)")
            if h2.pq != nil { rekeysSeen += 1 }
            _ = try RatchetFixture.decrypt(&alice, h2, c2)
        }
        #expect(rekeysSeen == 1, "exactly one rekey across 50 messages")
    }

    // MARK: Skipped keys

    @Test func skippedKeys_decryptOutOfOrderWithinMaxSkip() throws {
        var (alice, bob) = try RatchetFixture.pair(aliceSeed: 320, bobSeed: 420)
        var wire: [(RatchetHeader, Data)] = []
        for i in 0..<45 {
            wire.append(try RatchetFixture.encrypt(&alice, "ooo\(i)"))
        }
        // Deliver in a deterministic shuffle (no rekey inside 45 messages).
        var order = Array(0..<45)
        var generator = SeededRandomSource(seed: 31337)
        order.sort { _, _ in generator.bytes(1)[0] % 2 == 0 }
        for index in order {
            let (header, ciphertext) = wire[index]
            #expect(try RatchetFixture.decrypt(&bob, header, ciphertext) == "ooo\(index)")
        }
        #expect(bob.skippedKeyCount == 0, "all cached keys consumed and purged")
    }

    @Test func skippedKeys_reorderAcrossRekeyBoundary() throws {
        var (alice, bob) = try RatchetFixture.pair(aliceSeed: 325, bobSeed: 425)
        var wire: [(RatchetHeader, Data)] = []
        for i in 0..<60 {
            wire.append(try RatchetFixture.encrypt(&alice, "x\(i)"))
        }
        // Segment-wise reorder: pre-rekey messages in reverse, the rekey
        // message (n=49), then post-rekey messages in reverse.
        let order = Array((0..<49).reversed()) + [49] + Array((50..<60).reversed())
        for index in order {
            let (header, ciphertext) = wire[index]
            #expect(try RatchetFixture.decrypt(&bob, header, ciphertext) == "x\(index)")
        }
    }

    @Test func skippedKeys_beyond1000Rejected() throws {
        var (alice, bob) = try RatchetFixture.pair(aliceSeed: 330, bobSeed: 430)
        var last: (RatchetHeader, Data)?
        for i in 0...(PQRCConstants.maxSkip + 1) {
            last = try RatchetFixture.encrypt(&alice, "skip\(i)")
        }
        let (header, ciphertext) = try #require(last)
        #expect(header.n == PQRCConstants.maxSkip + 1)
        #expect(throws: PQRCError.self) {
            var copy = bob
            _ = try RatchetFixture.decrypt(&copy, header, ciphertext)
        }
        // And the live state is untouched: the first message still decrypts.
        _ = bob
    }

    @Test func skippedKeys_deletedAfterUse() throws {
        var (alice, bob) = try RatchetFixture.pair(aliceSeed: 340, bobSeed: 440)
        let first = try RatchetFixture.encrypt(&alice, "first")
        let second = try RatchetFixture.encrypt(&alice, "second")
        _ = try RatchetFixture.decrypt(&bob, second.0, second.1)
        #expect(bob.skippedKeyCount == 1)
        _ = try RatchetFixture.decrypt(&bob, first.0, first.1)
        #expect(bob.skippedKeyCount == 0, "skipped key purged after use")
        // Using it twice is impossible.
        var replay = bob
        #expect(throws: PQRCError.self) {
            _ = try RatchetFixture.decrypt(&replay, first.0, first.1)
        }
    }

    // MARK: No timers in the key schedule

    @Test func noTimers_keyScheduleHasNoClockDependency() async throws {
        // API-level: DoubleRatchet stores no Clock (SPEC §5.2 — message-driven only).
        let (alice, _) = try RatchetFixture.pair()
        for child in Mirror(reflecting: alice).children {
            #expect(!(child.value is any Clock), "ratchet must not hold a Clock")
        }

        // Behavior-level: two full PQRCSession conversations whose clocks
        // diverge wildly must produce identical key schedules. (The clock DOES
        // feed timestamp fuzzing — only the keys must be unaffected.)
        func runConversation(clockValues: [Int64]) async throws -> [String] {
            let clock = FixedClock(now: clockValues[0])
            let (a, b) = try RatchetFixture.pair(aliceSeed: 350, bobSeed: 450)
            let aliceSession = try PQRCSession(
                snapshot: a.makeSnapshot(), peerIdentityPubkey: Data(),
                usedLastResortPrekey: false, clock: clock,
                randomSource: SeededRandomSource(seed: 351))
            let bobSession = try PQRCSession(
                snapshot: b.makeSnapshot(), peerIdentityPubkey: Data(),
                usedLastResortPrekey: false, clock: clock,
                randomSource: SeededRandomSource(seed: 451))
            var keys: [String] = []
            for (i, value) in clockValues.enumerated() {
                clock.set(value)  // would perturb any clock-dependent schedule
                let out = try await aliceSession.encrypt(
                    body: MessageBody(text: "tick\(i)", sentAt: clock.now()),
                    participantType: .human)
                _ = try await bobSession.decrypt(
                    rumor: out.rumor, fuzzedTimestamp: out.fuzzedTimestamp)
                let reply = try await bobSession.encrypt(
                    body: MessageBody(text: "tock\(i)", sentAt: clock.now()),
                    participantType: .human)
                _ = try await aliceSession.decrypt(
                    rumor: reply.rumor, fuzzedTimestamp: reply.fuzzedTimestamp)
                let snapshot = await aliceSession.snapshot()
                keys.append(snapshot.rootKey.hex)
                keys.append(snapshot.cks?.hex ?? "")
                keys.append(snapshot.ckr?.hex ?? "")
            }
            return keys
        }
        let stable = try await runConversation(clockValues: [1_000_000, 1_000_000, 1_000_000, 1_000_000])
        let chaotic = try await runConversation(clockValues: [1_000_000, 5_000_000, 99_999_999_999, 1_000])
        #expect(stable == chaotic, "mutating the clock must have zero effect on the key schedule")
    }
}
