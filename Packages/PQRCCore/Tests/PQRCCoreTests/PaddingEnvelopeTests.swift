// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import Testing

@testable import PQRCCore

struct PaddingVector: Codable {
    struct Case: Codable {
        let plaintextLength: Int
        let bucket: Int?  // nil => must throw (blob path only)
        let paddedLength: Int?
        let ciphertextLength: Int?
    }
    let cases: [Case]
}

@Suite("Padding, AD, wire format (SPEC §7–8)", .tags(.envelope))
struct PaddingEnvelopeTests {
    /// AEAD overhead on top of the bucket: 4-byte length prefix + 16-byte GCM tag.
    static let aeadOverhead = 20

    static func makePaddingVector() throws -> PaddingVector {
        let lengths = [0, 1, 255, 256, 257, 1023, 1024, 4095, 16384, 65535, 65536, 65537]
        let cases = try lengths.map { length -> PaddingVector.Case in
            if length > PQRCConstants.inlineSizeLimit {
                return PaddingVector.Case(
                    plaintextLength: length, bucket: nil, paddedLength: nil, ciphertextLength: nil)
            }
            let bucket = try Padding.bucket(for: length)
            return PaddingVector.Case(
                plaintextLength: length, bucket: bucket, paddedLength: bucket + 4,
                ciphertextLength: bucket + aeadOverhead)
        }
        return PaddingVector(cases: cases)
    }

    @Test func padding_roundTripsAllBoundaryLengths() throws {
        let vector: PaddingVector = try Vectors.loadOrGenerate(
            "padding.json", generate: Self.makePaddingVector)
        for testCase in vector.cases {
            let plaintext = Data(repeating: 0x42, count: testCase.plaintextLength)
            guard let bucket = testCase.bucket else {
                #expect(throws: PQRCError.self) { _ = try Padding.pad(plaintext) }
                continue
            }
            let padded = try Padding.pad(plaintext)
            #expect(try Padding.bucket(for: testCase.plaintextLength) == bucket)
            #expect(padded.count == testCase.paddedLength)
            #expect(try Padding.unpad(padded) == plaintext)

            // And through real AEAD, the ciphertext collapses to bucket + overhead.
            let mk = SymmetricKey(data: Data(repeating: 1, count: 32))
            let ciphertext = try DoubleRatchet.aeadSeal(
                messageKey: mk, plaintext: padded, ad: Data("ad".utf8))
            #expect(ciphertext.count == testCase.ciphertextLength)
        }
    }

    @Test func padding_over64KBInlineThrows() throws {
        #expect(throws: PQRCError.plaintextExceedsInlineLimit(size: 65537)) {
            _ = try Padding.pad(Data(count: 65537))
        }
    }

    @Test func ciphertextLengths_collapseToBucketSet() throws {
        // 500 random plaintexts ≤ 64 KB: ciphertext sizes form EXACTLY the
        // bucket set + overhead — no size side channel.
        let random = SeededRandomSource(seed: 808)
        var observed = Set<Int>()
        for _ in 0..<500 {
            let lengthSeed = random.bytes(4).uint32BE(at: 0) ?? 0
            let length = Int(lengthSeed) % (PQRCConstants.inlineSizeLimit + 1)
            let padded = try Padding.pad(random.bytes(length))
            let ciphertext = try DoubleRatchet.aeadSeal(
                messageKey: SymmetricKey(data: random.bytes(32)),
                plaintext: padded, ad: Data())
            observed.insert(ciphertext.count)
        }
        let allowed = Set(PQRCConstants.paddingBuckets.map { $0 + Self.aeadOverhead })
        #expect(observed.isSubset(of: allowed))
        #expect(observed.count > 1, "sample should hit multiple buckets")
    }

    @Test func ad_bindsContext() throws {
        // Tampering any AD component fails decryption; the matching AD succeeds.
        let mk = SymmetricKey(data: Data(repeating: 7, count: 32))
        let padded = try Padding.pad(Data("bound to context".utf8))
        let goodAD = AssociatedData.build(
            participantType: .human, n: 7, fuzzedTimestamp: 1_750_000_000)
        let ciphertext = try DoubleRatchet.aeadSeal(messageKey: mk, plaintext: padded, ad: goodAD)

        #expect(
            try DoubleRatchet.aeadOpen(messageKey: mk, ciphertext: ciphertext, ad: goodAD) == padded)

        let tampered: [Data] = [
            // wrong version
            {
                var ad = Data("9".utf8)
                ad.append(Data(ParticipantType.human.rawValue.utf8))
                ad.append(Data(uint32BE: 7))
                ad.append(Data(int64BE: 1_750_000_000))
                return ad
            }(),
            // wrong participant_type (human -> agent forgery attempt)
            AssociatedData.build(participantType: .agent, n: 7, fuzzedTimestamp: 1_750_000_000),
            // wrong message number
            AssociatedData.build(participantType: .human, n: 8, fuzzedTimestamp: 1_750_000_000),
            // wrong fuzzed timestamp
            AssociatedData.build(participantType: .human, n: 7, fuzzedTimestamp: 1_750_000_001),
        ]
        for badAD in tampered {
            #expect(throws: PQRCError.decryptionFailed) {
                _ = try DoubleRatchet.aeadOpen(messageKey: mk, ciphertext: ciphertext, ad: badAD)
            }
        }
    }

    @Test func fuzz_timestampWithinTwoDaysPast_neverFuture() throws {
        // Property test, 10k samples (TEST-PLAN §5).
        let clock = FixedClock(now: 1_760_000_000)
        let random = SeededRandomSource(seed: 161_803)
        for _ in 0..<10_000 {
            let fuzzed = TimestampFuzzer.fuzzedTimestamp(clock: clock, randomSource: random)
            #expect(fuzzed <= clock.now(), "never in the future")
            #expect(clock.now() - fuzzed <= PQRCConstants.timestampFuzzWindowSeconds)
        }
    }

    @Test func wire_fieldNamesMatchNIPExactly() throws {
        // Golden-string check on every wire struct (CLAUDE.md: spk, pqpk, otp,
        // otp_pq, lrp, dh, pn, n, pq, ptr ...).
        let header = RatchetHeader(
            dh: Data([1]), pn: 2, n: 3,
            pq: PQRekeyHeader(ct: Data([4]), pk: Data([5]), ctr: 6, tgt: Data([7])))
        let headerJSON = String(
            decoding: try WireJSON.encoder().encode(header), as: UTF8.self)
        #expect(
            headerJSON
                == #"{"dh":"AQ==","n":3,"pn":2,"pq":{"ct":"BA==","ctr":6,"pk":"BQ==","tgt":"Bw=="}}"#)

        let pointer = ContentPointer(
            blossomURL: "https://blossom.example/abc", decryptionKey: Data([7]),
            sha256: "ff", sizeBytes: 9, mirrorURLs: ["https://m.example/abc"])
        let rumor = RumorContent(
            type: .message, participantType: .agent, senderRole: .agent,
            header: RatchetHeader(dh: Data([1]), pn: 0, n: 0, pq: nil),
            ciphertext: Data([9]), contentPointer: pointer)
        let rumorJSON = String(decoding: try WireJSON.encoder().encode(rumor), as: UTF8.self)
        #expect(rumorJSON.contains(#""pqrc_version":"1""#))
        #expect(rumorJSON.contains(#""participant_type":"agent""#))
        #expect(rumorJSON.contains(#""sender_role":"agent""#))
        #expect(rumorJSON.contains(#""ratchet_header":"#))
        #expect(rumorJSON.contains(#""ptr":"#))
        #expect(rumorJSON.contains(#""blossom_url":"#))
        #expect(rumorJSON.contains(#""decryption_key":"#))
        #expect(rumorJSON.contains(#""size_bytes":"#))
        #expect(rumorJSON.contains(#""mirror_urls":"#))

        let bundle = PrekeyBundle(
            identityPubkey: Data([1]),
            ikDH: .init(key: Data([2]), sig: Data([3])),
            spk: .init(key: Data([4]), sig: Data([5])),
            pqpk: .init(key: Data([6]), sig: Data([7])),
            otp: [Data([8])], otpPQ: [Data([9])],
            lrp: .init(key: Data([10]), sig: Data([11])))
        let bundleJSON = String(decoding: try WireJSON.encoder().encode(bundle), as: UTF8.self)
        for field in ["\"ik\"", "\"ik_dh\"", "\"spk\"", "\"pqpk\"", "\"otp\"", "\"otp_pq\"", "\"lrp\""] {
            #expect(bundleJSON.contains(field), "missing wire field \(field)")
        }

        let handshakeJSON = String(
            decoding: try WireJSON.encoder().encode(
                HandshakeMessage(
                    suite: PQRCConstants.handshakeSuite, ik: Data([1]), ikDH: Data([2]),
                    ikDHSig: Data([9]), ek: Data([3]),
                    kemCT: Data([4]), kemPK: Data([5]), spkUsed: Data([6]),
                    otpUsed: Data([7]), otpPQUsed: Data([8]), lrpUsed: false)),
            as: UTF8.self)
        for field in ["\"suite\"", "\"ik_dh\"", "\"ik_dh_sig\"", "\"ek\"", "\"kem_ct\"", "\"kem_pk\"", "\"spk_used\"", "\"otp_used\"", "\"otp_pq_used\"", "\"lrp_used\""] {
            #expect(handshakeJSON.contains(field), "missing wire field \(field)")
        }
    }

    @Test func wire_unknownFieldsIgnoredNotFatal() throws {
        // Forward compatibility (SPEC §12): unknown JSON fields never break decoding.
        let json = """
            {
              "pqrc_version": "1",
              "type": "message",
              "participant_type": "human",
              "sender_role": "identity",
              "ratchet_header": {"dh": "AQ==", "pn": 0, "n": 0, "pq": null,
                                 "future_epoch": 12},
              "ciphertext": "AA==",
              "conversation_type": "1to1",
              "some_v2_field": {"nested": ["x"]}
            }
            """
        let rumor = try WireJSON.decoder().decode(RumorContent.self, from: Data(json.utf8))
        #expect(rumor.type == .message)
        #expect(rumor.header?.n == 0)
    }
}

@Suite("EncryptedStore (SPEC §3.4, D9)", .tags(.security))
struct EncryptedStoreTests {
    @Test func sealOpen_roundTrip_andRecordKeyIsolation() throws {
        let store = EncryptedStore(
            randomSource: SeededRandomSource(seed: 1), nonceSource: SeededRandomSource(seed: 2))
        let secret = Data("ratchet state canary".utf8)
        let blob = try store.seal(secret, recordID: "record-A")
        #expect(!blob.hexString.contains(secret.hexString), "blob must not contain plaintext")
        #expect(try store.open(blob, recordID: "record-A") == secret)
        // Per-record key derivation: the same blob fails under another record ID.
        #expect(throws: PQRCError.decryptionFailed) {
            _ = try store.open(blob, recordID: "record-B")
        }
    }

    @Test func masterKey_wrapUnwrapRoundTrip() throws {
        let nonceSource = SeededRandomSource(seed: 3)
        let wrapper = SoftwareKeyWrapper(
            keyEncryptionKey: SeededRandomSource(seed: 4).bytes(32), nonceSource: nonceSource)
        let store = EncryptedStore(
            randomSource: SeededRandomSource(seed: 5), nonceSource: nonceSource)
        let wrapped = try store.wrappedMasterKey(using: wrapper)
        let reopened = EncryptedStore(
            masterKey: try wrapper.unwrap(wrapped: wrapped), nonceSource: nonceSource)
        let blob = try store.seal(Data("persisted".utf8), recordID: "r")
        #expect(try reopened.open(blob, recordID: "r") == Data("persisted".utf8))
        // A wrong KEK cannot unwrap.
        let wrongWrapper = SoftwareKeyWrapper(
            keyEncryptionKey: SeededRandomSource(seed: 6).bytes(32), nonceSource: nonceSource)
        #expect(throws: PQRCError.keyWrapFailure) {
            _ = try wrongWrapper.unwrap(wrapped: wrapped)
        }
    }
}
