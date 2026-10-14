// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import Testing

@testable import EldrKeystore

private func tmp() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("eldr-tpm-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// A FAKE TPM for logic tests (no hardware, no simulator): "sealing" is AES-GCM under a key
/// that only this instance holds, so a different instance = a different machine.
final class FakeTPM: TPMSealer, @unchecked Sendable {  // test-only; mutable flag is set before use
    let key = SymmetricKey(size: .bits256)
    var failSeal = false
    func seal(_ secret: Data) throws -> Data {
        if failSeal { throw TPMKeystoreError.failed("injected") }
        return try AES.GCM.seal(secret, using: key).combined!
    }
    func unseal(_ blob: Data) throws -> Data {
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: blob), using: key) }
        catch { throw TPMKeystoreError.failed("not this TPM") }
    }
}

@Suite("TPM keystore logic (fake TPM)")
struct TPMKeystoreLogicTests {
    let env = ["ELDR_CHAT_PASSPHRASE": "correct horse"]

    func passphraseStoreWithSecret(_ dir: URL) throws {
        let (s, p) = try makeLinuxKeystore(directory: dir, profile: .eldrChat, environment: env, tpmPresent: { false })
        #expect(p == .passphraseOnDisk)
        try s.save(Data("identity".utf8), account: "id")
    }

    @Test func freshHostWithTPM_createsTPMWrapped_andAnotherTPMCannotOpen() throws {
        let dir = tmp(), tpm = FakeTPM()
        let (s, p) = try makeLinuxKeystore(directory: dir, profile: .eldrChat, environment: [:], tpmPresent: { true }, tpm: tpm)
        #expect(p == .tpmWrapped && p.isHardwareBacked)
        try s.save(Data("x".utf8), account: "a")
        #expect(KeystoreProtection.inspect(directory: dir) == .tpm)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("master.wrap").path))
        // Disk copied to another machine (another TPM): refused.
        #expect(throws: (any Error).self) {
            _ = try makeLinuxKeystore(directory: dir, profile: .eldrChat, environment: [:], tpmPresent: { true }, tpm: FakeTPM())
        }
        // No TPM at all: refused, never a silent fallback.
        #expect(throws: (any Error).self) {
            _ = try makeLinuxKeystore(directory: dir, profile: .eldrChat, environment: self.env, tpmPresent: { false })
        }
        let (s2, _) = try makeLinuxKeystore(directory: dir, profile: .eldrChat, environment: [:], tpmPresent: { true }, tpm: tpm)
        #expect(s2.load(account: "a") == Data("x".utf8))
    }

    @Test func layeredPassphrase_bothRequired() throws {
        let dir = tmp(), tpm = FakeTPM()
        let (_, p) = try makeLinuxKeystore(directory: dir, profile: .eldrChat, environment: env, tpmPresent: { true }, tpm: tpm)
        #expect(p == .tpmWrappedWithPassphrase)
        #expect(KeystoreProtection.inspect(directory: dir) == .tpmAndPassphrase)
        #expect(throws: (any Error).self) {  // TPM alone
            _ = try makeLinuxKeystore(directory: dir, profile: .eldrChat, environment: [:], tpmPresent: { true }, tpm: tpm)
        }
        #expect(throws: (any Error).self) {  // wrong passphrase
            _ = try makeLinuxKeystore(directory: dir, profile: .eldrChat,
                                      environment: ["ELDR_CHAT_PASSPHRASE": "wrong"], tpmPresent: { true }, tpm: tpm)
        }
        #expect(throws: (any Error).self) {  // passphrase, other TPM
            _ = try makeLinuxKeystore(directory: dir, profile: .eldrChat, environment: self.env, tpmPresent: { true }, tpm: FakeTPM())
        }
    }

    @Test func upgrade_keepsEveryKey_andRetiresPassphraseOnlyWrap() throws {
        let dir = tmp(), tpm = FakeTPM()
        try passphraseStoreWithSecret(dir)
        try upgradeKeystoreToTPM(directory: dir, passphrase: "correct horse", keepPassphrase: false, tpm: tpm)
        #expect(KeystoreProtection.inspect(directory: dir) == .tpm)
        for f in ["master.wrap", "master.salt", ".master.tpm.staged"] {
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(f).path))
        }
        let (s, p) = try makeLinuxKeystore(directory: dir, profile: .eldrChat, environment: [:], tpmPresent: { true }, tpm: tpm)
        #expect(p == .tpmWrapped)
        #expect(s.load(account: "id") == Data("identity".utf8))
        #expect(throws: TPMKeystoreError.alreadyTPM) {
            try upgradeKeystoreToTPM(directory: dir, passphrase: "correct horse", keepPassphrase: false, tpm: tpm)
        }
    }

    @Test func failedUpgrade_losesNothing() throws {
        let dir = tmp(), tpm = FakeTPM()
        try passphraseStoreWithSecret(dir)
        let before = try Data(contentsOf: dir.appendingPathComponent("master.wrap"))
        tpm.failSeal = true
        #expect(throws: (any Error).self) {
            try upgradeKeystoreToTPM(directory: dir, passphrase: "correct horse", keepPassphrase: true, tpm: tpm)
        }
        #expect(throws: (any Error).self) {  // wrong passphrase also changes nothing
            try upgradeKeystoreToTPM(directory: dir, passphrase: "nope", keepPassphrase: true, tpm: FakeTPM())
        }
        #expect(try Data(contentsOf: dir.appendingPathComponent("master.wrap")) == before)
        #expect(KeystoreProtection.inspect(directory: dir) == .passphraseOnly)
        let (s, _) = try makeLinuxKeystore(directory: dir, profile: .eldrChat, environment: env, tpmPresent: { false })
        #expect(s.load(account: "id") == Data("identity".utf8))
    }

    @Test func brokenTPMOnFreshHost_failsClosed() throws {
        let tpm = FakeTPM(); tpm.failSeal = true
        #expect(throws: LinuxKeystoreError.self) {
            _ = try makeLinuxKeystore(directory: tmp(), profile: .eldrChat, environment: self.env, tpmPresent: { true }, tpm: tpm)
        }
    }
}

/// SIMULATION ONLY: swtpm is a software TPM. Passing here proves the tpm2-tss/ESAPI code path
/// (seal, load, unseal, encrypted session, marshalling) — NOT hardware protection. Skipped
/// when swtpm or the tpm2-tss headers/libraries are absent.
private let swtpmPath: String? = ["/usr/bin/swtpm", "/usr/local/bin/swtpm"].first { FileManager.default.isExecutableFile(atPath: $0) }

@Suite("TPM keystore via swtpm (SIMULATED TPM, not hardware)", .serialized,
       .enabled(if: swtpmPath != nil && SystemTPM.compiledIn, "needs swtpm + libtss2-dev"))
struct SwtpmKeystoreTests {
    final class Sim {
        let proc = Process()
        let port = Int.random(in: 20000...40000)
        let state = tmp()
        var tcti: String { "swtpm:host=127.0.0.1,port=\(port)" }
        init() throws {
            proc.executableURL = URL(fileURLWithPath: swtpmPath!)
            proc.arguments = ["socket", "--tpm2", "--server", "type=tcp,port=\(port),bindaddr=127.0.0.1",
                              "--ctrl", "type=tcp,port=\(port + 1),bindaddr=127.0.0.1",
                              "--tpmstate", "dir=\(state.path)", "--flags", "not-need-init,startup-clear"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try proc.run()
            Thread.sleep(forTimeInterval: 0.5)
        }
        func stop() { kill(proc.processIdentifier, SIGKILL); proc.waitUntilExit(); try? FileManager.default.removeItem(at: state) }
    }

    @Test func sealUnsealRoundTrip_andUpgradeMigration() throws {
        let sim = try Sim()
        defer { sim.stop() }
        let tpm = SystemTPM(tcti: sim.tcti)
        let secret = Data((0..<32).map { UInt8($0) })
        let blob = try tpm.seal(secret)
        #expect(!blob.isEmpty && blob.range(of: secret) == nil)  // sealed blob never holds the secret
        #expect(try tpm.unseal(blob) == secret)

        // Fresh keystore through ELDR_TPM_TCTI (the real auto-detect path, simulated TPM).
        let dir = tmp()
        let env = ["ELDR_TPM_TCTI": sim.tcti]
        let (s, p) = try makeLinuxKeystore(directory: dir, profile: .eldrChat, environment: env, tpmPresent: { false })
        #expect(p == .tpmWrapped)
        try s.save(Data("k".utf8), account: "a")
        let (s2, _) = try makeLinuxKeystore(directory: dir, profile: .eldrChat, environment: env, tpmPresent: { false })
        #expect(s2.load(account: "a") == Data("k".utf8))

        // Upgrade a passphrase keystore in place.
        let old = tmp()
        let penv = ["ELDR_CHAT_PASSPHRASE": "pw"]
        let (ps, _) = try makeLinuxKeystore(directory: old, profile: .eldrChat, environment: penv, tpmPresent: { false })
        try ps.save(Data("id".utf8), account: "id")
        try upgradeKeystoreToTPM(directory: old, passphrase: "pw", keepPassphrase: true, tpm: tpm)
        let (us, up) = try makeLinuxKeystore(directory: old, profile: .eldrChat,
                                             environment: penv.merging(env) { a, _ in a }, tpmPresent: { false })
        #expect(up == .tpmWrappedWithPassphrase)
        #expect(us.load(account: "id") == Data("id".utf8))
    }

    @Test func blobFromAnotherSimulatedTPM_isRefused() throws {
        let a = try Sim(), b = try Sim()
        defer { a.stop(); b.stop() }
        let blob = try SystemTPM(tcti: a.tcti).seal(Data(repeating: 7, count: 32))
        #expect(throws: TPMKeystoreError.self) { _ = try SystemTPM(tcti: b.tcti).unseal(blob) }
    }
}
