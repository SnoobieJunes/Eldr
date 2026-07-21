// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import PQRCCore

/// NIP-59 three-layer gift wrap (SPEC §8): rumor (unsigned) → seal (kind 13,
/// sender-signed) → wrap (kind 1059, fresh random one-time key).
///
/// The relay-visible surface is exactly: kind 1059, a fuzzed `created_at`, the
/// recipient `p` tag, and a random pubkey. Never the sender, never content.
public enum GiftWrap {
    public struct Unwrapped: Sendable {
        public let rumor: RumorContent
        /// Sender's Nostr pubkey, revealed only after unsealing on-device.
        public let senderNostrPubkey: String
        /// The fuzzed timestamp (= AD component, = seal/wrap created_at).
        public let fuzzedTimestamp: Int64
        /// The wrap event id (relay-level dedupe key).
        public let wrapEventID: String
    }

    /// Builds the inner two layers only: rumor (unsigned) → seal (kind 13,
    /// sender-signed, encrypted to the recipient).
    ///
    /// This is the unit the local link ships directly (SPEC §10): on a
    /// point-to-point link there is no relay to hide the sender from, so the
    /// outer kind-1059 wrap is unnecessary — but the seal stays, because it is
    /// what provides sender authenticity and keeps rumor metadata confidential
    /// against a man-in-the-middle on the local radio link.
    public static func seal(
        rumor: RumorContent,
        sender: NostrKeypair,
        recipientNostrPubkey: String,
        fuzzedTimestamp: Int64,
        randomSource: any RandomSource,
        nonceSource: any NonceSource
    ) throws -> NostrEvent {
        // 1. Rumor: unsigned kind-1420 event. Never published unwrapped.
        let rumorJSON = try WireJSON.encoder().encode(rumor)
        let rumorEvent = NostrEvent(
            pubkey: sender.publicKeyHex,
            createdAt: fuzzedTimestamp,
            kind: PQRCConstants.rumorEventKind,
            tags: [],
            content: String(decoding: rumorJSON, as: UTF8.self)
        )
        // 2. Seal: rumor encrypted to the recipient, signed by the sender's
        //    real Nostr key. Tags MUST be empty (SPEC §8.1).
        let rumorEventJSON = try WireJSON.encoder().encode(rumorEvent)
        let sealContent = try SealCipher.encrypt(
            rumorEventJSON, privateKey: sender.privateKeyData,
            peerPublicKeyHex: recipientNostrPubkey, nonceSource: nonceSource)
        return try sender.sign(
            NostrEvent(
                pubkey: sender.publicKeyHex,
                createdAt: fuzzedTimestamp,
                kind: PQRCConstants.sealEventKind,
                tags: [],
                content: sealContent
            ), randomSource: randomSource)
    }

    /// Wraps one rumor for one recipient. The same fuzzed timestamp the sender
    /// committed into the AEAD AD is used for both seal and wrap `created_at`
    /// (APP-SPEC §2; test fuzz_sameValueUsedInADandWrap).
    ///
    /// `recipientReceivingKey` (SPEC §9.3, kind 10422): when the sender has
    /// fetched the recipient's rotating ephemeral receiving sub-key, it is used as
    /// the relay-visible `p` tag instead of the recipient's identity Nostr pubkey,
    /// so a passive relay observer cannot link the envelope to the identity. It is
    /// PURELY the routing tag — the seal/wrap encryption is still to
    /// `recipientNostrPubkey`, unchanged. `nil` (the default) keeps the identity
    /// p-tag, so behavior is byte-identical for senders that have not opted in
    /// (backward compatibility — an old sender still reaches a new receiver).
    public static func wrap(
        rumor: RumorContent,
        sender: NostrKeypair,
        recipientNostrPubkey: String,
        fuzzedTimestamp: Int64,
        randomSource: any RandomSource,
        nonceSource: any NonceSource,
        recipientReceivingKey: String? = nil
    ) throws -> NostrEvent {
        // Layers 1–2 (rumor + seal), shared with the local-link path.
        let seal = try seal(
            rumor: rumor, sender: sender, recipientNostrPubkey: recipientNostrPubkey,
            fuzzedTimestamp: fuzzedTimestamp, randomSource: randomSource,
            nonceSource: nonceSource)
        // 3. Gift wrap: seal encrypted again, signed by a FRESH one-time key.
        let oneTimeKey = try NostrKeypair(randomSource: randomSource)
        let sealJSON = try WireJSON.encoder().encode(seal)
        let wrapContent = try SealCipher.encrypt(
            sealJSON, privateKey: oneTimeKey.privateKeyData,
            peerPublicKeyHex: recipientNostrPubkey, nonceSource: nonceSource)
        // NIP-40: a relay running the expiration policy auto-deletes the wrap
        // after this time. Anchored to the FUZZED created_at (not real now) so it
        // reveals no timing beyond what created_at already does (SPEC §8.4).
        let expiration = fuzzedTimestamp + PQRCConstants.expirationWindowSeconds
        // The `p` tag is the only recipient-routing surface a relay sees. Use the
        // ephemeral receiving sub-key when the sender has one; otherwise the
        // identity Nostr pubkey (default, unchanged).
        let pTag = recipientReceivingKey ?? recipientNostrPubkey
        return try oneTimeKey.sign(
            NostrEvent(
                pubkey: oneTimeKey.publicKeyHex,
                createdAt: fuzzedTimestamp,
                kind: PQRCConstants.giftWrapEventKind,
                tags: [["p", pTag], ["expiration", String(expiration)]],
                content: wrapContent
            ), randomSource: randomSource)
    }

    /// Recipient side: unwrap → verify → unseal → verify → rumor.
    ///
    /// `acceptsReceivingPTag` lets a recipient also accept a gift wrap addressed
    /// to one of its rotating ephemeral receiving sub-keys (SPEC §9.3, kind 10422)
    /// — the sub-key is only a routing pseudonym, so decryption still uses the
    /// recipient's identity Nostr key below. The default rejects every non-identity
    /// p-tag, so behavior is unchanged for callers that have not opted in.
    public static func unwrap(
        _ wrapEvent: NostrEvent,
        recipient: NostrKeypair,
        acceptsReceivingPTag: (String) -> Bool = { _ in false }
    ) throws -> Unwrapped {
        guard wrapEvent.kind == PQRCConstants.giftWrapEventKind,
            let pTag = wrapEvent.firstTagValue("p"),
            pTag == recipient.publicKeyHex || acceptsReceivingPTag(pTag),
            NostrKeypair.verify(wrapEvent)
        else { throw NostrError.wrapMalformed }

        let sealJSON = try SealCipher.decrypt(
            wrapEvent.content, privateKey: recipient.privateKeyData,
            peerPublicKeyHex: wrapEvent.pubkey)
        let seal = try WireJSON.decoder().decode(NostrEvent.self, from: sealJSON)
        // Identical verification to a locally delivered seal; the wrap id (not
        // the seal id) stays the dedupe key on the relay path.
        return try unseal(seal, recipient: recipient, dedupeID: wrapEvent.id,
                          fuzzedTimestamp: wrapEvent.createdAt)
    }

    /// Recipient side for a seal received WITHOUT a wrap (local link, SPEC §10):
    /// verify seal signature → decrypt → verify rumor authorship → rumor.
    ///
    /// `dedupeID` defaults to a `local:`-prefixed seal id so locally delivered
    /// messages share the relay path's replay/dedupe machinery without ever
    /// colliding with a real wrap event id.
    public static func unseal(
        _ seal: NostrEvent,
        recipient: NostrKeypair,
        dedupeID: String? = nil,
        fuzzedTimestamp: Int64? = nil
    ) throws -> Unwrapped {
        guard seal.kind == PQRCConstants.sealEventKind, seal.tags.isEmpty,
            seal.hasValidID(), NostrKeypair.verify(seal)
        else { throw NostrError.invalidSignature }

        let rumorJSON = try SealCipher.decrypt(
            seal.content, privateKey: recipient.privateKeyData, peerPublicKeyHex: seal.pubkey)
        let rumorEvent = try WireJSON.decoder().decode(NostrEvent.self, from: rumorJSON)
        // The rumor must be unsigned and must claim the same author the seal proved.
        guard rumorEvent.isRumor else { throw NostrError.invalidEvent }
        guard rumorEvent.pubkey == seal.pubkey else { throw NostrError.senderMismatch }

        let rumor = try WireJSON.decoder().decode(
            RumorContent.self, from: Data(rumorEvent.content.utf8))
        return Unwrapped(
            rumor: rumor,
            senderNostrPubkey: seal.pubkey,
            // The seal's own created_at IS the fuzzed timestamp the sender
            // committed into the AEAD AD (APP-SPEC §2), so the local path
            // needs no extra timestamp field on the wire.
            fuzzedTimestamp: fuzzedTimestamp ?? seal.createdAt,
            wrapEventID: dedupeID ?? "local:\(seal.id)"
        )
    }
}
