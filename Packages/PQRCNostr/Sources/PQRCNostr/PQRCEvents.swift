// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCCore

/// Builders/parsers for the PQRC replaceable events: kind 10420 (binding),
/// kind 10421 (prekey bundle), kind 10050 (DM relay list).
///
/// The binding's cross-signature and the bundle's per-key signatures live in
/// PQRCCore; this layer adds the outer Nostr event + BIP-340 signature, giving
/// the "both directions" property (CLAUDE.md invariant 7).
public enum PQRCEvents {
    // MARK: kind 10420 — identity binding

    public static func bindingEvent(
        binding: IdentityBinding, signer: NostrKeypair, createdAt: Int64,
        randomSource: any RandomSource
    ) throws -> NostrEvent {
        try signer.sign(
            NostrEvent(
                pubkey: signer.publicKeyHex,
                createdAt: createdAt,
                kind: PQRCConstants.bindingEventKind,
                tags: [
                    ["pqrc_version", binding.version],
                    ["identity_key", binding.identityPubkey.hexString],
                    ["agent_key", binding.agentPubkey.hexString],
                    ["binding_sig", binding.crossSignature.base64EncodedString()],
                    ["pqrc_capabilities"] + binding.capabilities,
                ],
                content: ""
            ), randomSource: randomSource)
    }

    /// Parses AND fully verifies a kind-10420 event in both directions.
    /// Returns trusted keys only on success.
    public static func verifyBindingEvent(_ event: NostrEvent) throws -> VerifiedBinding {
        try verifyBindingEventWithRaw(event).verified
    }

    /// As `verifyBindingEvent`, additionally returning the raw binding so the
    /// app layer can persist it (and re-run `BindingVerifier.verify` on every
    /// restore — invariant 7 survives persistence).
    public static func verifyBindingEventWithRaw(
        _ event: NostrEvent
    ) throws -> (verified: VerifiedBinding, raw: IdentityBinding) {
        guard event.kind == PQRCConstants.bindingEventKind else {
            throw PQRCError.bindingVerificationFailed(.missingTag("kind"))
        }
        guard let version = event.firstTagValue("pqrc_version") else {
            throw PQRCError.bindingVerificationFailed(.missingTag("pqrc_version"))
        }
        guard let identityHex = event.firstTagValue("identity_key"),
            let identityKey = Data(hexString: identityHex)
        else { throw PQRCError.bindingVerificationFailed(.missingTag("identity_key")) }
        guard let agentHex = event.firstTagValue("agent_key"),
            let agentKey = Data(hexString: agentHex)
        else { throw PQRCError.bindingVerificationFailed(.missingTag("agent_key")) }
        guard let sigB64 = event.firstTagValue("binding_sig"),
            let crossSig = Data(base64Encoded: sigB64)
        else { throw PQRCError.bindingVerificationFailed(.missingTag("binding_sig")) }

        let binding = IdentityBinding(
            nostrPubkey: Data(hexString: event.pubkey) ?? Data(),
            identityPubkey: identityKey,
            agentPubkey: agentKey,
            version: version,
            crossSignature: crossSig
        )
        let verified = try BindingVerifier.verify(
            binding, outerSignatureValid: NostrKeypair.verify(event))
        return (verified, binding)
    }

    // MARK: kind 10421 — prekey bundle

    /// The bundle travels as JSON in `content` (NIP-XX §4): structured keys
    /// with signatures fit JSON better than flat tag arrays. [upstream-NIP]
    public static func prekeyBundleEvent(
        bundle: PrekeyBundle, signer: NostrKeypair, createdAt: Int64,
        randomSource: any RandomSource
    ) throws -> NostrEvent {
        let content = String(decoding: try WireJSON.encoder().encode(bundle), as: UTF8.self)
        return try signer.sign(
            NostrEvent(
                pubkey: signer.publicKeyHex,
                createdAt: createdAt,
                kind: PQRCConstants.prekeyBundleEventKind,
                tags: [["pqrc_version", PQRCConstants.version]],
                content: content
            ), randomSource: randomSource)
    }

    /// Parses a kind-10421 event and verifies BOTH the outer Nostr signature
    /// and every identity prekey signature against the binding-verified
    /// identity key. Refuses unverified input.
    public static func verifyPrekeyBundleEvent(
        _ event: NostrEvent, verifiedBinding: VerifiedBinding
    ) throws -> PrekeyBundle {
        guard event.kind == PQRCConstants.prekeyBundleEventKind,
            event.pubkey == verifiedBinding.nostrPubkey.hexString,
            NostrKeypair.verify(event)
        else { throw PQRCError.invalidPrekeySignature }
        let bundle = try WireJSON.decoder().decode(
            PrekeyBundle.self, from: Data(event.content.utf8))
        try bundle.verifySignatures(identityPubkey: verifiedBinding.identityPubkey)
        return bundle
    }

    // MARK: kind 10422 — ephemeral receiving key (SPEC §9.3, NIP-XX §13)

    /// Builds the replaceable kind-10422 event advertising a rotating ephemeral
    /// receiving sub-key. Outer BIP-340 signature (Nostr key) + inner Ed25519
    /// signature (identity key, carried in the `sig` tag) give the same
    /// both-directions binding as the kind-10420 identity assertion.
    public static func ephemeralReceivingKeyEvent(
        key: EphemeralReceivingKey, signer: NostrKeypair, createdAt: Int64,
        randomSource: any RandomSource
    ) throws -> NostrEvent {
        try signer.sign(
            NostrEvent(
                pubkey: signer.publicKeyHex,
                createdAt: createdAt,
                kind: PQRCConstants.ephemeralReceivingKeyEventKind,
                tags: [
                    ["pqrc_version", key.version],
                    ["identity_key", key.identityPubkey.hexString],
                    ["public_key", key.publicKey.hexString],
                    ["conversation_binding", key.conversationBinding],
                    ["epoch", String(key.epoch)],
                    ["sig", key.signature.base64EncodedString()],
                ],
                content: ""
            ), randomSource: randomSource)
    }

    /// Parses AND fully verifies a kind-10422 event for a sender about to use the
    /// sub-key as a `p` tag. Both directions are checked: the outer BIP-340
    /// signature (the author Nostr key vouches for the event) and the inner
    /// Ed25519 signature over `pqrc-ephemeral-receiving-v1` (the identity key owns
    /// the sub-key). `expectedIdentityPubkey` is the recipient's
    /// binding-verified identity — a sub-key signed by any other identity is
    /// rejected. Returns a trusted key only on success.
    public static func verifyEphemeralReceivingKeyEvent(
        _ event: NostrEvent, expectedIdentityPubkey: Data
    ) throws -> EphemeralReceivingKey {
        guard event.kind == PQRCConstants.ephemeralReceivingKeyEventKind,
            NostrKeypair.verify(event)  // outer direction: Nostr key signs the event
        else { throw PQRCError.invalidPrekeySignature }
        guard let version = event.firstTagValue("pqrc_version"),
            let identityHex = event.firstTagValue("identity_key"),
            let identityKey = Data(hexString: identityHex),
            let publicHex = event.firstTagValue("public_key"),
            let publicKey = Data(hexString: publicHex),
            let binding = event.firstTagValue("conversation_binding"),
            let epochStr = event.firstTagValue("epoch"), let epoch = UInt64(epochStr),
            let sigB64 = event.firstTagValue("sig"), let signature = Data(base64Encoded: sigB64)
        else { throw PQRCError.invalidPrekeySignature }
        let key = EphemeralReceivingKey(
            identityPubkey: identityKey, publicKey: publicKey,
            conversationBinding: binding, epoch: epoch, version: version, signature: signature)
        // Inner direction: identity key signs the sub-key, and it must be the
        // identity we expect for this recipient.
        guard EphemeralReceivingKey.isValidEphemeralKey(key, identityPubkey: expectedIdentityPubkey)
        else { throw PQRCError.invalidPrekeySignature }
        return key
    }

    // MARK: kind 10050 — DM relay list

    public static func relayListEvent(
        relayURLs: [String], signer: NostrKeypair, createdAt: Int64,
        randomSource: any RandomSource
    ) throws -> NostrEvent {
        try signer.sign(
            NostrEvent(
                pubkey: signer.publicKeyHex,
                createdAt: createdAt,
                kind: PQRCConstants.dmRelayListEventKind,
                tags: relayURLs.map { ["relay", $0] },
                content: ""
            ), randomSource: randomSource)
    }
}
