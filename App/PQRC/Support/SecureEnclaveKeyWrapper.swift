import CryptoKit
import Foundation
import PQRCCore

/// Production `MasterKeyWrapper` (SPEC §3.4, D9): the master storage key is
/// wrapped via Secure Enclave P-256 key agreement. The SE key is hardware-bound
/// and non-exportable; it serves strictly as root-of-trust for wrapping.
///
/// Where no Secure Enclave exists (some simulators), falls back to a software
/// KEK held in the Keychain (device-only). The fallback is recorded in
/// DEVIATIONS [tech-debt] and only ever engages off-hardware.
struct SecureEnclaveKeyWrapper: MasterKeyWrapper {
    private let keychain: KeychainStore
    private static let seKeyAccount = "se-wrapping-key"
    private static let softwareKEKAccount = "software-kek-fallback"

    init(keychain: KeychainStore) {
        self.keychain = keychain
    }

    func wrap(masterKey: Data) throws -> Data {
        if SecureEnclave.isAvailable {
            let sePrivate: SecureEnclave.P256.KeyAgreement.PrivateKey
            if let stored = keychain.loadIfPresent(account: Self.seKeyAccount) {
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
                let stored = keychain.loadIfPresent(account: Self.seKeyAccount)
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
            Log.store.fault(
                "SE available but software KEK used — invariant 10 regression")
        }
        let kek: Data
        if let stored = keychain.loadIfPresent(account: Self.softwareKEKAccount) {
            kek = stored
        } else {
            kek = SystemRandomSource().bytes(32)
            try keychain.save(kek, account: Self.softwareKEKAccount)
        }
        return SoftwareKeyWrapper(keyEncryptionKey: kek, nonceSource: SystemNonceSource())
    }
}
