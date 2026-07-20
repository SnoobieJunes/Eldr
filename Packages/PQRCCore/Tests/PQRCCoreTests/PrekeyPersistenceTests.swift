// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import Testing

@testable import PQRCCore

/// Prekey-state persistence (T2): a restored manager must serve the same
/// bundle, resolve handshakes addressed to pre-restart prekeys, and keep
/// rejecting consumed ones forever.
@Suite("Prekey persistence (T2)", .tags(.crypto))
struct PrekeyPersistenceTests {
    private func makeManager(
        seed: UInt64
    ) throws -> (identity: PQRCIdentity, manager: PrekeyManager, random: SeededRandomSource) {
        let random = SeededRandomSource(seed: seed)
        let identity = try PQRCIdentity(seed: random.bytes(32))
        let manager = try PrekeyManager(identity: identity, randomSource: random, oneTimeCount: 4)
        return (identity, manager, random)
    }

    @Test func snapshotRestore_publishesIdenticalBundle() async throws {
        let (identity, manager, random) = try makeManager(seed: 41)
        let original = try await manager.publicBundle()
        let state = await manager.snapshot()

        let restored = try PrekeyManager(
            identity: identity, randomSource: random,
            state: try JSONDecoder().decode(
                PrekeyState.self, from: try JSONEncoder().encode(state)))
        let republished = try await restored.publicBundle()

        // Same public keys after a JSON round trip (signatures are fresh but
        // verify against the same identity).
        #expect(republished.spk.key == original.spk.key)
        #expect(republished.pqpk.key == original.pqpk.key)
        #expect(republished.otp == original.otp)
        #expect(republished.otpPQ == original.otpPQ)
        #expect(republished.lrp?.key == original.lrp?.key)
        try republished.verifySignatures(identityPubkey: identity.publicKeyData)
    }

    @Test func restoredManager_resolvesPreRestartHandshake_andKeepsReuseRejected() async throws {
        let (bobIdentity, bobManager, bobRandom) = try makeManager(seed: 42)
        let aliceRandom = SeededRandomSource(seed: 43)
        let aliceIdentity = try PQRCIdentity(seed: aliceRandom.bytes(32))
        let aliceDH = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: aliceRandom.bytes(32))

        // Alice initiates against Bob's published bundle (pre-"restart").
        let bundle = try await bobManager.publicBundle()
        let initiation = try PQXDH.initiate(
            myIdentity: aliceIdentity, myIdentityDH: aliceDH, peerBundle: bundle,
            randomSource: aliceRandom)
        let handshake = initiation.message

        // Bob "relaunches": restore a manager from the persisted snapshot.
        let state = await bobManager.snapshot()
        let restored = try PrekeyManager(
            identity: bobIdentity, randomSource: bobRandom, state: state)

        // The pre-restart handshake resolves and both sides agree on SK.
        let consumed = try await restored.consume(
            spkUsed: handshake.spkUsed, otpUsed: handshake.otpUsed,
            otpPQUsed: handshake.otpPQUsed, lrpUsed: handshake.lrpUsed)
        let response = try PQXDH.respond(
            myIdentityPub: bobIdentity.publicKeyData, consumed: consumed, message: handshake)
        #expect(response.sharedSecret == initiation.sharedSecret)

        // Consumption persists: a snapshot taken AFTER the consume keeps the
        // replayed handshake rejected in the next "launch" too.
        let postConsume = await restored.snapshot()
        let secondRestore = try PrekeyManager(
            identity: bobIdentity, randomSource: bobRandom, state: postConsume)
        await #expect(throws: PQRCError.self) {
            _ = try await secondRestore.consume(
                spkUsed: handshake.spkUsed, otpUsed: handshake.otpUsed,
                otpPQUsed: handshake.otpPQUsed, lrpUsed: handshake.lrpUsed)
        }
    }

    @Test func replenish_topsUpPools_withoutForgettingConsumed() async throws {
        let (bobIdentity, bobManager, bobRandom) = try makeManager(seed: 44)
        let aliceRandom = SeededRandomSource(seed: 45)
        let aliceIdentity = try PQRCIdentity(seed: aliceRandom.bytes(32))
        let aliceDH = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: aliceRandom.bytes(32))
        let bundle = try await bobManager.publicBundle()
        let handshake = try PQXDH.initiate(
            myIdentity: aliceIdentity, myIdentityDH: aliceDH, peerBundle: bundle,
            randomSource: aliceRandom
        ).message
        _ = try await bobManager.consume(
            spkUsed: handshake.spkUsed, otpUsed: handshake.otpUsed,
            otpPQUsed: handshake.otpPQUsed, lrpUsed: handshake.lrpUsed)
        let countAfterConsume = await bobManager.oneTimePrekeyCount
        #expect(countAfterConsume == 3)

        #expect(try await bobManager.replenish(to: 8))
        #expect(await bobManager.oneTimePrekeyCount == 8)

        // Replenishment is not amnesia: the consumed prekey stays rejected.
        let restored = try PrekeyManager(
            identity: bobIdentity, randomSource: bobRandom,
            state: await bobManager.snapshot())
        await #expect(throws: PQRCError.self) {
            _ = try await restored.consume(
                spkUsed: handshake.spkUsed, otpUsed: handshake.otpUsed,
                otpPQUsed: handshake.otpPQUsed, lrpUsed: handshake.lrpUsed)
        }
    }
}
