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
        let ikDHSig: String
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
                ikDHSig: message.ikDHSig.hex, ek: message.ek.hex, kemCT: message.kemCT.hex, kemPK: message.kemPK.hex,
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
                ikDHSig: hexData(wire.ikDHSig), ek: hexData(wire.ek), kemCT: hexData(wire.kemCT), kemPK: hexData(wire.kemPK),
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
            ikDH: initiation.message.ikDH, ikDHSig: initiation.message.ikDHSig,
            ek: initiation.message.ek, kemCT: badCT, kemPK: initiation.message.kemPK,
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
            ikDH: initiation2.message.ikDH, ikDHSig: initiation2.message.ikDHSig,
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

    // MARK: - Identity binding (the ik → ik_dh gap)

    /// The attack this closes: Mallory runs an ordinary handshake with her OWN
    /// keys, then rewrites `ik` to name Alice and recomputes SK from inputs she
    /// wholly controls. Every DH leg still checks out, so the responder derives
    /// a secret Mallory knows in full and files the session under Alice's name.
    /// The gift-wrap seal signature blocks this at the transport, but `respond`
    /// must not depend on a check two layers away in another package.
    @Test func handshake_rewrittenIdentity_isRejected() async throws {
        let fx = try await Self.fixture(
            aliceSeedByte: "a1", bobSeedByte: "b1", bobPrekeySeed: 7001,
            oneTimeCount: 2, stripLRP: false)
        let mallory = try PQRCIdentity(seed: hexData(String(repeating: "ee", count: 32)))
        let malloryIKDH = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: SeededRandomSource(seed: 777).bytes(32))
        let honest = try PQXDH.initiate(
            myIdentity: mallory, myIdentityDH: malloryIKDH,
            peerBundle: fx.bundle, randomSource: SeededRandomSource(seed: 778))
        let m = honest.message
        let forged = HandshakeMessage(
            suite: m.suite, ik: fx.alice.publicKeyData,   // <- Alice's name…
            ikDH: m.ikDH, ikDHSig: m.ikDHSig,             // …on Mallory's keys
            ek: m.ek, kemCT: m.kemCT, kemPK: m.kemPK, spkUsed: m.spkUsed,
            otpUsed: m.otpUsed, otpPQUsed: m.otpPQUsed, lrpUsed: m.lrpUsed)

        #expect(throws: PQRCError.initiatorIdentityUnverified) { try forged.validate() }
        let consumed = try await fx.bobPrekeys.consume(
            spkUsed: m.spkUsed, otpUsed: m.otpUsed,
            otpPQUsed: m.otpPQUsed, lrpUsed: m.lrpUsed)
        #expect(throws: PQRCError.initiatorIdentityUnverified) {
            _ = try PQXDH.respond(
                myIdentityPub: fx.bob.publicKeyData, consumed: consumed, message: forged)
        }
    }

    @Test func handshake_reportsTheIdentityItVerified() async throws {
        let fx = try await Self.fixture(
            aliceSeedByte: "a2", bobSeedByte: "b2", bobPrekeySeed: 7002,
            oneTimeCount: 2, stripLRP: false)
        let initiation = try PQXDH.initiate(
            myIdentity: fx.alice, myIdentityDH: fx.aliceIKDH,
            peerBundle: fx.bundle, randomSource: SeededRandomSource(seed: 7003))
        let consumed = try await fx.bobPrekeys.consume(initiation.message)
        let response = try PQXDH.respond(
            myIdentityPub: fx.bob.publicKeyData, consumed: consumed, message: initiation.message)
        #expect(response.sharedSecret == initiation.sharedSecret)
        // This — not the raw `ik` — is what the messenger compares to the binding.
        #expect(response.initiatorIdentityPub == fx.alice.publicKeyData)
    }

    @Test func handshake_tamperedBindingSignature_isRejected() async throws {
        let fx = try await Self.fixture(
            aliceSeedByte: "a3", bobSeedByte: "b3", bobPrekeySeed: 7004,
            oneTimeCount: 2, stripLRP: false)
        let m = try PQXDH.initiate(
            myIdentity: fx.alice, myIdentityDH: fx.aliceIKDH,
            peerBundle: fx.bundle, randomSource: SeededRandomSource(seed: 7005)).message
        var badSig = m.ikDHSig
        badSig[badSig.startIndex] ^= 0x01
        let tampered = HandshakeMessage(
            suite: m.suite, ik: m.ik, ikDH: m.ikDH, ikDHSig: badSig, ek: m.ek,
            kemCT: m.kemCT, kemPK: m.kemPK, spkUsed: m.spkUsed,
            otpUsed: m.otpUsed, otpPQUsed: m.otpPQUsed, lrpUsed: m.lrpUsed)
        #expect(throws: PQRCError.initiatorIdentityUnverified) { try tampered.validate() }
    }

    // MARK: - The fourth DH leg (SPEC §4.2)

    /// dh2 = DH(EK_A, IK_B) is the only leg needing the RESPONDER's long-term
    /// key. Without it, everything on Bob's side hangs off the medium-lived
    /// `spk`, so a leaked signed prekey alone impersonates him to every
    /// initiator working from his published bundle. One message, one set of
    /// prekeys, only `ik_dh` moves.
    @Test func sharedSecret_dependsOnResponderIdentityKey() async throws {
        let fx = try await Self.fixture(
            aliceSeedByte: "d1", bobSeedByte: "d2", bobPrekeySeed: 7009,
            oneTimeCount: 1, stripLRP: false)
        let initiation = try PQXDH.initiate(
            myIdentity: fx.alice, myIdentityDH: fx.aliceIKDH,
            peerBundle: fx.bundle, randomSource: SeededRandomSource(seed: 5150))
        let real = try await fx.bobPrekeys.consume(initiation.message)
        let honest = try PQXDH.respond(
            myIdentityPub: fx.bob.publicKeyData, consumed: real, message: initiation.message)
        #expect(honest.sharedSecret == initiation.sharedSecret)

        let impostorIKDH = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: SeededRandomSource(seed: 90210).bytes(32))
        let swapped = PrekeyManager.ConsumedPrekeys(
            ikDH: impostorIKDH, spk: real.spk, otp: real.otp, otpPQ: real.otpPQ,
            pqpk: real.pqpk, usedLastResort: real.usedLastResort)
        let wrong = try PQXDH.respond(
            myIdentityPub: fx.bob.publicKeyData, consumed: swapped, message: initiation.message)
        #expect(
            wrong.sharedSecret != initiation.sharedSecret,
            "SK ignores the responder's identity key — PQXDH's dh2 leg is missing")
    }

    // MARK: - Prekey pool integrity (invariant 11)

    /// A real, published `otp_used` paired with a garbage `otp_pq_used`. If the
    /// DH half is deleted before the PQ half is resolved, every such message
    /// costs the responder a one-time prekey and the sender nothing.
    @Test func rejectedHandshake_burnsNoOneTimePrekey() async throws {
        let fx = try await Self.fixture(
            aliceSeedByte: "f1", bobSeedByte: "f2", bobPrekeySeed: 7010,
            oneTimeCount: 3, stripLRP: false)
        let m = try PQXDH.initiate(
            myIdentity: fx.alice, myIdentityDH: fx.aliceIKDH,
            peerBundle: fx.bundle, randomSource: SeededRandomSource(seed: 7011)).message

        let before = await fx.bobPrekeys.oneTimePrekeyCount
        await #expect(throws: PQRCError.unknownPrekey) {
            _ = try await fx.bobPrekeys.consume(
                spkUsed: m.spkUsed, otpUsed: m.otpUsed,
                otpPQUsed: Data(repeating: 0xFF, count: 32), lrpUsed: false)
        }
        let after = await fx.bobPrekeys.oneTimePrekeyCount
        #expect(after == before, "a rejected handshake must not consume a prekey")

        // …and the genuine handshake still resolves afterwards.
        let consumed = try await fx.bobPrekeys.consume(m)
        #expect(consumed.otp != nil)
    }

    /// `consume(_:)` validates first, so the ordering cannot be got wrong even
    /// by a caller who never thought about it.
    @Test func consumeMessage_validatesBeforeSpending() async throws {
        let fx = try await Self.fixture(
            aliceSeedByte: "c9", bobSeedByte: "ca", bobPrekeySeed: 7030,
            oneTimeCount: 3, stripLRP: false)
        let mallory = try PQRCIdentity(seed: hexData(String(repeating: "3b", count: 32)))
        let malloryIKDH = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: SeededRandomSource(seed: 7031).bytes(32))
        let honest = try PQXDH.initiate(
            myIdentity: mallory, myIdentityDH: malloryIKDH,
            peerBundle: fx.bundle, randomSource: SeededRandomSource(seed: 7032))
        let m = honest.message
        let forged = HandshakeMessage(
            suite: m.suite, ik: fx.alice.publicKeyData, ikDH: m.ikDH, ikDHSig: m.ikDHSig,
            ek: m.ek, kemCT: m.kemCT, kemPK: m.kemPK, spkUsed: m.spkUsed,
            otpUsed: m.otpUsed, otpPQUsed: m.otpPQUsed, lrpUsed: m.lrpUsed)

        let before = await fx.bobPrekeys.oneTimePrekeyCount
        await #expect(throws: PQRCError.initiatorIdentityUnverified) {
            _ = try await fx.bobPrekeys.consume(forged)
        }
        #expect(await fx.bobPrekeys.oneTimePrekeyCount == before)
    }

    @Test func contradictoryPrekeyClaim_isRejected() async throws {
        let fx = try await Self.fixture(
            aliceSeedByte: "f3", bobSeedByte: "f4", bobPrekeySeed: 7012,
            oneTimeCount: 2, stripLRP: false)
        let m = try PQXDH.initiate(
            myIdentity: fx.alice, myIdentityDH: fx.aliceIKDH,
            peerBundle: fx.bundle, randomSource: SeededRandomSource(seed: 7013)).message
        #expect(m.otpUsed != nil)
        // dh4 has exactly one source; claiming both hides which key was used.
        await #expect(throws: PQRCError.handshakeMalformed) {
            _ = try await fx.bobPrekeys.consume(
                spkUsed: m.spkUsed, otpUsed: m.otpUsed, otpPQUsed: nil, lrpUsed: true)
        }
    }

    /// A kind-10421 bundle carries the whole pool, so every initiator picks for
    /// itself. Taking `otp.first` made any two initiators collide, and the
    /// second one's handshake died at `consume` — their message silently never
    /// arrived and they saw no error.
    @Test func oneTimePrekeySelection_isSpreadAcrossInitiators() async throws {
        let fx = try await Self.fixture(
            aliceSeedByte: "f5", bobSeedByte: "f6", bobPrekeySeed: 7014,
            oneTimeCount: 16, stripLRP: false)
        var chosen = Set<Data>()
        for seed in UInt64(8000)..<UInt64(8008) {
            let m = try PQXDH.initiate(
                myIdentity: fx.alice, myIdentityDH: fx.aliceIKDH,
                peerBundle: fx.bundle, randomSource: SeededRandomSource(seed: seed)).message
            chosen.insert(try #require(m.otpUsed))
        }
        #expect(chosen.count > 1, "every initiator chose the same one-time prekey")
    }

}
