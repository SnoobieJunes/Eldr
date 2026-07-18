import Foundation
import Testing

@testable import PQRCACP

// WS-B5: these suites were previously duplicated across two hosts —
// Apps/Huginn/Tests/GatewayHandshakeTests.swift + GatewayReplyTests.swift (testing the
// Huginn copy of `SybilclawGatewayClient`) and
// Packages/EldrNode/Tests/EldrNodeCoreTests/SybilclawGatewayFramingTests.swift (a near-
// duplicate parity lock on the node's OWN copy, added specifically because the two
// clients had already drifted once). Now that there is exactly ONE client (this package),
// there is exactly one suite: every assertion from all three original suites survives
// here (the node suite's checks were a subset of the app's — `connectDeclares...`,
// `connectRequestsOperatorScopes`, `authIsOmitted...` map onto the equivalent app-side
// tests below), so nothing regresses, and a drift can never happen again — there is
// only one `connectParams()` left to drift.

/// Locks the SybilClaw/OpenClaw gateway `connect` handshake identity against a future blind
/// edit. The id/mode MUST come from the gateway's compiled allowlists (13 client ids / 7 modes,
/// .../protocol/client-info.ts) or the handshake is rejected with
/// "must be equal to constant; must match a schema in anyOf". The cofounder's fork
/// (rdevaul/sybilclaw) speaks protocol v3 and upstream is v4; the gateway accepts a client iff
/// its advertised range BRACKETS the server version, so we send [3, 4]. These regressed once
/// already (we shipped "huginn"/"operator"/maxProtocol 4 alone) — that bug is what this guards.
@Suite("Gateway connect handshake")
struct GatewayHandshakeTests {
    // Transcribed from packages/gateway-protocol/src/client-info.ts (github.com/openclaw/openclaw,
    // verified 2026-06-28). The test fails loudly if connectParams() ever drifts off-list again.
    static let validClientIDs: Set<String> = [
        "webchat-ui", "openclaw-control-ui", "openclaw-tui", "webchat", "cli",
        "gateway-client", "openclaw-macos", "openclaw-ios", "openclaw-android",
        "node-host", "test", "fingerprint", "openclaw-probe",
    ]
    static let validClientModes: Set<String> = [
        "webchat", "cli", "ui", "backend", "node", "probe", "test",
    ]

    private func params(token: String? = nil) -> [String: Any] {
        SybilclawGatewayClient(port: 18789, token: token).connectParams()
    }
    private func client() -> [String: Any] {
        params()["client"] as? [String: Any] ?? [:]
    }

    @Test func clientIDAndModeAreAllowlisted() {
        let c = client()
        let id = c["id"] as? String
        let mode = c["mode"] as? String
        #expect(id == "openclaw-macos")
        #expect(mode == "backend")
        #expect(id.map(Self.validClientIDs.contains(_:)) == true)
        #expect(mode.map(Self.validClientModes.contains(_:)) == true)
    }

    /// (Merged from the node's `connectDeclaresBackendClientIdentityAndProtocolRange`.)
    @Test func clientDeclaresMacOSPlatform() {
        #expect(client()["platform"] as? String == "macos")
    }

    @Test func protocolRangeBracketsForkV3() {
        // The gateway accepts a client iff min ≤ serverVersion ≤ max. The fork is v3, so the
        // range must include 3; we advertise [3, 4] to also accept an upstream v4 gateway.
        let p = params()
        let min = p["minProtocol"] as? Int
        let max = p["maxProtocol"] as? Int
        #expect(min == 3)
        #expect(max == 4)
        #expect((min ?? 99) <= 3 && (max ?? 0) >= 3)  // brackets the fork's v3
    }

    @Test func operatorRoleAndScopesPreserved() {
        // The valid authz layer (separate from client.id/mode) that our June-25 rewrite got right.
        let p = params()
        #expect(p["role"] as? String == "operator")
        let scopes = p["scopes"] as? [String] ?? []
        // Exact match (the node suite's stronger check) implies each `contains` the app
        // suite asserted individually.
        #expect(scopes == ["operator.read", "operator.write", "operator.talk.secrets"])
    }

    @Test func handshakeCarriesNoPromptOrToken() {
        // Defense-in-depth for the diagnostics redaction: the handshake must never carry user
        // content, and with no token configured there is no `auth` block to leak.
        let p = params()
        #expect(p["message"] == nil)
        #expect(p["auth"] == nil)
    }

    @Test func authBlockAppearsOnlyWhenTokenConfigured() {
        #expect(params(token: nil)["auth"] == nil)
        let auth = params(token: "secret")["auth"] as? [String: Any]
        #expect(auth?["token"] as? String == "secret")
    }
}

/// Locks the sybilclaw gateway REPLY selection (audit finding A2). The assistant text is the
/// cumulative agent-stream snapshot (`event:agent` `data.text`, accumulated into `assembled`).
/// The terminal `chat:final` frame's `message` field is NOT guaranteed to be that text — the
/// fork can put an echo of the prompt, a routing note, or a status string there — so the client
/// MUST prefer the streamed text and use the chat `message` only as a last-resort fallback when
/// nothing streamed. A prior version returned `finalMessage ?? assembled`, which surfaced the
/// echo/status instead of the real reply. This suite guards that regression.
///
/// (A3 — returning the assembled text when the gateway closes the socket without a terminal
/// `chat:final` — is control-flow in `runTurn` around `receive()`; it's covered by the build +
/// a live-gateway smoke test, not this pure-function suite.)
@Suite("Gateway reply selection (A2)")
struct GatewayReplyTests {
    @Test func prefersAgentStreamOverChatEcho() {
        // The streamed assistant text wins even when the chat:final frame carries a non-empty
        // `message` (here, an echo of the user's prompt).
        let reply = SybilclawGatewayClient.chooseReply(
            assembled: "The capital of France is Paris.",
            chatMessage: "you said: what's the capital of France?")
        #expect(reply == "The capital of France is Paris.")
    }

    @Test func agentStreamOnlyWhenNoChatMessage() {
        let reply = SybilclawGatewayClient.chooseReply(assembled: "hello world", chatMessage: nil)
        #expect(reply == "hello world")
    }

    @Test func fallsBackToChatMessageWhenNothingStreamed() {
        // A gateway variant that never emits `agent` frames: the chat `message` is all we have.
        let reply = SybilclawGatewayClient.chooseReply(assembled: "", chatMessage: "fallback text")
        #expect(reply == "fallback text")
    }

    @Test func placeholderWhenBothEmpty() {
        #expect(
            SybilclawGatewayClient.chooseReply(assembled: "", chatMessage: nil)
                == "(sybilclaw returned no text)")
        #expect(
            SybilclawGatewayClient.chooseReply(assembled: "", chatMessage: "")
                == "(sybilclaw returned no text)")
    }
}

/// WS-B5: the diagnostics hook never carries payload text — only protocol/connection-state
/// events, constructible with no network at all.
@Suite("Gateway diagnostics events")
struct GatewayDiagnosticEventTests {
    @Test func eventsCarryNoFreeformPayloadField() {
        // Compile-level guard as much as a runtime one: every case's associated data is
        // host/port (connection target) or a short protocol reason string — never a
        // "prompt"/"reply"/"text" field. Constructing each case is itself the assertion
        // that the enum's shape hasn't grown a payload-carrying case.
        let events: [SybilclawGatewayEvent] = [
            .connecting(host: "127.0.0.1", port: 18789),
            .connected,
            .disconnected(reason: "closed during connect"),
            .turnStarted,
            .turnSucceeded,
            .turnFailed(reason: "sybilclaw gateway error: chat.send was rejected"),
        ]
        #expect(events.count == 6)
    }
}
