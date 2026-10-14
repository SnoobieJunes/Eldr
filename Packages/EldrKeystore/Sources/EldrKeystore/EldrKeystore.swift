// SPDX-License-Identifier: Apache-2.0
//
// Moved from Packages/EldrNode/Sources/eldr-node/FileIdentityStore.swift (WS-L2/L3) so
// eldr-node and the Linux client share one implementation. Behaviour, file format and
// eldr-node's on-disk compatibility are unchanged: `KeystoreProfile.eldrNode` reproduces
// the node's exact HKDF label, env names and credential name.
import Crypto
import Foundation
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
// macOS test suite; it is only SELECTED on Linux (each consumer's store factory).

/// Which rung actually protects the master key on this host. Derived from the live resolve,
/// not declared — a config can't claim `.tpmSealed` while the scrypt rung ran.
/// Per-consumer naming. Two profiles never share a directory, HKDF label or credential,
/// so a node keystore and a client keystore on one host are cryptographically separate.
public struct KeystoreProfile: Sendable, Equatable {
    /// Prefix for diagnostics ("eldr-node: …").
    public var tool: String
    /// HKDF salt for per-account keys. Changing it orphans existing files — never edit.
    public var hkdfSaltLabel: String
    /// File name of the TPM-sealed master key under `$CREDENTIALS_DIRECTORY`.
    public var credentialName: String
    public var passphraseEnv: String
    public var passphraseFileEnv: String

    public init(tool: String, hkdfSaltLabel: String, credentialName: String,
                passphraseEnv: String, passphraseFileEnv: String) {
        self.tool = tool
        self.hkdfSaltLabel = hkdfSaltLabel
        self.credentialName = credentialName
        self.passphraseEnv = passphraseEnv
        self.passphraseFileEnv = passphraseFileEnv
    }

    /// The headless node — byte-for-byte the pre-move values (existing keystores load).
    public static let eldrNode = KeystoreProfile(
        tool: "eldr-node", hkdfSaltLabel: "eldr-node/keystore/v1", credentialName: "eldr-node-master",
        passphraseEnv: "ELDR_KEYSTORE_PASSPHRASE", passphraseFileEnv: "ELDR_KEYSTORE_PASSPHRASE_FILE")

    /// The Linux client (`eldr-chat`).
    public static let eldrChat = KeystoreProfile(
        tool: "eldr-chat", hkdfSaltLabel: "eldr-chat/keystore/v1", credentialName: "eldr-chat-master",
        passphraseEnv: "ELDR_CHAT_PASSPHRASE", passphraseFileEnv: "ELDR_CHAT_PASSPHRASE_FILE")
}

/// The storage seam both consumers code against (macOS eldr-node also conforms its
/// Keychain wrapper to it).
public protocol IdentityStore: Sendable {
    func load(account: String) -> Data?
    func save(_ data: Data, account: String) throws
    func delete(account: String)
}

public enum KeystorePosture: String, Sendable {
    /// Master key delivered by systemd-creds, sealed to the TPM outside the process.
    case tpmSealed
    /// A systemd credential supplied the master key, but a TPM is NOT present on this host, so
    /// hardware sealing cannot be claimed — the credential may be an unencrypted `LoadCredential`
    /// / `SetCredential`. Honest middle rung: no silent "TPM-backed" overclaim (invariant 10).
    case systemdCredential
    /// scrypt KEK, passphrase typed interactively — no passphrase trace on disk.
    case passphraseTyped
    /// scrypt KEK, passphrase from env/file so the daemon can restart unattended — WEAK:
    /// the passphrase travels with the disk image (AC31). Only acceptable knowingly.
    case passphraseOnDisk
    /// Master key wrapped in-process under a secret sealed in THIS host's TPM (AC218).
    case tpmWrapped
    /// TPM-wrapped AND passphrase-protected: both are required to unlock.
    case tpmWrappedWithPassphrase
    /// Master key wrapped under a FIDO2 security key's hmac-secret (AC224).
    case securityKey
    /// Security key AND passphrase: both required.
    case securityKeyWithPassphrase

    public var isHardwareBacked: Bool {
        self == .tpmSealed || self == .tpmWrapped || self == .tpmWrappedWithPassphrase
            || self == .securityKey || self == .securityKeyWithPassphrase
    }

    /// Short label for status bars / `keystore status`.
    public var shortLabel: String {
        switch self {
        case .tpmSealed: return "TPM (systemd-creds)"
        case .systemdCredential: return "systemd credential, no TPM ⚠"
        case .passphraseTyped: return "passphrase only ⚠"
        case .passphraseOnDisk: return "passphrase file only ⚠"
        case .tpmWrapped: return "TPM"
        case .tpmWrappedWithPassphrase: return "TPM + passphrase"
        case .securityKey: return "security key"
        case .securityKeyWithPassphrase: return "security key + passphrase"
        }
    }

    /// The line the node prints LOUDLY at start so an operator knows what actually protects
    /// their keys (never a silent downgrade).
    public var report: String {
        switch self {
        case .tpmSealed:
            return "keystore: TPM-sealed master key (systemd-creds) — hardware-backed, unattended-safe."
        case .systemdCredential:
            return "keystore: master key from a systemd credential, but NO TPM is present — ⚠️ sealing "
                + "is not verifiable in-process; hardware backing is unconfirmed (invariant 10)."
        case .passphraseTyped:
            return "keystore: ⚠️ WARNING — passphrase-only protection (no TPM in use). A copied disk can be "
                + "attacked offline by guessing the passphrase."
        case .passphraseOnDisk:
            return "keystore: ⚠️ WARNING — passphrase-only protection, and the passphrase is in an env var "
                + "or file: anyone with a copy of this disk can open your keys (SPEC §0 / DEVIATIONS AC31). "
                + "No TPM in use. Run `keystore status` for details."
        case .tpmWrapped:
            return "keystore: master key wrapped by this machine's TPM — a copied disk cannot open it."
        case .tpmWrappedWithPassphrase:
            return "keystore: master key wrapped by this machine's TPM AND your passphrase — both required."
        case .securityKey:
            return "keystore: master key wrapped by your FIDO2 security key — a copied disk cannot open it without the key."
        case .securityKeyWithPassphrase:
            return "keystore: master key wrapped by your FIDO2 security key AND your passphrase — both required."
        }
    }
}

public enum LinuxKeystoreError: Error, CustomStringConvertible {
    case tpmPresentButUnused(tool: String)
    case noPassphrase(KeystoreProfile)
    case corruptMasterWrap
    case writeFailed(String)
    case passphraseFileTooOpen(String)
    case weakPassphrase(String)

    public var description: String {
        switch self {
        case .tpmPresentButUnused(let tool):
            return "\(tool): a TPM is present (/dev/tpmrm0) but the master key is not TPM-sealed. "
                + "Invariant 10 allows a passphrase KEK ONLY where no secure element exists — seal the "
                + "master key with systemd-creds (LoadCredentialEncrypted), or set "
                + "ELDR_KEYSTORE_ALLOW_NO_TPM=1 to knowingly accept the weaker passphrase posture. "
                + "An existing passphrase keystore can be moved to the TPM with `keystore upgrade` "
                + "(needs the tpm2-tss libraries: libtss2-esys, libtss2-tctildr, libtss2-mu)."
        case .noPassphrase(let p):
            return "\(p.tool): no keystore passphrase. Provide \(p.passphraseEnv) (or "
                + "\(p.passphraseFileEnv)), or start attended at a TTY to type one — or better, "
                + "TPM-seal the master key via systemd-creds (invariant 10)."
        case .corruptMasterWrap:
            return "keystore: the wrapped master key failed to decrypt — wrong passphrase, or the "
                + "keystore is corrupt. Refusing to proceed (fail-closed)."
        case .writeFailed(let path):
            return "keystore: could not write keystore file \(path)."
        case .weakPassphrase(let why):
            return "keystore: passphrase too weak (\(why)). Use at least \(PassphrasePolicy.minLength) characters "
                + "with some variety — four or five random words work well. It only protects a copied disk if "
                + "it is hard to guess."
        case .passphraseFileTooOpen(let path):
            return "keystore: passphrase file \(path) is readable by other users. "
                + "Run `chmod 600 \(path)` (fail-closed, like ssh with a private key)."
        }
    }
}

/// scrypt helpers. Production params are memory-hard yet Pi-feasible; the raw entry point is
/// exposed (internal) so a KAT test can pin it against RFC 7914's published vectors — proving
/// the binding is correct rather than hand-rolled (SPEC §2).
public enum LinuxKeystoreScrypt {
    /// N (rounds) = 2^16, r = 8, p = 1 ⇒ ~64 MiB — memory-hard, ~sub-second on a Pi.
    public static let rounds = 1 << 16
    public static let blockSize = 8
    public static let parallelism = 1

    public static func derive(
        passphrase: some DataProtocol, salt: some DataProtocol, outputByteCount: Int,
        rounds: Int, blockSize: Int, parallelism: Int
    ) throws -> SymmetricKey {
        try KDF.Scrypt.deriveKey(
            from: passphrase, salt: salt, outputByteCount: outputByteCount,
            rounds: rounds, blockSize: blockSize, parallelism: parallelism)
    }

    /// The 32-byte KEK for wrapping the master key, at production params.
    public static func kek(passphrase: String, salt: Data) throws -> SymmetricKey {
        try derive(
            passphrase: Data(passphrase.utf8), salt: salt, outputByteCount: 32,
            rounds: rounds, blockSize: blockSize, parallelism: parallelism)
    }
}

/// The node's Linux identity store: one AES-256-GCM file per account under `directory`, each
/// keyed by `HKDF(masterKey, info: account)` for per-account domain separation. Files are
/// 0600; the directory 0700; plaintext never touches disk.
public struct FileIdentityStore: IdentityStore {
    public let directory: URL
    public let profile: KeystoreProfile
    private let masterKey: SymmetricKey

    public init(directory: URL, masterKey: SymmetricKey, profile: KeystoreProfile) {
        self.directory = directory
        self.masterKey = masterKey
        self.profile = profile
    }

    private func perAccountKey(_ account: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey, salt: Data(profile.hkdfSaltLabel.utf8),
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

    public func load(account: String) -> Data? {
        guard let combined = try? Data(contentsOf: fileURL(account)),
            let box = try? AES.GCM.SealedBox(combined: combined),
            let plaintext = try? AES.GCM.open(box, using: perAccountKey(account))
        else { return nil }
        return plaintext
    }

    public func save(_ data: Data, account: String) throws {
        try FileIdentityStore.ensureDirectory(directory)
        let sealed = try AES.GCM.seal(data, using: perAccountKey(account))
        guard let combined = sealed.combined else {
            throw LinuxKeystoreError.writeFailed(fileURL(account).path)
        }
        try FileIdentityStore.writeFile(fileURL(account), combined)
    }

    public func delete(account: String) {
        try? FileManager.default.removeItem(at: fileURL(account))
    }

    // MARK: - 0600/0700 file helpers

    public static func ensureDirectory(_ dir: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    /// Atomic 0600 write: a temp file in the same directory, then `rename(2)`. A crash
    /// mid-write leaves the previous file intact instead of a truncated blob (which would
    /// fail to decrypt and could look like "no state").
    public static func writeFile(_ url: URL, _ data: Data) throws {
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw LinuxKeystoreError.writeFailed(url.path) }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        guard rename(tmp.path, url.path) == 0 else {
            try? fm.removeItem(at: tmp)
            throw LinuxKeystoreError.writeFailed(url.path)
        }
    }
}

// MARK: - The master-key ladder + store selection (Linux)

/// Build the Linux identity store and report which rung protects it. Returns the store and
/// the DERIVED posture (from what actually resolved the master key). Fail-closed at every
/// doubt (SPEC §0). Injectable environment for tests.
public func makeLinuxKeystore(
    directory dir: URL,
    profile: KeystoreProfile,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    tpmPresent: () -> Bool = defaultTpmPresent,
    tpm: (any TPMSealer)? = nil,
    fido: (any FIDOAuthenticator)? = nil
) throws -> (store: FileIdentityStore, posture: KeystorePosture) {
    try FileIdentityStore.ensureDirectory(dir)
    let sealer = tpm ?? defaultTPMSealer(environment: environment, tpmPresent: tpmPresent)
    let (masterKey, posture) = try resolveMasterKey(
        directory: dir, profile: profile, environment: environment, tpmPresent: tpmPresent, tpm: sealer,
        fido: fido ?? defaultFIDOAuthenticator(environment: environment))
    return (FileIdentityStore(directory: dir, masterKey: masterKey, profile: profile), posture)
}

/// The real TPM-presence probe (a Linux character device). Injectable in `makeLinuxIdentityStore`
/// so the fail-closed refusal path is testable on a host with no TPM device.
public func defaultTpmPresent() -> Bool {
    let fm = FileManager.default
    return fm.fileExists(atPath: "/dev/tpmrm0") || fm.fileExists(atPath: "/dev/tpm0")
}

/// The ladder. TPM-sealed key if systemd handed us one; else refuse if a TPM is present and
/// unused (invariant 10); else the scrypt-passphrase rung.
private func resolveMasterKey(
    directory: URL, profile: KeystoreProfile, environment env: [String: String], tpmPresent: () -> Bool,
    tpm: (any TPMSealer)?, fido: (any FIDOAuthenticator)?
) throws -> (SymmetricKey, KeystorePosture) {
    // Rung 1 — TPM via systemd-creds: the plaintext key sits in $CREDENTIALS_DIRECTORY,
    // unsealed by systemd from a TPM-sealed credential. No TPM code in this process.
    if let credDir = env["CREDENTIALS_DIRECTORY"], !credDir.isEmpty {
        let credURL = URL(fileURLWithPath: credDir).appendingPathComponent(profile.credentialName)
        if let raw = try? Data(contentsOf: credURL), raw.count == 32 {
            // Only claim hardware sealing when a TPM is actually present — a systemd credential
            // alone does not prove it was TPM-sealed (it could be a plain LoadCredential=).
            return (SymmetricKey(data: raw), tpmPresent() ? .tpmSealed : .systemdCredential)
        }
    }

    // Rung 1b — in-process TPM wrap (AC218). An existing master.tpm is authoritative: it
    // NEVER falls back to anything weaker (fail-closed if the TPM is gone or refuses).
    if let rec = try TPMMaster.read(directory) {
        guard let tpm else {
            throw TPMKeystoreError.unavailable("this keystore is TPM-wrapped but no usable TPM was found")
        }
        var pass: String?
        if rec.passphraseSalt != nil { pass = try obtainPassphrase(env, profile).passphrase }
        let key = try TPMMaster.open(rec, tpm: tpm, passphrase: pass)
        return (key, pass == nil ? .tpmWrapped : .tpmWrappedWithPassphrase)
    }
    // Rung 1c — FIDO2 security-key wrap (AC224). Authoritative and fail-closed like master.tpm.
    if let rec = try FIDOMaster.read(directory) {
        guard let fido else { throw FIDOKeystoreError.unavailable("this keystore needs a FIDO2 security key (libfido2)") }
        var pass: String?
        if rec.passphraseSalt != nil { pass = try obtainPassphrase(env, profile).passphrase }
        let key = try FIDOMaster.open(rec, fido: fido, passphrase: pass)
        return (key, pass == nil ? .securityKey : .securityKeyWithPassphrase)
    }
    // First run on a host with a usable TPM: create a TPM-wrapped keystore. A passphrase from
    // env/file (never prompted here) is layered on top when given.
    let fm = FileManager.default
    let fresh = !fm.fileExists(atPath: directory.appendingPathComponent("master.wrap").path)
        && !fm.fileExists(atPath: directory.appendingPathComponent("master.salt").path)
    if fresh, let tpm {
        let pass = optionalPassphrase(env, profile)
        let master = SymmetricKey(size: .bits256)
        if let rec = try? TPMMaster.make(master: master, tpm: tpm, passphrase: pass),
            (try? TPMMaster.writeVerified(rec, dir: directory, master: master, tpm: tpm, passphrase: pass)) != nil
        {
            return (master, pass == nil ? .tpmWrapped : .tpmWrappedWithPassphrase)
        }
        // The TPM did not work: fall through to the refusal below (fail-closed).
    }

    // Rung refusal — a TPM exists but nothing sealed a key to it. Passphrase-only here would
    // violate invariant 10's "ONLY where no secure element exists"; fail closed unless the
    // operator knowingly overrides.
    if tpmPresent() && env["ELDR_KEYSTORE_ALLOW_NO_TPM"] != "1" {
        throw LinuxKeystoreError.tpmPresentButUnused(tool: profile.tool)
    }

    // Rung 2 — scrypt-passphrase.
    let (passphrase, typed) = try obtainPassphrase(env, profile)
    let masterKey = try unwrapOrInitMaster(directory: directory, passphrase: passphrase)
    return (masterKey, typed ? .passphraseTyped : .passphraseOnDisk)
}

/// A passphrase from env/file only (no prompt), for layering on a NEW TPM keystore.
private func optionalPassphrase(_ env: [String: String], _ profile: KeystoreProfile) -> String? {
    if let p = env[profile.passphraseEnv], !p.isEmpty { return p }
    if let path = env[profile.passphraseFileEnv], !path.isEmpty {
        var st = stat()
        if stat(path, &st) == 0, st.st_mode & 0o077 != 0 { return nil }
        if let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let p = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty
        { return p }
    }
    return nil
}

/// Env/file (on-disk posture, lets a daemon restart) or an interactive TTY prompt (typed, no
/// on-disk trace). A daemon with none of these fails closed.
private func obtainPassphrase(_ env: [String: String], _ profile: KeystoreProfile) throws -> (passphrase: String, typed: Bool) {
    if let p = env[profile.passphraseEnv], !p.isEmpty {
        return (p, false)
    }
    if let path = env[profile.passphraseFileEnv], !path.isEmpty {
        // AC215: a group/world-readable passphrase file hands every local user the
        // master key's only protection. Refuse it rather than use it silently.
        var st = stat()
        if stat(path, &st) == 0, st.st_mode & 0o077 != 0 {
            throw LinuxKeystoreError.passphraseFileTooOpen(path)
        }
    }
    if let path = env[profile.passphraseFileEnv], !path.isEmpty,
        let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
        let p = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty
    {
        return (p, false)
    }
    // Interactive: only when attached to a TTY (a systemd daemon is not). `getpass` does not
    // echo — a passphrase must never land in the terminal scrollback.
    if isatty(FileHandle.standardInput.fileDescriptor) == 1 {
        if let c = getpass("\(profile.tool) keystore passphrase: ") {
            let pw = String(cString: c)
            if !pw.isEmpty { return (pw, true) }
        }
    }
    throw LinuxKeystoreError.noPassphrase(profile)
}

/// Load-or-create the 256-bit master key, wrapped on disk under a scrypt KEK.
private func unwrapOrInitMaster(directory: URL, passphrase: String) throws -> SymmetricKey {
    let wrapURL = directory.appendingPathComponent("master.wrap")
    let saltURL = directory.appendingPathComponent("master.salt")
    let fm = FileManager.default

    // Exactly ONE of the pair present ⇒ a corrupt / half-written keystore. Refuse rather than
    // fall through to first-run, which would silently mint a fresh master key and orphan every
    // existing *.enc identity blob (fail-closed, the file's own contract).
    let wrapExists = fm.fileExists(atPath: wrapURL.path)
    let saltExists = fm.fileExists(atPath: saltURL.path)
    if wrapExists != saltExists { throw LinuxKeystoreError.corruptMasterWrap }

    if wrapExists, saltExists,
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
    // AC222: a new keystore gets a minimum-strength passphrase (existing ones still open).
    try PassphrasePolicy.check(passphrase)
    let masterRaw = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    let salt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
    let kek = try LinuxKeystoreScrypt.kek(passphrase: passphrase, salt: salt)
    let sealed = try AES.GCM.seal(masterRaw, using: kek)
    guard let wrapped = sealed.combined else { throw LinuxKeystoreError.writeFailed(wrapURL.path) }
    try FileIdentityStore.writeFile(saltURL, salt)
    try FileIdentityStore.writeFile(wrapURL, wrapped)
    return SymmetricKey(data: masterRaw)
}


/// Minimum passphrase strength at keystore CREATION (AC222, owner decision). Deliberately
/// simple and explainable: length, variety, and not a well-known password. Existing
/// keystores keep opening with whatever passphrase they were made with.
public enum PassphrasePolicy {
    public static let minLength = 12
    public static let minDistinct = 6
    static let common: Set<String> = [
        "password1234", "passwordpassword", "123456789012", "qwertyuiopas", "letmeinletmein",
        "correct horse battery staple", "iloveyou1234", "administrator", "changemechangeme",
    ]

    public static func check(_ p: String) throws {
        if p.count < minLength { throw LinuxKeystoreError.weakPassphrase("shorter than \(minLength) characters") }
        if Set(p.lowercased()).count < minDistinct {
            throw LinuxKeystoreError.weakPassphrase("too few different characters")
        }
        if common.contains(p.lowercased()) { throw LinuxKeystoreError.weakPassphrase("a well-known password") }
    }
}
