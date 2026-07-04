import Foundation
import Testing

@testable import eldr_node

/// Parity lock for the headless node's OpenClaw/sybilclaw **connect handshake**.
///
/// The node's `SybilclawGatewayClient` is a deliberately trimmed COPY of Apps/Huginn's — the
/// two share the wire framing but diverge on session-key strategy, diagnostics, and the runner
/// half (see the file banners). The copies "drifted once and that broke this path" (an off-
/// allowlist handshake lingered in the node copy after the app's was fixed). Apps/Huginn pins
/// its copy with `GatewayHandshakeTests`; this pins the node copy to the SAME protocol-critical
/// literals, so a drift in EITHER copy now fails a test instead of only surfacing against a live
/// gateway. If the gateway spec genuinely changes, update BOTH suites together — that coupling
/// is the point.
@Suite("eldr-node sybilclaw gateway framing parity")
struct SybilclawGatewayFramingTests {
    private func connectParams(token: String? = nil) -> [String: Any] {
        SybilclawGatewayClient(port: 18789, token: token).connectParams()
    }

    @Test func connectDeclaresBackendClientIdentityAndProtocolRange() {
        let p = connectParams()
        // Protocol range [3,4] — brackets the fork's v3 and upstream v4.
        #expect(p["minProtocol"] as? Int == 3)
        #expect(p["maxProtocol"] as? Int == 4)
        #expect(p["role"] as? String == "operator")
        // id/mode are gateway-allowlist-checked; "backend" (not "ui") avoids the browser-origin
        // check this native socket would fail. These are the fields whose earlier drift schema-
        // rejected every connect on the node path.
        let client = p["client"] as? [String: Any]
        #expect(client?["id"] as? String == "openclaw-macos")
        #expect(client?["mode"] as? String == "backend")
        #expect(client?["platform"] as? String == "macos")
    }

    @Test func connectRequestsOperatorScopes() {
        let scopes = connectParams()["scopes"] as? [String]
        #expect(scopes == ["operator.read", "operator.write", "operator.talk.secrets"])
    }

    @Test func authIsOmittedWithoutATokenAndCarriedWithOne() {
        #expect(connectParams(token: nil)["auth"] == nil)
        let auth = connectParams(token: "s3cr3t")["auth"] as? [String: Any]
        #expect(auth?["token"] as? String == "s3cr3t")
    }
}
