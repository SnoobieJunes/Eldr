// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import PQRCCore
@testable import PQRCNostr

/// Offline contact restore: the kind-10420 event captured at fetch time
/// re-verifies with no relay, and any tampering is rejected.
@Suite("Stored binding event re-verify", .tags(.security))
struct StoredBindingEventTests {
    private func fetched() async throws -> (PQRCMessenger, Persona, NostrEvent) {
        let relay = LocalRelaySimulator()
        let alice = try await Persona.make(
            name: "Alice", seedByte: "a1", seed: 1, transports: [await relay.connect()])
        let bob = try await Persona.make(
            name: "Bob", seedByte: "b1", seed: 2, transports: [await relay.connect()])
        try await bob.messenger.announce(relayURLs: ["local://relay"], maxAttempts: 2)
        let (contact, _) = try await alice.messenger.fetchVerifiedPeer(
            nostrPubkeyHex: bob.nostrKeypair.publicKeyHex)
        #expect(contact.identityHex == bob.identityHex)
        let event = try #require(
            await alice.messenger.verifiedBindingEvent(nostrPubkeyHex: bob.nostrKeypair.publicKeyHex))
        return (alice.messenger, bob, event)
    }

    @Test func storedEvent_roundTripsThroughJSON_andReverifiesOffline() async throws {
        let (_, bob, event) = try await fetched()
        let decoded = try JSONDecoder().decode(NostrEvent.self, from: JSONEncoder().encode(event))
        let restored = try VerifiedContact(storedBindingEvent: decoded)
        #expect(restored.identityHex == bob.identityHex)
        #expect(restored.nostrPubkeyHex == bob.nostrKeypair.publicKeyHex)
    }

    @Test func tamperedIdentityTag_isRejected() async throws {
        let (_, _, event) = try await fetched()
        var json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        var tags = try #require(json["tags"] as? [[String]])
        let i = try #require(tags.firstIndex { $0.first == "identity_key" })
        tags[i][1] = String(repeating: "ab", count: 32)
        json["tags"] = tags
        let forged = try JSONDecoder().decode(
            NostrEvent.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(throws: (any Error).self) { try VerifiedContact(storedBindingEvent: forged) }
    }

    @Test func unfetchedPeer_hasNoStoredEvent() async throws {
        let (alice, _, _) = try await fetched()
        #expect(await alice.verifiedBindingEvent(nostrPubkeyHex: String(repeating: "0", count: 64)) == nil)
    }
}

/// Background binding refresh: adopt only a newer, valid, SAME-identity binding.
@Suite("Binding refresh (no silent identity swap)", .tags(.security))
struct BindingRefreshTests {
    private func binding(
        identity: PQRCIdentity, signer: NostrKeypair, at t: Int64
    ) throws -> NostrEvent {
        try PQRCEvents.bindingEvent(
            binding: IdentityBinding.make(
                identity: identity, nostrPubkey: Data(hexString: signer.publicKeyHex)!),
            signer: signer, createdAt: t, randomSource: SeededRandomSource(seed: UInt64(t)))
    }
    private let idA = try! PQRCIdentity(seed: Data(repeating: 0xA1, count: 32))
    private let idB = try! PQRCIdentity(seed: Data(repeating: 0xB2, count: 32))
    private let kp = try! NostrKeypair(randomSource: SeededRandomSource(seed: 7))

    @Test func newerSameIdentity_isAdopted() throws {
        let old = try binding(identity: idA, signer: kp, at: 100)
        let new = try binding(identity: idA, signer: kp, at: 200)
        #expect(PQRCMessenger.evaluateBindingRefresh(stored: old, candidate: new) == .updated(new))
    }
    @Test func olderOrSame_isNotAdopted() throws {
        let cur = try binding(identity: idA, signer: kp, at: 200)
        let older = try binding(identity: idA, signer: kp, at: 100)
        #expect(PQRCMessenger.evaluateBindingRefresh(stored: cur, candidate: older) == .unchanged)
        #expect(PQRCMessenger.evaluateBindingRefresh(stored: cur, candidate: cur) == .unchanged)
    }
    @Test func differentIdentity_isFlaggedNotAdopted() throws {
        let old = try binding(identity: idA, signer: kp, at: 100)
        let swapped = try binding(identity: idB, signer: kp, at: 300)
        #expect(PQRCMessenger.evaluateBindingRefresh(stored: old, candidate: swapped)
            == .identityChanged(newIdentityHex: idB.publicKeyData.hexString))
    }
    @Test func forgedSignature_orOtherAuthor_isInvalid() throws {
        let old = try binding(identity: idA, signer: kp, at: 100)
        var forged = try binding(identity: idA, signer: kp, at: 300)
        forged.createdAt = 400  // breaks id + signature
        #expect(PQRCMessenger.evaluateBindingRefresh(stored: old, candidate: forged) == .invalid)
        let other = try NostrKeypair(randomSource: SeededRandomSource(seed: 8))
        let foreign = try binding(identity: idA, signer: other, at: 300)
        #expect(PQRCMessenger.evaluateBindingRefresh(stored: old, candidate: foreign) == .invalid)
    }

    /// Integration over the relay simulator: re-announcing (newer, same identity) is adopted;
    /// an identity swap under the same Nostr key is flagged and the old contact is kept.
    @Test func relayRefresh_adoptsNewer_flagsIdentitySwap() async throws {
        let relay = LocalRelaySimulator()
        let alice = try await Persona.make(
            name: "Alice", seedByte: "a1", seed: 1, transports: [await relay.connect()])
        let bob = try await Persona.make(
            name: "Bob", seedByte: "b1", seed: 2, transports: [await relay.connect()])
        try await bob.messenger.announce(relayURLs: ["local://relay"], maxAttempts: 2)
        _ = try await alice.messenger.fetchVerifiedPeer(nostrPubkeyHex: bob.nostrKeypair.publicKeyHex)
        let stored = try #require(
            await alice.messenger.verifiedBindingEvent(nostrPubkeyHex: bob.nostrKeypair.publicKeyHex))
        #expect(await alice.messenger.refreshContactBinding(stored: stored, timeout: .seconds(2)) == .unchanged)

        let pub = await relay.connect()
        let newer = try binding(identity: bob.identity, signer: bob.nostrKeypair, at: stored.createdAt + 10)
        _ = try await pub.publish(newer)
        #expect(await alice.messenger.refreshContactBinding(stored: stored, timeout: .seconds(2)) == .updated(newer))

        let swapped = try binding(identity: idB, signer: bob.nostrKeypair, at: stored.createdAt + 20)
        _ = try await pub.publish(swapped)
        let r = await alice.messenger.refreshContactBinding(stored: newer, timeout: .seconds(2))
        #expect(r == .identityChanged(newIdentityHex: idB.publicKeyData.hexString))
        // Old identity still the trusted contact.
        #expect(await alice.messenger.verifiedContact(identityHex: bob.identityHex) != nil)
        #expect(await alice.messenger.verifiedContact(identityHex: idB.publicKeyData.hexString) == nil)
    }
}
