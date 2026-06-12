import CryptoKit
import Foundation
import OSLog
import PQRCAgent
import PQRCCore
import PQRCNostr
import Security
import SwiftData
import Testing

@testable import PQRC

/// TEST-PLAN §9: security & privacy regression. Tagged `.security` — CI fails
/// the build on any failure here regardless of retry policy.
@Suite("Security & privacy regression (TEST-PLAN §9)", .serialized)
struct SecuritySuiteTests {
    static let canary = "CANARY-7f3a-the-plaintext-that-must-never-touch-disk"

    @Test func atRest_noPlaintextInStoreFiles() async throws {
        // Write canary messages through the real SwiftData store, then scan the
        // raw SQLite + WAL + SHM bytes for the canary.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pqrc-atrest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("store.sqlite")

        let container = try SwiftDataMessageStore.makeContainer(inMemory: false, url: storeURL)
        let store = SwiftDataMessageStore(modelContainer: container)
        await store.configure(
            crypter: EncryptedStore(
                randomSource: SystemRandomSource(), nonceSource: SystemNonceSource()))
        for i in 0..<20 {
            try await store.save(
                StoredMessage(
                    id: "canary-\(i)", conversationID: "conv", senderIdentity: "me",
                    participantType: .human, text: "\(Self.canary) #\(i)", sentAt: Int64(i)))
        }
        // Round-trips fine through the crypter...
        let loaded = try await store.messages(conversationID: "conv")
        #expect(loaded.count == 20)
        #expect(loaded.first?.text.contains(Self.canary) == true)

        // ...but the canary appears nowhere in the raw store files.
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        #expect(!files.isEmpty)
        let canaryBytes = Data(Self.canary.utf8)
        for file in files {
            let raw = (try? Data(contentsOf: file)) ?? Data()
            #expect(raw.range(of: canaryBytes) == nil, "plaintext canary found in \(file.lastPathComponent)")
        }
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func keychain_attributesAreThisDeviceOnlyWhenUnlocked() throws {
        let keychain = KeychainStore(service: "chat.pqrc.test-attrs")
        defer { keychain.deleteAll() }
        try keychain.save(Data("secret".utf8), account: "probe")
        let attributes = try #require(keychain.attributes(account: "probe"))
        let accessible = attributes[kSecAttrAccessible as String] as? String
        #expect(
            accessible == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String),
            "long-term secrets MUST be WhenUnlockedThisDeviceOnly (SPEC §3.1)")
        let synchronizable = attributes[kSecAttrSynchronizable as String] as? Int
        #expect(synchronizable != 1, "never iCloud-synced")
    }

    @Test func logs_noPayloadLeakage() async throws {
        // Run a REAL send+receive with the canary as content, then scan
        // everything this process logged. The logging policy is that payloads
        // are never interpolated at all — OSLogStore read in-process reveals
        // even `.private` values, so `.private` is not sufficient protection.
        let relay = LocalRelaySimulator()
        let alice = PersonaRuntime(
            displayName: "Alice", transports: [await relay.connect()],
            blobStore: LocalBlossomSimulator(), provider: MockAgentProvider(),
            randomSource: SeededRandomSource(seed: 81), nonceSource: SeededRandomSource(seed: 82),
            keychainService: "chat.pqrc.test-logs-alice")
        let bob = PersonaRuntime(
            displayName: "Bob", transports: [await relay.connect()],
            blobStore: LocalBlossomSimulator(), provider: MockAgentProvider(),
            randomSource: SeededRandomSource(seed: 83), nonceSource: SeededRandomSource(seed: 84),
            keychainService: "chat.pqrc.test-logs-bob")
        await alice.keychain.deleteAll()
        await bob.keychain.deleteAll()
        _ = try await alice.bootstrap(inMemoryStore: true)
        _ = try await bob.bootstrap(inMemoryStore: true)
        try await alice.addVerifiedPeer(bob)
        try await bob.addVerifiedPeer(alice)
        try await alice.establishWith(bob, firstMessage: Self.canary)
        try await Task.sleep(for: .milliseconds(300))
        Log.messageEvent("send", conversationID: "conv-123", payloadBytes: Self.canary.utf8.count)
        let bobMessages = await bob.messages(conversationID: await alice.identityHex)
        #expect(bobMessages.first?.text == Self.canary, "the canary really flowed end to end")

        let logStore = try OSLogStore(scope: .currentProcessIdentifier)
        let position = logStore.position(date: Date().addingTimeInterval(-60))
        let entries = try logStore.getEntries(at: position)
            .compactMap { $0 as? OSLogEntryLog }
        #expect(entries.contains { $0.subsystem == "chat.pqrc" }, "expected captured entries")
        for entry in entries {
            #expect(
                !entry.composedMessage.contains(Self.canary),
                "payload leaked into the log stream via \(entry.subsystem)")
        }
        await alice.shutdown()
        await bob.shutdown()
    }

    @Test func blocked_senderDroppedPostUnseal_noUITrace() async throws {
        // Full runtime path: Bob blocks Alice; her messages vanish post-unseal
        // with no notification to her and no trace in Bob's store (D8).
        let relay = LocalRelaySimulator()
        let alice = PersonaRuntime(
            displayName: "Alice", transports: [await relay.connect()],
            blobStore: LocalBlossomSimulator(), provider: MockAgentProvider(),
            randomSource: SeededRandomSource(seed: 71), nonceSource: SeededRandomSource(seed: 72),
            keychainService: "chat.pqrc.test-block-alice")
        let bob = PersonaRuntime(
            displayName: "Bob", transports: [await relay.connect()],
            blobStore: LocalBlossomSimulator(), provider: MockAgentProvider(),
            randomSource: SeededRandomSource(seed: 73), nonceSource: SeededRandomSource(seed: 74),
            keychainService: "chat.pqrc.test-block-bob")
        await alice.keychain.deleteAll()
        await bob.keychain.deleteAll()
        _ = try await alice.bootstrap(inMemoryStore: true)
        _ = try await bob.bootstrap(inMemoryStore: true)
        try await alice.addVerifiedPeer(bob)
        try await bob.addVerifiedPeer(alice)
        try await alice.establishWith(bob, firstMessage: "hello before block")
        try await Task.sleep(for: .milliseconds(200))
        let aliceHex = await alice.identityHex
        #expect(await bob.messages(conversationID: aliceHex).count == 1)

        await bob.setBlocked(aliceHex, blocked: true)
        try await alice.sendMessage("you should never see this", conversationID: await bob.identityHex)
        try await Task.sleep(for: .milliseconds(300))
        let after = await bob.messages(conversationID: aliceHex)
        #expect(after.count == 1, "blocked sender's message must leave no trace")
        await alice.shutdown()
        await bob.shutdown()
    }

    @Test func wipeIdentity_destroysKeysAndStore() async throws {
        let relay = LocalRelaySimulator()
        let runtime = PersonaRuntime(
            displayName: "Doomed", transports: [await relay.connect()],
            blobStore: LocalBlossomSimulator(), provider: MockAgentProvider(),
            keychainService: "chat.pqrc.test-wipe")
        await runtime.keychain.deleteAll()
        _ = try await runtime.bootstrap(inMemoryStore: true)
        let keychain = await runtime.keychain
        #expect(keychain.loadIfPresent(account: "identity-seed") != nil)
        #expect(keychain.loadIfPresent(account: "wrapped-master-key") != nil)

        try await runtime.wipeIdentity()
        #expect(keychain.loadIfPresent(account: "identity-seed") == nil)
        #expect(keychain.loadIfPresent(account: "nostr-key") == nil)
        #expect(keychain.loadIfPresent(account: "wrapped-master-key") == nil)
    }

    @Test func secureEnclaveWrapper_roundTripsOnThisHost() throws {
        // Uses the SE when available, the documented software fallback otherwise.
        let keychain = KeychainStore(service: "chat.pqrc.test-se")
        defer { keychain.deleteAll() }
        let wrapper = SecureEnclaveKeyWrapper(keychain: keychain)
        let master = SystemRandomSource().bytes(32)
        let wrapped = try wrapper.wrap(masterKey: master)
        #expect(wrapped != master)
        #expect(try wrapper.unwrap(wrapped: wrapped) == master)
    }
}
