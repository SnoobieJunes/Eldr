// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@testable import eldr_node

// WS-B5: the node's OWN copy of the sybilclaw gateway client is gone — `SybilclawLLMClient`
// now wraps PQRCACP's unified `SybilclawGatewayClient` and conforms to
// `SessionScopedLLMClient` so `ACPAgent` (see `PQRCACPTests/ACPAgentTests.swift`'s
// `sessionScopedClient_getsDistinctSessionIdPerACPSession_noBleed`) can give each ACP
// session its OWN gateway session. This suite pins the node-specific half of that fix:
// `gatewaySessionKey(for:)`, the pure function turning an ACP `sessionId` into a gateway
// session key. Before this fix the node built ONE `sessionBase` at `SybilclawGatewayClient`
// construction and reused it for every turn regardless of which ACP session it belonged
// to — two live conversations (e.g. two projects) would share one sybilclaw gateway
// session and bleed context into each other.
@Suite("eldr-node sybilclaw session scoping (WS-B5)")
struct SybilclawLLMClientTests {
    @Test func twoDistinctACPSessions_produceTwoDistinctGatewaySessionKeys() {
        let keyA = SybilclawLLMClient.gatewaySessionKey(for: "eldr-session-1")
        let keyB = SybilclawLLMClient.gatewaySessionKey(for: "eldr-session-2")
        #expect(keyA != keyB)  // two scopes → two distinct sessionKeys, no bleed
    }

    @Test func sameACPSession_producesTheSameGatewaySessionKeyEveryTime() {
        // Stability across turns of the SAME session — the gateway must keep bucketing
        // this conversation's history under one key across the whole session, not a
        // fresh one per turn (the "random-UUID-per-message" bug this line's sibling fix,
        // `sessionBase`, was originally added to kill).
        let first = SybilclawLLMClient.gatewaySessionKey(for: "eldr-session-7")
        let second = SybilclawLLMClient.gatewaySessionKey(for: "eldr-session-7")
        #expect(first == second)
    }
}
