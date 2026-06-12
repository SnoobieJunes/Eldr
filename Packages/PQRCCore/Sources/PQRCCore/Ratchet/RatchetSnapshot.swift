import Crypto
import Foundation

/// Codable snapshot of ratchet state for encrypted-at-rest persistence
/// (SPEC §3.4). Contains live secrets — it MUST only ever be stored through
/// `EncryptedStore`; the at-rest canary test enforces no plaintext leakage.
public struct RatchetSnapshot: Codable, Equatable, Sendable {
    public struct SkippedEntry: Codable, Equatable, Sendable {
        public let chain: Data
        public let n: Int
        public let messageKey: Data
    }

    public let rootKey: Data
    public let dhs: Data
    public let dhr: Data?
    public let cks: Data?
    public let ckr: Data?
    public let ns: Int
    public let nr: Int
    public let pn: Int
    public let messagesSinceRekey: Int
    public let rekeyCounter: Int
    public let peerRekeyCounter: Int
    /// Retained KEM private seeds, oldest→newest (current = last).
    public let myKEMSeeds: [Data]
    public let peerKEM: Data
    public let skipped: [SkippedEntry]
    public let pendingOutboundRootFolds: [Data]
    public let pendingInboundRootFolds: [Data]
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
            pendingOutboundRootFolds: pendingOutboundRootFolds,
            pendingInboundRootFolds: pendingInboundRootFolds
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