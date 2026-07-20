// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

import PQRCCore

// §13.5 endpoint model: the watch-along draft marker must round-trip through the
// MessageBody Codable wire, use stable snake_case keys, be omitted when absent, and —
// crucially — be tolerated as an unknown field by clients that predate it (SPEC §12).
@Suite("AgentDraft wire (§13.5 endpoint)")
struct AgentDraftWireTests {

    @Test func agentDraftRoundTripsWithSnakeCaseKeys() throws {
        let draft = AgentDraft(agentName: "eldr", voiceInto: "group-123", threadID: "t1")
        let data = try JSONEncoder().encode(draft)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("agent_name"))
        #expect(json.contains("voice_into"))
        #expect(json.contains("thread_id"))
        #expect(try JSONDecoder().decode(AgentDraft.self, from: data) == draft)
    }

    @Test func messageBodyCarriesAgentDraft() throws {
        let body = MessageBody(
            text: "the key is sk-XXXX", sentAt: 1000,
            agentDraft: AgentDraft(agentName: "eldr", voiceInto: "g", threadID: nil))
        let data = try JSONEncoder().encode(body)
        #expect(String(decoding: data, as: UTF8.self).contains("agent_draft"))
        let decoded = try JSONDecoder().decode(MessageBody.self, from: data)
        #expect(decoded.agentDraft == body.agentDraft)
        #expect(decoded.text == "the key is sk-XXXX")
    }

    @Test func absentDraftDecodesNilAndIsNotEmitted() throws {
        let body = MessageBody(text: "hi", sentAt: 5)
        let data = try JSONEncoder().encode(body)
        #expect(!String(decoding: data, as: UTF8.self).contains("agent_draft"))
        #expect(try JSONDecoder().decode(MessageBody.self, from: data).agentDraft == nil)
    }

    @Test func unknownFieldsTolerated() throws {
        // A peer sends a body with a field this client doesn't know — must still decode,
        // and our known optional fields fill in (forward compatibility, SPEC §12).
        let json = #"{"text":"hi","sent_at":7,"some_future_field":42,"agent_draft":{"voice_into":"g"}}"#
        let decoded = try JSONDecoder().decode(MessageBody.self, from: Data(json.utf8))
        #expect(decoded.text == "hi")
        #expect(decoded.agentDraft?.voiceInto == "g")
        #expect(decoded.agentDraft?.agentName == nil)
    }
}
