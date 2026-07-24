// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import PQRCNostr

/// WS-I7: the gateway↔supervisor status contract. Huginn's status row ("●
/// connected — 4 replies · 1.2k tokens") is folded from these lines, so this
/// suite pins BOTH directions — a reworded emitter or a loosened parser fails
/// here rather than silently zeroing a user's dashboard.
@Suite("Buzz gateway status lines")
struct BuzzGatewayStatusTests {

    @Test("every status round-trips emit → parse")
    func roundTrip() {
        let cases: [BuzzGatewayStatus] = [
            .starting(relay: "wss://auston.communities.buzz.xyz", agentPubkey: String(repeating: "a", count: 64)),
            .connected(relay: "wss://auston.communities.buzz.xyz"),
            .listening(channels: 3),
            .reply(channel: "4f1c9d2e-0000-0000-0000-000000000000", characters: 412),
            .tokens(turn: 1234),
            .failed(message: "LLM turn failed: connection refused"),
        ]
        for status in cases {
            let line = status.line
            #expect(line.hasPrefix(BuzzGatewayStatus.prefix))
            #expect(BuzzGatewayStatus.parse(line) == status, "round-trip failed for \(status)")
        }
    }

    @Test("ordinary log lines and unknown kinds are ignored, never fatal")
    func ignoresNoise() {
        #expect(BuzzGatewayStatus.parse("eldr-buzz-agent: authenticated to wss://…") == nil)
        #expect(BuzzGatewayStatus.parse("") == nil)
        #expect(BuzzGatewayStatus.parse(BuzzGatewayStatus.prefix + "not json") == nil)
        // Forward compatibility (SPEC §12): a newer gateway's kind is skipped.
        #expect(BuzzGatewayStatus.parse(BuzzGatewayStatus.prefix + #"{"kind":"from-the-future"}"#) == nil)
    }

    @Test("a line keeps parsing when the child's own prefix is in front of it")
    func toleratesLeadingPrefix() {
        let embedded = "eldr-buzz-agent: " + BuzzGatewayStatus.connected(relay: "wss://r").line
        #expect(BuzzGatewayStatus.parse(embedded) == .connected(relay: "wss://r"))
    }

    @Test("counters fold a whole log tail into the status row's numbers")
    func countersFoldALogTail() {
        var counters = BuzzGatewayCounters()
        let agent = String(repeating: "b", count: 64)
        let log = [
            "eldr-buzz-agent: brain: http://127.0.0.1:1337/v1 model=qwen",
            BuzzGatewayStatus.starting(relay: "wss://r", agentPubkey: agent).line,
            BuzzGatewayStatus.failed(message: "membership announce not accepted").line,
            BuzzGatewayStatus.connected(relay: "wss://r").line,
            BuzzGatewayStatus.listening(channels: 2).line,
            BuzzGatewayStatus.reply(channel: "c1", characters: 100).line,
            BuzzGatewayStatus.tokens(turn: 900).line,
            BuzzGatewayStatus.reply(channel: "c1", characters: 40).line,
            BuzzGatewayStatus.tokens(turn: 350).line,
        ]
        for line in log { counters.ingest(line: line) }

        #expect(counters.agentPubkey == agent)
        #expect(counters.authenticated)
        #expect(counters.channelsListening == 2)
        #expect(counters.replies == 2)
        #expect(counters.tokens == 1250)
        // A failure BEFORE a successful connect must not leave the row red.
        #expect(counters.lastFailure == nil)
    }

    @Test("a failure after connecting is surfaced, and a later reply clears it")
    func failureIsStickyUntilTheNextSuccess() {
        var counters = BuzzGatewayCounters()
        counters.ingest(.connected(relay: "wss://r"))
        counters.ingest(.failed(message: "LLM turn failed"))
        #expect(counters.lastFailure == "LLM turn failed")
        counters.ingest(.reply(channel: "c", characters: 5))
        #expect(counters.lastFailure == nil)
        #expect(counters.replies == 1)
    }
}

/// WS-I7 "Remove": the agent-signed retirement + NIP-09 deletion request the GUI
/// publishes before destroying the agent key.
@Suite("Buzz agent retirement events")
struct BuzzRetirementEventTests {

    @Test("retirement profile is a kind:0 that says so")
    func retirementProfile() {
        let pubkey = String(repeating: "c", count: 64)
        let event = BuzzEvents.retirementProfile(
            pubkey: pubkey, displayName: "Eldr", reason: "Disconnected by its owner.")
        #expect(event.kind == BuzzEvents.Kind.profile)
        #expect(event.pubkey == pubkey)
        #expect(event.content.contains("Eldr (retired)"))
        #expect(event.content.contains("Disconnected by its owner."))
        #expect(event.isRumor, "builders return UNSIGNED events; the caller signs")
        #expect(event.hasValidID())
    }

    @Test("deletion request is NIP-09 kind:5 addressing the agent's own profiles")
    func deletionRequest() {
        let pubkey = String(repeating: "d", count: 64)
        let event = BuzzEvents.profileDeletionRequest(pubkey: pubkey, reason: "agent revoked")
        #expect(event.kind == 5)
        #expect(event.content == "agent revoked")
        let addresses = event.tags.filter { $0.first == "a" }.map { $0[1] }
        #expect(addresses == ["0:\(pubkey):", "10100:\(pubkey):"])
        #expect(event.hasValidID())
    }
}
