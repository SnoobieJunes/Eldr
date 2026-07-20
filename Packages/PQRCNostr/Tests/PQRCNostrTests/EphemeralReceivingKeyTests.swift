// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import Testing

@testable import PQRCCore
@testable import PQRCNostr

/// Ephemeral receiving keys on the wire (SPEC §9.3, kind 10422): the gift-wrap
/// `p` tag becomes a rotating routing pseudonym, with strict backward compat in
/// BOTH directions (an old identity-p-tag sender still reaches a new receiver; a
/// new sender falls back to the identity p-tag when the peer has no key).
@Suite("Ephemeral receiving keys — wire (SPEC §9.3)", .tags(.envelope, .security))
struct EphemeralReceivingKeyTests {
    private static let ephemeralPTag = String(repeating: "cd", count: 32)

    private func wrap(
        _ recipient: NostrKeypair, sender: NostrKeypair, ephemeral: String? = nil
    ) throws -> NostrEvent {
        try GiftWrap.wrap(
            rumor: EnvelopeTests.sampleRumor(), sender: sender,
            recipientNostrPubkey: recipient.publicKeyHex, fuzzedTimestamp: 1_749_900_000,
            randomSource: SeededRandomSource(seed: 21), nonceSource: SeededRandomSource(seed: 22),
            recipientReceivingKey: ephemeral)
    }

    // MARK: - GiftWrap p-tag

    @Test func wrap_usesEphemeralPTag_whenProvided_identityWhenNot() throws {
        let (sender, recipient) = try EnvelopeTests.fixtureKeys()
        let withEphemeral = try wrap(recipient, sender: sender, ephemeral: Self.ephemeralPTag)
        #expect(withEphemeral.firstTagValue("p") == Self.ephemeralPTag)
        #expect(withEphemeral.firstTagValue("p") != recipient.publicKeyHex)

        // Default (nil) keeps the identity p-tag — byte-for-byte the old behavior.
        let withoutEphemeral = try wrap(recipient, sender: sender)
        #expect(withoutEphemeral.firstTagValue("p") == recipient.publicKeyHex)
    }

    @Test func unwrap_acceptsIdentityByDefault_andEphemeralViaPredicate() throws {
        let (sender, recipient) = try EnvelopeTests.fixtureKeys()
        let rumor = EnvelopeTests.sampleRumor()
        let ephemeralWrap = try wrap(recipient, sender: sender, ephemeral: Self.ephemeralPTag)

        // Default predicate rejects a non-identity p-tag (unchanged behavior).
        #expect(throws: NostrError.self) {
            _ = try GiftWrap.unwrap(ephemeralWrap, recipient: recipient)
        }
        // A predicate that accepts our own sub-key unwraps it — decryption still
        // uses the recipient's identity Nostr key (the sub-key is only routing).
        let unwrapped = try GiftWrap.unwrap(
            ephemeralWrap, recipient: recipient,
            acceptsReceivingPTag: { $0 == Self.ephemeralPTag })
        #expect(unwrapped.rumor == rumor)
        #expect(unwrapped.senderNostrPubkey == sender.publicKeyHex)

        // A foreign ephemeral p-tag the recipient does not own is rejected even
        // with a (non-matching) predicate.
        #expect(throws: NostrError.self) {
            _ = try GiftWrap.unwrap(
                ephemeralWrap, recipient: recipient,
                acceptsReceivingPTag: { $0 == "ff".repeatedHex(32) })
        }

        // An identity-p-tagged wrap still unwraps with the default predicate.
        let identityWrap = try wrap(recipient, sender: sender)
        #expect(try GiftWrap.unwrap(identityWrap, recipient: recipient).rumor == rumor)
    }

    // MARK: - kind-10422 event

    @Test func ephemeralReceivingKeyEvent_verifiesBothDirections() async throws {
        let identity = try PQRCIdentity(seed: hexData(String(repeating: "5a", count: 32)))
        let nostr = try NostrKeypair(privateKey: hexData(String(repeating: "5b", count: 32)))
        let manager = EphemeralKeyManager(identity: identity, randomSource: SeededRandomSource(seed: 1))
        let bundle = try await manager.getPublicBundle(for: identity.publicKeyData.hexString)

        let event = try PQRCEvents.ephemeralReceivingKeyEvent(
            key: bundle, signer: nostr, createdAt: 1_750_000_000,
            randomSource: SeededRandomSource(seed: 2))
        #expect(event.kind == PQRCConstants.ephemeralReceivingKeyEventKind)

        let verified = try PQRCEvents.verifyEphemeralReceivingKeyEvent(
            event, expectedIdentityPubkey: identity.publicKeyData)
        #expect(verified.publicKey == bundle.publicKey)
        #expect(verified.pTag == bundle.pTag)

        // Wrong expected identity → rejected (inner direction).
        #expect(throws: PQRCError.self) {
            _ = try PQRCEvents.verifyEphemeralReceivingKeyEvent(
                event, expectedIdentityPubkey: Data(repeating: 0x09, count: 32))
        }
        // Tampered outer event (BIP-340) → rejected.
        var tampered = event
        tampered.tags = tampered.tags.map { $0[0] == "epoch" ? ["epoch", "999"] : $0 }
        #expect(throws: PQRCError.self) {
            _ = try PQRCEvents.verifyEphemeralReceivingKeyEvent(
                tampered, expectedIdentityPubkey: identity.publicKeyData)
        }
    }

    // MARK: - Messenger: sender side (fetch + p-tag selection)

    @Test func sender_fetchesAndUsesEphemeralPTag_elseIdentityFallback() async throws {
        let relay = LocalRelaySimulator()
        let clock = FixedClock(now: 1_752_000_000)
        let alice = try await Persona.make(
            name: "alice", seedByte: "a1", seed: 31, transports: [await relay.connect()], clock: clock)
        let bob = try await Persona.make(
            name: "bob", seedByte: "b1", seed: 32, transports: [await relay.connect()], clock: clock)
        await alice.messenger.addContact(try bob.asContact())
        await bob.messenger.addContact(try alice.asContact())

        // Bob advertises an ephemeral receiving key.
        let bobEphemeral = EphemeralKeyManager(
            identity: bob.identity, randomSource: SeededRandomSource(seed: 200))
        try await bob.messenger.enableEphemeralReceivingKeys(bobEphemeral)
        let published = try await bob.messenger.publishReceivingKey(
            for: bob.identity.publicKeyData.hexString)

        // Alice fetches + verifies it, then sends — the wrap carries the sub-key,
        // never Bob's identity npub.
        let fetched = await alice.messenger.fetchEphemeralReceivingKey(
            peerNostrPubkeyHex: bob.nostrKeypair.publicKeyHex,
            peerIdentityPubkey: bob.identity.publicKeyData)
        #expect(fetched == published.pTag)

        let bundle = try await bob.prekeyManager.publicBundle()
        try await alice.messenger.establishSession(
            with: try bob.asContact(), bundle: bundle,
            firstMessage: MessageBody(text: "hi", sentAt: clock.now()))

        let wraps = await relay.storedEvents(kind: PQRCConstants.giftWrapEventKind)
        #expect(wraps.count == 1)
        #expect(wraps.first?.firstTagValue("p") == published.pTag)
        #expect(wraps.first?.firstTagValue("p") != bob.nostrKeypair.publicKeyHex)
    }

    @Test func sender_fallsBackToIdentityPTag_whenPeerHasNoKey() async throws {
        let relay = LocalRelaySimulator()
        let clock = FixedClock(now: 1_752_000_000)
        let alice = try await Persona.make(
            name: "alice", seedByte: "a2", seed: 41, transports: [await relay.connect()], clock: clock)
        let bob = try await Persona.make(
            name: "bob", seedByte: "b2", seed: 42, transports: [await relay.connect()], clock: clock)
        await alice.messenger.addContact(try bob.asContact())
        await bob.messenger.addContact(try alice.asContact())

        // No 10422 published; fetch misses (bounded), and the send uses identity.
        let fetched = await alice.messenger.fetchEphemeralReceivingKey(
            peerNostrPubkeyHex: bob.nostrKeypair.publicKeyHex,
            peerIdentityPubkey: bob.identity.publicKeyData, timeout: .milliseconds(200))
        #expect(fetched == nil)

        let bundle = try await bob.prekeyManager.publicBundle()
        try await alice.messenger.establishSession(
            with: try bob.asContact(), bundle: bundle,
            firstMessage: MessageBody(text: "hi", sentAt: clock.now()))

        let wraps = await relay.storedEvents(kind: PQRCConstants.giftWrapEventKind)
        #expect(wraps.first?.firstTagValue("p") == bob.nostrKeypair.publicKeyHex)
    }

    // MARK: - Messenger: receiver side (dual-subscribe, both directions)

    @Test func newSender_reachesNewReceiver_viaEphemeralPTag() async throws {
        // Public relay (no anchor gating): ephemeral receiving keys cannot work
        // with an anchor relay that ties kind-1059 delivery to AUTH-as-recipient
        // (the X25519 sub-key is not a Nostr keypair) — see DEVIATIONS T4.
        let relay = LocalRelaySimulator(anchorGating: false)
        let clock = FixedClock(now: 1_752_000_000)
        let alice = try await Persona.make(
            name: "alice", seedByte: "a3", seed: 51, transports: [await relay.connect()], clock: clock)
        let bob = try await Persona.make(
            name: "bob", seedByte: "b3", seed: 52, transports: [await relay.connect()], clock: clock)
        await alice.messenger.addContact(try bob.asContact())
        await bob.messenger.addContact(try alice.asContact())

        let bobEphemeral = EphemeralKeyManager(
            identity: bob.identity, randomSource: SeededRandomSource(seed: 201))
        try await bob.messenger.enableEphemeralReceivingKeys(bobEphemeral)
        _ = try await bob.messenger.publishReceivingKey(for: bob.identity.publicKeyData.hexString)

        let bobEvents = EventCollector()
        await bobEvents.attach(try await bob.messenger.start())  // dual-subscribe: identity + ephemeral

        _ = await alice.messenger.fetchEphemeralReceivingKey(
            peerNostrPubkeyHex: bob.nostrKeypair.publicKeyHex,
            peerIdentityPubkey: bob.identity.publicKeyData)
        let bundle = try await bob.prekeyManager.publicBundle()
        try await alice.messenger.establishSession(
            with: try bob.asContact(), bundle: bundle,
            firstMessage: MessageBody(text: "ephemeral hello", sentAt: clock.now()))

        let received = await bobEvents.waitForMessages(1)
        #expect(received.count == 1)
        #expect(received.first?.body.text == "ephemeral hello")
        await bobEvents.stop()
    }

    @Test func oldSender_stillReachesNewReceiver_viaIdentityPTag() async throws {
        // Backward compat, the other direction: Alice never fetches (identity
        // p-tag), Bob has ephemeral keys on; the dual-subscribe still covers the
        // identity p-tag so the message lands.
        let relay = LocalRelaySimulator(anchorGating: false)
        let clock = FixedClock(now: 1_752_000_000)
        let alice = try await Persona.make(
            name: "alice", seedByte: "a4", seed: 61, transports: [await relay.connect()], clock: clock)
        let bob = try await Persona.make(
            name: "bob", seedByte: "b4", seed: 62, transports: [await relay.connect()], clock: clock)
        await alice.messenger.addContact(try bob.asContact())
        await bob.messenger.addContact(try alice.asContact())

        let bobEphemeral = EphemeralKeyManager(
            identity: bob.identity, randomSource: SeededRandomSource(seed: 202))
        try await bob.messenger.enableEphemeralReceivingKeys(bobEphemeral)
        _ = try await bob.messenger.publishReceivingKey(for: bob.identity.publicKeyData.hexString)

        let bobEvents = EventCollector()
        await bobEvents.attach(try await bob.messenger.start())

        // Alice does NOT fetch → identity p-tag.
        let bundle = try await bob.prekeyManager.publicBundle()
        try await alice.messenger.establishSession(
            with: try bob.asContact(), bundle: bundle,
            firstMessage: MessageBody(text: "legacy hello", sentAt: clock.now()))

        let received = await bobEvents.waitForMessages(1)
        #expect(received.count == 1)
        #expect(received.first?.body.text == "legacy hello")
        let wraps = await relay.storedEvents(kind: PQRCConstants.giftWrapEventKind)
        #expect(wraps.first?.firstTagValue("p") == bob.nostrKeypair.publicKeyHex)
        await bobEvents.stop()
    }
}

extension String {
    /// Test helper: an N-byte lowercase-hex string from a 2-char byte literal.
    fileprivate func repeatedHex(_ count: Int) -> String { String(repeating: self, count: count) }
}
