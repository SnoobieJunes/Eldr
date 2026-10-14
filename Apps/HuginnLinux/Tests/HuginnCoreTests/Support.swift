// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import EldrKeystore
import Foundation
@testable import HuginnCore

struct TempDir {
    let path: String
    init() {
        path = (NSTemporaryDirectory() as NSString).appendingPathComponent("huginn-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    func sub(_ s: String) -> String { (path as NSString).appendingPathComponent(s) }
    var paths: HuginnPaths { HuginnPaths(configDir: sub("config"), binDir: sub("bin")) }
    func remove() { try? FileManager.default.removeItem(atPath: path) }
}

/// A real EldrKeystore file store with a random master key (no passphrase/TPM needed).
func testSecrets(_ dir: TempDir) -> any SecretStore {
    let d = URL(fileURLWithPath: dir.sub("keystore"))
    try? FileIdentityStore.ensureDirectory(d)
    return FileIdentityStore(directory: d, masterKey: SymmetricKey(size: .bits256), profile: HuginnSecrets.profile)
}

func run(_ exe: String, _ args: [String], env: [String: String]? = nil) throws -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    if let env { p.environment = env }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

func write(_ text: String, _ path: String, mode: Int = 0o644) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: Data(text.utf8), attributes: [.posixPermissions: mode])
}
