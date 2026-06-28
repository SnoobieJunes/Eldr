import CryptoKit
import Foundation
import PQRCCore
import os

/// Production `MasterKeyWrapper` for the Huginn macOS app (SPEC §3.4, D9,
/// invariant 10): the 256-bit master storage key is wrapped via Secure Enclave
/// P-256 key agreement. The SE key is hardware-bound and non-exportable; it
/// serves strictly as the root-of-trust for wrapping — the master key it guards
/// is never written to disk unwrapped.
///
/// This is the macOS port of the iOS `SecureEnclaveKeyWrapper`, adapted to
/// Huginn's `KeychainBox` (data-protection keychain, `…WhenUnlockedThisDeviceOnly`,
/// never synced). Logic is identical to the iOS wrapper: ECIES-style ephemeral
/// P-256 agreement against the SE key, HKDF-SHA256 to a 32-byte KEK, AES-256-GCM
/// over the master key.
///
/// Where no Secure Enclave exists, falls back to a software KEK held in the
/// Keychain (device-only). That fallback is recorded in DEVIATIONS [tech-debt]
/// and is tripwired (below) so it can only ever engage off-hardware — engaging
/// it on a machine that HAS an SE would be the exact at-rest brute-force
/// downgrade invariant 10 / DEVIATIONS AC31 closes.
struct MacSecureEnclaveKeyWrapper: MasterKeyWrapper {
    let keychain: KeychainBox
    // Internal (not private) so `ConversationMemory.wipe()` can shred these alongside
    // the wrapped master key.
    static let seKeyAccount = "se-wrapping-key"
    static let softwareKEKAccount = "software-kek-fallback"

    /// Security-channel logger. Only ever emits STATIC, `.public` strings — no
    /// key bytes or conversation-derived material ever reach it (invariant 12).
    private static let log = Logger(subsystem: "chat.eldr.huginn", category: "security")

    init(keychain: KeychainBox = KeychainBox()) {
        self.keychain = keychain
    }

    func wrap(masterKey: Data) throws -> Data {
        if SecureEnclave.isAvailable {
            let sePrivate: SecureEnclave.P256.KeyAgreement.PrivateKey
            if let stored = keychain.load(account: Self.seKeyAccount) {
                sePrivate = try SecureEnclave.P256.KeyAgreement.PrivateKey(
                    dataRepresentation: stored)
            } else {
                sePrivate = try SecureEnclave.P256.KeyAgreement.PrivateKey()
                try keychain.save(sePrivate.dataRepresentation, account: Self.seKeyAccount)
            }
            // ECIES-style: ephemeral P-256 against the SE key, HKDF, AES-GCM.
            let ephemeral = P256.KeyAgreement.PrivateKey()
            let shared = try sePrivate.sharedSecretFromKeyAgreement(with: ephemeral.publicKey)
            let kek = shared.hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: Data("pqrc-se-wrap-v1".utf8),
                sharedInfo: Data(), outputByteCount: 32)
            let sealed = try AES.GCM.seal(masterKey, using: kek)
            guard let combined = sealed.combined else { throw PQRCError.keyWrapFailure }
            return ephemeral.publicKey.x963Representation + combined
        }
        return try softwareWrapper().wrap(masterKey: masterKey)
    }

    func unwrap(wrapped: Data) throws -> Data {
        if SecureEnclave.isAvailable {
            guard wrapped.count > 65,
                let stored = keychain.load(account: Self.seKeyAccount)
            else { throw PQRCError.keyWrapFailure }
            let sePrivate = try SecureEnclave.P256.KeyAgreement.PrivateKey(
                dataRepresentation: stored)
            let ephemeralPublic = try P256.KeyAgreement.PublicKey(
                x963Representation: wrapped.prefix(65))
            let shared = try sePrivate.sharedSecretFromKeyAgreement(with: ephemeralPublic)
            let kek = shared.hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: Data("pqrc-se-wrap-v1".utf8),
                sharedInfo: Data(), outputByteCount: 32)
            do {
                let box = try AES.GCM.SealedBox(combined: wrapped.dropFirst(65))
                return try AES.GCM.open(box, using: kek)
            } catch {
                throw PQRCError.keyWrapFailure
            }
        }
        return try softwareWrapper().unwrap(wrapped: wrapped)
    }

    private func softwareWrapper() throws -> SoftwareKeyWrapper {
        // Tripwire (invariant 10, DEVIATIONS AC31): this software-KEK path is
        // legitimate ONLY where no Secure Enclave exists. If the SE is present
        // yet we reach here, a regression has silently downgraded at-rest
        // wrapping to a software key — the exact stolen-disk-image brute-force
        // risk AC31 closes. Fail loudly in debug, fault-log in release. No key
        // bytes are ever logged; the message is a static `.public` string.
        if SecureEnclave.isAvailable {
            assertionFailure(
                "SE available but software KEK used — invariant 10 regression")
            Self.log.fault(
                "SE available but software KEK used — invariant 10 regression")
        }
        let kek: Data
        if let stored = keychain.load(account: Self.softwareKEKAccount) {
            kek = stored
        } else {
            kek = SystemRandomSource().bytes(32)
            try keychain.save(kek, account: Self.softwareKEKAccount)
        }
        return SoftwareKeyWrapper(keyEncryptionKey: kek, nonceSource: SystemNonceSource())
    }
}