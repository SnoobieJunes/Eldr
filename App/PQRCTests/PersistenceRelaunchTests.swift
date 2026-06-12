import Foundation
import PQRCAgent
import PQRCCore
import PQRCNostr
import Testing

@testable import PQRC

/// The relaunch regression ("messages and contacts disappear after you reopen
/// the app"): a PersonaRuntime booted against the same Keychain service and
/// store file must come back with its contacts, history, ratchet sessions and
/// aliases — and keep conversing.
@Suite("Relaunch persistence (A11)", .serialized)
struct PersistenceRelaunchTests {
    private func makeRuntime(
        name: String, seed: UInt64, relay: LocalRelaySimulator, service: String
    ) async -> PersonaRuntime {
        PersonaRuntime(
            displayName: name, transports: [await relay.connect()],
            blobStore: LocalBlossomSimulator(), provider: MockAgentProvider(),
            randomSource: SeededRandomSource(seed: seed),
            nonceSource: SeededRandomSource(seed: seed &+ 50),
            keychainService: service)
    }

    @Test func relaunch_restoresContactsMessagesSessions_andKeepsConversing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pqrc-relaunch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("store.sqlite")
        let service = "chat.pqrc.test-relaunch-bob"

        let relay = LocalRelaySimulator()
        let alice = await makeRuntime(
            name: "Alice", seed: 81, relay: relay, service: "chat.pqrc.test-relaunch-alice")
        let bob = await makeRuntime(name: "Bob", seed: 83, relay: relay, service: service)
        await alice.keychain.deleteAll()
        await bob.keychain.deleteAll()
        _ = try await alice.bootstrap(inMemoryStore: true)
        _ = try await bob.bootstrap(inMemoryStore: false, storeURL: storeURL)
        try await alice.addVerifiedPeer(bob)
        try await bob.addVerifiedPeer(alice)

        // Alice announces an alias, establishes, and both sides talk.
        await alice.setMyAlias("Allie")
        try await alice.establishWith(bob, firstMessage: "before relaunch")
        try await Task.sleep(for: .milliseconds(300))
        let aliceHex = await alice.identityHex
        let bobHex = await bob.identityHex
        try await bob.sendMessage("ack before relaunch", conversationID: aliceHex)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await bob.messages(conversationID: aliceHex).count == 2)
        let bobIdentityBefore = await bob.identityHex
        await bob.shutdown()

        // "Relaunch": a fresh runtime over the same Keychain + store file.
        let bob2 = await makeRuntime(name: "Bob", seed: 85, relay: relay, service: service)
        _ = try await bob2.bootstrap(inMemoryStore: false, storeURL: storeURL)

        // Identity, contacts, history, and the peer's alias all survived.
        #expect(await bob2.identityHex == bobIdentityBefore)
        let restored = await bob2.messages(conversationID: aliceHex)
        #expect(restored.map(\.text) == ["before relaunch", "ack before relaunch"])
        let records = await bob2.allContactRecords()
        #expect(records.count == 1)
        #expect(records.first?.identityHex == aliceHex)
        #expect(records.first?.peerAlias == "Allie")

        // The ratchet session survived too: conversation continues BOTH ways
        // with no re-handshake.
        try await alice.sendMessage("after relaunch", conversationID: bobHex)
        try await Task.sleep(for: .milliseconds(400))
        #expect(
            await bob2.messages(conversationID: aliceHex).map(\.text).contains("after relaunch"),
            "restored session must decrypt new traffic")
        try await bob2.sendMessage("bob still here", conversationID: aliceHex)
        try await Task.sleep(for: .milliseconds(400))
        #expect(
            await alice.messages(conversationID: bobHex).map(\.text).contains("bob still here"),
            "peer must decrypt traffic from the restored session")

        // No duplicates from relay replays (the processed-envelope seed).
        let texts = await bob2.messages(conversationID: aliceHex).map(\.text)
        #expect(texts.filter { $0 == "before relaunch" }.count == 1)

        await alice.shutdown()
        await bob2.shutdown()
        await bob2.keychain.deleteAll()
        await alice.keychain.deleteAll()
    }
}
