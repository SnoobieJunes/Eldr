// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation

/// Codable prekey-state snapshot (T2). Private halves are keyed by the same
/// SHA-256-of-public-key hashes the wire uses (`otp_used` / `otp_pq_used`),
/// so a restored manager resolves handshakes addressed to any previously
/// published bundle. Contains live secrets — Keychain or `EncryptedStore`
/// storage only, never plaintext at rest.
public struct PrekeyState: Codable, Sendable {
    // Private-key material is `var` (read-only public surface via `internal(set)`)
    // so `zeroize()` can wipe the in-memory plaintext after it has been
    // serialized + encrypted at rest. The dictionary *keys* and `consumed` are
    // SHA-256-of-public-key hashes — not secret — and stay `let`/untouched.
    public internal(set) var ikDH: Data
    public internal(set) var spk: Data
    public internal(set) var pqpkSeed: Data
    public internal(set) var otps: [Data: Data]
    public internal(set) var otpPQSeeds: [Data: Data]
    public internal(set) var lrp: Data
    public let consumed: Set<Data>

    public init(
        ikDH: Data, spk: Data, pqpkSeed: Data, otps: [Data: Data],
        otpPQSeeds: [Data: Data], lrp: Data, consumed: Set<Data>
    ) {
        self.ikDH = ikDH
        self.spk = spk
        self.pqpkSeed = pqpkSeed
        self.otps = otps
        self.otpPQSeeds = otpPQSeeds
        self.lrp = lrp
        self.consumed = consumed
    }

    /// Wipes every private-key byte buffer this state holds: identity DH, signed
    /// prekey, PQ prekey seed, all one-time prekey private halves (DH + KEM
    /// seeds), and the last-resort key. Call ONCE the state has been serialized
    /// and the resulting blob encrypted at rest — never before, or the persisted
    /// ciphertext would be built from zeroed plaintext. The `otp_used`-style
    /// hash keys and `consumed` set are public-derived and left intact. After
    /// this the state is no longer usable for restore.
    public mutating func zeroize() {
        ikDH.zeroize()
        spk.zeroize()
        pqpkSeed.zeroize()
        lrp.zeroize()
        // Snapshot keys before mutating values: mutating a dictionary value can
        // trigger copy-on-write and invalidate a live `.keys` iterator.
        for key in Array(otps.keys) { otps[key]?.zeroize() }
        for key in Array(otpPQSeeds.keys) { otpPQSeeds[key]?.zeroize() }
    }
}

/// Owns prekey private halves: generation, consumption, deletion (actor —
/// CLAUDE.md: actors own all mutable session state).
///
/// Invariant 11: consumed one-time prekey private halves are deleted; reuse is
/// rejected; exhaustion falls back to the last-resort key (flagged, documented
/// unlinkability caveat — never a confidentiality downgrade).
public actor PrekeyManager {
    public struct ConsumedPrekeys: Sendable {
        /// Our long-term X25519 identity key — PQXDH's `IK_B`, needed for dh2.
        public let ikDH: Curve25519.KeyAgreement.PrivateKey
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

    /// Restore from a persisted snapshot (T2): a handshake addressed to a
    /// bundle published before the last relaunch must still resolve its
    /// one-time prekey, or offline-initiated sessions break across launches.
    public init(identity: PQRCIdentity, randomSource: RandomSource, state: PrekeyState) throws {
        self.identity = identity
        self.randomSource = randomSource
        self.ikDHPrivate = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: state.ikDH)
        self.spkPrivate = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: state.spk)
        self.pqpkPrivate = try MLKEM768.PrivateKey(seedRepresentation: state.pqpkSeed, publicKey: nil)
        self.lrpPrivate = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: state.lrp)
        var otps: [Data: Curve25519.KeyAgreement.PrivateKey] = [:]
        for (hash, raw) in state.otps {
            otps[hash] = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
        }
        var otpPQs: [Data: MLKEM768.PrivateKey] = [:]
        for (hash, seed) in state.otpPQSeeds {
            otpPQs[hash] = try MLKEM768.PrivateKey(seedRepresentation: seed, publicKey: nil)
        }
        self.otpPrivate = otps
        self.otpPQPrivate = otpPQs
        self.consumedOTPHashes = state.consumed
    }

    /// Snapshot for persistence. Contains live private halves — it MUST only
    /// ever be stored in the Keychain or through `EncryptedStore` (SPEC §3.4);
    /// the at-rest canary test enforces no plaintext leakage.
    public func snapshot() -> PrekeyState {
        PrekeyState(
            ikDH: ikDHPrivate.rawRepresentation,
            spk: spkPrivate.rawRepresentation,
            pqpkSeed: pqpkPrivate.seedRepresentation,
            otps: otpPrivate.mapValues(\.rawRepresentation),
            otpPQSeeds: otpPQPrivate.mapValues(\.seedRepresentation),
            lrp: lrpPrivate.rawRepresentation,
            consumed: consumedOTPHashes
        )
    }

    /// Tops the one-time pools back up to `target`. Returns true if any key
    /// was generated (caller should re-snapshot and republish the bundle).
    /// Replenishment never touches consumed hashes: a replayed handshake
    /// against an old, consumed prekey stays rejected forever.
    public func replenish(to target: Int) throws -> Bool {
        var generated = false
        while otpPrivate.count < target {
            let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: randomSource.bytes(32))
            otpPrivate[sha256(key.publicKey.rawRepresentation)] = key
            generated = true
        }
        while otpPQPrivate.count < target {
            let pqKey = try MLKEM768.PrivateKey(seedRepresentation: randomSource.bytes(64), publicKey: nil)
            otpPQPrivate[sha256(pqKey.publicKey.rawRepresentation)] = pqKey
            generated = true
        }
        return generated
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
    /// Validate a handshake, then resolve the private halves it references.
    /// **Prefer this over the field-by-field overload** — it cannot be called in
    /// the wrong order, so a forged or malformed handshake is rejected before it
    /// can spend a one-time prekey (invariant 11).
    public func consume(_ message: HandshakeMessage) throws -> ConsumedPrekeys {
        try message.validate()
        return try consume(
            spkUsed: message.spkUsed, otpUsed: message.otpUsed,
            otpPQUsed: message.otpPQUsed, lrpUsed: message.lrpUsed)
    }

    /// Resolve the private halves an initiator says it used (D4 wire fields
    /// `spk_used` / `otp_used` / `otp_pq_used`, SHA-256 of the public key).
    /// Consumed one-time halves are deleted before returning.
    ///
    /// Everything is resolved BEFORE anything is deleted. Previously the DH
    /// one-time half was removed and marked consumed, and only then was the PQ
    /// half looked up — so a message pairing a real `otp_used` with a garbage
    /// `otp_pq_used` threw, kept nothing, and still burned a published prekey.
    /// That is a pool drain costing the sender nothing.
    ///
    /// Performs no message-level validation; unless you are resolving prekeys
    /// for something other than a `HandshakeMessage`, call ``consume(_:)``.
    public func consume(
        spkUsed: Data, otpUsed: Data?, otpPQUsed: Data?, lrpUsed: Bool
    ) throws -> ConsumedPrekeys {
        guard sha256(spkPrivate.publicKey.rawRepresentation) == spkUsed else {
            throw PQRCError.unknownPrekey
        }
        guard !(lrpUsed && otpUsed != nil) else {
            throw PQRCError.handshakeMalformed
        }

        // ---- Resolve. Nothing is mutated in this phase. ----
        var otp: Curve25519.KeyAgreement.PrivateKey?
        if lrpUsed {
            // Last-resort path: reusable by design; unlinkability caveat documented.
            otp = lrpPrivate
        } else if let otpUsed {
            guard !consumedOTPHashes.contains(otpUsed) else {
                throw PQRCError.oneTimePrekeyAlreadyConsumed
            }
            guard let found = otpPrivate[otpUsed] else { throw PQRCError.unknownPrekey }
            otp = found
        }
        var otpPQ: MLKEM768.PrivateKey?
        if let otpPQUsed {
            guard !consumedOTPHashes.contains(otpPQUsed) else {
                throw PQRCError.oneTimePrekeyAlreadyConsumed
            }
            guard let found = otpPQPrivate[otpPQUsed] else { throw PQRCError.unknownPrekey }
            otpPQ = found
        }

        // ---- Commit. Past this point nothing can throw. ----
        if !lrpUsed, let otpUsed {
            otpPrivate.removeValue(forKey: otpUsed)
            consumedOTPHashes.insert(otpUsed)
        }
        if let otpPQUsed {
            otpPQPrivate.removeValue(forKey: otpPQUsed)
            consumedOTPHashes.insert(otpPQUsed)
        }

        return ConsumedPrekeys(
            ikDH: ikDHPrivate, spk: spkPrivate, otp: otp, otpPQ: otpPQ,
            pqpk: pqpkPrivate, usedLastResort: lrpUsed
        )
    }
}
