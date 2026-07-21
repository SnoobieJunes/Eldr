// SPDX-License-Identifier: AGPL-3.0-only
import CommonCrypto
import CryptoKit
import Foundation
import PQRCCore

/// Resolves the OPAQUE namespace ("siloID") of a deniable hidden account from its
/// passphrase. Per AC31 (SPEC §3.4) the passphrase determines ONLY which namespace
/// to open — NOT the at-rest key. The silo's key-encryption-key is a RANDOM key
/// hardware-wrapped by the Secure Enclave (see `AccountVault`), so a stolen-device
/// image can't be brute-forced even if the namespace is guessed; the passphrase is
/// an optional second factor (`passphraseKEK`), never the sole barrier.
///
/// `passphrase → PBKDF2 → HKDF("…-id-v1") → siloID`
/// - `siloID` is the namespace for the silo's keychain service + store file.
///   Nothing on disk lists accounts; a hidden silo exists iff someone enters its
///   passphrase. A wrong passphrase yields a *different* siloID whose files don't
///   exist — indistinguishable from "no account here" (deniable).
///
/// PBKDF2-HMAC-SHA256 is a vetted system primitive (CommonCrypto), not a custom
/// one — consistent with CLAUDE.md ("compose vetted building blocks"). A FIXED
/// app-wide salt is deliberate: a stored per-account salt would itself reveal that
/// an account exists / how many. Confidentiality no longer rests on passphrase
/// entropy (the SE wrap does), so the fixed salt costs only a passphrase-guessing
/// *confirmation* oracle to someone who can already enumerate the keychain — not a
/// confidentiality break. Trade-off recorded in DEVIATIONS AC31.
enum SiloKey {
    /// Fixed, app-wide. NOT secret (it ships in the binary); its job is domain
    /// separation, not entropy. Per-account randomness comes from the passphrase.
    private static let appSalt = Data("pqrc-silo-kdf-v1".utf8)
    /// OWASP-class iteration count for PBKDF2-HMAC-SHA256. Calibrate down only if
    /// it exceeds ~400 ms on the oldest supported device.
    static let iterations: UInt32 = 600_000

    /// The opaque namespace a passphrase resolves to. Same passphrase → same
    /// siloID (so a hidden account reopens); a different passphrase → a different,
    /// non-existent namespace (deniable). 16 bytes, hex. This is ONLY a selector —
    /// the at-rest key is the SE-wrapped random KEK held by `AccountVault`.
    static func siloID(for passphrase: String) -> String {
        let accountKey = pbkdf2(
            passphrase: passphrase, salt: appSalt, iterations: iterations, keyLength: 32)
        let idKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: accountKey),
            info: Data("pqrc-silo-id-v1".utf8), outputByteCount: 16)
        return idKey.withUnsafeBytes { Data($0) }
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Derive a key-encryption-key from a passphrase for the OPTIONAL passphrase layer
    /// nested UNDER the Secure-Enclave wrap (see `AccountVault`, DEVIATIONS AC31). PBKDF2
    /// is sufficient here because brute-forcing this layer ALSO requires the non-exportable
    /// Secure-Enclave key — it's a second factor, not the sole barrier.
    static func passphraseKEK(_ passphrase: String) -> SymmetricKey {
        let accountKey = pbkdf2(
            passphrase: passphrase, salt: appSalt, iterations: iterations, keyLength: 32)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: accountKey),
            info: Data("pqrc-passphrase-kek-v1".utf8), outputByteCount: 32)
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
