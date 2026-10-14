// SPDX-License-Identifier: Apache-2.0
import Crypto
import Foundation
import Testing

@testable import EldrClientCore
import EldrKeystore

@Suite("AC221: bridge inbox at rest")
struct BridgeInboxTests {
    @Test func inboxIsEncrypted_drainDecryptsAndDeletes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eldr-inbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = FileIdentityStore(directory: dir.appendingPathComponent("st"), masterKey: SymmetricKey(size: .bits256), profile: .eldrChat)
        try FileIdentityStore.ensureDirectory(dir.appendingPathComponent("st"))
        let key = try BridgeInbox.key(store)
        #expect(try BridgeInbox.key(store).withUnsafeBytes { Data($0) } == key.withUnsafeBytes { Data($0) })
        let inbox = dir.appendingPathComponent("in.jsonl")
        let canary = #"{"text":"CANARY-secret-7731"}"#
        try BridgeInbox.append(Data(canary.utf8), to: inbox, key: key, plaintext: false)
        try BridgeInbox.append(Data(canary.utf8), to: inbox, key: key, plaintext: false)
        let disk = try Data(contentsOf: inbox)
        #expect(disk.range(of: Data("CANARY".utf8)) == nil)  // never on disk in clear
        let mode = (try FileManager.default.attributesOfItem(atPath: inbox.path)[.posixPermissions] as? Int) ?? 0
        #expect(mode == 0o600)
        let (recs, bad) = try await BridgeInbox.drain(inbox, key: key, settle: .zero)
        #expect(recs.count == 2 && bad == 0 && String(decoding: recs[0], as: UTF8.self) == canary)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0 != "st" }
        #expect(left.isEmpty)  // deleted after read
        // Another keystore's key can't read it.
        try BridgeInbox.append(Data(canary.utf8), to: inbox, key: key, plaintext: false)
        let other = try await BridgeInbox.drain(inbox, key: SymmetricKey(size: .bits256), settle: .zero)
        #expect(other.records.isEmpty && other.undecryptable == 1)
    }
}
