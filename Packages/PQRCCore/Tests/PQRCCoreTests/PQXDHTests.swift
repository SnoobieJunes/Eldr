// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import Testing

@testable import PQRCCore

struct PQXDHVector: Codable {
    struct Case: Codable {
        let name: String
        let aliceIdentitySeed: String
        let bobIdentitySeed: String
        let bobPrekeySeed: UInt64
        let bobOneTimeCount: Int
        let stripLRP: Bool
        // Frozen transcript (KEM encapsulation is internally randomized, so the
        // transcript is recorded once; verification re-runs every deterministic leg
        // plus the full responder path against these bytes).
        let handshake: HandshakeWire
        let sk: String
        let lrpUsed: Bool
        let otpUsed: Bool
    }
    struct HandshakeWire: Codable {
        let suite: String
        let ik: String
        let ikDH: String
        let ek: String
        let kemCT: String
        let kemPK: String
        let spkUsed: String
        let otpUsed: String?
        let otpPQUsed: String?
        let lrpUsed: Bool
    }
    let cases: [Case]
}

@Suite("PQXDH handshake (SPEC §4)", .tags(.crypto))
struct PQXDHTests {
    struct Fixture {
        let alice: PQRCIdentity
        let aliceIKDH: Curve25519.KeyAgreement.PrivateKey
        let bob: PQRCIdentity
        let bobPrekeys: PrekeyManager
        let bundle: PrekeyBundle
    }

    /// Deterministic fixture: Bob's full prekey state + Alice's keys from seeds.
    static func fixture(
        aliceSeedByte: String, bobSeedByte: String, bobPrekeySeed: UInt64,
        oneTimeCount: Int, stripLRP: Bool
    ) async throws -> Fixture {
        let alice = try PQRCIdentity(seed: hexData(String(repeating: aliceSeedByte, count: 32)))
        let bob = try PQRCIdentity(seed: hexData(String(repeating: bobSeedByte, count: 32)))
        let aliceRandom = SeededRandomSource(seed: bobPrekeySeed &+ 999)
        let aliceIKDH = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: aliceRandom.bytes(32))
        let bobPrekeys = try PrekeyManager(
            identity: bob, randomSource: SeededRandomSource(seed: bobPrekeySeed),
            oneTimeCount: oneTimeCount
        )
        var bundle = try await bobPrekeys.publicBundle()
        if stripLRP {
            bundle = PrekeyBundle(
                identityPubkey: bundle.identityPubkey, ikDH: bundle.ikDH, spk: bundle.spk,
                pqpk: bundle.pqpk, otp: bundle.otp, otpPQ: bundle.otpPQ, lrp: nil
            )
        }
        return Fixture(
            alice: alice, aliceIKDH: aliceIKDH, bob: bob, bobPrekeys: bobPrekeys, bundle: bundle
        )
    }

    static func runHandshake(
        _ name: String, aliceSeedByte: String, bobSeedByte: String, bobPrekeySeed: UInt64,
        oneTimeCount: Int, stripLRP: Bool
    ) async throws -> PQXDHVector.Case {
        let fx = try await fixture(
            aliceSeedByte: aliceSeedByte, bobSeedByte: bobSeedByte, bobPrekeySeed: bobPrekeySeed,
            oneTimeCount: oneTimeCount, stripLRP: stripLRP
        )
        try fx.bundle.verifySignatures(identityPubkey: fx.bob.publicKeyData)
        let initiation = try PQXDH.initiate(
            myIdentity: fx.alice, myIdentityDH: fx.aliceIKDH,
            peerBundle: fx.bundle, randomSource: SeededRandomSource(seed: 4242)
        )
        let message = initiation.message
        return PQXDHVector.Case(
            name: name,
            aliceIdentitySeed: fx.alice.privateKey.rawRepresentation.hex,
            bobIdentitySeed: fx.bob.privateKey.rawRepresentation.hex,
            bobPrekeySeed: bobPrekeySeed,
            bobOneTimeCount: oneTimeCount,
            stripLRP: stripLRP,
            handshake: PQXDHVector.HandshakeWire(
                suite: message.suite, ik: message.ik.hex, ikDH: message.ikDH.hex,
                ek: message.ek.hex, kemCT: message.kemCT.hex, kemPK: message.kemPK.hex,
                spkUsed: message.spkUsed.hex, otpUsed: message.otpUsed?.hex,
                otpPQUsed: message.otpPQUsed?.hex, lrpUsed: message.lrpUsed
            ),
            sk: initiation.sharedSecret.rawData.hex,
            lrpUsed: message.lrpUsed,
            otpUsed: message.otpUsed != nil
        )
    }

    static func vector() async throws -> PQXDHVector {
        PQXDHVector(cases: [
            try await runHandshake(
                "with_otp", aliceSeedByte: "11", bobSeedByte: "22", bobPrekeySeed: 1001,
                oneTimeCount: 3, stripLRP: false),
            try await runHandshake(
                "without_otp_no_lrp", aliceSeedByte: "33", bobSeedByte: "44", bobPrekeySeed: 1002,
                oneTimeCount: 0, stripLRP: true),
            try await runHandshake(
                "lrp_fallback", aliceSeedByte: "55", bobSeedByte: "66", bobPrekeySeed: 1003,
                oneTimeCount: 0, stripLRP: false),
        ])
    }

    @Test func pqxdh_bothSidesDeriveSameSK_vectorFrozen() async throws {
        let vector: PQXDHVector = try await Vectors.loadOrGenerateAsync(
            "pqxdh_handshake.json", generate: Self.vector)
        for testCase in vector.cases {
            // Rebuild Bob's private prekey state from the frozen seeds and run the
            // responder path against the frozen handshake message.
            let fx = try await Self.fixture(
                aliceSeedByte: String(testCase.aliceIdentitySeed.prefix(2)),
                bobSeedByte: String(testCase.bobIdentitySeed.prefix(2)),
                bobPrekeySeed: testCase.bobPrekeySeed,
                oneTimeCount: testCase.bobOneTimeCount,
                stripLRP: testCase.stripLRP
            )
            let wire = testCase.handshake
            let message = HandshakeMessage(
                suite: wire.suite, ik: hexData(wire.ik), ikDH: hexData(wire.ikDH),
                ek: hexData(wire.ek), kemCT: hexData(wire.kemCT), kemPK: hexData(wire.kemPK),
                spkUsed: hexData(wire.spkUsed), otpUsed: wire.otpUsed.map(hexData),
                otpPQUsed: wire.otpPQUsed.map(hexData), lrpUsed: wire.lrpUsed
            )
            let consumed = try await fx.bobPrekeys.consume(
                spkUsed: message.spkUsed, otpUsed: message.otpUsed,
                otpPQUsed: message.otpPQUsed, lrpUsed: message.lrpUsed
            )
            let response = try PQXDH.respond(
                myIdentityPub: fx.bob.publicKeyData, consumed: consumed, message: message
            )
            #expect(
                response.sharedSecret.rawData.hex == testCase.sk,
                "case \(testCase.name): responder must derive the frozen SK")
            #expect(response.usedLastResort == testCase.lrpUsed)
        }
    }

    @Test func pqxdh_bothSidesDeriveSameSK_live() async throws {
        for (count, strip) in [(3, false), (0, true), (0, false)] {
            let fx = try await Self.fixture(
                aliceSeedByte: "77", bobSeedByte: "88", bobPrekeySeed: 2001,
                oneTimeCount: count, stripLRP: strip
            )
            let initiation = try PQXDH.initiate(
                myIdentity: fx.alice, myIdentityDH: fx.aliceIKDH,
                peerBundle: fx.bundle, randomSource: SystemRandomSource()
            )
            let consumed = try await fx.bobPrekeys.consume(
                spkUsed: initiation.message.spkUsed, otpUsed: initiation.message.otpUsed,
                otpPQUsed: initiation.message.otpPQUsed, lrpUsed: initiation.message.lrpUsed
            )
            let response = try PQXDH.respond(
                myIdentityPub: fx.bob.publicKeyData, consumed: consumed,
                message: initiation.message
            )
            #expect(initiation.sharedSecret == response.sharedSecret)
        }
    }

    /// Hybrid property: corrupting either leg alone changes SK (breaking one is insufficient).
    @Test func pqxdh_skDependsOnBothLegs() async throws {
        let fx = try await Self.fixture(
            aliceSeedByte: "99", bobSeedByte: "aa", bobPrekeySeed: 3001,
            oneTimeCount: 1, stripLRP: false
        )
        let initiation = try PQXDH.initiate(
            myIdentity: fx.alice, myIdentityDH: fx.aliceIKDH,
            peerBundle: fx.bundle, randomSource: SeededRandomSource(seed: 7)
        )
        // Corrupt only the KEM ciphertext: responder SK must differ (implicit
        // rejection in ML-KEM yields a different shared secret, not an error).
        var badCT = initiation.message.kemCT
        badCT[badCT.startIndex] ^= 0x01
        let corruptKEM = HandshakeMessage(
            suite: initiation.message.suite, ik: initiation.message.ik,
            ikDH: initiation.message.ikDH, ek: initiation.message.ek,
            kemCT: badCT, kemPK: initiation.message.kemPK,
            spkUsed: initiation.message.spkUsed, otpUsed: initiation.message.otpUsed,
            otpPQUsed: initiation.message.otpPQUsed, lrpUsed: initiation.message.lrpUsed
        )
        let consumedForKEM = try await fx.bobPrekeys.consume(
            spkUsed: corruptKEM.spkUsed, otpUsed: corruptKEM.otpUsed,
            otpPQUsed: corruptKEM.otpPQUsed, lrpUsed: corruptKEM.lrpUsed
        )
        let kemCorruptedResponse = try PQXDH.respond(
            myIdentityPub: fx.bob.publicKeyData, consumed: consumedForKEM, message: corruptKEM
        )
        #expect(kemCorruptedResponse.sharedSecret != initiation.sharedSecret)

        // Corrupt only a DH leg (swap the ephemeral key): SK must differ too.
        let fx2 = try await Self.fixture(
            aliceSeedByte: "99", bobSeedByte: "ab", bobPrekeySeed: 3002,
            oneTimeCount: 1, stripLRP: false
        )
        let initiation2 = try PQXDH.initiate(
            myIdentity: fx2.alice, myIdentityDH: fx2.aliceIKDH,
            peerBundle: fx2.bundle, randomSource: SeededRandomSource(seed: 8)
        )
        let otherEphemeral = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: SeededRandomSource(seed: 1234).bytes(32))
        let badDH = HandshakeMessage(
            suite: initiation2.message.suite, ik: initiation2.message.ik,
            ikDH: initiation2.message.ikDH,
            ek: otherEphemeral.publicKey.rawRepresentation,
            kemCT: initiation2.message.kemCT, kemPK: initiation2.message.kemPK,
            spkUsed: initiation2.message.spkUsed, otpUsed: initiation2.message.otpUsed,
            otpPQUsed: initiation2.message.otpPQUsed, lrpUsed: initiation2.message.lrpUsed
        )
        let consumedForDH = try await fx2.bobPrekeys.consume(
            spkUsed: badDH.spkUsed, otpUsed: badDH.otpUsed,
            otpPQUsed: badDH.otpPQUsed, lrpUsed: badDH.lrpUsed
        )
        let dhCorruptedResponse = try PQXDH.respond(
            myIdentityPub: fx2.bob.publicKeyData, consumed: consumedForDH, message: badDH
        )
        #expect(dhCorruptedResponse.sharedSecret != initiation2.sharedSecret)
    }

    @Test func handshake_consumedOneTimePrekeyIsDeleted_andReuseRejected() async throws {
        let fx = try await Self.fixture(
            aliceSeedByte: "bb", bobSeedByte: "cc", bobPrekeySeed: 4001,
            oneTimeCount: 1, stripLRP: false
        )
        let initiation = try PQXDH.initiate(
            myIdentity: fx.alice, myIdentityDH: fx.aliceIKDH,
            peerBundle: fx.bundle, randomSource: SeededRandomSource(seed: 9)
        )
        let message = initiation.message
        _ = try await fx.bobPrekeys.consume(
            spkUsed: message.spkUsed, otpUsed: message.otpUsed,
            otpPQUsed: message.otpPQUsed, lrpUsed: message.lrpUsed
        )
        // Second handshake referencing the same consumed one-time prekey fails.
        await #expect(throws: PQRCError.oneTimePrekeyAlreadyConsumed) {
            _ = try await fx.bobPrekeys.consume(
                spkUsed: message.spkUsed, otpUsed: message.otpUsed,
                otpPQUsed: nil, lrpUsed: false
            )
        }
        // The lrp fallback still succeeds afterwards and is flagged.
        let lrpConsumed = try await fx.bobPrekeys.consume(
            spkUsed: message.spkUsed, otpUsed: nil, otpPQUsed: nil, lrpUsed: true
        )
        #expect(lrpConsumed.usedLastResort)
    }

    @Test func prekeySignatures_verifyAgainstBinding_andRejectForeignSigner() async throws {
        let fx = try await Self.fixture(
            aliceSeedByte: "dd", bobSeedByte: "ee", bobPrekeySeed: 5001,
            oneTimeCount: 2, stripLRP: false
        )
        // Valid against Bob's identity.
        try fx.bundle.verifySignatures(identityPubkey: fx.bob.publicKeyData)
        // Rejected against a different identity key.
        let mallory = try PQRCIdentity(seed: hexData(String(repeating: "ff", count: 32)))
        #expect(throws: PQRCError.invalidPrekeySignature) {
            try fx.bundle.verifySignatures(identityPubkey: mallory.publicKeyData)
        }
        // Rejected when a key is re-signed by a foreign identity.
        let forged = PrekeyBundle(
            identityPubkey: fx.bundle.identityPubkey,
            ikDH: fx.bundle.ikDH,
            spk: PrekeyBundle.SignedKey(
                key: fx.bundle.spk.key,
                sig: try mallory.sign(
                    PrekeyBundle.prekeySignatureMessage(label: "spk", key: fx.bundle.spk.key))
            ),
            pqpk: fx.bundle.pqpk, otp: fx.bundle.otp, otpPQ: fx.bundle.otpPQ, lrp: fx.bundle.lrp
        )
        #expect(throws: PQRCError.invalidPrekeySignature) {
            try forged.verifySignatures(identityPubkey: fx.bob.publicKeyData)
        }
    }
}
