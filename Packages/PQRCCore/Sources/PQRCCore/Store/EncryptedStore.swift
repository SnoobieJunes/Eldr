import Crypto
import Foundation

/// Seam for wrapping the 256-bit master storage key (SPEC §3.4, D9).
/// Production: Secure Enclave P-256 key agreement (app layer, where
/// CryptoKit.SecureEnclave exists). Tests and the macOS package build use a
/// software wrapper. The wrapped blob is what touches disk; the unwrapped
/// master key lives only in memory after first unlock.
public protocol MasterKeyWrapper: Sendable {
    func wrap(masterKey: Data) throws -> Data
    func unwrap(wrapped: Data) throws -> Data
}

/// Software wrapper for tests and platforms without a Secure Enclave.
/// Wraps with AES-256-GCM under a caller-held key-encryption key.
public struct SoftwareKeyWrapper: MasterKeyWrapper {
    private let keyEncryptionKey: SymmetricKey
    private let nonceSource: any NonceSource

    public init(keyEncryptionKey: Data, nonceSource: any NonceSource) {
        self.keyEncryptionKey = SymmetricKey(data: keyEncryptionKey)
        self.nonceSource = nonceSource
    }

    public func wrap(masterKey: Data) throws -> Data {
        let nonce = try AES.GCM.Nonce(data: nonceSource.nextNonce())
        let sealed = try AES.GCM.seal(masterKey, using: keyEncryptionKey, nonce: nonce)
        guard let combined = sealed.combined else { throw PQRCError.keyWrapFailure }
        return combined
    }

    public func unwrap(wrapped: Data) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: wrapped)
            return try AES.GCM.open(box, using: keyEncryptionKey)
        } catch {
            throw PQRCError.keyWrapFailure
        }
    }
}

/// Envelope encryption for sensitive records at rest (APP-SPEC §3, D9):
/// a 256-bit master key (wrapped by `MasterKeyWrapper`, i.e. the Secure
/// Enclave in production) with per-record keys derived via
/// HKDF(master, info: record UUID). Records are AES-256-GCM blobs.
public struct EncryptedStore: Sendable {
    private let masterKey: SymmetricKey
    private let nonceSource: any NonceSource

    /// Create with a fresh master key.
    public init(randomSource: any RandomSource, nonceSource: any NonceSource) {
        self.masterKey = SymmetricKey(data: randomSource.bytes(32))
        self.nonceSource = nonceSource
    }

    /// Reopen with an unwrapped master key.
    public init(masterKey: Data, nonceSource: any NonceSource) {
        self.masterKey = SymmetricKey(data: masterKey)
        self.nonceSource = nonceSource
    }

    public func wrappedMasterKey(using wrapper: any MasterKeyWrapper) throws -> Data {
        try wrapper.wrap(masterKey: masterKey.rawData)
    }

    /// Derive a stable, purpose-scoped sub-key from the master key for an out-of-band
    /// channel that a SEPARATE process must also key — e.g. the eldr-acp metadata files
    /// (`events.jsonl`, `eldr.md`), which the agent process writes and Huginn reads. Same
    /// HKDF construction as `recordKey` but `label` as `info`, so callers get a deterministic
    /// 32-byte key tied to the SE-wrapped master key (one root of trust). The returned bytes
    /// are sensitive: never log or persist them in the clear (invariant 12).
    ///
    /// - Important: `label` and `recordID` (see `recordKey`) share ONE HKDF namespace —
    ///   same salt, and the raw string as `info`. A `label` that equals some `recordID`
    ///   therefore derives the IDENTICAL key. Labels are consequently RESERVED: use a
    ///   distinctive, versioned constant (`"acp-metadata-v1"`), never anything a record
    ///   ID could be (a UUID, a `session-<peer>` key). This is deliberately NOT fixed by
    ///   adding a domain prefix: `info` feeds the derivation, so any change would silently
    ///   orphan every record already sealed on disk (the phone's message store, the Mac's
    ///   AI transcripts, the sealed metadata files). Closing it properly means bumping the
    ///   salt to `pqrc-store-v2` behind a re-seal MIGRATION, not an in-place edit.
    ///   Impact today is a hygiene gap, not a break: every `seal` draws a fresh nonce, so a
    ///   collision would reuse a key but never a key+nonce pair. Tracked in DEVIATIONS.
    public func deriveKey(label: String, byteCount: Int = 32) -> Data {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: Data("pqrc-store-v1".utf8),
            info: Data(label.utf8),
            outputByteCount: byteCount
        ).rawData
    }

    private func recordKey(for recordID: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: Data("pqrc-store-v1".utf8),
            info: Data(recordID.utf8),
            outputByteCount: 32
        )
    }

    /// Encrypts a record payload. Output layout: nonce(12) || ciphertext || tag(16).
    public func seal(_ plaintext: Data, recordID: String) throws -> Data {
        let nonceData = nonceSource.nextNonce()
        let sealed = try AES.GCM.seal(
            plaintext, using: recordKey(for: recordID), nonce: AES.GCM.Nonce(data: nonceData)
        )
        return nonceData + sealed.ciphertext + sealed.tag
    }

    public func open(_ blob: Data, recordID: String) throws -> Data {
        guard blob.count >= 28 else { throw PQRCError.decryptionFailed }
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: blob.prefix(12)),
                ciphertext: blob.dropFirst(12).dropLast(16),
                tag: blob.suffix(16)
            )
            return try AES.GCM.open(box, using: recordKey(for: recordID))
        } catch {
            throw PQRCError.decryptionFailed
        }
    }
}
