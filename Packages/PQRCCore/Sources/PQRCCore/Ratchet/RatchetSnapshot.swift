// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation

/// Codable snapshot of ratchet state for encrypted-at-rest persistence
/// (SPEC §3.4). Contains live secrets — it MUST only ever be stored through
/// `EncryptedStore`; the at-rest canary test enforces no plaintext leakage.
public struct RatchetSnapshot: Codable, Equatable, Sendable {
    public struct SkippedEntry: Codable, Equatable, Sendable {
        public let chain: Data
        public let n: Int
        // `var` so `RatchetSnapshot.zeroize()` can wipe the cached message key.
        public internal(set) var messageKey: Data
    }

    // Secret-bearing fields are `var` so `zeroize()` can wipe the in-memory
    // plaintext after it has been serialized + encrypted at rest (call sites in
    // the app layer). Public-key material (`dhr`, `peerKEM`) and counters stay
    // `let`. `internal(set)` keeps the public surface read-only while permitting
    // the in-package wipe.
    public internal(set) var rootKey: Data
    public internal(set) var dhs: Data
    public let dhr: Data?
    public internal(set) var cks: Data?
    public internal(set) var ckr: Data?
    public let ns: Int
    public let nr: Int
    public let pn: Int
    public let messagesSinceRekey: Int
    public let rekeyCounter: Int
    public let peerRekeyCounter: Int
    /// Retained KEM private seeds, oldest→newest (current = last).
    public internal(set) var myKEMSeeds: [Data]
    public let peerKEM: Data
    public internal(set) var skipped: [SkippedEntry]
    public internal(set) var pendingOutboundRootFolds: [Data]
    public internal(set) var pendingInboundRootFolds: [Data]

    /// Wipes every secret byte buffer this snapshot holds: root key, send/recv
    /// chain keys, our DH private half, KEM private seeds, cached message keys,
    /// and the pending root-fold shared secrets. Call ONCE the snapshot has been
    /// serialized and the resulting blob encrypted at rest — never before, or
    /// the persisted ciphertext would be built from zeroed plaintext. Public
    /// keys (`dhr`, `peerKEM`) and `Int` counters are not secret and left
    /// intact. After this the snapshot is no longer usable for restore.
    public mutating func zeroize() {
        rootKey.zeroize()
        dhs.zeroize()
        cks?.zeroize()
        ckr?.zeroize()
        for i in myKEMSeeds.indices { myKEMSeeds[i].zeroize() }
        for i in skipped.indices { skipped[i].messageKey.zeroize() }
        for i in pendingOutboundRootFolds.indices { pendingOutboundRootFolds[i].zeroize() }
        for i in pendingInboundRootFolds.indices { pendingInboundRootFolds[i].zeroize() }
    }
}

extension DoubleRatchet {
    public func makeSnapshot() -> RatchetSnapshot {
        RatchetSnapshot(
            rootKey: rootKey.rawData,
            dhs: dhs.rawRepresentation,
            dhr: dhr,
            cks: cks?.rawData,
            ckr: ckr?.rawData,
            ns: ns,
            nr: nr,
            pn: pn,
            messagesSinceRekey: messagesSinceRekey,
            rekeyCounter: rekeyCounter,
            peerRekeyCounter: peerRekeyCounter,
            myKEMSeeds: myKEMs.map(\.key.seedRepresentation),
            peerKEM: peerKEM,
            skipped: skipped.map {
                RatchetSnapshot.SkippedEntry(chain: $0.chain, n: $0.n, messageKey: $0.messageKey.rawData)
            },
            // Deep-copy the fold shared-secrets so each element owns a fresh,
            // independent buffer (like every other secret field above, which go
            // through `.rawData` / `.rawRepresentation`). A plain by-value
            // `[Data]` copy shares copy-on-write backing with the LIVE ratchet's
            // pending folds, so a future in-place wipe of the snapshot
            // (`zeroize()`) could corrupt the running session. `Data(_:)` forces
            // a unique copy per element, breaking the aliasing.
            pendingOutboundRootFolds: pendingOutboundRootFolds.map { Data($0) },
            pendingInboundRootFolds: pendingInboundRootFolds.map { Data($0) }
        )
    }

    public init(snapshot: RatchetSnapshot, randomSource: any RandomSource) throws {
        self.init(
            rootKey: SymmetricKey(data: snapshot.rootKey),
            dhs: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: snapshot.dhs),
            dhr: snapshot.dhr,
            cks: snapshot.cks.map { SymmetricKey(data: $0) },
            ckr: snapshot.ckr.map { SymmetricKey(data: $0) },
            ns: snapshot.ns,
            nr: snapshot.nr,
            pn: snapshot.pn,
            messagesSinceRekey: snapshot.messagesSinceRekey,
            rekeyCounter: snapshot.rekeyCounter,
            peerRekeyCounter: snapshot.peerRekeyCounter,
            myKEMs: try snapshot.myKEMSeeds.map { seed in
                let key = try MLKEM768.PrivateKey(seedRepresentation: seed, publicKey: nil)
                return KEMKey(pubkeyHash: sha256(key.publicKey.rawRepresentation), key: key)
            },
            peerKEM: snapshot.peerKEM,
            skipped: snapshot.skipped.map {
                SkippedKey(chain: $0.chain, n: $0.n, messageKey: SymmetricKey(data: $0.messageKey))
            },
            pendingOutboundRootFolds: snapshot.pendingOutboundRootFolds,
            pendingInboundRootFolds: snapshot.pendingInboundRootFolds,
            randomSource: randomSource
        )
    }

    init(
        rootKey: SymmetricKey, dhs: Curve25519.KeyAgreement.PrivateKey, dhr: Data?,
        cks: SymmetricKey?, ckr: SymmetricKey?, ns: Int, nr: Int, pn: Int,
        messagesSinceRekey: Int, rekeyCounter: Int, peerRekeyCounter: Int,
        myKEMs: [KEMKey], peerKEM: Data,
        skipped: [SkippedKey],
        pendingOutboundRootFolds: [Data], pendingInboundRootFolds: [Data],
        randomSource: any RandomSource
    ) {
        self.randomSource = randomSource
        self.rootKey = rootKey
        self.dhs = dhs
        self.dhr = dhr
        self.cks = cks
        self.ckr = ckr
        self.ns = ns
        self.nr = nr
        self.pn = pn
        self.messagesSinceRekey = messagesSinceRekey
        self.rekeyCounter = rekeyCounter
        self.peerRekeyCounter = peerRekeyCounter
        self.myKEMs = myKEMs
        self.peerKEM = peerKEM
        self.skipped = skipped
        self.pendingOutboundRootFolds = pendingOutboundRootFolds
        self.pendingInboundRootFolds = pendingInboundRootFolds
    }
}