// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation

/// The kind-10422 ephemeral receiving key (SPEC §9.3 strong mitigation, NIP-XX §13).
///
/// A rotating, per-conversation X25519 *public* sub-key that the recipient
/// advertises so the gift-wrap `p` tag carries a routing pseudonym instead of the
/// recipient's long-term identity npub. A passive relay observer therefore can no
/// longer link traffic to the identity (cardinal rule, SPEC §0).
///
/// IMPORTANT — scope of this key (CLAUDE.md): it is **only** a routing tag. SK,
/// the Double Ratchet, and the seal/wrap *encryption* are all unchanged — the
/// gift wrap is still encrypted to the recipient's Nostr key and decrypted with
/// the recipient's Nostr private key. The sub-key is never used for ECDH; only
/// its 32 public bytes are used, as the hex `p` tag. Nothing about
/// confidentiality changes.
///
/// Bound to the identity in BOTH directions, exactly like the kind-10420 binding
/// (invariant 7):
///   - the carrying kind-10422 Nostr event is BIP-340-signed by the Nostr key
///     (outer direction, verified in PQRCNostr);
///   - `signature` is the Ed25519 identity key's signature over the sub-key, the
///     conversation binding, and the epoch (context `pqrc-ephemeral-receiving-v1`).
/// A sender MUST verify both before using a fetched sub-key
/// (`EphemeralReceivingKey.isValidEphemeralKey` + the outer event signature).
public struct EphemeralReceivingKey: Codable, Equatable, Sendable {
    /// Ed25519 PQRC identity pubkey that owns this receiving sub-key.
    public let identityPubkey: Data
    /// X25519 public sub-key — the value carried as the gift-wrap `p` tag (hex).
    public let publicKey: Data
    /// Conversation-scoping domain the sub-key is bound to. The privacy-safe
    /// default (NIP-XX §13) is the recipient's OWN identity hex — it advertises
    /// one rotating key and leaks nothing the public kind-10420 binding doesn't
    /// already. A per-PEER binding would link the recipient to that peer for any
    /// observer; see DEVIATIONS T4 / THREAT_MODEL.
    public let conversationBinding: String
    /// Monotonic rotation counter (message-driven, never wall-clock — invariant 1).
    public let epoch: UInt64
    public let version: String
    /// Ed25519 signature by the identity key over `signatureMessage`.
    public let signature: Data

    public init(
        identityPubkey: Data, publicKey: Data, conversationBinding: String,
        epoch: UInt64, version: String = PQRCConstants.version, signature: Data
    ) {
        self.identityPubkey = identityPubkey
        self.publicKey = publicKey
        self.conversationBinding = conversationBinding
        self.epoch = epoch
        self.version = version
        self.signature = signature
    }

    /// Domain-separation context (NIP-XX §2). Also reused as the HKDF salt for
    /// sub-key derivation so all ephemeral-key material shares one tag.
    public static let signatureContext = "pqrc-ephemeral-receiving-v1"

    /// The Ed25519 message the identity key signs:
    /// "pqrc-ephemeral-receiving-v1" ‖ identity_pub(32) ‖ public_key(32)
    ///                               ‖ conversation_binding(utf8) ‖ epoch(u64be)
    public static func signatureMessage(
        identityPubkey: Data, publicKey: Data, conversationBinding: String, epoch: UInt64
    ) -> Data {
        var msg = Data(signatureContext.utf8)
        msg.append(identityPubkey)
        msg.append(publicKey)
        msg.append(Data(conversationBinding.utf8))
        msg.append(Data(uint64BE: epoch))
        return msg
    }

    /// The lowercase-hex `p`-tag value (and the receiver's subscription key).
    public var pTag: String { publicKey.hexString }

    /// Verify a fetched receiving key against the EXPECTED identity. This checks
    /// the INNER (identity → sub-key) direction; the caller MUST also have
    /// verified the carrying event's outer BIP-340 signature (done in
    /// `PQRCEvents.verifyEphemeralReceivingKeyEvent`). A forged or mismatched
    /// sub-key fails here and is never used as a routing tag.
    public static func isValidEphemeralKey(
        _ key: EphemeralReceivingKey, identityPubkey: Data
    ) -> Bool {
        guard key.version == PQRCConstants.version,
            key.publicKey.count == 32,
            key.identityPubkey == identityPubkey
        else { return false }
        let message = signatureMessage(
            identityPubkey: key.identityPubkey, publicKey: key.publicKey,
            conversationBinding: key.conversationBinding, epoch: key.epoch)
        return PQRCIdentity.verify(
            signature: key.signature, message: message, publicKey: key.identityPubkey)
    }
}

/// Persistable public state for one conversation's receiving-key rotation. Holds
/// ONLY public values (the p-tags + epoch) so it can be stored without the at-rest
/// secrecy demands of `PrekeyState`; the private sub-keys are re-derived on demand
/// from the identity-anchored seed and never persisted.
public struct EphemeralKeyEpoch: Codable, Equatable, Sendable {
    public let epoch: UInt64
    public let currentPTag: String
    /// Immediately-previous epoch's p-tag, still accepted during the changeover
    /// so messages already in flight to the old key are not dropped.
    public let previousPTag: String?

    public init(epoch: UInt64, currentPTag: String, previousPTag: String?) {
        self.epoch = epoch
        self.currentPTag = currentPTag
        self.previousPTag = previousPTag
    }
}

/// Owns the ephemeral-receiving-key seed and per-conversation rotation state
/// (actor — CLAUDE.md: actors own all mutable session state, no locks). Mirrors
/// `PrekeyManager`'s private-key ownership + `zeroize` discipline.
///
/// Sub-keys are derived deterministically via HKDF from a stable, identity-anchored
/// seed, so the SAME public sub-key re-derives across launches from just the
/// persisted epoch — and so a peer needs no extra shared secret to use the
/// advertised key (it simply reads the published kind-10422). Rotation is
/// MESSAGE-DRIVEN with random jitter from the injected `RandomSource`; there is no
/// clock anywhere in this type (invariant 1).
public actor EphemeralKeyManager {
    private let identity: PQRCIdentity
    private let randomSource: any RandomSource
    /// Base rotation cadence in messages and the +/- jitter around it.
    private let rotationBase: Int
    private let rotationJitter: Int
    /// Identity-anchored master seed for all sub-key derivation. Sensitive
    /// (a leak lets an observer recompute/link every p-tag — a privacy, not a
    /// confidentiality, downgrade); zeroizable, never persisted.
    private var seed: Data

    private struct ConversationState {
        var epoch: UInt64
        /// Message-count threshold for THIS epoch (= base ± jitter), drawn once.
        var rotateThreshold: Int
        var currentPublic: Data
        var previousPublic: Data?
    }
    private var conversations: [String: ConversationState] = [:]

    /// - Parameters:
    ///   - rotationBase: target messages per epoch (SPEC §9.3 guidance ~25).
    ///   - rotationJitter: +/- messages of random jitter (defeats pattern
    ///     analysis on the rotation boundary); clamped so the floor stays ≥ 1.
    public init(
        identity: PQRCIdentity, randomSource: any RandomSource,
        rotationBase: Int = 25, rotationJitter: Int = 5
    ) {
        self.identity = identity
        self.randomSource = randomSource
        self.rotationBase = max(1, rotationBase)
        self.rotationJitter = max(0, min(rotationJitter, max(0, rotationBase - 1)))
        var info = Data("pqrc-ephemeral-receiving-root".utf8)
        info.append(identity.publicKeyData)
        self.seed = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: identity.privateKey.rawRepresentation),
            salt: Data(EphemeralReceivingKey.signatureContext.utf8),
            info: info,
            outputByteCount: 32
        ).rawData
    }

    // MARK: - Derivation

    /// Derive the X25519 PUBLIC sub-key for a conversation/epoch. Deterministic:
    /// the same (identity, conversation, epoch) always yields the same public key,
    /// so it survives restart from just the persisted epoch. The private half is a
    /// transient — used only to obtain the public bytes, then zeroized.
    private func derivePublic(conversation: String, epoch: UInt64) throws -> Data {
        var info = Data("pqrc-ephemeral-receiving-sub".utf8)
        info.append(Data(conversation.utf8))
        info.append(Data(uint64BE: epoch))
        var subPrivate = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: seed),
            salt: Data(EphemeralReceivingKey.signatureContext.utf8),
            info: info,
            outputByteCount: 32
        ).rawData
        defer { subPrivate.zeroize() }
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: subPrivate)
        return key.publicKey.rawRepresentation
    }

    /// Draw a fresh per-epoch rotation threshold in `[base-jitter, base+jitter]`
    /// from the injected RandomSource (deterministic under `SeededRandomSource`).
    private func drawThreshold() -> Int {
        guard rotationJitter > 0 else { return rotationBase }
        let span = 2 * rotationJitter + 1
        let draw = Int(randomSource.bytes(1).first ?? 0) % span  // 0 ..< span
        return rotationBase - rotationJitter + draw  // base-j ... base+j
    }

    private func ensureState(_ conversation: String) throws -> ConversationState {
        if let existing = conversations[conversation] { return existing }
        let pub = try derivePublic(conversation: conversation, epoch: 0)
        let state = ConversationState(
            epoch: 0, rotateThreshold: drawThreshold(), currentPublic: pub, previousPublic: nil)
        conversations[conversation] = state
        return state
    }

    private func sign(conversation: String, epoch: UInt64, publicKey: Data) throws
        -> EphemeralReceivingKey
    {
        let message = EphemeralReceivingKey.signatureMessage(
            identityPubkey: identity.publicKeyData, publicKey: publicKey,
            conversationBinding: conversation, epoch: epoch)
        return EphemeralReceivingKey(
            identityPubkey: identity.publicKeyData, publicKey: publicKey,
            conversationBinding: conversation, epoch: epoch,
            signature: try identity.sign(message))
    }

    // MARK: - Public surface

    /// The signed kind-10422 bundle for a conversation's CURRENT epoch (publish it).
    public func getPublicBundle(for conversation: String) throws -> EphemeralReceivingKey {
        let state = try ensureState(conversation)
        return try sign(conversation: conversation, epoch: state.epoch, publicKey: state.currentPublic)
    }

    /// Current p-tag (hex) for a conversation: the value the receiver subscribes
    /// on and the value a peer should put in the gift-wrap `p` tag.
    public func currentPTag(for conversation: String) throws -> String {
        try ensureState(conversation).currentPublic.hexString
    }

    /// Message-driven rotation check (NO wall-clock — invariant 1). Returns true
    /// once `messageCount` for this conversation has reached the current epoch's
    /// randomized threshold; the caller then `rotate`s, publishes, and resets its
    /// own counter.
    public func shouldPublishNewKey(messageCount: Int, for conversation: String) throws -> Bool {
        let state = try ensureState(conversation)
        return messageCount >= state.rotateThreshold
    }

    /// Advance to the next epoch and return the new signed bundle. Keeps the
    /// outgoing epoch's p-tag as still-accepted (`acceptedPTags`) so messages in
    /// flight to the old key still arrive during the changeover.
    @discardableResult
    public func rotate(for conversation: String) throws -> EphemeralReceivingKey {
        let state = try ensureState(conversation)
        let nextEpoch = state.epoch + 1
        let pub = try derivePublic(conversation: conversation, epoch: nextEpoch)
        conversations[conversation] = ConversationState(
            epoch: nextEpoch, rotateThreshold: drawThreshold(),
            currentPublic: pub, previousPublic: state.currentPublic)
        return try sign(conversation: conversation, epoch: nextEpoch, publicKey: pub)
    }

    /// p-tags currently accepted for a conversation (current + previous epoch).
    public func acceptedPTags(for conversation: String) -> Set<String> {
        guard let state = conversations[conversation] else { return [] }
        var out: Set<String> = [state.currentPublic.hexString]
        if let previous = state.previousPublic { out.insert(previous.hexString) }
        return out
    }

    /// Every accepted p-tag across all known conversations — the dual-subscribe
    /// filter set and the `unwrap` acceptance predicate source.
    public func allAcceptedPTags() -> Set<String> {
        var out: Set<String> = []
        for state in conversations.values {
            out.insert(state.currentPublic.hexString)
            if let previous = state.previousPublic { out.insert(previous.hexString) }
        }
        return out
    }

    // MARK: - Persistence (public values only)

    /// Snapshot the per-conversation epochs for persistence. Contains NO secrets;
    /// the seed and private sub-keys are never serialized.
    public func snapshot() -> [String: EphemeralKeyEpoch] {
        conversations.mapValues {
            EphemeralKeyEpoch(
                epoch: $0.epoch, currentPTag: $0.currentPublic.hexString,
                previousPTag: $0.previousPublic?.hexString)
        }
    }

    /// Restore persisted epochs so re-subscribe survives a relaunch. Public
    /// sub-keys are RE-DERIVED from the seed (derivation is the single source of
    /// truth); the persisted hex is the app's pre-construction re-subscribe seed.
    public func restore(_ snapshot: [String: EphemeralKeyEpoch]) throws {
        for (conversation, epoch) in snapshot {
            let current = try derivePublic(conversation: conversation, epoch: epoch.epoch)
            let previous =
                epoch.epoch > 0
                ? try derivePublic(conversation: conversation, epoch: epoch.epoch - 1) : nil
            conversations[conversation] = ConversationState(
                epoch: epoch.epoch, rotateThreshold: drawThreshold(),
                currentPublic: current, previousPublic: previous)
        }
    }

    /// Wipe the in-memory seed and per-conversation state (mirrors
    /// `PrekeyState.zeroize`). The manager must be reconstructed before deriving
    /// further keys after this.
    public func zeroize() {
        seed.zeroize()
        conversations.removeAll()
    }
}
