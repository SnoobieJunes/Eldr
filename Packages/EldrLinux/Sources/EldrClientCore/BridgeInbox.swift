// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation

/// The AI-bridge inbox at rest (AC221, owner decision). `listen --inbox` used to append
/// plaintext JSON lines; now every line is AES-GCM sealed under a random key kept in the
/// keystore (account `bridge-inbox-key`), and `inbox read` decrypts, prints and DELETES
/// what it read. A clearly labeled debug opt-in (`--debug-plaintext-inbox`) keeps the
/// old plaintext format for local debugging only.
public enum BridgeInbox {
    public static let keyAccount = "bridge-inbox-key"
    static let prefix = "E1:"

    public static func key(_ store: FileIdentityStore) throws -> SymmetricKey {
        if let k = store.load(account: keyAccount), k.count == 32 { return SymmetricKey(data: k) }
        let k = SymmetricKey(size: .bits256)
        try store.save(k.withUnsafeBytes { Data($0) }, account: keyAccount)
        return k
    }

    /// One sealed line (no trailing newline).
    public static func seal(_ json: Data, key: SymmetricKey) throws -> Data {
        guard let c = try AES.GCM.seal(json, using: key).combined else { throw CocoaError(.coderInvalidValue) }
        return Data((prefix + c.base64EncodedString()).utf8)
    }

    /// Appends one record, 0600, sealed unless `plaintext` (debug only).
    public static func append(_ json: Data, to url: URL, key: SymmetricKey?, plaintext: Bool) throws {
        var line = plaintext ? json : try seal(json, key: key ?? { throw CocoaError(.coderInvalidValue) }())
        line.append(0x0A)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            else { throw CocoaError(.fileWriteUnknown) }
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }
        fh.seekToEndOfFile()
        fh.write(line)
    }

    /// Atomically takes the inbox (rename), decrypts every line, then overwrites and
    /// deletes the taken copy. Lines that fail to decrypt are skipped and counted.
    public static func drain(_ url: URL, key: SymmetricKey, settle: Duration = .milliseconds(200)) async throws
        -> (records: [Data], undecryptable: Int)
    {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return ([], 0) }
        let taken = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).reading.\(UUID().uuidString)")
        guard rename(url.path, taken.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        try? await Task.sleep(for: settle)  // a write already in flight lands in `taken`
        let data = (try? Data(contentsOf: taken)) ?? Data()
        var out: [Data] = [], bad = 0
        for raw in data.split(separator: 0x0A) where !raw.isEmpty {
            let s = String(decoding: raw, as: UTF8.self)
            if s.hasPrefix(prefix), let c = Data(base64Encoded: String(s.dropFirst(prefix.count))),
                let box = try? AES.GCM.SealedBox(combined: c), let p = try? AES.GCM.open(box, using: key)
            {
                out.append(p)
            } else if s.hasPrefix("{") {
                out.append(Data(raw))  // legacy / debug plaintext line
            } else {
                bad += 1
            }
        }
        if let fh = FileHandle(forWritingAtPath: taken.path) {
            fh.write(Data(repeating: 0, count: data.count)); try? fh.close()
        }
        try? fm.removeItem(at: taken)
        return (out, bad)
    }
}
