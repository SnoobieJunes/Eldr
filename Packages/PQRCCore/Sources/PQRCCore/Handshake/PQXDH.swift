// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation

/// Wire form of the handshake rumor content (NIP-XX §5; D2, D4, D10).
/// Travels inside a gift-wrapped rumor of type "handshake"; message #0 of the
/// Double Ratchet piggybacks alongside it (D10) so the first text rides along.
public struct HandshakeMessage: Codable, Equatable, Sendable {
    /// Handshake suite. v1 supports exactly "hybrid-v1" (explicit PQXDH hybrid; D2).
    public let suite: String
    /// Initiator's Ed25519 PQRC identity pubkey.
    public let ik: Data
    /// Initiator's X25519 identity-DH pubkey (verified against their bundle/binding).
    public let ikDH: Data
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
        case ek
        case kemCT = "kem_ct"
        case kemPK = "kem_pk"
        case spkUsed = "spk_used"
        case otpUsed = "otp_used"
        case otpPQUsed = "otp_pq_used"
        case lrpUsed = "lrp_used"
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
    /// (PQRCSessionManager refuses unverified bundles).
    public static func initiate(
        myIdentity: PQRCIdentity,
        myIdentityDH: Curve25519.KeyAgreement.PrivateKey,
        peerBundle bundle: PrekeyBundle,
        randomSource: RandomSource
    ) throws -> InitiationResult {
        let ephemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: randomSource.bytes(32))
        let spkPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: bundle.spk.key)

        let dh1 = try myIdentityDH.sharedSecretFromKeyAgreement(with: spkPub)
        let dh2 = try ephemeral.sharedSecretFromKeyAgreement(with: spkPub)

        // dh3: one-time prekey if available, else last-resort (flagged, SPEC §4.1),
        // else omitted entirely (publisher chose not to provide an lrp).
        var dh3: SharedSecret?
        var otpUsed: Data?
        var lrpUsed = false
        if let otpKey = bundle.otp.first {
            let pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: otpKey)
            dh3 = try ephemeral.sharedSecretFromKeyAgreement(with: pub)
            otpUsed = sha256(otpKey)
        } else if let lrp = bundle.lrp {
            let pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: lrp.key)
            dh3 = try ephemeral.sharedSecretFromKeyAgreement(with: pub)
            lrpUsed = true
        }

        // KEM leg: one-time PQ prekey if available, else the medium-lived pqpk.
        var otpPQUsed: Data?
        let kemTargetKey: Data
        if let otpPQ = bundle.otpPQ.first {
            kemTargetKey = otpPQ
            otpPQUsed = sha256(otpPQ)
        } else {
            kemTargetKey = bundle.pqpk.key
        }
        let kemTarget = try MLKEM768.PublicKey(rawRepresentation: kemTargetKey)
        let encapsulation = try kemTarget.encapsulate()

        let sk = deriveSK(
            dh1: dh1, dh2: dh2, dh3: dh3,
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
        /// Our spk private half — our initial ratchet keypair (Signal pattern).
        public let myRatchetPrivate: Curve25519.KeyAgreement.PrivateKey
        /// Initiator's fresh ML-KEM pubkey for our future PQ rekeys.
        public let peerKEMPubkey: Data
        public let usedLastResort: Bool
    }

    /// Responder side: recompute SK from the handshake message and our consumed
    /// private halves.
    public static func respond(
        myIdentityPub: Data,
        consumed: PrekeyManager.ConsumedPrekeys,
        message: HandshakeMessage
    ) throws -> ResponseResult {
        guard message.suite == PQRCConstants.handshakeSuite else {
            throw PQRCError.handshakeSuiteUnsupported(message.suite)
        }
        let ikDHPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: message.ikDH)
        let ekPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: message.ek)

        let dh1 = try consumed.spk.sharedSecretFromKeyAgreement(with: ikDHPub)
        let dh2 = try consumed.spk.sharedSecretFromKeyAgreement(with: ekPub)
        var dh3: SharedSecret?
        if let otp = consumed.otp {
            dh3 = try otp.sharedSecretFromKeyAgreement(with: ekPub)
        }
        let kemPrivate = consumed.otpPQ ?? consumed.pqpk
        let kemSS = try kemPrivate.decapsulate(message.kemCT)

        let sk = deriveSK(
            dh1: dh1, dh2: dh2, dh3: dh3,
            kemSharedSecret: kemSS,
            initiatorIdentityPub: message.ik,
            responderIdentityPub: myIdentityPub
        )
        return ResponseResult(
            sharedSecret: sk,
            myRatchetPrivate: consumed.spk,
            peerKEMPubkey: message.kemPK,
            usedLastResort: consumed.usedLastResort
        )
    }

    /// SK = HKDF-SHA256(dh1||dh2||dh3||ss_kem, salt "pqrc-v1-handshake",
    ///                  info "pqrc-root-key"||alice_pub||bob_pub) per SPEC §4.2.
    static func deriveSK(
        dh1: SharedSecret, dh2: SharedSecret, dh3: SharedSecret?,
        kemSharedSecret: SymmetricKey,
        initiatorIdentityPub: Data, responderIdentityPub: Data
    ) -> SymmetricKey {
        var ikm = Data()
        dh1.withUnsafeBytes { ikm.append(contentsOf: $0) }
        dh2.withUnsafeBytes { ikm.append(contentsOf: $0) }
        if let dh3 { dh3.withUnsafeBytes { ikm.append(contentsOf: $0) } }
        ikm.append(kemSharedSecret.rawData)

        var info = Data(PQRCConstants.handshakeHKDFInfoPrefix.utf8)
        info.append(initiatorIdentityPub)
        info.append(responderIdentityPub)

        // `SymmetricKey(data:)` copies the IKM into its own zeroed storage, so we
        // own the only other copy of the dh1‖dh2‖dh3‖ss_kem handshake secret;
        // wipe it once HKDF has consumed it (mirrors `kdfRootKey`). Same derived
        // key, just not left lingering in the heap.
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
