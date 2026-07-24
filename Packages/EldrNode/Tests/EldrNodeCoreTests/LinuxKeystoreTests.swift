// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import Testing

@testable import eldr_node

// WS-L3 — adversarial coverage for the Linux keystore ladder. FileIdentityStore + the ladder
// compile on every platform, so these run in the macOS suite too (not only in a Linux CI).

private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("eldr-keystore-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func hex(_ key: SymmetricKey) -> String {
    key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
}

@Suite("WS-L3 Linux keystore")
struct LinuxKeystoreTests {

    /// Proves the scrypt binding is the real RFC 7914 algorithm (SPEC §2 — no hand-rolled KDF).
    /// RFC 7914 §12: scrypt(P="", S="", N=16, r=1, p=1, dkLen=64).
    @Test func scryptMatchesRFC7914KAT() throws {
        let key = try LinuxKeystoreScrypt.derive(
            passphrase: Data(), salt: Data(), outputByteCount: 64,
            rounds: 16, blockSize: 1, parallelism: 1)
        #expect(
            hex(key) == "77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442"
                + "fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906")
    }

    @Test func fileStoreRoundTripsAndDeletes() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileIdentityStore(directory: dir, masterKey: SymmetricKey(size: .bits256))
        #expect(store.load(account: "node-nostr-key") == nil)  // absent → nil
        let secret = Data("a-nostr-private-key".utf8)
        try store.save(secret, account: "node-nostr-key")
        #expect(store.load(account: "node-nostr-key") == secret)  // round-trips
        store.delete(account: "node-nostr-key")
        #expect(store.load(account: "node-nostr-key") == nil)  // gone
    }

    /// A stolen disk image must not contain the plaintext: the per-account file is AES-GCM.
    @Test func fileStoreWritesNoPlaintextAndIs0600() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileIdentityStore(directory: dir, masterKey: SymmetricKey(size: .bits256))
        let canary = Data("SUPER-SECRET-CANARY-9d3f".utf8)
        try store.save(canary, account: "node-pqrc-identity-seed")
        let onDisk = try Data(contentsOf: dir.appendingPathComponent("node-pqrc-identity-seed.enc"))
        #expect(onDisk.range(of: canary) == nil)  // plaintext never on disk
        let perms = try FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent("node-pqrc-identity-seed.enc").path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    /// invariant 10: a passphrase KEK is legitimate ONLY where no secure element exists — a
    /// host WITH a TPM must refuse passphrase-only (fail-closed) unless knowingly overridden.
    @Test func ladderRefusesPassphraseWhenTpmPresent() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let env = ["ELDR_NODE_DATA_DIR": dir.path, "ELDR_KEYSTORE_PASSPHRASE": "hunter2"]
        #expect(throws: LinuxKeystoreError.self) {
            _ = try makeLinuxIdentityStore(environment: env, tpmPresent: { true })
        }
        // The explicit override is accepted (operator knowingly takes the weaker posture).
        var overridden = env
        overridden["ELDR_KEYSTORE_ALLOW_NO_TPM"] = "1"
        let (_, posture) = try makeLinuxIdentityStore(environment: overridden, tpmPresent: { true })
        #expect(posture == .passphraseOnDisk)
    }

    /// The posture is DERIVED from the rung that actually resolved the key — a TPM-provided
    /// credential yields `.tpmSealed`; an env passphrase yields `.passphraseOnDisk`. No config
    /// string can claim hardware backing it doesn't have.
    @Test func postureIsDerivedFromRungNotDeclared() throws {
        // env-passphrase rung → on-disk posture
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let (_, onDisk) = try makeLinuxIdentityStore(
            environment: ["ELDR_NODE_DATA_DIR": dir.path, "ELDR_KEYSTORE_PASSPHRASE": "pw"],
            tpmPresent: { false })
        #expect(onDisk == .passphraseOnDisk)
        #expect(!onDisk.isHardwareBacked)

        // systemd-creds TPM rung → tpmSealed posture (takes priority over any passphrase)
        let credDir = tempDir(); defer { try? FileManager.default.removeItem(at: credDir) }
        try FileIdentityStore.writeFile(
            credDir.appendingPathComponent("eldr-node-master"),
            SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        let dir2 = tempDir(); defer { try? FileManager.default.removeItem(at: dir2) }
        let (_, sealed) = try makeLinuxIdentityStore(
            environment: [
                "ELDR_NODE_DATA_DIR": dir2.path, "CREDENTIALS_DIRECTORY": credDir.path,
                "ELDR_KEYSTORE_PASSPHRASE": "pw",
            ], tpmPresent: { true })
        #expect(sealed == .tpmSealed)
        #expect(sealed.isHardwareBacked)
    }

    /// The wrapped master key persists and reloads under the same passphrase — a saved account
    /// survives a node restart.
    @Test func masterKeyPersistsAcrossReopen() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let env = ["ELDR_NODE_DATA_DIR": dir.path, "ELDR_KEYSTORE_PASSPHRASE": "correct-horse"]
        let (store1, _) = try makeLinuxIdentityStore(environment: env, tpmPresent: { false })
        let secret = Data("identity-dh-seed".utf8)
        try store1.save(secret, account: "node-identity-dh")
        // Reopen: unwraps the SAME master key from disk, so the account decrypts.
        let (store2, _) = try makeLinuxIdentityStore(environment: env, tpmPresent: { false })
        #expect(store2.load(account: "node-identity-dh") == secret)
    }

    /// A wrong passphrase must fail closed (the master wrap won't decrypt), never silently
    /// mint a different key that would orphan the stored identity.
    @Test func wrongPassphraseFailsClosed() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try makeLinuxIdentityStore(
            environment: ["ELDR_NODE_DATA_DIR": dir.path, "ELDR_KEYSTORE_PASSPHRASE": "first"],
            tpmPresent: { false })
        #expect(throws: LinuxKeystoreError.self) {
            _ = try makeLinuxIdentityStore(
                environment: ["ELDR_NODE_DATA_DIR": dir.path, "ELDR_KEYSTORE_PASSPHRASE": "WRONG"],
                tpmPresent: { false })
        }
    }

    /// A half-present keystore (only master.wrap OR only master.salt) must fail closed, never
    /// silently mint a fresh master key and orphan the existing identity (audit finding 6).
    @Test func partialKeystoreRefusesRatherThanRemint() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let env = ["ELDR_NODE_DATA_DIR": dir.path, "ELDR_KEYSTORE_PASSPHRASE": "pw"]
        _ = try makeLinuxIdentityStore(environment: env, tpmPresent: { false })  // writes wrap + salt
        try FileManager.default.removeItem(at: dir.appendingPathComponent("master.salt"))
        #expect(throws: LinuxKeystoreError.self) {
            _ = try makeLinuxIdentityStore(environment: env, tpmPresent: { false })
        }
    }

    /// A systemd credential is only labelled `.tpmSealed` when a TPM is actually present —
    /// otherwise the posture must not overclaim hardware backing (audit finding 7 / invariant 10).
    @Test func systemdCredentialWithoutTpmIsNotClaimedHardwareBacked() throws {
        let credDir = tempDir(); defer { try? FileManager.default.removeItem(at: credDir) }
        try FileIdentityStore.writeFile(
            credDir.appendingPathComponent("eldr-node-master"),
            SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let env = ["ELDR_NODE_DATA_DIR": dir.path, "CREDENTIALS_DIRECTORY": credDir.path]
        let (_, noTpm) = try makeLinuxIdentityStore(environment: env, tpmPresent: { false })
        #expect(noTpm == .systemdCredential)
        #expect(!noTpm.isHardwareBacked)
        let (_, withTpm) = try makeLinuxIdentityStore(environment: env, tpmPresent: { true })
        #expect(withTpm == .tpmSealed)
        #expect(withTpm.isHardwareBacked)
    }
}
