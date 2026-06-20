import CryptoKit
import Foundation
import PQRCCore

/// How an account's silo key is unlocked. The Secure Enclave hardware-wraps the silo key
/// in EVERY case (SPEC §3.4 — non-exportable, can't be brute-forced or pulled from a
/// backup); a **passphrase** is an OPTIONAL factor the user requires at setup, nested
/// UNDER the SE wrap so even an *unlocked* device needs it. (Biometric is a separate,
/// additive convenience — the existing `.userPresence` tier caches the recovered silo key
/// behind Face ID / Touch ID — and is orthogonal to this enum.)
enum AccountUnlock: Sendable, Equatable {
    /// SE-only: opens whenever the device is unlocked. No extra factor.
    case secureEnclave
    /// SE + a passphrase required on every unlock.
    case passphrase(String)
}

/// Stores and recovers an account's RANDOM silo key — the KEK that seals the account's
/// identity material and roots its store master key. The silo key is hardware-wrapped by
/// the Secure Enclave (SPEC §3.4), optionally nested under a passphrase. This REPLACES the
/// old passphrase-DERIVED silo KEK (PBKDF2 + fixed salt), which was offline-brute-forceable
/// from a stolen-device image (DEVIATIONS AC31).
///
/// Layering, per the chosen unlock method:
/// - `.secureEnclave`  →  `wrapped = SE.wrap(siloKEK)`
/// - `.passphrase(p)`  →  `wrapped = SE.wrap( AES-GCM(PBKDF2(p), siloKEK) )`
///
/// Recovery reverses it. A disk image **without the live, non-exportable SE key cannot
/// unwrap either form — even with the correct passphrase** — so there is no offline
/// brute-force surface; the passphrase layer is a second factor, not the sole barrier.
/// Composes only vetted primitives (SE ECIES + AES-256-GCM + PBKDF2/HKDF) per SPEC §2.
struct AccountVault {
    private let keychain: KeychainStore
    private let randomSource: any RandomSource
    /// Account name (within the silo's keychain service) holding the wrapped silo key.
    static let wrappedKEKAccount = "wrapped-silo-kek"

    init(keychain: KeychainStore, randomSource: any RandomSource = SystemRandomSource()) {
        self.keychain = keychain
        self.randomSource = randomSource
    }

    /// Create a fresh account: generate a random silo key, hardware-wrap it (+ the
    /// optional passphrase layer), persist the wrapped blob, and return the silo key to
    /// boot with.
    @discardableResult
    func create(unlock: AccountUnlock) throws -> SymmetricKey {
        let siloKEK = SymmetricKey(data: randomSource.bytes(32))
        let inner = try innerWrap(siloKEK, unlock: unlock)
        let wrapped = try SecureEnclaveKeyWrapper(keychain: keychain).wrap(masterKey: inner)
        try keychain.save(wrapped, account: Self.wrappedKEKAccount)
        return siloKEK
    }

    /// Recover the silo key for an existing account. Throws `keyWrapFailure` if absent, if
    /// the SE can't unwrap (wrong device), or — for `.passphrase` — if the passphrase is
    /// wrong (the caller treats that as "wrong passphrase").
    func open(unlock: AccountUnlock) throws -> SymmetricKey {
        guard let wrapped = keychain.loadIfPresent(account: Self.wrappedKEKAccount) else {
            throw PQRCError.keyWrapFailure
        }
        let inner = try SecureEnclaveKeyWrapper(keychain: keychain).unwrap(wrapped: wrapped)
        return try innerUnwrap(inner, unlock: unlock)
    }

    /// Whether this silo has a stored (SE-wrapped) key.
    func exists() -> Bool { keychain.loadIfPresent(account: Self.wrappedKEKAccount) != nil }

    // MARK: - passphrase layer (nested under the SE wrap)

    private func innerWrap(_ siloKEK: SymmetricKey, unlock: AccountUnlock) throws -> Data {
        let raw = siloKEK.withUnsafeBytes { Data($0) }
        switch unlock {
        case .secureEnclave: return raw
        case .passphrase(let pass): return try SiloKey.seal(raw, kek: SiloKey.passphraseKEK(pass))
        }
    }

    private func innerUnwrap(_ inner: Data, unlock: AccountUnlock) throws -> SymmetricKey {
        switch unlock {
        case .secureEnclave: return SymmetricKey(data: inner)
        case .passphrase(let pass):
            return SymmetricKey(data: try SiloKey.open(inner, kek: SiloKey.passphraseKEK(pass)))
        }
    }
}
