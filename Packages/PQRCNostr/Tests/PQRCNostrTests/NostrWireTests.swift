// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import PQRCCore
@testable import PQRCNostr

/// NIP-01/NIP-42 WebSocket framing used by `NostrWebSocketTransport` and the
/// pqrc-relay server. Pure codec tests — no sockets.
@Suite("Nostr wire codec", .tags(.transport))
struct NostrWireTests {
    static func sampleEvent() throws -> NostrEvent {
        let keypair = try NostrKeypair(privateKey: hexData(String(repeating: "d7", count: 32)))
        return try keypair.sign(
            NostrEvent(
                pubkey: keypair.publicKeyHex, createdAt: 1_750_000_000, kind: 1,
                tags: [["p", "abc"], ["challenge", "xyz"]], content: "wire \"quotes\" / slashes"),
            randomSource: SystemRandomSource())
    }

    @Test func clientMessages_roundTrip() throws {
        let event = try Self.sampleEvent()

        // EVENT keeps the event verifiable through the round trip.
        let eventText = try NostrWire.encode(NostrClientMessage.event(event))
        guard case .event(let decodedEvent)? = NostrWire.decodeClient(eventText) else {
            Issue.record("EVENT did not decode")
            return
        }
        #expect(decodedEvent == event)
        #expect(NostrKeypair.verify(decodedEvent))

        // REQ carries filters with the NIP-01 field names (incl. "#p").
        let filters = [
            NostrFilter(kinds: [1059], pTags: ["deadbeef"], since: 42),
            NostrFilter(authors: ["aa"], ids: ["bb"]),
        ]
        let reqText = try NostrWire.encode(
            NostrClientMessage.req(subscriptionID: "sub-1", filters: filters))
        #expect(reqText.contains("\"#p\""))
        guard case .req(let subscriptionID, let decodedFilters)? = NostrWire.decodeClient(reqText)
        else {
            Issue.record("REQ did not decode")
            return
        }
        #expect(subscriptionID == "sub-1")
        #expect(decodedFilters == filters)

        // CLOSE / AUTH.
        let closeText = try NostrWire.encode(NostrClientMessage.close(subscriptionID: "sub-1"))
        guard case .close("sub-1")? = NostrWire.decodeClient(closeText) else {
            Issue.record("CLOSE did not decode")
            return
        }
        let authText = try NostrWire.encode(NostrClientMessage.auth(event))
        guard case .auth(let decodedAuth)? = NostrWire.decodeClient(authText) else {
            Issue.record("AUTH did not decode")
            return
        }
        #expect(decodedAuth == event)
    }

    @Test func relayMessages_roundTrip() throws {
        let event = try Self.sampleEvent()

        let eventText = try NostrWire.encode(
            NostrRelayMessage.event(subscriptionID: "s", event))
        guard case .event("s", let decoded)? = NostrWire.decodeRelay(eventText) else {
            Issue.record("relay EVENT did not decode")
            return
        }
        #expect(decoded == event)

        let okText = try NostrWire.encode(
            NostrRelayMessage.ok(eventID: event.id, accepted: true, message: "stored"))
        guard case .ok(event.id, true, "stored")? = NostrWire.decodeRelay(okText) else {
            Issue.record("OK did not decode")
            return
        }

        let eoseText = try NostrWire.encode(NostrRelayMessage.eose(subscriptionID: "s"))
        guard case .eose("s")? = NostrWire.decodeRelay(eoseText) else {
            Issue.record("EOSE did not decode")
            return
        }

        let authText = try NostrWire.encode(NostrRelayMessage.auth(challenge: "nonce123"))
        guard case .auth("nonce123")? = NostrWire.decodeRelay(authText) else {
            Issue.record("AUTH did not decode")
            return
        }

        let closedText = try NostrWire.encode(
            NostrRelayMessage.closed(subscriptionID: "s", message: "rate limited"))
        guard case .closed("s", "rate limited")? = NostrWire.decodeRelay(closedText) else {
            Issue.record("CLOSED did not decode")
            return
        }
    }

    @Test func malformedAndUnknownInput_decodesToNil_neverFatal() throws {
        // SPEC §12: tolerate, never crash, never trust.
        let garbage = [
            "", "not json", "{}", "[]", "[42]",
            #"["UNKNOWN-VERB", "x"]"#,
            #"["EVENT"]"#,  // missing payload
            #"["OK", "id-only"]"#,  // missing accepted flag
            #"["EVENT", "sub", {"id": 7}]"#,  // wrong field types
        ]
        for text in garbage {
            #expect(NostrWire.decodeClient(text) == nil)
            #expect(NostrWire.decodeRelay(text) == nil)
        }
        // Extra array elements are ignored, not fatal.
        let extra = #"["EOSE", "s", "future-field", 12]"#
        guard case .eose("s")? = NostrWire.decodeRelay(extra) else {
            Issue.record("extra elements must not break decoding")
            return
        }
    }
}
