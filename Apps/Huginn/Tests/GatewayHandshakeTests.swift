import Foundation
import Testing

@testable import Huginn

// Locks the SybilClaw/OpenClaw gateway `connect` handshake identity against a future blind
// edit. The id/mode MUST come from the gateway's compiled allowlists (13 client ids / 7 modes,
// packages/gateway-protocol/src/client-info.ts) or the handshake is rejected with
// "must be equal to constant; must match a schema in anyOf". The cofounder's fork
// (rdevaul/sybilclaw v2026.5.12) speaks protocol v3, so the range must be [3, 3]. These regressed
// once already (we shipped "huginn"/"operator"/maxProtocol 4) — that bug is what this suite guards.

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

    private func params() -> [String: Any] {
        SybilclawGatewayClient(port: 18789).connectParams()
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

    @Test func protocolRangeIsV3() {
        let p = params()
        #expect(p["minProtocol"] as? Int == 3)
        #expect(p["maxProtocol"] as? Int == 3)
    }

    @Test func operatorRoleAndScopesPreserved() {
        // The valid authz layer (separate from client.id/mode) that our June-25 rewrite got right.
        let p = params()
        #expect(p["role"] as? String == "operator")
        let scopes = p["scopes"] as? [String] ?? []
        #expect(scopes.contains("operator.read"))
        #expect(scopes.contains("operator.write"))
    }

    @Test func handshakeCarriesNoPromptOrToken() {
        // Defense-in-depth for the diagnostics redaction: the handshake must never carry user
        // content, and with no token configured there is no `auth` block to leak.
        let p = params()
        #expect(p["message"] == nil)
        #expect(p["auth"] == nil)
    }

    @Test func authBlockAppearsOnlyWhenTokenConfigured() {
        let withToken = SybilclawGatewayClient(port: 18789, token: "secret").connectParams()
        let auth = withToken["auth"] as? [String: Any]
        #expect(auth?["token"] as? String == "secret")
    }
}
