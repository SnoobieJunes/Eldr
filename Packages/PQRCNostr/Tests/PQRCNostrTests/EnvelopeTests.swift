// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import Testing

@testable import PQRCCore
@testable import PQRCNostr

struct GiftWrapVector: Codable {
    let senderNostrPrivate: String
    let recipientNostrPrivate: String
    let fuzzedTimestamp: Int64
    let rumorJSON: String
    let wrapEventJSON: String
}

@Suite("Gift wrap envelope (SPEC §8)", .tags(.envelope))
struct EnvelopeTests {
    static func fixtureKeys() throws -> (sender: NostrKeypair, recipient: NostrKeypair) {
        (
            try NostrKeypair(privateKey: hexData(String(repeating: "11", count: 32))),
            try NostrKeypair(privateKey: hexData(String(repeating: "22", count: 32)))
        )
    }

    static func sampleRumor() -> RumorContent {
        RumorContent(
            type: .message, participantType: .human, senderRole: .identity,
            header: RatchetHeader(dh: Data(repeating: 3, count: 32), pn: 0, n: 7, pq: nil),
            ciphertext: Data(repeating: 4, count: 276))
    }

    @Test func giftwrap_vectorFrozen_andReWrapIsByteIdentical() throws {
        let vector: GiftWrapVector = try Vectors.loadOrGenerate("giftwrap.json") {
            let (sender, recipient) = try Self.fixtureKeys()
            let rumor = Self.sampleRumor()
            let wrap = try GiftWrap.wrap(
                rumor: rumor, sender: sender,
                recipientNostrPubkey: recipient.publicKeyHex,
                fuzzedTimestamp: 1_749_900_000,
                randomSource: SeededRandomSource(seed: 99),
                nonceSource: SeededRandomSource(seed: 98))
            return GiftWrapVector(
                senderNostrPrivate: sender.privateKeyData.hexString,
                recipientNostrPrivate: recipient.privateKeyData.hexString,
                fuzzedTimestamp: 1_749_900_000,
                rumorJSON: String(decoding: try WireJSON.encoder().encode(rumor), as: UTF8.self),
                wrapEventJSON: String(
                    decoding: try WireJSON.encoder().encode(wrap), as: UTF8.self))
        }
        // Deterministic re-wrap from the frozen seeds reproduces the event byte-for-byte.
        let sender = try NostrKeypair(privateKey: hexData(vector.senderNostrPrivate))
        let recipient = try NostrKeypair(privateKey: hexData(vector.recipientNostrPrivate))
        let rumor = try WireJSON.decoder().decode(
            RumorContent.self, from: Data(vector.rumorJSON.utf8))
        let rewrap = try GiftWrap.wrap(
            rumor: rumor, sender: sender, recipientNostrPubkey: recipient.publicKeyHex,
            fuzzedTimestamp: vector.fuzzedTimestamp,
            randomSource: SeededRandomSource(seed: 99),
            nonceSource: SeededRandomSource(seed: 98))
        let rewrapJSON = String(decoding: try WireJSON.encoder().encode(rewrap), as: UTF8.self)
        #expect(rewrapJSON == vector.wrapEventJSON)

        // And the frozen wrap unwraps to the frozen rumor.
        let frozenWrap = try WireJSON.decoder().decode(
            NostrEvent.self, from: Data(vector.wrapEventJSON.utf8))
        let unwrapped = try GiftWrap.unwrap(frozenWrap, recipient: recipient)
        #expect(unwrapped.rumor == rumor)
        #expect(unwrapped.senderNostrPubkey == sender.publicKeyHex)
        #expect(unwrapped.fuzzedTimestamp == vector.fuzzedTimestamp)
    }

    @Test func wrap_unwrap_unseal_roundTrip() throws {
        let (sender, recipient) = try Self.fixtureKeys()
        let rumor = Self.sampleRumor()
        let wrap = try GiftWrap.wrap(
            rumor: rumor, sender: sender, recipientNostrPubkey: recipient.publicKeyHex,
            fuzzedTimestamp: 1_749_900_111,
            randomSource: SystemRandomSource(), nonceSource: SystemNonceSource())
        let unwrapped = try GiftWrap.unwrap(wrap, recipient: recipient)
        #expect(unwrapped.rumor == rumor)
        #expect(unwrapped.senderNostrPubkey == sender.publicKeyHex)
        // Only the intended recipient can unwrap.
        let outsider = try NostrKeypair(privateKey: hexData(String(repeating: "33", count: 32)))
        #expect(throws: NostrError.self) {
            _ = try GiftWrap.unwrap(wrap, recipient: outsider)
        }
    }

    @Test func giftwrap_outerKeyIsFreshPerMessage() throws {
        let (sender, recipient) = try Self.fixtureKeys()
        let random = SeededRandomSource(seed: 4)
        let nonces = SeededRandomSource(seed: 5)
        var outerKeys = Set<String>()
        for i in 0..<1000 {
            let wrap = try GiftWrap.wrap(
                rumor: Self.sampleRumor(), sender: sender,
                recipientNostrPubkey: recipient.publicKeyHex,
                fuzzedTimestamp: Int64(1_749_000_000 + i),
                randomSource: random, nonceSource: nonces)
            outerKeys.insert(wrap.pubkey)
        }
        #expect(outerKeys.count == 1000, "every wrap must use a distinct one-time key")
        #expect(!outerKeys.contains(sender.publicKeyHex), "never the sender's real key")
    }

    @Test func giftwrap_for16384BucketMessage_staysUnderRelayContentLimit() throws {
        // The largest padding bucket a relay chunk uses is 16384. After the
        // seal+wrap layers (each ~1.33× base64 expansion), the resulting event
        // content MUST stay under the 65535-byte limit common relays (khatru)
        // enforce — otherwise large pastes are rejected "content is too large".
        // This is the regression guard for that exact failure.
        let (sender, recipient) = try Self.fixtureKeys()
        // 16384 bucket + 4-byte length prefix + 16-byte GCM tag.
        let ciphertext = Data(repeating: 4, count: 16384 + 4 + 16)
        let rumor = RumorContent(
            type: .message, participantType: .human, senderRole: .identity,
            header: RatchetHeader(dh: Data(repeating: 3, count: 32), pn: 0, n: 7, pq: nil),
            ciphertext: ciphertext)
        let wrap = try GiftWrap.wrap(
            rumor: rumor, sender: sender, recipientNostrPubkey: recipient.publicKeyHex,
            fuzzedTimestamp: 1_749_900_000,
            randomSource: SeededRandomSource(seed: 1), nonceSource: SeededRandomSource(seed: 2))
        #expect(
            wrap.content.utf8.count <= 65535,
            "wrap content \(wrap.content.utf8.count) exceeds the 65535 relay limit")
    }

    @Test func giftwrap_relayVisibleSurfaceLeaksNothing() throws {
        let (sender, recipient) = try Self.fixtureKeys()
        let canary = "CANARY-the-quick-brown-plaintext"
        var rumor = Self.sampleRumor()
        rumor.ciphertext = Data(canary.utf8)  // worst case: canary in the inner payload
        let wrap = try GiftWrap.wrap(
            rumor: rumor, sender: sender, recipientNostrPubkey: recipient.publicKeyHex,
            fuzzedTimestamp: 1_749_900_222,
            randomSource: SeededRandomSource(seed: 6), nonceSource: SeededRandomSource(seed: 7))

        #expect(wrap.kind == PQRCConstants.giftWrapEventKind)
        // The recipient p tag plus a NIP-40 expiration anchored to the FUZZED
        // created_at (expiration − window == created_at), so it leaks no timing
        // the public created_at doesn't already.
        let expectedExpiration = String(1_749_900_222 + PQRCConstants.expirationWindowSeconds)
        #expect(
            wrap.tags == [["p", recipient.publicKeyHex], ["expiration", expectedExpiration]],
            "only the recipient p tag and a fuzz-anchored expiration")
        #expect(wrap.pubkey != sender.publicKeyHex)

        let serialized = String(decoding: try WireJSON.encoder().encode(wrap), as: UTF8.self)
        #expect(!serialized.contains(sender.publicKeyHex), "sender pubkey must not appear")
        #expect(!serialized.contains(canary), "no plaintext canary on the wire")
        #expect(!serialized.contains(Data(canary.utf8).base64EncodedString()))
    }

    @Test func rumor_isUnsigned_andSealSignedBySenderVerifies() throws {
        let (sender, recipient) = try Self.fixtureKeys()
        let wrap = try GiftWrap.wrap(
            rumor: Self.sampleRumor(), sender: sender,
            recipientNostrPubkey: recipient.publicKeyHex,
            fuzzedTimestamp: 1_749_900_333,
            randomSource: SeededRandomSource(seed: 8), nonceSource: SeededRandomSource(seed: 9))
        // Peel the layers manually.
        let sealJSON = try SealCipher.decrypt(
            wrap.content, privateKey: recipient.privateKeyData, peerPublicKeyHex: wrap.pubkey)
        let seal = try WireJSON.decoder().decode(NostrEvent.self, from: sealJSON)
        #expect(seal.kind == PQRCConstants.sealEventKind)
        #expect(seal.pubkey == sender.publicKeyHex)
        #expect(seal.tags.isEmpty)
        #expect(NostrKeypair.verify(seal), "seal must verify under the sender's Nostr key")

        let rumorJSON = try SealCipher.decrypt(
            seal.content, privateKey: recipient.privateKeyData, peerPublicKeyHex: seal.pubkey)
        let rumorEvent = try WireJSON.decoder().decode(NostrEvent.self, from: rumorJSON)
        #expect(rumorEvent.isRumor, "rumor must be unsigned")
        #expect(rumorEvent.kind == PQRCConstants.rumorEventKind)

        // A seal whose inner rumor claims a different author is rejected.
        var forgedRumorEvent = rumorEvent
        forgedRumorEvent.pubkey = recipient.publicKeyHex
        let forgedSealContent = try SealCipher.encrypt(
            try WireJSON.encoder().encode(forgedRumorEvent),
            privateKey: sender.privateKeyData, peerPublicKeyHex: recipient.publicKeyHex,
            nonceSource: SystemNonceSource())
        let forgedSeal = try sender.sign(
            NostrEvent(
                pubkey: sender.publicKeyHex, createdAt: wrap.createdAt,
                kind: PQRCConstants.sealEventKind, tags: [], content: forgedSealContent),
            randomSource: SystemRandomSource())
        let oneTime = try NostrKeypair(randomSource: SystemRandomSource())
        let forgedWrapContent = try SealCipher.encrypt(
            try WireJSON.encoder().encode(forgedSeal),
            privateKey: oneTime.privateKeyData, peerPublicKeyHex: recipient.publicKeyHex,
            nonceSource: SystemNonceSource())
        let forgedWrap = try oneTime.sign(
            NostrEvent(
                pubkey: oneTime.publicKeyHex, createdAt: wrap.createdAt,
                kind: PQRCConstants.giftWrapEventKind,
                tags: [["p", recipient.publicKeyHex]], content: forgedWrapContent),
            randomSource: SystemRandomSource())
        #expect(throws: NostrError.senderMismatch) {
            _ = try GiftWrap.unwrap(forgedWrap, recipient: recipient)
        }
    }

    @Test func fuzz_sameValueUsedInADandWrap() async throws {
        // The fuzzed timestamp committed into the AEAD AD is the created_at on
        // BOTH the seal and the wrap.
        let relay = LocalRelaySimulator()
        let clock = FixedClock(now: 1_752_000_000)
        let alice = try await Persona.make(
            name: "alice", seedByte: "aa", seed: 1, transports: [await relay.connect()],
            clock: clock)
        let bob = try await Persona.make(
            name: "bob", seedByte: "bb", seed: 2, transports: [await relay.connect()],
            clock: clock)
        await alice.messenger.addContact(try bob.asContact())
        await bob.messenger.addContact(try alice.asContact())

        let bobEvents = EventCollector()
        await bobEvents.attach(try await bob.messenger.start())

        let bundle = try await bob.prekeyManager.publicBundle()
        try await alice.messenger.establishSession(
            with: try bob.asContact(), bundle: bundle,
            firstMessage: MessageBody(text: "ts binding", sentAt: clock.now()))

        let received = await bobEvents.waitForMessages(1)
        #expect(received.count == 1)

        // Inspect the stored wrap: seal.created_at == wrap.created_at, both in
        // the past-only fuzz window, and decryption already proved the AD match.
        let wraps = await relay.storedEvents(kind: PQRCConstants.giftWrapEventKind)
        #expect(wraps.count == 1)
        let wrap = try #require(wraps.first)
        let sealJSON = try SealCipher.decrypt(
            wrap.content, privateKey: bob.nostrKeypair.privateKeyData,
            peerPublicKeyHex: wrap.pubkey)
        let seal = try WireJSON.decoder().decode(NostrEvent.self, from: sealJSON)
        #expect(seal.createdAt == wrap.createdAt)
        #expect(wrap.createdAt <= clock.now())
        #expect(clock.now() - wrap.createdAt <= PQRCConstants.timestampFuzzWindowSeconds)
        await bobEvents.stop()
    }
}

@Suite("NIP-01 events, BIP-340, bech32", .tags(.envelope))
struct NostrEventTests {
    @Test func eventID_canonicalSerializationAndEscaping() throws {
        let event = NostrEvent(
            pubkey: String(repeating: "ab", count: 32), createdAt: 1_700_000_000, kind: 1,
            tags: [["p", "deadbeef"], ["e", "cafe"]],
            content: "line1\nline2 \"quoted\" back\\slash\ttab")
        let canonical = String(decoding: event.canonicalSerialization(), as: UTF8.self)
        #expect(
            canonical
                == "[0,\"\(String(repeating: "ab", count: 32))\",1700000000,1,[[\"p\",\"deadbeef\"],[\"e\",\"cafe\"]],\"line1\\nline2 \\\"quoted\\\" back\\\\slash\\ttab\"]"
        )
        #expect(event.id == sha256(event.canonicalSerialization()).hexString)
    }

    @Test func signVerify_roundTrip_andTamperDetection() throws {
        let keypair = try NostrKeypair(privateKey: hexData(String(repeating: "77", count: 32)))
        let signed = try keypair.sign(
            NostrEvent(
                pubkey: keypair.publicKeyHex, createdAt: 1, kind: 13, tags: [], content: "x"),
            randomSource: SeededRandomSource(seed: 1))
        #expect(NostrKeypair.verify(signed))
        var tampered = signed
        tampered.content = "y"
        #expect(!NostrKeypair.verify(tampered))  // id no longer matches
        tampered.id = tampered.computedID()
        #expect(!NostrKeypair.verify(tampered))  // sig no longer matches
    }

    @Test func bech32_npubMatchesNIP19ReferenceVector() {
        // NIP-19 reference: this hex pubkey <-> this npub.
        let hex = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
        let npub = Bech32.npub(hex)
        #expect(npub == "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6")
        #expect(Bech32.pubkeyHex(fromNpub: npub) == hex)
    }
}
