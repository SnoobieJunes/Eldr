// SPDX-License-Identifier: Apache-2.0
//
// Optional FIDO2 security-key wrap factor (DEVIATIONS AC224) for machines WITHOUT a TPM.
// The master key is AES-GCM wrapped under KEK = HKDF(hmacSecret(salt) || scryptKEK?), where
// hmacSecret is computed INSIDE the security key (CTAP2 hmac-secret extension, a touch is
// required). `master.fido` copied elsewhere is useless without the physical key; with a
// passphrase layered on, both are needed. libfido2 is dlopen'd (CEldrFIDO), no Swift deps.
import CEldrFIDO
import Crypto
import Foundation

struct FIDOWrappedMaster: Codable {
    var v: Int = 1
    var rpID: String
    var credentialID: Data
    var hmacSalt: Data
    var wrap: Data
    var passphraseSalt: Data?
}

public enum FIDOKeystoreError: Error, CustomStringConvertible, Equatable {
    case unavailable(String)
    case failed(String)
    case alreadyWrapped

    public var description: String {
        switch self {
        case .unavailable(let w): return "security key unavailable: \(w)"
        case .failed(let w): return "security key operation failed: \(w)"
        case .alreadyWrapped: return "keystore is already TPM- or security-key-wrapped"
        }
    }
}

/// The security-key seam (tests inject a mock; production is `SystemFIDO`).
public protocol FIDOAuthenticator: Sendable {
    func enroll(rpID: String) throws -> Data
    func hmacSecret(rpID: String, credentialID: Data, salt: Data) throws -> Data
}

/// A real key via libfido2. `path` nil = first enumerated device; `ELDR_FIDO_DEVICE` overrides.
/// `pin` is the authenticator PIN if one is set (`ELDR_FIDO_PIN`). UNVERIFIED on hardware in CI.
public struct SystemFIDO: FIDOAuthenticator {
    public var path: String?
    public var pin: String?
    public init(path: String? = nil, pin: String? = nil) { self.path = path; self.pin = pin }
    public static var compiledIn: Bool { eldr_fido_compiled_in() == 1 }

    public func enroll(rpID: String) throws -> Data {
        var id = [UInt8](repeating: 0, count: 1024)
        var len = id.count
        var err = [CChar](repeating: 0, count: 256)
        try Self.check(eldr_fido_enroll(path, rpID, pin, &id, &len, &err, err.count), err)
        return Data(id.prefix(len))
    }

    public func hmacSecret(rpID: String, credentialID: Data, salt: Data) throws -> Data {
        guard salt.count == 32 else { throw FIDOKeystoreError.failed("salt must be 32 bytes") }
        var out = [UInt8](repeating: 0, count: 32)
        defer { for i in out.indices { out[i] = 0 } }
        var err = [CChar](repeating: 0, count: 256)
        let rc = credentialID.withUnsafeBytes { c in
            salt.withUnsafeBytes { s in
                eldr_fido_hmac(path, rpID, pin, c.bindMemory(to: UInt8.self).baseAddress, c.count,
                               s.bindMemory(to: UInt8.self).baseAddress, &out, &err, err.count)
            }
        }
        try Self.check(rc, err)
        return Data(out)
    }

    private static func check(_ rc: Int32, _ err: [CChar]) throws {
        let msg = String(decoding: err.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        switch rc {
        case ELDR_FIDO_OK: return
        case ELDR_FIDO_UNAVAILABLE: throw FIDOKeystoreError.unavailable(msg)
        default: throw FIDOKeystoreError.failed(msg)
        }
    }
}

enum FIDOMaster {
    static let fileName = "master.fido"
    static let rpID = "eldr-keystore.local"

    static func kek(hmac: Data, passphraseKEK: SymmetricKey?) -> SymmetricKey {
        var ikm = hmac
        if let p = passphraseKEK { p.withUnsafeBytes { ikm.append(contentsOf: $0) } }
        defer { ikm.resetBytes(in: 0..<ikm.count) }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm), salt: Data("eldr/keystore/fido-wrap/v1".utf8),
            info: Data((passphraseKEK == nil ? "fido" : "fido+passphrase").utf8), outputByteCount: 32)
    }

    static func make(master: SymmetricKey, fido: any FIDOAuthenticator, passphrase: String?) throws -> FIDOWrappedMaster {
        var pk: SymmetricKey?
        var psalt: Data?
        if let passphrase {
            try PassphrasePolicy.check(passphrase)
            let s = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
            psalt = s
            pk = try LinuxKeystoreScrypt.kek(passphrase: passphrase, salt: s)
        }
        let cred = try fido.enroll(rpID: rpID)
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let h = try fido.hmacSecret(rpID: rpID, credentialID: cred, salt: salt)
        guard h.count == 32 else { throw FIDOKeystoreError.failed("hmac-secret length") }
        let box = try AES.GCM.seal(master.withUnsafeBytes { Data($0) }, using: kek(hmac: h, passphraseKEK: pk))
        guard let wrap = box.combined else { throw FIDOKeystoreError.failed("seal wrap") }
        return FIDOWrappedMaster(rpID: rpID, credentialID: cred, hmacSalt: salt, wrap: wrap, passphraseSalt: psalt)
    }

    static func open(_ rec: FIDOWrappedMaster, fido: any FIDOAuthenticator, passphrase: String?) throws -> SymmetricKey {
        var pk: SymmetricKey?
        if let salt = rec.passphraseSalt {
            guard let passphrase else { throw TPMKeystoreError.passphraseRequired }
            pk = try LinuxKeystoreScrypt.kek(passphrase: passphrase, salt: salt)
        }
        let h = try fido.hmacSecret(rpID: rec.rpID, credentialID: rec.credentialID, salt: rec.hmacSalt)
        do {
            let raw = try AES.GCM.open(AES.GCM.SealedBox(combined: rec.wrap), using: kek(hmac: h, passphraseKEK: pk))
            guard raw.count == 32 else { throw LinuxKeystoreError.corruptMasterWrap }
            return SymmetricKey(data: raw)
        } catch { throw LinuxKeystoreError.corruptMasterWrap }
    }

    static func read(_ dir: URL) throws -> FIDOWrappedMaster? {
        let url = dir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let d = try? Data(contentsOf: url), let rec = try? JSONDecoder().decode(FIDOWrappedMaster.self, from: d)
        else { throw LinuxKeystoreError.corruptMasterWrap }
        return rec
    }

    static func writeVerified(_ rec: FIDOWrappedMaster, dir: URL, master: SymmetricKey,
                              fido: any FIDOAuthenticator, passphrase: String?) throws {
        let url = dir.appendingPathComponent(fileName)
        let staged = dir.appendingPathComponent(".master.fido.staged")
        try FileIdentityStore.writeFile(staged, try JSONEncoder().encode(rec))
        do {
            guard let back = try? JSONDecoder().decode(FIDOWrappedMaster.self, from: Data(contentsOf: staged)),
                try open(back, fido: fido, passphrase: passphrase).withUnsafeBytes({ Data($0) })
                    == master.withUnsafeBytes({ Data($0) })
            else { throw FIDOKeystoreError.failed("verification of the new security-key wrap failed") }
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

/// Moves a passphrase keystore onto a security key (same master key; *.enc stay readable).
/// Verified before the passphrase-only wrap is shredded. `keepPassphrase` = both required.
public func upgradeKeystoreToSecurityKey(
    directory dir: URL, passphrase: String, keepPassphrase: Bool, fido: any FIDOAuthenticator
) throws {
    if try TPMMaster.read(dir) != nil || FIDOMaster.read(dir) != nil { throw FIDOKeystoreError.alreadyWrapped }
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
    let rec = try FIDOMaster.make(master: master, fido: fido, passphrase: p)
    try FIDOMaster.writeVerified(rec, dir: dir, master: master, fido: fido, passphrase: p)
    for u in [wrapURL, saltURL] {
        if let n = try? Data(contentsOf: u).count { try? FileIdentityStore.writeFile(u, Data(repeating: 0, count: n)) }
        try? FileManager.default.removeItem(at: u)
    }
}

/// The security key to use, or nil (libfido2 is only touched when a keystore asks for it).
public func defaultFIDOAuthenticator(environment env: [String: String]) -> (any FIDOAuthenticator)? {
    guard SystemFIDO.compiledIn else { return nil }
    let dev = env["ELDR_FIDO_DEVICE"].flatMap { $0.isEmpty ? nil : $0 }
    let pin = env["ELDR_FIDO_PIN"].flatMap { $0.isEmpty ? nil : $0 }
    return SystemFIDO(path: dev, pin: pin)
}
