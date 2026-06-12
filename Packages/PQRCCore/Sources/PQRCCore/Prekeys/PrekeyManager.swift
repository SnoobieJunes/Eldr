import Crypto
import Foundation

/// Owns prekey private halves: generation, consumption, deletion (actor —
/// CLAUDE.md: actors own all mutable session state).
///
/// Invariant 11: consumed one-time prekey private halves are deleted; reuse is
/// rejected; exhaustion falls back to the last-resort key (flagged, documented
/// unlinkability caveat — never a confidentiality downgrade).
public actor PrekeyManager {
    public struct ConsumedPrekeys: Sendable {
        public let spk: Curve25519.KeyAgreement.PrivateKey
        public let otp: Curve25519.KeyAgreement.PrivateKey?
        public let otpPQ: MLKEM768.PrivateKey?
        public let pqpk: MLKEM768.PrivateKey
        public let usedLastResort: Bool
    }

    private let identity: PQRCIdentity
    private let randomSource: RandomSource

    private var ikDHPrivate: Curve25519.KeyAgreement.PrivateKey
    private var spkPrivate: Curve25519.KeyAgreement.PrivateKey
    private var pqpkPrivate: MLKEM768.PrivateKey
    /// Keyed by SHA-256 of the public key (the `otp_used` wire reference).
    private var otpPrivate: [Data: Curve25519.KeyAgreement.PrivateKey]
    private var otpPQPrivate: [Data: MLKEM768.PrivateKey]
    private var lrpPrivate: Curve25519.KeyAgreement.PrivateKey
    /// Hashes of consumed one-time prekeys, kept to reject reuse explicitly.
    private var consumedOTPHashes: Set<Data> = []

    public init(identity: PQRCIdentity, randomSource: RandomSource, oneTimeCount: Int = 10) throws {
        self.identity = identity
        self.randomSource = randomSource
        self.ikDHPrivate = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: randomSource.bytes(32))
        self.spkPrivate = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: randomSource.bytes(32))
        self.pqpkPrivate = try MLKEM768.PrivateKey(seedRepresentation: randomSource.bytes(64), publicKey: nil)
        self.lrpPrivate = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: randomSource.bytes(32))
        var otps: [Data: Curve25519.KeyAgreement.PrivateKey] = [:]
        var otpPQs: [Data: MLKEM768.PrivateKey] = [:]
        for _ in 0..<oneTimeCount {
            let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: randomSource.bytes(32))
            otps[sha256(key.publicKey.rawRepresentation)] = key
            let pqKey = try MLKEM768.PrivateKey(seedRepresentation: randomSource.bytes(64), publicKey: nil)
            otpPQs[sha256(pqKey.publicKey.rawRepresentation)] = pqKey
        }
        self.otpPrivate = otps
        self.otpPQPrivate = otpPQs
    }

    public var identityDHPrivateKey: Curve25519.KeyAgreement.PrivateKey { ikDHPrivate }
    public var signedPrekeyPrivateKey: Curve25519.KeyAgreement.PrivateKey { spkPrivate }
    public var oneTimePrekeyCount: Int { otpPrivate.count }

    /// Builds the publishable bundle, signing medium-lived keys with the identity key.
    public func publicBundle() throws -> PrekeyBundle {
        func signed(_ label: String, _ key: Data) throws -> PrekeyBundle.SignedKey {
            let msg = PrekeyBundle.prekeySignatureMessage(label: label, key: key)
            return PrekeyBundle.SignedKey(key: key, sig: try identity.sign(msg))
        }
        // Sorted for a stable wire representation (vector freezing).
        let otpPubs = otpPrivate.values.map(\.publicKey.rawRepresentation).sorted { $0.hexString < $1.hexString }
        let otpPQPubs = otpPQPrivate.values.map(\.publicKey.rawRepresentation).sorted { $0.hexString < $1.hexString }
        return PrekeyBundle(
            identityPubkey: identity.publicKeyData,
            ikDH: try signed("ik_dh", ikDHPrivate.publicKey.rawRepresentation),
            spk: try signed("spk", spkPrivate.publicKey.rawRepresentation),
            pqpk: try signed("pqpk", pqpkPrivate.publicKey.rawRepresentation),
            otp: otpPubs,
            otpPQ: otpPQPubs,
            lrp: try signed("lrp", lrpPrivate.publicKey.rawRepresentation)
        )
    }

    /// Responder side: resolve the private halves an initiator says it used
    /// (D4 wire fields `spk_used` / `otp_used` / `otp_pq_used`, SHA-256 of the
    /// public key). Consumed one-time halves are deleted before returning.
    public func consume(
        spkUsed: Data, otpUsed: Data?, otpPQUsed: Data?, lrpUsed: Bool
    ) throws -> ConsumedPrekeys {
        guard sha256(spkPrivate.publicKey.rawRepresentation) == spkUsed else {
            throw PQRCError.unknownPrekey
        }
        var otp: Curve25519.KeyAgreement.PrivateKey?
        if lrpUsed {
            // Last-resort path: reusable by design; unlinkability caveat documented.
            otp = lrpPrivate
        } else if let otpUsed {
            if consumedOTPHashes.contains(otpUsed) {
                throw PQRCError.oneTimePrekeyAlreadyConsumed
            }
            guard let found = otpPrivate.removeValue(forKey: otpUsed) else {
                throw PQRCError.unknownPrekey
            }
            consumedOTPHashes.insert(otpUsed)
            otp = found
        }
        var otpPQ: MLKEM768.PrivateKey?
        if let otpPQUsed {
            if consumedOTPHashes.contains(otpPQUsed) {
                throw PQRCError.oneTimePrekeyAlreadyConsumed
            }
            guard let found = otpPQPrivate.removeValue(forKey: otpPQUsed) else {
                throw PQRCError.unknownPrekey
            }
            consumedOTPHashes.insert(otpPQUsed)
            otpPQ = found
        }
        return ConsumedPrekeys(
            spk: spkPrivate, otp: otp, otpPQ: otpPQ, pqpk: pqpkPrivate, usedLastResort: lrpUsed
        )
    }
}
