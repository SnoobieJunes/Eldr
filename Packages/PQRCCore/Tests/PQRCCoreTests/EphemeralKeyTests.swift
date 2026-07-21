// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import Testing

@testable import PQRCCore

/// Ephemeral receiving keys (SPEC §9.3, kind 10422). The sub-key is a relay-visible
/// routing pseudonym only; these tests pin the derivation, the message-driven
/// rotation (with jitter, NEVER wall-clock — invariant 1), the both-directions
/// identity binding, and persistence.
@Suite("Ephemeral receiving keys (SPEC §9.3)", .tags(.crypto, .security))
struct EphemeralKeyTests {
    private func identity(_ seed: UInt64) throws -> PQRCIdentity {
        try PQRCIdentity(seed: SeededRandomSource(seed: seed).bytes(32))
    }

    @Test func hkdfDerivation_isDeterministicAcrossInstances() async throws {
        let id = try identity(1)
        let a = EphemeralKeyManager(identity: id, randomSource: SeededRandomSource(seed: 7))
        let b = EphemeralKeyManager(identity: id, randomSource: SeededRandomSource(seed: 99))

        // Same identity + conversation + epoch → same public sub-key, regardless of
        // the RandomSource (which only drives rotation jitter, not derivation).
        let pa = try await a.currentPTag(for: "conv-x")
        let pb = try await b.currentPTag(for: "conv-x")
        #expect(pa == pb)
        #expect(Data(hexString: pa)?.count == 32)

        // Different conversations derive distinct sub-keys.
        let other = try await a.currentPTag(for: "conv-y")
        #expect(other != pa)

        // A different identity derives a different key for the same conversation.
        let c = EphemeralKeyManager(identity: try identity(2), randomSource: SeededRandomSource(seed: 7))
        #expect(try await c.currentPTag(for: "conv-x") != pa)
    }

    @Test func rotation_isMessageDriven_withJitterInRange() async throws {
        let id = try identity(3)
        // base 25 ± 5 → thresholds land in [20, 30]; rotation is driven only by the
        // message count handed in, never by a clock.
        let mgr = EphemeralKeyManager(
            identity: id, randomSource: SeededRandomSource(seed: 5),
            rotationBase: 25, rotationJitter: 5)

        // Below the (jittered) threshold: never rotate; at/above: rotate.
        #expect(try await mgr.shouldPublishNewKey(messageCount: 19, for: "c") == false)
        var firstThreshold = 20
        while try await mgr.shouldPublishNewKey(messageCount: firstThreshold, for: "c") == false {
            firstThreshold += 1
            #expect(firstThreshold <= 30, "threshold must be within base ± jitter")
        }
        #expect((20...30).contains(firstThreshold))

        let before = try await mgr.currentPTag(for: "c")
        let rotated = try await mgr.rotate(for: "c")
        let after = try await mgr.currentPTag(for: "c")
        #expect(rotated.epoch == 1)
        #expect(after != before, "rotation must change the advertised sub-key")
        // The previous epoch stays accepted during the changeover.
        #expect(await mgr.acceptedPTags(for: "c").contains(before))
        #expect(await mgr.acceptedPTags(for: "c").contains(after))
    }

    @Test func rotation_usesNoClock() async throws {
        // Determinism proof for invariant 1: two managers with identical seeds and
        // identical message-count inputs make identical rotation decisions, with no
        // wall-clock anywhere in the type.
        let id = try identity(11)
        let a = EphemeralKeyManager(identity: id, randomSource: SeededRandomSource(seed: 42))
        let b = EphemeralKeyManager(identity: id, randomSource: SeededRandomSource(seed: 42))
        for n in 0...40 {
            #expect(
                try await a.shouldPublishNewKey(messageCount: n, for: "c")
                    == b.shouldPublishNewKey(messageCount: n, for: "c"))
        }
    }

    @Test func getPublicBundle_isSignedAndVerifies_bothDirectionsInner() async throws {
        let id = try identity(4)
        let mgr = EphemeralKeyManager(identity: id, randomSource: SeededRandomSource(seed: 1))
        let bundle = try await mgr.getPublicBundle(for: "conv")

        #expect(bundle.identityPubkey == id.publicKeyData)
        #expect(bundle.epoch == 0)
        #expect(bundle.conversationBinding == "conv")
        #expect(EphemeralReceivingKey.isValidEphemeralKey(bundle, identityPubkey: id.publicKeyData))
        // Wrong expected identity is rejected.
        let other = try identity(5)
        #expect(
            !EphemeralReceivingKey.isValidEphemeralKey(
                bundle, identityPubkey: other.publicKeyData))
    }

    @Test func badSignatureEphemeralKey_isRejected() async throws {
        let id = try identity(6)
        let mgr = EphemeralKeyManager(identity: id, randomSource: SeededRandomSource(seed: 2))
        let good = try await mgr.getPublicBundle(for: "conv")

        // Tampered signature.
        var badSig = good.signature
        badSig[0] ^= 0xFF
        let forgedSig = EphemeralReceivingKey(
            identityPubkey: good.identityPubkey, publicKey: good.publicKey,
            conversationBinding: good.conversationBinding, epoch: good.epoch, signature: badSig)
        #expect(
            !EphemeralReceivingKey.isValidEphemeralKey(forgedSig, identityPubkey: id.publicKeyData))

        // Substituted sub-key under the same (now stale) signature.
        var swappedPub = good.publicKey
        swappedPub[0] ^= 0xFF
        let forgedKey = EphemeralReceivingKey(
            identityPubkey: good.identityPubkey, publicKey: swappedPub,
            conversationBinding: good.conversationBinding, epoch: good.epoch,
            signature: good.signature)
        #expect(
            !EphemeralReceivingKey.isValidEphemeralKey(forgedKey, identityPubkey: id.publicKeyData))

        // An attacker re-signing with their OWN identity but claiming the victim's
        // identity pubkey fails (the sig won't verify under the claimed key).
        let attacker = EphemeralKeyManager(
            identity: try identity(7), randomSource: SeededRandomSource(seed: 3))
        let attackerKey = try await attacker.getPublicBundle(for: "conv")
        let impersonation = EphemeralReceivingKey(
            identityPubkey: id.publicKeyData, publicKey: attackerKey.publicKey,
            conversationBinding: attackerKey.conversationBinding, epoch: attackerKey.epoch,
            signature: attackerKey.signature)
        #expect(
            !EphemeralReceivingKey.isValidEphemeralKey(impersonation, identityPubkey: id.publicKeyData))
    }

    @Test func snapshotRestore_reDerivesSamePublicValues() async throws {
        let id = try identity(8)
        let mgr = EphemeralKeyManager(identity: id, randomSource: SeededRandomSource(seed: 4))
        _ = try await mgr.getPublicBundle(for: "alpha")
        _ = try await mgr.rotate(for: "alpha")
        _ = try await mgr.getPublicBundle(for: "beta")
        let snap = await mgr.snapshot()

        // JSON round-trip (the app persists this) then restore into a fresh manager.
        let encoded = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode([String: EphemeralKeyEpoch].self, from: encoded)
        let restored = EphemeralKeyManager(identity: id, randomSource: SeededRandomSource(seed: 4))
        try await restored.restore(decoded)

        #expect(try await restored.currentPTag(for: "alpha") == mgr.currentPTag(for: "alpha"))
        #expect(try await restored.currentPTag(for: "beta") == mgr.currentPTag(for: "beta"))
        // The accepted set (current + previous) survives, so re-subscribe still
        // covers in-flight traffic to the pre-restart key.
        #expect(await restored.allAcceptedPTags() == mgr.allAcceptedPTags())
        // Stored hex matches the re-derived value (cross-check).
        #expect(decoded["alpha"]?.currentPTag == (try await mgr.currentPTag(for: "alpha")))
    }
}
