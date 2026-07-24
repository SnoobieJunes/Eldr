// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import PQRCCore
import CryptoExtras  // Scrypt (RFC 7914), from the already-pinned swift-crypto

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// WS-L3 — the node's Linux keystore (CLAUDE.md invariant 10). `NodeKeychain` covers Apple
// (Secure Enclave); a Linux host has no macOS Keychain, so long-term secrets live in a
// file store whose per-account blobs are AES-256-GCM encrypted under a 256-bit MASTER KEY,
// and the master key is itself protected by the strongest rung the host offers:
//
//   1. TPM-sealed (preferred, unattended-safe): the master key is delivered by systemd via
//      `LoadCredentialEncrypted=` — sealed to the TPM OUTSIDE this process, so there is no
//      Swift TPM code here and no passphrase on disk. The daemon just reads it from
//      `$CREDENTIALS_DIRECTORY` at start.
//   2. scrypt-passphrase (fallback, ONLY where no secure element exists): the master key is
//      wrapped on disk under a memory-hard scrypt KEK derived from a passphrase. Typed at an
//      interactive start it leaves no on-disk trace; supplied via env/file (so an unattended
//      daemon can restart) it travels with the disk image — the exact stolen-image weakness
//      DEVIATIONS AC31 is about, so that posture is reported LOUDLY and never silently.
//
// invariant 10 says the passphrase rung is legitimate ONLY where no secure element exists,
// so a host that HAS a TPM but isn't using it is refused (fail-closed) unless the operator
// explicitly overrides. The posture is DERIVED from which rung actually resolved the key —
// never a config string that could claim hardware backing it doesn't have.
//
// This file compiles on every platform (pure Crypto/Foundation) so it is exercised by the
// macOS test suite; it is only SELECTED on Linux (`makeIdentityStore`).

/// Which rung actually protects the master key on this host. Derived from the live resolve,
/// not declared — a config can't claim `.tpmSealed` while the scrypt rung ran.
enum KeystorePosture: String, Sendable {
    /// Master key delivered by systemd-creds, sealed to the TPM outside the process.
    case tpmSealed
    /// scrypt KEK, passphrase typed interactively — no passphrase trace on disk.
    case passphraseTyped
    /// scrypt KEK, passphrase from env/file so the daemon can restart unattended — WEAK:
    /// the passphrase travels with the disk image (AC31). Only acceptable knowingly.
    case passphraseOnDisk

    var isHardwareBacked: Bool { self == .tpmSealed }

    /// The line the node prints LOUDLY at start so an operator knows what actually protects
    /// their keys (never a silent downgrade).
    var report: String {
        switch self {
        case .tpmSealed:
            return "keystore: TPM-sealed master key (systemd-creds) — hardware-backed, unattended-safe."
        case .passphraseTyped:
            return "keystore: scrypt-passphrase master key, typed interactively — no on-disk passphrase."
        case .passphraseOnDisk:
            return "keystore: scrypt-passphrase master key from env/file — ⚠️ the passphrase travels "
                + "with a stolen disk image (SPEC §0 / DEVIATIONS AC31). No hardware binding on this host."
        }
    }
}

enum LinuxKeystoreError: Error, CustomStringConvertible {
    case tpmPresentButUnused
    case noPassphrase
    case corruptMasterWrap
    case writeFailed(String)

    var description: String {
        switch self {
        case .tpmPresentButUnused:
            return "eldr-node: a TPM is present (/dev/tpmrm0) but the master key is not TPM-sealed. "
                + "Invariant 10 allows a passphrase KEK ONLY where no secure element exists — seal the "
                + "master key with systemd-creds (LoadCredentialEncrypted), or set "
                + "ELDR_KEYSTORE_ALLOW_NO_TPM=1 to knowingly accept the weaker passphrase posture."
        case .noPassphrase:
            return "eldr-node: no keystore passphrase. Provide ELDR_KEYSTORE_PASSPHRASE (or "
                + "ELDR_KEYSTORE_PASSPHRASE_FILE), or start attended at a TTY to type one — or better, "
                + "TPM-seal the master key via systemd-creds (invariant 10)."
        case .corruptMasterWrap:
            return "eldr-node: the wrapped master key failed to decrypt — wrong passphrase, or the "
                + "keystore is corrupt. Refusing to proceed (fail-closed)."
        case .writeFailed(let path):
            return "eldr-node: could not write keystore file \(path)."
        }
    }
}

/// scrypt helpers. Production params are memory-hard yet Pi-feasible; the raw entry point is
/// exposed (internal) so a KAT test can pin it against RFC 7914's published vectors — proving
/// the binding is correct rather than hand-rolled (SPEC §2).
enum LinuxKeystoreScrypt {
    /// N (rounds) = 2^16, r = 8, p = 1 ⇒ ~64 MiB — memory-hard, ~sub-second on a Pi.
    static let rounds = 1 << 16
    static let blockSize = 8
    static let parallelism = 1

    static func derive(
        passphrase: some DataProtocol, salt: some DataProtocol, outputByteCount: Int,
        rounds: Int, blockSize: Int, parallelism: Int
    ) throws -> SymmetricKey {
        try KDF.Scrypt.deriveKey(
            from: passphrase, salt: salt, outputByteCount: outputByteCount,
            rounds: rounds, blockSize: blockSize, parallelism: parallelism)
    }

    /// The 32-byte KEK for wrapping the master key, at production params.
    static func kek(passphrase: String, salt: Data) throws -> SymmetricKey {
        try derive(
            passphrase: Data(passphrase.utf8), salt: salt, outputByteCount: 32,
            rounds: rounds, blockSize: blockSize, parallelism: parallelism)
    }
}

/// The node's Linux identity store: one AES-256-GCM file per account under `directory`, each
/// keyed by `HKDF(masterKey, info: account)` for per-account domain separation. Files are
/// 0600; the directory 0700; plaintext never touches disk.
struct FileIdentityStore: IdentityStore {
    let directory: URL
    private let masterKey: SymmetricKey

    init(directory: URL, masterKey: SymmetricKey) {
        self.directory = directory
        self.masterKey = masterKey
    }

    private func perAccountKey(_ account: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey, salt: Data("eldr-node/keystore/v1".utf8),
            info: Data(account.utf8), outputByteCount: 32)
    }

    private func fileURL(_ account: String) -> URL {
        // Accounts are internal constants ([A-Za-z0-9-]); clamp defensively so a hostile
        // account can never escape the directory.
        let safe = account.map { c -> Character in
            c.isLetter || c.isNumber || c == "-" || c == "_" || c == "." ? c : "_"
        }
        return directory.appendingPathComponent(String(safe) + ".enc")
    }

    func load(account: String) -> Data? {
        guard let combined = try? Data(contentsOf: fileURL(account)),
            let box = try? AES.GCM.SealedBox(combined: combined),
            let plaintext = try? AES.GCM.open(box, using: perAccountKey(account))
        else { return nil }
        return plaintext
    }

    func save(_ data: Data, account: String) throws {
        try FileIdentityStore.ensureDirectory(directory)
        let sealed = try AES.GCM.seal(data, using: perAccountKey(account))
        guard let combined = sealed.combined else {
            throw LinuxKeystoreError.writeFailed(fileURL(account).path)
        }
        try FileIdentityStore.writeFile(fileURL(account), combined)
    }

    func delete(account: String) {
        try? FileManager.default.removeItem(at: fileURL(account))
    }

    // MARK: - 0600/0700 file helpers

    static func ensureDirectory(_ dir: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    static func writeFile(_ url: URL, _ data: Data) throws {
        let fm = FileManager.default
        guard fm.createFile(
            atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw LinuxKeystoreError.writeFailed(url.path) }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - The master-key ladder + store selection (Linux)

/// Build the Linux identity store and report which rung protects it. Returns the store and
/// the DERIVED posture (from what actually resolved the master key). Fail-closed at every
/// doubt (SPEC §0). Injectable environment for tests.
func makeLinuxIdentityStore(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    tpmPresent: () -> Bool = defaultTpmPresent
) throws -> (store: any IdentityStore, posture: KeystorePosture) {
    let dir = keystoreDirectory(environment)
    try FileIdentityStore.ensureDirectory(dir)
    let (masterKey, posture) = try resolveMasterKey(
        directory: dir, environment: environment, tpmPresent: tpmPresent)
    return (FileIdentityStore(directory: dir, masterKey: masterKey), posture)
}

/// `$ELDR_NODE_DATA_DIR` (tests) → `$XDG_DATA_HOME/eldr-node` → `$HOME/.local/share/eldr-node`.
private func keystoreDirectory(_ env: [String: String]) -> URL {
    if let override = env["ELDR_NODE_DATA_DIR"], !override.isEmpty {
        return URL(fileURLWithPath: override)
    }
    let base: String
    if let xdg = env["XDG_DATA_HOME"], !xdg.isEmpty {
        base = xdg
    } else if let home = env["HOME"], !home.isEmpty {
        base = home + "/.local/share"
    } else {
        base = FileManager.default.currentDirectoryPath + "/.eldr-node-data"
    }
    return URL(fileURLWithPath: base).appendingPathComponent("eldr-node")
}

/// The real TPM-presence probe (a Linux character device). Injectable in `makeLinuxIdentityStore`
/// so the fail-closed refusal path is testable on a host with no TPM device.
func defaultTpmPresent() -> Bool {
    let fm = FileManager.default
    return fm.fileExists(atPath: "/dev/tpmrm0") || fm.fileExists(atPath: "/dev/tpm0")
}

/// The ladder. TPM-sealed key if systemd handed us one; else refuse if a TPM is present and
/// unused (invariant 10); else the scrypt-passphrase rung.
private func resolveMasterKey(
    directory: URL, environment env: [String: String], tpmPresent: () -> Bool
) throws -> (SymmetricKey, KeystorePosture) {
    // Rung 1 — TPM via systemd-creds: the plaintext key sits in $CREDENTIALS_DIRECTORY,
    // unsealed by systemd from a TPM-sealed credential. No TPM code in this process.
    if let credDir = env["CREDENTIALS_DIRECTORY"], !credDir.isEmpty {
        let credURL = URL(fileURLWithPath: credDir).appendingPathComponent("eldr-node-master")
        if let raw = try? Data(contentsOf: credURL), raw.count == 32 {
            return (SymmetricKey(data: raw), .tpmSealed)
        }
    }

    // Rung refusal — a TPM exists but nothing sealed a key to it. Passphrase-only here would
    // violate invariant 10's "ONLY where no secure element exists"; fail closed unless the
    // operator knowingly overrides.
    if tpmPresent() && env["ELDR_KEYSTORE_ALLOW_NO_TPM"] != "1" {
        throw LinuxKeystoreError.tpmPresentButUnused
    }

    // Rung 2 — scrypt-passphrase.
    let (passphrase, typed) = try obtainPassphrase(env)
    let masterKey = try unwrapOrInitMaster(directory: directory, passphrase: passphrase)
    return (masterKey, typed ? .passphraseTyped : .passphraseOnDisk)
}

/// Env/file (on-disk posture, lets a daemon restart) or an interactive TTY prompt (typed, no
/// on-disk trace). A daemon with none of these fails closed.
private func obtainPassphrase(_ env: [String: String]) throws -> (passphrase: String, typed: Bool) {
    if let p = env["ELDR_KEYSTORE_PASSPHRASE"], !p.isEmpty {
        return (p, false)
    }
    if let path = env["ELDR_KEYSTORE_PASSPHRASE_FILE"], !path.isEmpty,
        let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
        let p = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty
    {
        return (p, false)
    }
    // Interactive: only when attached to a TTY (a systemd daemon is not). `getpass` does not
    // echo — a passphrase must never land in the terminal scrollback.
    if isatty(FileHandle.standardInput.fileDescriptor) == 1 {
        if let c = getpass("eldr-node keystore passphrase: ") {
            let pw = String(cString: c)
            if !pw.isEmpty { return (pw, true) }
        }
    }
    throw LinuxKeystoreError.noPassphrase
}

/// Load-or-create the 256-bit master key, wrapped on disk under a scrypt KEK.
private func unwrapOrInitMaster(directory: URL, passphrase: String) throws -> SymmetricKey {
    let wrapURL = directory.appendingPathComponent("master.wrap")
    let saltURL = directory.appendingPathComponent("master.salt")
    let fm = FileManager.default

    if fm.fileExists(atPath: wrapURL.path), fm.fileExists(atPath: saltURL.path),
        let salt = try? Data(contentsOf: saltURL), let wrapped = try? Data(contentsOf: wrapURL)
    {
        let kek = try LinuxKeystoreScrypt.kek(passphrase: passphrase, salt: salt)
        do {
            let box = try AES.GCM.SealedBox(combined: wrapped)
            let raw = try AES.GCM.open(box, using: kek)
            guard raw.count == 32 else { throw LinuxKeystoreError.corruptMasterWrap }
            return SymmetricKey(data: raw)
        } catch {
            throw LinuxKeystoreError.corruptMasterWrap
        }
    }

    // First run: fresh master key, fresh salt, wrap and persist (0600) before returning.
    let rng = SystemRandomSource()
    let masterRaw = rng.bytes(32)
    let salt = rng.bytes(16)
    let kek = try LinuxKeystoreScrypt.kek(passphrase: passphrase, salt: salt)
    let sealed = try AES.GCM.seal(masterRaw, using: kek)
    guard let wrapped = sealed.combined else { throw LinuxKeystoreError.writeFailed(wrapURL.path) }
    try FileIdentityStore.writeFile(saltURL, salt)
    try FileIdentityStore.writeFile(wrapURL, wrapped)
    return SymmetricKey(data: masterRaw)
}
