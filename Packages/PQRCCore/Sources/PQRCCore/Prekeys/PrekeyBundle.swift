import Crypto
import Foundation

/// Public half of a kind-10421 prekey bundle (SPEC §4.1, NIP-XX §4).
///
/// Field names are the NIP wire names: `ik_dh` (identity-DH key), `spk`
/// (signed X25519 prekey), `pqpk` (ML-KEM-768 prekey), `otp` (one-time X25519),
/// `otp_pq` (one-time ML-KEM-768), `lrp` (last-resort X25519).
///
/// `ik_dh` exists because Ed25519 identity keys cannot perform X25519 directly
/// and CryptoKit provides no Ed25519→X25519 conversion (doing so by hand would
/// be a custom primitive, forbidden by SPEC §2). The dedicated X25519 identity-DH
/// key is signed by the Ed25519 identity key instead. Recorded in DEVIATIONS.
public struct PrekeyBundle: Codable, Equatable, Sendable {
    public struct SignedKey: Codable, Equatable, Sendable {
        public let key: Data
        public let sig: Data
        public init(key: Data, sig: Data) {
            self.key = key
            self.sig = sig
        }
    }

    public let version: String
    /// Owner's Ed25519 PQRC identity pubkey (binds the bundle to an identity).
    public let identityPubkey: Data
    public let ikDH: SignedKey
    public let spk: SignedKey
    public let pqpk: SignedKey
    public let otp: [Data]
    public let otpPQ: [Data]
    /// Optional: a publisher MAY omit the last-resort key, accepting that
    /// initiators get no dh3 leg once one-time prekeys are exhausted.
    public let lrp: SignedKey?

    enum CodingKeys: String, CodingKey {
        case version = "pqrc_version"
        case identityPubkey = "ik"
        case ikDH = "ik_dh"
        case spk
        case pqpk
        case otp
        case otpPQ = "otp_pq"
        case lrp
    }

    public init(
        version: String = PQRCConstants.version,
        identityPubkey: Data, ikDH: SignedKey, spk: SignedKey, pqpk: SignedKey,
        otp: [Data], otpPQ: [Data], lrp: SignedKey?
    ) {
        self.version = version
        self.identityPubkey = identityPubkey
        self.ikDH = ikDH
        self.spk = spk
        self.pqpk = pqpk
        self.otp = otp
        self.otpPQ = otpPQ
        self.lrp = lrp
    }

    /// Domain-separated message signed by the identity key for each medium-lived key.
    public static func prekeySignatureMessage(label: String, key: Data) -> Data {
        var msg = Data("pqrc-prekey-v1".utf8)
        msg.append(Data(label.utf8))
        msg.append(key)
        return msg
    }

    /// Verifies all identity signatures on the bundle's medium-lived keys
    /// against the given (already binding-verified) identity pubkey.
    /// One-time prekeys are unsigned (Signal pattern); they are covered by the
    /// outer Nostr event signature on the carrying kind-10421 event.
    public func verifySignatures(identityPubkey expected: Data) throws {
        guard identityPubkey == expected else { throw PQRCError.invalidPrekeySignature }
        var signedKeys = [("ik_dh", ikDH), ("spk", spk), ("pqpk", pqpk)]
        if let lrp { signedKeys.append(("lrp", lrp)) }
        for (label, signed) in signedKeys {
            let msg = Self.prekeySignatureMessage(label: label, key: signed.key)
            guard PQRCIdentity.verify(signature: signed.sig, message: msg, publicKey: expected) else {
                throw PQRCError.invalidPrekeySignature
            }
        }
    }
}
