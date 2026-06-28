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

    // MARK: - Per-AI gate fields + two-axis grants (this revamp, P1)

    @Test func storedMessageRoundTripsPerAIFields() throws {
        let sealed = Data([0x01, 0x02, 0x03, 0x04])
        let original = StoredMessage(
            id: "m1", conversationID: "c", senderIdentity: "me",
            participantType: .agent, text: "hi", sentAt: 7,
            agentName: "clever-otter", agentAIID: "ai-123",
            aiMarks: ["ai-123", "ai-456"], sealedAgentContent: sealed)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StoredMessage.self, from: data)
        #expect(decoded == original)
        #expect(decoded.agentAIID == "ai-123")
        #expect(decoded.aiMarks == ["ai-123", "ai-456"])
        #expect(decoded.sealedAgentContent == sealed)
    }

    @Test func storedMessageDecodesWithoutPerAIFields() throws {
        // A record written before the per-AI gate existed must decode (new fields
        // nil → "visible to all my AIs", today's behavior) rather than fail.
        let legacy = """
            {"id":"m1","conversationID":"c","senderIdentity":"s","participantType":"agent",
             "text":"hello","sentAt":7,"isContext":false,"aiContext":true,"localStatus":"sent"}
            """
        let message = try JSONDecoder().decode(StoredMessage.self, from: Data(legacy.utf8))
        #expect(message.agentAIID == nil)
        #expect(message.aiMarks == nil)
        #expect(message.sealedAgentContent == nil)
        #expect(message.aiContext == true)  // legacy shareability flag preserved
    }

    @Test func humanAxisGrantIsByteStable() throws {
        let alice = try PQRCIdentity(seed: Data(repeating: 0xA7, count: 32))
        // Default axis == "human": tag and signature must match the pre-axis form.
        let scope = AIContextGrant.Scope.conversation("c1")
        #expect(scope.axis == "human")
        #expect(scope.tag == "conversation:c1")
        let defaultBytes = AIContextGrant.signatureMessage(
            scope: scope, activeUntil: 1_756_000_000, enabledBy: alice.publicKeyData)
        let explicitHuman = AIContextGrant.Scope(kind: "conversation", id: "c1", axis: "human")
        #expect(
            AIContextGrant.signatureMessage(
                scope: explicitHuman, activeUntil: 1_756_000_000,
                enabledBy: alice.publicKeyData) == defaultBytes)
        // Encode omits the default axis (frozen-vector / old-client safe).
        let json = String(decoding: try JSONEncoder().encode(scope), as: UTF8.self)
        #expect(!json.contains("axis"))
    }

    /// A NEW client → NEW client ai-axis grant survives the FULL wire round-trip and
    /// VERIFIES (the on-device path). If this passes, a grant rejection between two
    /// up-to-date clients is impossible — a real-device "not signed" violation then
    /// means the peer runs an OLDER build that predates the axis field.
    @Test func aiAxisGrantRoundTripsAndVerifiesAcrossTheWire() throws {
        let alice = try PQRCIdentity(seed: Data(repeating: 0xC3, count: 32))
        let grant = try AIContextGrant.make(
            scope: .conversation("c1", axis: AIContextGrant.Scope.aiAxis),
            activeUntil: 1_756_000_000, identity: alice)
        let body = MessageBody(text: "x", sentAt: 1, aiContextGrant: grant)
        let data = try WireJSON.encoder().encode(body)
        let decoded = try WireJSON.decoder().decode(MessageBody.self, from: data)
        let g = try #require(decoded.aiContextGrant)
        #expect(g.scope.axis == "ai")
        #expect(g.scope.tag == "conversation:c1:ai")
        #expect(g.enabledBy == alice.publicKeyData)
        #expect(
            g.hasValidSignature() == true,
            "an ai-axis grant verifies on a peer that understands the axis (new↔new works)")
    }

    @Test func aiAxisGrantTagAndSignatureDistinct() throws {
        let alice = try PQRCIdentity(seed: Data(repeating: 0xB4, count: 32))
        let human = AIContextGrant.Scope.conversation("c1", axis: "human")
        let ai = AIContextGrant.Scope.conversation("c1", axis: "ai")
        #expect(ai.tag == "conversation:c1:ai")
        #expect(ai.tag != human.tag)
        let humanSig = try AIContextGrant.make(
            scope: human, activeUntil: 1_756_000_000, identity: alice).sig
        let aiSig = try AIContextGrant.make(
            scope: ai, activeUntil: 1_756_000_000, identity: alice).sig
        #expect(humanSig != aiSig)  // distinct tags ⇒ distinct signatures
        // ai-axis serializes the field; an axis-less (old) scope decodes as human.
        let aiJSON = String(decoding: try JSONEncoder().encode(ai), as: UTF8.self)
        #expect(aiJSON.contains("\"axis\":\"ai\""))
        let legacyScopeJSON = #"{"kind":"conversation","id":"c1"}"#
        let decoded = try JSONDecoder().decode(
            AIContextGrant.Scope.self, from: Data(legacyScopeJSON.utf8))
        #expect(decoded.axis == "human")
    }
}
