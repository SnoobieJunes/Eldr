// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import Testing

@testable import PQRCCore
@testable import PQRCNostr

/// Conformance tests for the Buzz interop codecs (NIP-44 v2, NIP-OA, NIP-01
/// id + BIP-340 signing) against Block/Buzz's OWN published vectors — the four
/// full NIP-AE engram events (docs/nips/NIP-AE.md §Reference test vectors) and
/// the NIP-OA spec vector (buzz-sdk/src/nip_oa.rs). If these pass, an Eldr node
/// produces bytes a Buzz relay / verifier accepts, and reads bytes they emit.

/// Deterministic all-zero "randomness" — reproduces the pinned aux=0 / nonce=0
/// vectors. NEVER used in production (SPEC §2: production nonces are CSPRNG).
private struct ZeroRandomSource: RandomSource {
    func bytes(_ count: Int) -> Data { Data(repeating: 0, count: count) }
}

// Well-known secp256k1 test keys (secret 0x01 and 0x02) and their x-only pubkeys.
private let seckey1 = Data(repeating: 0, count: 31) + Data([0x01])
private let seckey2 = Data(repeating: 0, count: 31) + Data([0x02])
private let pubkey1 = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
private let pubkey2 = "c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"

@Suite("Buzz interop — crypto conformance")
struct BuzzInteropCryptoTests {

    // MARK: - ChaCha20 (RFC 8439 §2.4.2)

    @Test("ChaCha20 reproduces RFC 8439 §2.4.2 encryption vector")
    func chacha20RFCVector() {
        let key = (0..<32).map { UInt8($0) }
        let nonce: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0x4a, 0, 0, 0, 0]
        let plaintext = Array(
            "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."
                .utf8)
        let expected =
            "6e2e359a2568f98041ba0728dd0d6981e97e7aec1d4360c20a27afccfd9fae0bf91b65c5524733ab8f593dabcd62b3571639d624e65152ab8f530c359f0861d807ca0dbf500d6a6156a38e088a22b65e52bc514d16ccf806818ce91ab77937365af90bbf74a35be6b40b8eedf2785e42874d"
        // RFC 8439 §2.4.2 uses initial block counter = 1.
        let out = ChaCha20.xor(key: key, nonce: nonce, counter: 1, data: plaintext)
        #expect(Data(out).hexString == expected)
    }

    // MARK: - NIP-44 conversation key

    @Test("NIP-44 conversation key matches Buzz K_c vector (sec1=01, pub2)")
    func nip44ConversationKey() throws {
        let kc = try NIP44.conversationKey(privateKey: seckey1, peerPublicKeyHex: pubkey2)
        #expect(kc.hexString == "c41c775356fd92eadc63ff5a0dc1da211b268cbea22316767095b2871ea1412d")
        // Symmetric: computing from the other side yields the same key.
        let kcReverse = try NIP44.conversationKey(privateKey: seckey2, peerPublicKeyHex: pubkey1)
        #expect(kcReverse.hexString == kc.hexString)
    }

    @Test("NIP-44 padding buckets match calc_padded_len")
    func nip44Padding() {
        #expect(NIP44.calcPaddedLen(1) == 32)
        #expect(NIP44.calcPaddedLen(32) == 32)
        #expect(NIP44.calcPaddedLen(33) == 64)
        #expect(NIP44.calcPaddedLen(37) == 64)
        #expect(NIP44.calcPaddedLen(45) == 64)
        #expect(NIP44.calcPaddedLen(100) == 128)
        #expect(NIP44.calcPaddedLen(256) == 256)
        // Official NIP-44 vectors: 320→320, 383→384, 384→384.
        #expect(NIP44.calcPaddedLen(320) == 320)
        #expect(NIP44.calcPaddedLen(383) == 384)
        #expect(NIP44.calcPaddedLen(384) == 384)
        #expect(NIP44.calcPaddedLen(65535) == 65536)
    }

    // MARK: - Full NIP-AE event vectors (NIP-44 encrypt + NIP-01 id + BIP-340)

    /// Each tuple: (createdAt, nonceHex, dTagHex, body, expectedContentB64,
    /// contentSha256, eventId, sig).
    private static let engramVectors:
        [(Int64, String, String, String, String, String, String, String)] = [
            (
                1_700_000_000,
                "0000000000000000000000000000000000000000000000000000000000000001",
                "72d4f9629106451505d7d341ea85bb3ebad4f654fcfd2aad100d5a35f8a85cba",
                #"{"slug":"mem/example","value":"hello, agent memory"}"#,
                "AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABedgcxyfmpph68LBjCWZsTI5lb0Cbg8dIPVYVe/WVj/l4Yd8HGgzC8awyBi9bn9ClRdtd2IPsmont0jN/cajVSQhahTOwuNNwoJtZIg35aSsUzeCq4tQfd8E+fLoKomdPxjs=",
                "ff680a293019af12709972ae68b6ee79a47f354381a94ca4074d8e0fe3c8bb50",
                "f4a594177b7aeea4fe99a09efbf74ae85f0126244f322135682c405888a38689",
                "0a4582f0bc5995b9a010afda5984f568055988ebbe4552b4e0ec6d11aeb2b303af940f3d84726a7edd1763badb284eb3aa8457664ceba85a90d6252ed4b494cb"
            ),
            (
                1_700_000_001,
                "0000000000000000000000000000000000000000000000000000000000000002",
                "31651571a312780cfdc1f0b706b682ac9f3f51a053e8dca76fe57710bae5a4d4",
                #"{"slug":"mem/notes/2026-05-12","value":"meeting note: [[mem/example]]"}"#,
                "AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACG/JBPvdZxDwAxOG7bY3AW2q1slZqBjQC3NxfPVtfcR+TGjp2GKtjyXyqNwG08GK+00I1u1vUZ4cCjcun9A7ra92rleKKJ5w57pqgFspbv1vClUJY5487A/5phVDHkw6DhRCSMDpEMw5Tapj3Wm1ponAVr5PciPOrTxltEfTVdSKaPA==",
                "ba7b026809363134c4f8de6cfbd82417b838e265281ff7e0005dc193bf1b32c8",
                "1a43298ea1fa9b73462a85b9f16f5f6bd2a7ab18b0b02424e5ec3f3b8a48e030",
                "dc9da456db1c89f070edc5f994786f270fc00e8ff19f33d5b0f6cea49421cd727fcd79bb288f3e3dbd5af9ca1ba67f9bd11b02a47c1e6c37cfd32665c17e4a24"
            ),
            (
                1_700_000_002,
                "0000000000000000000000000000000000000000000000000000000000000003",
                "72d4f9629106451505d7d341ea85bb3ebad4f654fcfd2aad100d5a35f8a85cba",
                #"{"slug":"mem/example","value":null}"#,
                "AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADuau8i0Wu4+ULnp2qTfd+O23jJAapMRrKGGwabNVOlT9hSF8FViBHIS6f86/7xK4qGOin4IH8Wr/3cvHDcQGQd3IXQJr8LHgJkaYpQPdBO1bgqiFu8K3L/CLb1PgG1X7RQ8E=",
                "0c9f72125f6460e68cb4b7ee42298afc8969840f83a156d90aa98a5f461fea44",
                "c8604bef05295856a67a88ec895e07b5b47a2febc23c82934734096a7b123b63",
                "c8d53859cf08b3a9a20a5b01c61d12fa2f082f462adb635420f05dc6f9bb662a174e729023854bf53e5e35fae8f6f4c9d604e8979a070e298cd77cfb7e6b6468"
            ),
            (
                1_700_000_003,
                "0000000000000000000000000000000000000000000000000000000000000004",
                "bdc233238ffe52e272b44cc233c8f33a2bc510b08be04495b225964283be4a90",
                #"{"slug":"core","profile":"test agent. see [[mem/example]] and [[mem/notes/2026-05-12]]."}"#,
                "AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEEeZHAFjhc8DAcKaVSSB7IoKG3nr+dX3LXlU7UIdOKayhIVPXvl4WuFmBSVxLO6yEV5vnLvzbo7rU0uPRYyAJLPNnifVTCw2EQZH70zOwTc/mVvaATHKzqcFo5VHrbpKNTzeNnz1Vds2yg2DXmdxaoWQA4YfnlLwZDOpyu9JP1uB1Yw==",
                "070f0f3e2e2bdc016b3ae06e8754e7814ffd4e98f0d5a70d75d1e8eab0d0e474",
                "980419c4d231266471242456c832d0c2eb1e6974468dc795f3ae327484129058",
                "ce113fff1205eadb38928b224a90247be1a00b0c3f8ab583d4a5f7274ddba51ebb5eb9d627d44664a78d2e870e61835cf61446cc812ecea139e8b7d41b8e238f"
            ),
        ]

    @Test("NIP-44 encrypt reproduces Buzz NIP-AE event content byte-exactly")
    func nip44EncryptEngramVectors() throws {
        // Author = agent (seckey1 / pubkey1); recipient = owner (pubkey2).
        let ck = try NIP44.conversationKey(privateKey: seckey1, peerPublicKeyHex: pubkey2)
        for (_, nonceHex, _, body, expectedContent, contentSha, _, _) in Self.engramVectors {
            let nonce = Data(hexString: nonceHex)!
            let content = try NIP44.encrypt(plaintext: body, conversationKey: ck, nonce: nonce)
            #expect(content == expectedContent)
            #expect(sha256(Data(content.utf8)).hexString == contentSha)
        }
    }

    @Test("NIP-44 decrypt recovers the plaintext from Buzz vector content")
    func nip44DecryptEngramVectors() throws {
        // Owner side: recipient = owner (seckey2), sender = agent (pubkey1).
        let ck = try NIP44.conversationKey(privateKey: seckey2, peerPublicKeyHex: pubkey1)
        for (_, _, _, body, expectedContent, _, _, _) in Self.engramVectors {
            let recovered = try NIP44.decrypt(payload: expectedContent, conversationKey: ck)
            #expect(recovered == body)
        }
    }

    @Test("NIP-01 id + BIP-340 sig reproduce Buzz NIP-AE events byte-exactly")
    func nip01IdAndSignatureEngramVectors() throws {
        let keypair = try NostrKeypair(privateKey: seckey1)
        #expect(keypair.publicKeyHex == pubkey1)  // seckey 0x01 → known pubkey
        let zero = ZeroRandomSource()
        for (createdAt, _, dTag, _, content, _, eventId, sig) in Self.engramVectors {
            let event = NostrEvent(
                pubkey: pubkey1, createdAt: createdAt, kind: 30174,
                tags: [["d", dTag], ["p", pubkey2]], content: content)
            #expect(event.id == eventId)
            let signed = try keypair.sign(event, randomSource: zero)
            #expect(signed.sig == sig)  // aux=0 → BIP-340 deterministic vector
            #expect(NostrKeypair.verify(signed))
        }
    }

    // MARK: - NIP-AE blinded d-tag (HMAC over the conversation key)

    @Test("NIP-AE blinded d-tag matches Buzz vectors")
    func nipAEDTag() throws {
        let ck = try NIP44.conversationKey(privateKey: seckey1, peerPublicKeyHex: pubkey2)
        // d = HMAC-SHA256(K_c, "agent-memory/v1/d-tag" || 0x00 || slug)
        func dTag(_ slug: String) -> String {
            var msg = Data("agent-memory/v1/d-tag".utf8)
            msg.append(0x00)
            msg.append(Data(slug.utf8))
            return Data(HMAC<Crypto.SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: ck)))
                .hexString
        }
        #expect(dTag("core") == "bdc233238ffe52e272b44cc233c8f33a2bc510b08be04495b225964283be4a90")
        #expect(
            dTag("mem/example") == "72d4f9629106451505d7d341ea85bb3ebad4f654fcfd2aad100d5a35f8a85cba")
        #expect(
            dTag("mem/notes/2026-05-12")
                == "31651571a312780cfdc1f0b706b682ac9f3f51a053e8dca76fe57710bae5a4d4")
    }

    // MARK: - NIP-OA owner attestation (buzz-sdk spec vector)

    @Test("NIP-OA preimage SHA-256 matches spec vector")
    func nipOAPreimageDigest() {
        let digest = NIPOA.preimageDigest(
            agentPublicKeyHex: pubkey2, conditions: "kind=1&created_at<1713957000")
        #expect(digest.hexString == "08cdecd55af4c28d3801fd69615dcf5cc04fab3bc134b38a840bf157197069a6")
    }

    @Test("NIP-OA verifies the spec-provided signature")
    func nipOAVerifySpecSignature() throws {
        // Spec vector: owner=pubkey1, agent=pubkey2, conditions, known sig.
        let specSig =
            "8b7df2575caf0a108374f8471722b233c53f9ff827a8b0f91861966c3b9dd5cb2e189eae9f49d72187674c2f5bd244145e10ff86c9f257ffe65a1ee5f108b369"
        let tag = NIPOA.encodeTag(
            owner: pubkey1, conditions: "kind=1&created_at<1713957000", sig: specSig)
        let owner = try NIPOA.verifyAuthTag(tag, agentPublicKeyHex: pubkey2)
        #expect(owner == pubkey1)
    }

    @Test("NIP-OA compute→verify round trips")
    func nipOARoundTrip() throws {
        let random = SystemRandomSource()
        let agent = try NostrKeypair(randomSource: random)
        let tag = try NIPOA.computeAuthTag(
            ownerPrivateKey: seckey1, agentPublicKeyHex: agent.publicKeyHex,
            conditions: "kind=9", randomSource: random)
        let owner = try NIPOA.verifyAuthTag(tag, agentPublicKeyHex: agent.publicKeyHex)
        #expect(owner == pubkey1)
        // Wrong agent pubkey must fail.
        let other = try NostrKeypair(randomSource: random)
        #expect(throws: (any Error).self) {
            try NIPOA.verifyAuthTag(tag, agentPublicKeyHex: other.publicKeyHex)
        }
    }

    @Test("NIP-OA conditions grammar accepts valid and rejects invalid")
    func nipOAConditionsGrammar() {
        for good in [
            "", "kind=1", "kind=0", "kind=65535", "created_at<1713957000", "created_at>0",
            "kind=1&created_at<1713957000", "kind=9&created_at>100&created_at<200",
        ] {
            #expect(throws: Never.self) { try NIPOA.validateConditions(good) }
        }
        for bad in [
            "kind=1&", "&kind=1", "kind=1&&created_at<100", "kind=01", "kind=65536",
            "created_at<4294967296", "foo=1", "Kind=1", "kind= 1", "kind=abc", "kind=-1",
        ] {
            #expect(throws: (any Error).self) { try NIPOA.validateConditions(bad) }
        }
    }

    @Test("NIP-OA rejects self-attestation and malformed tags")
    func nipOARejects() {
        #expect(throws: (any Error).self) {
            _ = try NIPOA.computeAuthTag(
                ownerPrivateKey: seckey1, agentPublicKeyHex: pubkey1, conditions: "kind=9",
                randomSource: ZeroRandomSource())
        }
        for bad in ["not json", #"["auth","a","b"]"#, #"{"auth":"x"}"#] {
            #expect(throws: (any Error).self) { try NIPOA.parseAuthTag(bad) }
        }
    }
}
