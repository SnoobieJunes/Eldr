// SPDX-License-Identifier: Apache-2.0
//
// In-process TPM 2.0 wrapping of the keystore master key (DEVIATIONS AC218, invariant 10).
//
// A 32-byte secret is SEALED in this host's TPM (fixedTPM|fixedParent keyed-hash object under
// the owner-hierarchy SRK, through the system tpm2-tss ESAPI, see CEldrTPM). The master key is
// AES-GCM wrapped under KEK = HKDF(tpmSecret || scryptKEK?) — so `master.tpm` copied to another
// machine is useless without THIS TPM, and when a passphrase is layered on top BOTH are needed.
import CEldrTPM
import Crypto
import CryptoExtras
import Foundation

/// On-disk `master.tpm` (JSON, 0600).
struct TPMWrappedMaster: Codable {
    var v: Int = 1
    /// TPM2B_PUBLIC || TPM2B_PRIVATE of the sealed secret (only loadable by this TPM).
    var sealed: Data
    /// AES-GCM(masterKey) under the KEK.
    var wrap: Data
    /// scrypt salt when a passphrase is layered on top (nil = TPM only).
    var passphraseSalt: Data?
}

public enum TPMKeystoreError: Error, CustomStringConvertible, Equatable {
    case unavailable(String)
    case failed(String)
    case passphraseRequired
    case alreadyTPM
    case notPassphraseKeystore

    public var description: String {
        switch self {
        case .unavailable(let w): return "TPM unavailable: \(w)"
        case .failed(let w): return "TPM operation failed: \(w)"
        case .passphraseRequired:
            return "this keystore is TPM-wrapped AND passphrase-protected; supply the passphrase too"
        case .alreadyTPM: return "keystore is already TPM-wrapped"
        case .notPassphraseKeystore: return "no passphrase keystore (master.wrap) to upgrade here"
        }
    }
}

/// The TPM seam (tests can inject a fake; production is `SystemTPM`).
public protocol TPMSealer: Sendable {
    func seal(_ secret: Data) throws -> Data
    func unseal(_ blob: Data) throws -> Data
}

/// The system TPM via tpm2-tss. `tcti` nil = the tpm2-tss default (tabrmd, /dev/tpmrm0, /dev/tpm0);
/// `ELDR_TPM_TCTI` overrides it (e.g. "swtpm:host=127.0.0.1,port=2321" for the SIMULATED tests).
public struct SystemTPM: TPMSealer {
    public var tcti: String?
    public init(tcti: String? = nil) { self.tcti = tcti }

    public static var compiledIn: Bool { eldr_tpm_compiled_in() == 1 }

    public func seal(_ secret: Data) throws -> Data {
        var blob = [UInt8](repeating: 0, count: 4096)
        var blobLen = blob.count
        var err = [CChar](repeating: 0, count: 256)
        let rc = secret.withUnsafeBytes { s in
            eldr_tpm_seal(tcti, s.bindMemory(to: UInt8.self).baseAddress, s.count, &blob, &blobLen, &err, err.count)
        }
        try Self.check(rc, err)
        return Data(blob.prefix(blobLen))
    }

    public func unseal(_ blob: Data) throws -> Data {
        var out = [UInt8](repeating: 0, count: 128)
        var outLen = out.count
        var err = [CChar](repeating: 0, count: 256)
        let rc = blob.withUnsafeBytes { b in
            eldr_tpm_unseal(tcti, b.bindMemory(to: UInt8.self).baseAddress, b.count, &out, &outLen, &err, err.count)
        }
        defer { for i in out.indices { out[i] = 0 } }
        try Self.check(rc, err)
        return Data(out.prefix(outLen))
    }

    private static func check(_ rc: Int32, _ err: [CChar]) throws {
        let msg = String(decoding: err.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        switch rc {
        case ELDR_TPM_OK: return
        case ELDR_TPM_UNAVAILABLE: throw TPMKeystoreError.unavailable(msg)
        default: throw TPMKeystoreError.failed(msg)
        }
    }
}

enum TPMMaster {
    static let fileName = "master.tpm"

    static func kek(tpmSecret: Data, passphraseKEK: SymmetricKey?) -> SymmetricKey {
        var ikm = tpmSecret
        if let p = passphraseKEK { p.withUnsafeBytes { ikm.append(contentsOf: $0) } }
        defer { ikm.resetBytes(in: 0..<ikm.count) }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm), salt: Data("eldr/keystore/tpm-wrap/v1".utf8),
            info: Data((passphraseKEK == nil ? "tpm" : "tpm+passphrase").utf8), outputByteCount: 32)
    }

    /// Builds (but does not write) a TPM-wrapped record for `master`.
    static func make(master: SymmetricKey, tpm: any TPMSealer, passphrase: String?) throws -> TPMWrappedMaster {
        let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let sealed = try tpm.seal(secret)
        var salt: Data?
        var pk: SymmetricKey?
        if let passphrase {
            let s = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
            salt = s
            pk = try LinuxKeystoreScrypt.kek(passphrase: passphrase, salt: s)
        }
        let raw = master.withUnsafeBytes { Data($0) }
        let box = try AES.GCM.seal(raw, using: kek(tpmSecret: secret, passphraseKEK: pk))
        guard let wrap = box.combined else { throw TPMKeystoreError.failed("seal wrap") }
        return TPMWrappedMaster(sealed: sealed, wrap: wrap, passphraseSalt: salt)
    }

    static func open(_ rec: TPMWrappedMaster, tpm: any TPMSealer, passphrase: String?) throws -> SymmetricKey {
        var pk: SymmetricKey?
        if let salt = rec.passphraseSalt {
            guard let passphrase else { throw TPMKeystoreError.passphraseRequired }
            pk = try LinuxKeystoreScrypt.kek(passphrase: passphrase, salt: salt)
        }
        let secret = try tpm.unseal(rec.sealed)
        do {
            let raw = try AES.GCM.open(AES.GCM.SealedBox(combined: rec.wrap), using: kek(tpmSecret: secret, passphraseKEK: pk))
            guard raw.count == 32 else { throw LinuxKeystoreError.corruptMasterWrap }
            return SymmetricKey(data: raw)
        } catch {
            throw LinuxKeystoreError.corruptMasterWrap  // wrong passphrase or wrong TPM
        }
    }

    static func read(_ dir: URL) throws -> TPMWrappedMaster? {
        let url = dir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let d = try? Data(contentsOf: url), let rec = try? JSONDecoder().decode(TPMWrappedMaster.self, from: d)
        else { throw LinuxKeystoreError.corruptMasterWrap }
        return rec
    }

    /// Writes `rec` atomically, then re-opens it from disk and checks it yields `master`
    /// BEFORE anything else is touched (no key loss on a failed or half-done upgrade).
    static func writeVerified(_ rec: TPMWrappedMaster, dir: URL, master: SymmetricKey,
                              tpm: any TPMSealer, passphrase: String?) throws {
        let url = dir.appendingPathComponent(fileName)
        let staged = dir.appendingPathComponent(".master.tpm.staged")
        try FileIdentityStore.writeFile(staged, try JSONEncoder().encode(rec))
        do {
            guard let back = try? JSONDecoder().decode(TPMWrappedMaster.self, from: Data(contentsOf: staged)),
                try open(back, tpm: tpm, passphrase: passphrase).withUnsafeBytes({ Data($0) })
                    == master.withUnsafeBytes({ Data($0) })
            else { throw TPMKeystoreError.failed("verification of the new TPM wrap failed") }
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        guard rename(staged.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: staged)
            throw LinuxKeystoreError.writeFailed(url.path)
        }
    }
}

/// Upgrades an existing scrypt-passphrase keystore to TPM wrapping, in place and atomically:
/// the old wrap is unlocked with `passphrase`, a new `master.tpm` is written and VERIFIED, and
/// only then is the passphrase-only `master.wrap`/`master.salt` removed (a disk copy must not
/// keep a TPM-free way in). Same master key, so every *.enc file stays readable.
/// `keepPassphrase` layers the passphrase on top (both required afterwards).
public func upgradeKeystoreToTPM(
    directory dir: URL, passphrase: String, keepPassphrase: Bool, tpm: any TPMSealer
) throws {
    if try TPMMaster.read(dir) != nil { throw TPMKeystoreError.alreadyTPM }
    let wrapURL = dir.appendingPathComponent("master.wrap")
    let saltURL = dir.appendingPathComponent("master.salt")
    guard let wrapped = try? Data(contentsOf: wrapURL), let salt = try? Data(contentsOf: saltURL) else {
        throw TPMKeystoreError.notPassphraseKeystore
    }
    let master: SymmetricKey
    do {
        let raw = try AES.GCM.open(AES.GCM.SealedBox(combined: wrapped),
                                   using: try LinuxKeystoreScrypt.kek(passphrase: passphrase, salt: salt))
        guard raw.count == 32 else { throw LinuxKeystoreError.corruptMasterWrap }
        master = SymmetricKey(data: raw)
    } catch { throw LinuxKeystoreError.corruptMasterWrap }
    let p = keepPassphrase ? passphrase : nil
    let rec = try TPMMaster.make(master: master, tpm: tpm, passphrase: p)
    try TPMMaster.writeVerified(rec, dir: dir, master: master, tpm: tpm, passphrase: p)
    // Only now retire the passphrase-only wrap (overwrite, then unlink).
    for u in [wrapURL, saltURL] {
        if let n = try? Data(contentsOf: u).count {
            try? FileIdentityStore.writeFile(u, Data(repeating: 0, count: n))
        }
        try? FileManager.default.removeItem(at: u)
    }
}

/// What protects a keystore directory, without unlocking it (for `keystore status`).
public enum KeystoreProtection: String, Sendable {
    case tpm, tpmAndPassphrase, passphraseOnly, uninitialized

    public static func inspect(directory dir: URL) -> KeystoreProtection {
        if let rec = try? TPMMaster.read(dir) { return rec.passphraseSalt == nil ? .tpm : .tpmAndPassphrase }
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("master.wrap").path) { return .passphraseOnly }
        return .uninitialized
    }
}

/// The TPM to use on this host, or nil: `ELDR_TPM_TCTI` (explicit, e.g. a SIMULATOR), else the
/// default tpm2-tss path when a TPM character device exists.
public func defaultTPMSealer(environment env: [String: String], tpmPresent: () -> Bool) -> (any TPMSealer)? {
    guard SystemTPM.compiledIn else { return nil }
    if let t = env["ELDR_TPM_TCTI"], !t.isEmpty { return SystemTPM(tcti: t) }
    return tpmPresent() ? SystemTPM(tcti: nil) : nil
}
