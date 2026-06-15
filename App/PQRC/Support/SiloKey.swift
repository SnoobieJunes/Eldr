import CommonCrypto
import CryptoKit
import Foundation
import PQRCCore

/// Derives a "silo" (an isolated account) deterministically from a passphrase —
/// the cryptographic heart of deniable multi-account on one device.
///
/// `passphrase → PBKDF2 → accountKey → { siloID, kek }`
/// - `siloID` is the OPAQUE namespace for the silo's keychain service + store
///   file. Nothing on disk lists accounts; a silo exists iff someone enters its
///   passphrase. A wrong passphrase derives a *different* siloID whose files
///   simply don't exist — indistinguishable from "no account here" (deniable).
/// - `kek` (key-encryption-key) wraps the silo's secrets (identity + store master
///   key). Without the passphrase the silo's blobs are opaque AES-GCM.
///
/// PBKDF2-HMAC-SHA256 is a vetted system primitive (CommonCrypto), not a custom
/// one — consistent with CLAUDE.md ("compose vetted building blocks"). A FIXED
/// app-wide salt is deliberate: a stored per-account salt would itself reveal that
/// an account exists / how many exist, defeating deniability. We rely on
/// passphrase entropy + a high iteration count instead (encourage strong
/// passphrases). Trade-off recorded in docs/DEVIATIONS.md.
enum SiloKey {
    /// Fixed, app-wide. NOT secret (it ships in the binary); its job is domain
    /// separation, not entropy. Per-account randomness comes from the passphrase.
    private static let appSalt = Data("pqrc-silo-kdf-v1".utf8)
    /// OWASP-class iteration count for PBKDF2-HMAC-SHA256. Calibrate down only if
    /// it exceeds ~400 ms on the oldest supported device.
    static let iterations: UInt32 = 600_000

    struct Derived: Sendable {
        /// Hex namespace for `keychainService` ("chat.pqrc.silo.<siloID>") and the
        /// store file ("<siloID>.store").
        let siloID: String
        /// Wraps the silo's secrets (identity material + EncryptedStore master key).
        let kek: SymmetricKey
    }

    static func derive(passphrase: String) -> Derived {
        let accountKey = pbkdf2(
            passphrase: passphrase, salt: appSalt, iterations: iterations, keyLength: 32)
        let prk = SymmetricKey(data: accountKey)
        let idKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: prk, info: Data("pqrc-silo-id-v1".utf8), outputByteCount: 16)
        let kek = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: prk, info: Data("pqrc-silo-kek-v1".utf8), outputByteCount: 32)
        let siloID = idKey.withUnsafeBytes { Data($0) }
            .map { String(format: "%02x", $0) }.joined()
        return Derived(siloID: siloID, kek: kek)
    }

    /// AES-256-GCM seal of `plaintext` under the silo `kek` (for the secrets blob).
    static func seal(_ plaintext: Data, kek: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: kek)
        guard let combined = sealed.combined else { throw PQRCError.keyWrapFailure }
        return combined
    }

    static func open(_ blob: Data, kek: SymmetricKey) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: blob)
        return try AES.GCM.open(box, using: kek)
    }

    private static func pbkdf2(
        passphrase: String, salt: Data, iterations: UInt32, keyLength: Int
    ) -> Data {
        var derived = Data(count: keyLength)
        let pw = Data(passphrase.utf8)
        let status = derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltBytes in
                pw.withUnsafeBytes { pwBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwBytes.baseAddress?.assumingMemoryBound(to: CChar.self), pw.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                        out.baseAddress?.assumingMemoryBound(to: UInt8.self), keyLength)
                }
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 derivation failed")
        return derived
    }
}
