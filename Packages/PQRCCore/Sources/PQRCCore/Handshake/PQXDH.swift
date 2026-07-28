// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation

/// Wire form of the handshake rumor content (NIP-XX §5; D2, D4, D10).
/// Travels inside a gift-wrapped rumor of type "handshake"; message #0 of the
/// Double Ratchet piggybacks alongside it (D10) so the first text rides along.
public struct HandshakeMessage: Codable, Equatable, Sendable {
    /// Handshake suite. v1 supports exactly "hybrid-v2" (explicit PQXDH hybrid; D2).
    public let suite: String
    /// Initiator's Ed25519 PQRC identity pubkey.
    public let ik: Data
    /// Initiator's X25519 identity-DH pubkey (PQXDH `IK_A`).
    public let ikDH: Data
    /// `ik`'s signature over `ikDH`, in the same domain-separated form the
    /// prekey bundle uses. Without it `ik` is a free-text field: `respond` reads
    /// `ikDH` to do the arithmetic and `ik` to name the peer, so anything that
    /// does not tie them together lets a sender put someone else's name on a
    /// handshake they built with their own keys.
    public let ikDHSig: Data
    /// Initiator's ephemeral X25519 pubkey.
    public let ek: Data
    /// ML-KEM-768 ciphertext encapsulated to the responder's PQ prekey.
    public let kemCT: Data
    /// Initiator's fresh ML-KEM-768 public key for future inbound PQ rekeys (§6).
    public let kemPK: Data
    /// SHA-256 of the responder public prekeys used (D4).
    public let spkUsed: Data
    public let otpUsed: Data?
    public let otpPQUsed: Data?
    public let lrpUsed: Bool

    enum CodingKeys: String, CodingKey {
        case suite
        case ik
        case ikDH = "ik_dh"
        case ikDHSig = "ik_dh_sig"
        case ek
        case kemCT = "kem_ct"
        case kemPK = "kem_pk"
        case spkUsed = "spk_used"
        case otpUsed = "otp_used"
        case otpPQUsed = "otp_pq_used"
        case lrpUsed = "lrp_used"
    }
}

extension HandshakeMessage {
    /// Every check that needs no private keys: the suite is one we speak, `ik`
    /// really signed `ik_dh`, the prekey claims are not self-contradictory, and
    /// `kem_pk` parses.
    ///
    /// Run this the moment a handshake arrives — **before**
    /// ``PrekeyManager/consume(spkUsed:otpUsed:otpPQUsed:lrpUsed:)``. One-time
    /// prekeys are a finite resource that consuming spends (invariant 11), so
    /// anything rejectable for free must be rejected for free.
    /// ``PQXDH/respond(myIdentityPub:consumed:message:)`` repeats these checks.
    public func validate() throws {
        guard suite == PQRCConstants.handshakeSuite else {
            throw PQRCError.handshakeSuiteUnsupported(suite)
        }
        guard PQRCIdentity.verify(
            signature: ikDHSig,
            message: PrekeyBundle.prekeySignatureMessage(label: "ik_dh", key: ikDH),
            publicKey: ik
        ) else {
            throw PQRCError.initiatorIdentityUnverified
        }
        // dh4 has exactly one source. A message claiming both a one-time prekey
        // and the last-resort key is either broken or probing; do not pick for it.
        guard !(lrpUsed && otpUsed != nil) else {
            throw PQRCError.handshakeMalformed
        }
        // Fail at the edge rather than deep inside the ratchet's first rekey.
        guard (try? MLKEM768.PublicKey(rawRepresentation: kemPK)) != nil else {
            throw PQRCError.handshakeMalformed
        }
    }
}

/// PQXDH (SPEC §4.2): hybrid X25519 + ML-KEM-768 asynchronous handshake.
/// Breaking the derived SK requires breaking BOTH legs.
public enum PQXDH {
    public struct InitiationResult: Sendable {
        public let sharedSecret: SymmetricKey
        public let message: HandshakeMessage
        /// Initiator's ML-KEM private half matching `message.kemPK`.
        public let myKEMPrivate: MLKEM768.PrivateKey
        /// Responder's signed prekey — doubles as their initial ratchet pubkey (Signal pattern).
        public let peerRatchetPubkey: Data
        /// Responder's current ML-KEM pubkey for our future PQ rekeys.
        public let peerKEMPubkey: Data
    }

    /// Initiator side. `bundle` must already have passed `verifySignatures`
    /// against a binding-verified identity key — enforced by the caller
    /// (PQRCMessenger refuses unverified bundles).
    public static func initiate(
        myIdentity: PQRCIdentity,
        myIdentityDH: Curve25519.KeyAgreement.PrivateKey,
        peerBundle bundle: PrekeyBundle,
        randomSource: RandomSource
    ) throws -> InitiationResult {
        let ephemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: randomSource.bytes(32))
        let spkPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: bundle.spk.key)
        let peerIKDHPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: bundle.ikDH.key)

        // The four PQXDH legs. dh1 and dh2 authenticate — each requires one
        // side's LONG-TERM key — while dh3 and dh4 supply forward secrecy.
        // dh2 is why compromising the medium-lived `spk` alone is not enough to
        // impersonate the responder: it needs `ik_dh` too.
        let dh1 = try myIdentityDH.sharedSecretFromKeyAgreement(with: spkPub)
        let dh2 = try ephemeral.sharedSecretFromKeyAgreement(with: peerIKDHPub)
        let dh3 = try ephemeral.sharedSecretFromKeyAgreement(with: spkPub)

        // dh4: one-time prekey if available, else last-resort (flagged, SPEC §4.1),
        // else omitted entirely (publisher chose not to provide an lrp).
        var dh4: SharedSecret?
        var otpUsed: Data?
        var lrpUsed = false
        if let otpKey = bundle.otp.randomElement(drawingFrom: randomSource) {
            let pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: otpKey)
            dh4 = try ephemeral.sharedSecretFromKeyAgreement(with: pub)
            otpUsed = sha256(otpKey)
        } else if let lrp = bundle.lrp {
            let pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: lrp.key)
            dh4 = try ephemeral.sharedSecretFromKeyAgreement(with: pub)
            lrpUsed = true
        }

        // KEM leg: one-time PQ prekey if available, else the medium-lived pqpk.
        var otpPQUsed: Data?
        let kemTargetKey: Data
        if let otpPQ = bundle.otpPQ.randomElement(drawingFrom: randomSource) {
            kemTargetKey = otpPQ
            otpPQUsed = sha256(otpPQ)
        } else {
            kemTargetKey = bundle.pqpk.key
        }
        let kemTarget = try MLKEM768.PublicKey(rawRepresentation: kemTargetKey)
        let encapsulation = try kemTarget.encapsulate()

        let sk = deriveSK(
            dh1: dh1, dh2: dh2, dh3: dh3, dh4: dh4,
            kemSharedSecret: encapsulation.sharedSecret,
            initiatorIdentityPub: myIdentity.publicKeyData,
            responderIdentityPub: bundle.identityPubkey
        )

        // Fresh ML-KEM pair so the responder can rekey toward us later (§6).
        let myKEM = try MLKEM768.PrivateKey(seedRepresentation: randomSource.bytes(64), publicKey: nil)

        let message = HandshakeMessage(
            suite: PQRCConstants.handshakeSuite,
            ik: myIdentity.publicKeyData,
            ikDH: myIdentityDH.publicKey.rawRepresentation,
            ikDHSig: try myIdentity.sign(
                PrekeyBundle.prekeySignatureMessage(
                    label: "ik_dh", key: myIdentityDH.publicKey.rawRepresentation)),
            ek: ephemeral.publicKey.rawRepresentation,
            kemCT: encapsulation.encapsulated,
            kemPK: myKEM.publicKey.rawRepresentation,
            spkUsed: sha256(bundle.spk.key),
            otpUsed: otpUsed,
            otpPQUsed: otpPQUsed,
            lrpUsed: lrpUsed
        )
        return InitiationResult(
            sharedSecret: sk,
            message: message,
            myKEMPrivate: myKEM,
            peerRatchetPubkey: bundle.spk.key,
            // The responder's ratchet holds the KEM key the handshake actually
            // consumed (otp_pq when present); our first rekey must target THAT
            // key, not the medium-lived pqpk, or rekey decapsulation fails.
            peerKEMPubkey: kemTargetKey
        )
    }

    public struct ResponseResult: Sendable {
        public let sharedSecret: SymmetricKey
        /// The identity key that signed the initiator's `ik_dh`, now verified.
        /// Check THIS against the contact's binding, not the raw `message.ik`:
        /// this one has been proven to own the key that did the arithmetic.
        public let initiatorIdentityPub: Data
        /// Our spk private half — our initial ratchet keypair (Signal pattern).
        public let myRatchetPrivate: Curve25519.KeyAgreement.PrivateKey
        /// Initiator's fresh ML-KEM pubkey for our future PQ rekeys.
        public let peerKEMPubkey: Data
        public let usedLastResort: Bool
    }

    /// Responder side: recompute SK from the handshake message and our consumed
    /// private halves.
    ///
    /// Verifies the `ik` → `ik_dh` binding before deriving anything, which makes
    /// the handshake implicitly authenticated in PQXDH's sense: only the holder
    /// of `ik_dh`'s private half can reach the same SK. It does NOT establish
    /// that `ik` is the contact you meant — the caller compares
    /// `initiatorIdentityPub` against a both-directions-verified binding
    /// (invariant 7).
    public static func respond(
        myIdentityPub: Data,
        consumed: PrekeyManager.ConsumedPrekeys,
        message: HandshakeMessage
    ) throws -> ResponseResult {
        try message.validate()

        let ikDHPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: message.ikDH)
        let ekPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: message.ek)

        let dh1 = try consumed.spk.sharedSecretFromKeyAgreement(with: ikDHPub)
        let dh2 = try consumed.ikDH.sharedSecretFromKeyAgreement(with: ekPub)
        let dh3 = try consumed.spk.sharedSecretFromKeyAgreement(with: ekPub)
        var dh4: SharedSecret?
        if let otp = consumed.otp {
            dh4 = try otp.sharedSecretFromKeyAgreement(with: ekPub)
        }
        let kemPrivate = consumed.otpPQ ?? consumed.pqpk
        let kemSS = try kemPrivate.decapsulate(message.kemCT)

        let sk = deriveSK(
            dh1: dh1, dh2: dh2, dh3: dh3, dh4: dh4,
            kemSharedSecret: kemSS,
            initiatorIdentityPub: message.ik,
            responderIdentityPub: myIdentityPub
        )
        return ResponseResult(
            sharedSecret: sk,
            initiatorIdentityPub: message.ik,
            myRatchetPrivate: consumed.spk,
            peerKEMPubkey: message.kemPK,
            usedLastResort: consumed.usedLastResort
        )
    }

    /// SK = HKDF-SHA256(dh1||dh2||dh3||dh4||ss_kem, salt "pqrc-v1-handshake",
    ///                  info "pqrc-root-key"||alice_pub||bob_pub) per SPEC §4.2.
    ///
    /// The four legs are PQXDH's, in the spec's order:
    ///   dh1 = DH(IK_A, SPK_B)   dh3 = DH(EK_A, SPK_B)
    ///   dh2 = DH(EK_A, IK_B)    dh4 = DH(EK_A, OPK_B), when a one-time key exists
    static func deriveSK(
        dh1: SharedSecret, dh2: SharedSecret, dh3: SharedSecret, dh4: SharedSecret?,
        kemSharedSecret: SymmetricKey,
        initiatorIdentityPub: Data, responderIdentityPub: Data
    ) -> SymmetricKey {
        var ikm = Data()
        dh1.withUnsafeBytes { ikm.append(contentsOf: $0) }
        dh2.withUnsafeBytes { ikm.append(contentsOf: $0) }
        dh3.withUnsafeBytes { ikm.append(contentsOf: $0) }
        if let dh4 { dh4.withUnsafeBytes { ikm.append(contentsOf: $0) } }
        ikm.append(kemSharedSecret.rawData)

        var info = Data(PQRCConstants.handshakeHKDFInfoPrefix.utf8)
        info.append(initiatorIdentityPub)
        info.append(responderIdentityPub)

        // `SymmetricKey(data:)` copies the IKM into its own zeroed storage, so we
        // own the only other copy of the dh1‖…‖ss_kem handshake secret; wipe it
        // once HKDF has consumed it (mirrors `kdfRootKey`). Same derived key,
        // just not left lingering in the heap.
        let sk = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: Data(PQRCConstants.handshakeHKDFSalt.utf8),
            info: info,
            outputByteCount: 32
        )
        ikm.zeroize()
        return sk
    }
}
