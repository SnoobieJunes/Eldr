import Foundation
import PQRCCore
import Testing

@testable import Huginn

/// Phase 1 of the encrypted Mac-AI-endpoint transcript (SPEC §3.4, D9, invariant 12).
/// Exercises the at-rest layer directly with an injected `EncryptedStore`, so the suite
/// never touches the Keychain (headless-host safe — same constraint as LLMTokenAtRestTests).
@Suite("Encrypted conversation transcript")
struct ConversationMemoryTests {

    private func freshDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("eldr-transcripts-\(UUID().uuidString)", isDirectory: true)
    }

    private func newStore() -> EncryptedStore {
        EncryptedStore(randomSource: SystemRandomSource(), nonceSource: SystemNonceSource())
    }

    private func msg(
        _ id: String, _ convo: String, _ type: ParticipantType, _ text: String, _ at: Int64
    ) -> StoredMessage {
        StoredMessage(
            id: id, conversationID: convo, senderIdentity: "owner",
            participantType: type, text: text, sentAt: at)
    }

    @Test func storeRoundTripsAndPreservesOrder() async throws {
        let dir = freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = EncryptedFileMessageStore(directory: dir, store: newStore())
        let convo = "eldr:abc"
        try await store.save(msg("1", convo, .human, "hello", 1))
        try await store.save(msg("2", convo, .agent, "hi there", 2))
        let got = try await store.messages(conversationID: convo)
        #expect(got.map(\.id) == ["1", "2"])
        #expect(got.map(\.text) == ["hello", "hi there"])
    }

    @Test func conversationsAreIsolated() async throws {
        let dir = freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = EncryptedFileMessageStore(directory: dir, store: newStore())
        try await store.save(msg("a", "eldr:1", .human, "one", 1))
        try await store.save(msg("b", "eldr:2", .human, "two", 1))
        #expect(try await store.messages(conversationID: "eldr:1").map(\.text) == ["one"])
        #expect(try await store.messages(conversationID: "eldr:2").map(\.text) == ["two"])
    }

    /// Invariant 12: nothing conversation- or identity-derived hits disk in cleartext —
    /// not the message text, not the conversationID, not the sender hex, not in filenames.
    @Test func nothingPlaintextOrIdOnDisk() async throws {
        let dir = freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = EncryptedFileMessageStore(directory: dir, store: newStore())
        let secret = "skCANARY7f3a9PLAINTEXT"
        let convo = "eldr:secretConvoIdCanary"
        try await store.save(
            StoredMessage(
                id: "x", conversationID: convo, senderIdentity: "ownerHexCanary",
                participantType: .human, text: secret, sentAt: 1))

        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!files.isEmpty)
        for file in files { #expect(!file.contains("secretConvoIdCanary")) }  // opaque hashed names

        var blob = Data()
        for file in files { blob.append(try Data(contentsOf: dir.appendingPathComponent(file))) }
        let onDisk = String(decoding: blob, as: UTF8.self)
        #expect(!onDisk.contains(secret))
        #expect(!onDisk.contains("secretConvoIdCanary"))
        #expect(!onDisk.contains("ownerHexCanary"))
    }

    @Test func memoryRecordsAndRendersPriorContext() async throws {
        let dir = freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mem = ConversationMemory(directory: dir, encryptedStore: newStore())
        let convo = "eldr:mem-1"
        #expect(await mem.priorContext(sessionKey: convo, maxBytes: 4096) == nil)  // empty

        await mem.record(
            "My name is Ada", as: .human, senderIdentity: "owner",
            sessionKey: convo, threadID: nil, agentName: nil)
        await mem.record(
            "Nice to meet you, Ada.", as: .agent, senderIdentity: "eldr-acp",
            sessionKey: convo, threadID: nil, agentName: nil)

        let ctx = try #require(await mem.priorContext(sessionKey: convo, maxBytes: 4096))
        #expect(ctx.contains("Ada"))
        #expect(ctx.contains("Nice to meet you"))
        // A different conversation sees none of it (no cross-conversation bleed).
        #expect(await mem.priorContext(sessionKey: "eldr:other", maxBytes: 4096) == nil)
    }

    @Test func priorContextRespectsByteCapAndKeepsMostRecent() async throws {
        let dir = freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mem = ConversationMemory(directory: dir, encryptedStore: newStore())
        let convo = "eldr:cap"
        for i in 0..<50 {
            await mem.record(
                String(repeating: "x", count: 200) + "#\(i)", as: .human,
                senderIdentity: "owner", sessionKey: convo, threadID: nil, agentName: nil)
        }
        let ctx = try #require(await mem.priorContext(sessionKey: convo, maxBytes: 512))
        #expect(ctx.utf8.count <= 512)
        #expect(ctx.contains("#49"))  // tail-biased: the newest turn survives the cap
    }

    @Test func wipeRemovesTranscript() async throws {
        let dir = freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mem = ConversationMemory(directory: dir, encryptedStore: newStore())
        await mem.record(
            "secret", as: .human, senderIdentity: "owner",
            sessionKey: "eldr:w", threadID: nil, agentName: nil)
        #expect(await mem.priorContext(sessionKey: "eldr:w", maxBytes: 4096) != nil)
        await mem.wipe()
        #expect(await mem.priorContext(sessionKey: "eldr:w", maxBytes: 4096) == nil)
    }
}
