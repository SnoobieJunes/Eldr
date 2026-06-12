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

    /// Wraps one rumor for one recipient. The same fuzzed timestamp the sender
    /// committed into the AEAD AD is used for both seal and wrap `created_at`
    /// (APP-SPEC §2; test fuzz_sameValueUsedInADandWrap).
    public static func wrap(
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
        let seal = try sender.sign(
            NostrEvent(
                pubkey: sender.publicKeyHex,
                createdAt: fuzzedTimestamp,
                kind: PQRCConstants.sealEventKind,
                tags: [],
                content: sealContent
            ), randomSource: randomSource)
        // 3. Gift wrap: seal encrypted again, signed by a FRESH one-time key.
        let oneTimeKey = try NostrKeypair(randomSource: randomSource)
        let sealJSON = try WireJSON.encoder().encode(seal)
        let wrapContent = try SealCipher.encrypt(
            sealJSON, privateKey: oneTimeKey.privateKeyData,
            peerPublicKeyHex: recipientNostrPubkey, nonceSource: nonceSource)
        return try oneTimeKey.sign(
            NostrEvent(
                pubkey: oneTimeKey.publicKeyHex,
                createdAt: fuzzedTimestamp,
                kind: PQRCConstants.giftWrapEventKind,
                tags: [["p", recipientNostrPubkey]],
                content: wrapContent
            ), randomSource: randomSource)
    }

    /// Recipient side: unwrap → verify → unseal → verify → rumor.
    public static func unwrap(_ wrapEvent: NostrEvent, recipient: NostrKeypair) throws -> Unwrapped {
        guard wrapEvent.kind == PQRCConstants.giftWrapEventKind,
            wrapEvent.firstTagValue("p") == recipient.publicKeyHex,
            NostrKeypair.verify(wrapEvent)
        else { throw NostrError.wrapMalformed }

        let sealJSON = try SealCipher.decrypt(
            wrapEvent.content, privateKey: recipient.privateKeyData,
            peerPublicKeyHex: wrapEvent.pubkey)
        let seal = try WireJSON.decoder().decode(NostrEvent.self, from: sealJSON)
        guard seal.kind == PQRCConstants.sealEventKind, seal.tags.isEmpty,
            NostrKeypair.verify(seal)
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
            fuzzedTimestamp: wrapEvent.createdAt,
            wrapEventID: wrapEvent.id
        )
    }
}
