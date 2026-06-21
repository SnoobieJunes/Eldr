import CryptoKit
import Foundation
import Testing

@testable import EldrChat

/// AC31: the silo key is RANDOM and hardware-wrapped by the Secure Enclave (not
/// passphrase-derived), optionally nested under a passphrase. A disk image without the
/// live, non-exportable SE key cannot unwrap it — even with the right passphrase.
///
/// On the simulator `SecureEnclave.isAvailable == false`, so the wrapper uses its
/// documented software fallback; these tests verify the vault's LOGIC (round-trip, the
/// passphrase layer, no-plaintext-at-rest). The real Secure Enclave path is exercised on
/// device by `SecuritySuiteTests.secureEnclaveWrapper_roundTripsOnThisHost`.
@Suite("AccountVault (SE-wrapped silo key, AC31)")
struct AccountVaultTests {
    private func freshVault() -> (AccountVault, KeychainStore) {
        let keychain = KeychainStore(service: "test-vault-\(UUID().uuidString)")
        return (AccountVault(keychain: keychain), keychain)
    }

    private func cleanup(_ keychain: KeychainStore) {
        for account in [AccountVault.wrappedKEKAccount, "se-wrapping-key", "software-kek-fallback"] {
            keychain.delete(account: account)
        }
    }

    @Test func secureEnclaveOnly_createThenOpen_roundTrips() throws {
        let (vault, keychain) = freshVault()
        defer { cleanup(keychain) }
        let created = try vault.create(unlock: .secureEnclave)
        #expect(try vault.open(unlock: .secureEnclave) == created)
    }

    @Test func passphrase_correctOpens_wrongFails() throws {
        let (vault, keychain) = freshVault()
        defer { cleanup(keychain) }
        let created = try vault.create(unlock: .passphrase("correct horse battery staple"))
        #expect(try vault.open(unlock: .passphrase("correct horse battery staple")) == created)
        #expect(throws: (any Error).self) {
            _ = try vault.open(unlock: .passphrase("wrong passphrase"))
        }
    }

    @Test func existsReflectsCreation() throws {
        let (vault, keychain) = freshVault()
        defer { cleanup(keychain) }
        #expect(!vault.exists())
        _ = try vault.create(unlock: .secureEnclave)
        #expect(vault.exists())
    }

    @Test func storedBlobIsWrapped_neverThePlaintextKey() throws {
        let (vault, keychain) = freshVault()
        defer { cleanup(keychain) }
        let created = try vault.create(unlock: .secureEnclave)
        let rawKey = created.withUnsafeBytes { Data($0) }
        let wrapped = try #require(keychain.loadIfPresent(account: AccountVault.wrappedKEKAccount))
        #expect(wrapped.range(of: rawKey) == nil, "the stored blob must be wrapped, not the plaintext key")
    }
}
