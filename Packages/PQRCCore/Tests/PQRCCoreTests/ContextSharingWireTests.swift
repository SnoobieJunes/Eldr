import Crypto
import Foundation
import Testing

@testable import PQRCCore

/// Wire + persistence guarantees for the AI-context feature (DEVIATIONS N23–N25).
@Suite("AI context wire format")
struct ContextSharingWireTests {
    @Test func messageBodyRoundTripsNewFields() throws {
        let alice = try PQRCIdentity(seed: Data(repeating: 0xA7, count: 32))
        let grant = try AIContextGrant.make(
            scope: .thread("t1"), activeUntil: 1_756_000_000, identity: alice)
        let body = MessageBody(
            text: "see the plan", sentAt: 1_756_000_001,
            aiContext: true, aiContextMark: AIContextMark(messageID: "m9", value: true),
            aiContextGrant: grant)
        let data = try WireJSON.encoder().encode(body)
        let decoded = try WireJSON.decoder().decode(MessageBody.self, from: data)
        #expect(decoded == body)
        #expect(decoded.aiContext == true)
        #expect(decoded.aiContextGrant?.hasValidSignature() == true)

        // Wire names match the NIP-candidate snake_case.
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"ai_context\""))
        #expect(json.contains("\"ai_context_grant\""))
        #expect(json.contains("\"ai_context_mark\""))
    }

    @Test func olderClientToleratesUnknownFields() throws {
        // A body carrying the new keys must decode on a client that ignores them
        // (SPEC §12 forward-compat). Absent keys default to nil/false.
        let json = """
            {"text":"hi","sent_at":1,"ai_context":true,"surprise_field":42}
            """
        let body = try WireJSON.decoder().decode(MessageBody.self, from: Data(json.utf8))
        #expect(body.aiContext == true)
        #expect(body.text == "hi")
    }

    @Test func storedMessageDecodesWithoutAiContext() throws {
        // Payloads written before `aiContext` existed must still decode (default
        // false) rather than failing the whole record.
        let legacy = """
            {"id":"m1","conversationID":"c","senderIdentity":"s","participantType":"human",
             "text":"hello","sentAt":7,"isContext":false,"localStatus":"sent"}
            """
        let message = try JSONDecoder().decode(StoredMessage.self, from: Data(legacy.utf8))
        #expect(message.aiContext == false)
        #expect(message.text == "hello")
    }
}
