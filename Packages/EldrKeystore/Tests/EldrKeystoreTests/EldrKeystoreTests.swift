// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import Testing

@testable import EldrKeystore

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("eldr-ks-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}
private func hex(_ k: SymmetricKey) -> String {
    k.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
}

@Suite("Shared Linux keystore")
struct EldrKeystoreTests {
    /// RFC 7914 §12 KAT — the scrypt binding is the real algorithm.
    @Test func scryptKAT() throws {
        let k = try LinuxKeystoreScrypt.derive(
            passphrase: Data(), salt: Data(), outputByteCount: 64, rounds: 16, blockSize: 1, parallelism: 1)
        #expect(hex(k) == "77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442"
            + "fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906")
    }

    /// On-disk compatibility pin for keystores written BEFORE the move: a file sealed with
    /// HKDF(master, salt "eldr-node/keystore/v1", info account) must still open.
    @Test func eldrNodeProfile_readsPreMoveFormat() throws {
        let dir = tempDir()
        let master = SymmetricKey(size: .bits256)
        let k = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: master, salt: Data("eldr-node/keystore/v1".utf8),
            info: Data("node-nostr-key".utf8), outputByteCount: 32)
        let sealed = try AES.GCM.seal(Data("legacy".utf8), using: k).combined!
        try sealed.write(to: dir.appendingPathComponent("node-nostr-key.enc"))
        let store = FileIdentityStore(directory: dir, masterKey: master, profile: .eldrNode)
        #expect(store.load(account: "node-nostr-key") == Data("legacy".utf8))
    }

    /// Profiles are cryptographically separate: same master key + account, different files.
    @Test func profilesDoNotCrossDecrypt() throws {
        let dir = tempDir()
        let master = SymmetricKey(size: .bits256)
        try FileIdentityStore(directory: dir, masterKey: master, profile: .eldrChat)
            .save(Data("chat".utf8), account: "keys")
        #expect(FileIdentityStore(directory: dir, masterKey: master, profile: .eldrNode)
            .load(account: "keys") == nil)
    }

    @Test func profileEnvNamesAndCredential_areHonoured() throws {
        let dir = tempDir()
        // Node env var must NOT unlock a chat keystore, and vice versa.
        #expect(throws: LinuxKeystoreError.self) {
            _ = try makeLinuxKeystore(directory: dir, profile: .eldrChat,
                environment: ["ELDR_KEYSTORE_PASSPHRASE": "pw-long-enough-1"], tpmPresent: { false })
        }
        let (_, p) = try makeLinuxKeystore(directory: dir, profile: .eldrChat,
            environment: ["ELDR_CHAT_PASSPHRASE": "pw-long-enough-1"], tpmPresent: { false })
        #expect(p == .passphraseOnDisk)
        let cred = tempDir()
        try FileIdentityStore.writeFile(cred.appendingPathComponent("eldr-chat-master"),
            SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        let (_, sealed) = try makeLinuxKeystore(directory: tempDir(), profile: .eldrChat,
            environment: ["CREDENTIALS_DIRECTORY": cred.path], tpmPresent: { true })
        #expect(sealed == .tpmSealed)
    }

    @Test func roundTrip_noPlaintext_0600_wrongPassphraseFailsClosed() throws {
        let dir = tempDir()
        let env = ["ELDR_CHAT_PASSPHRASE": "correct-long-phrase"]
        let (s, _) = try makeLinuxKeystore(directory: dir, profile: .eldrChat, environment: env, tpmPresent: { false })
        try s.save(Data("CANARY-123".utf8), account: "a")
        let raw = try Data(contentsOf: dir.appendingPathComponent("a.enc"))
        #expect(raw.range(of: Data("CANARY-123".utf8)) == nil)
        let perms = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("a.enc").path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        let (s2, _) = try makeLinuxKeystore(directory: dir, profile: .eldrChat, environment: env, tpmPresent: { false })
        #expect(s2.load(account: "a") == Data("CANARY-123".utf8))
        #expect(throws: LinuxKeystoreError.self) {
            _ = try makeLinuxKeystore(directory: dir, profile: .eldrChat,
                environment: ["ELDR_CHAT_PASSPHRASE": "wrong"], tpmPresent: { false })
        }
        #expect(throws: LinuxKeystoreError.self) {
            _ = try makeLinuxKeystore(directory: tempDir(), profile: .eldrChat, environment: env, tpmPresent: { true })
        }
    }

    @Test func atomicWrite_replacesAndLeavesNoTempFiles() throws {
        let dir = tempDir()
        let s = FileIdentityStore(directory: dir, masterKey: SymmetricKey(size: .bits256), profile: .eldrChat)
        try s.save(Data("v1".utf8), account: "a")
        try s.save(Data("v2".utf8), account: "a")
        #expect(s.load(account: "a") == Data("v2".utf8))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names == ["a.enc"])
    }
}

@Suite("Audit: passphrase file permissions")
struct AuditPassphraseFileTests {
    @Test func worldReadablePassphraseFileIsRefused() throws {
        let dir = tempDir()
        let pf = dir.appendingPathComponent("pass")
        FileManager.default.createFile(atPath: pf.path, contents: Data("canary-pass-123".utf8), attributes: [.posixPermissions: 0o644])
        let env = ["ELDR_CHAT_PASSPHRASE_FILE": pf.path]
        #expect(throws: LinuxKeystoreError.self) {
            _ = try makeLinuxKeystore(directory: dir.appendingPathComponent("st"), profile: .eldrChat, environment: env, tpmPresent: { false })
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pf.path)
        let (_, posture) = try makeLinuxKeystore(directory: dir.appendingPathComponent("st"), profile: .eldrChat, environment: env, tpmPresent: { false })
        #expect(posture == .passphraseOnDisk)
        // Canary: the passphrase never lands in the state dir in clear.
        for f in try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("st").path) {
            let d = try Data(contentsOf: dir.appendingPathComponent("st").appendingPathComponent(f))
            #expect(d.range(of: Data("canary-pass-123".utf8)) == nil)
        }
        let mode = (try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("st").path)[.posixPermissions] as? Int) ?? 0
        #expect(mode == 0o700)
    }
}

@Suite("AC222: passphrase strength at creation")
struct PassphrasePolicyTests {
    @Test func weakRefusedAtCreation_existingStillOpens() throws {
        for weak in ["hunter2", "aaaaaaaaaaaaaaaa", "password1234", "abcabcabcabc"] {
            #expect(throws: LinuxKeystoreError.self) { try PassphrasePolicy.check(weak) }
        }
        try PassphrasePolicy.check("violet tractor moss engine")
        let dir = tempDir()
        #expect(throws: LinuxKeystoreError.self) {
            _ = try makeLinuxKeystore(directory: dir, profile: .eldrChat, environment: ["ELDR_CHAT_PASSPHRASE": "short"], tpmPresent: { false })
        }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("master.wrap").path))
    }
}
