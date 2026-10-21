// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import Testing

@testable import EldrKeystore

private func tmp() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("eldr-fido-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// A MOCK security key: hmac-secret = HMAC(deviceSecret, credID || salt). A different
/// instance is a different physical key. No hardware involved.
final class MockFIDO: FIDOAuthenticator, @unchecked Sendable {
    let device = SymmetricKey(size: .bits256)
    var touches = 0
    func enroll(rpID: String) throws -> Data { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) } }
    func hmacSecret(rpID: String, credentialID: Data, salt: Data) throws -> Data {
        touches += 1
        return Data(HMAC<SHA256>.authenticationCode(for: credentialID + salt, using: device))
    }
}

@Suite("FIDO2 security-key keystore (mock key)")
struct FIDOKeystoreTests {
    let env = ["ELDR_CHAT_PASSPHRASE": "correct horse battery"]

    func passphraseStore(_ dir: URL) throws {
        let (s, _) = try makeLinuxKeystore(directory: dir, profile: .eldrChat, environment: env, tpmPresent: { false })
        try s.save(Data("identity".utf8), account: "id")
    }

    @Test func upgrade_keyOnly_otherKeyRefused_noFallback() throws {
        let dir = tmp(), key = MockFIDO()
        try passphraseStore(dir)
        try upgradeKeystoreToSecurityKey(directory: dir, passphrase: env["ELDR_CHAT_PASSPHRASE"]!, keepPassphrase: false, fido: key)
        #expect(KeystoreProtection.inspect(directory: dir) == .securityKey)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("master.wrap").path))
        let (s, p) = try makeLinuxKeystore(directory: dir, profile: .eldrChat, environment: [:], tpmPresent: { false }, fido: key)
        #expect(p == .securityKey && p.isHardwareBacked)
        #expect(s.load(account: "id") == Data("identity".utf8))
        #expect(throws: (any Error).self) {  // another security key
            _ = try makeLinuxKeystore(directory: dir, profile: .eldrChat, environment: [:], tpmPresent: { false }, fido: MockFIDO())
        }
    }

    @Test func layeredPassphrase_bothRequired() throws {
        let dir = tmp(), key = MockFIDO()
        try passphraseStore(dir)
        try upgradeKeystoreToSecurityKey(directory: dir, passphrase: env["ELDR_CHAT_PASSPHRASE"]!, keepPassphrase: true, fido: key)
        #expect(KeystoreProtection.inspect(directory: dir) == .securityKeyAndPassphrase)
        let (s, p) = try makeLinuxKeystore(directory: dir, profile: .eldrChat, environment: env, tpmPresent: { false }, fido: key)
        #expect(p == .securityKeyWithPassphrase)
        #expect(s.load(account: "id") == Data("identity".utf8))
        let wrong = ["ELDR_CHAT_PASSPHRASE": "wrong horse battery"]
        #expect(throws: (any Error).self) {
            _ = try makeLinuxKeystore(directory: dir, profile: .eldrChat, environment: wrong, tpmPresent: { false }, fido: key)
        }
        #expect(throws: (any Error).self) {
            _ = try makeLinuxKeystore(directory: dir, profile: .eldrChat, environment: env, tpmPresent: { false }, fido: MockFIDO())
        }
    }

    @Test func wrongPassphraseUpgradeLeavesKeystoreIntact() throws {
        let dir = tmp()
        try passphraseStore(dir)
        #expect(throws: (any Error).self) {
            try upgradeKeystoreToSecurityKey(directory: dir, passphrase: "nope nope nope", keepPassphrase: false, fido: MockFIDO())
        }
        #expect(KeystoreProtection.inspect(directory: dir) == .passphraseOnly)
    }
}
