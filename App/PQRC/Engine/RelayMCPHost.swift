// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import PQRCMCP
import PQRCNostr

/// Phase D3 — the PHONE end of MCP passthrough over the relay. When a CONSENTED
/// `coding_agent` node's coding agent calls one of the phone's MCP chat tools, the
/// request arrives as an `MCP1|` frame on the message mesh; this host feeds it to an
/// `MCPServer` and frames the response back. One host per node, owned by
/// `PersonaRuntime` and created ONLY for a node that is (a) the owner's paired coding
/// agent and (b) has the "share chat context" consent on.
///
/// ## Where redaction + the ai_window gate are enforced (the security claim)
///
/// This host runs the SAME `MCPServer(bridge: RuntimeSecureChatBridge)` the local
/// loopback path uses (`LocalMCPServer`). `RuntimeSecureChatBridge`'s read methods
/// return ONLY firewall-redacted, byte-bounded data (codenames, ≤64 KB — never raw
/// names or identity hex), and its `sendAsMyAI` is ai_window-gated and fails closed.
/// So the node — which never holds the bridge or the chat store — receives ONLY what
/// the bridge returns. A `send_as_my_ai` the node attempts with no active window is
/// indistinguishable from a local MCP client's: the same window gate fires, the same
/// `isError` comes back, and the phone stays silent on the wire (invariant 9 / SPEC
/// §13). Redaction happens HERE, phone-side, BEFORE anything is framed onto the relay
/// (`serve` → `server.handle` → the bridge), so an unredacted byte never leaves.
///
/// ## Frame discrimination + the C-3 owner pin
///
/// The transport's magic is `MCP1|`, un-confusable with `ACP1|` (the agent-control
/// channel) and a JSON-RPC `{`. The C-3 owner pin (only the consented owner-node's
/// frames are serviced) is enforced by `PersonaRuntime.handleReceived` BEFORE a frame
/// reaches `deliverInbound` here — the host is only ever created for, and only ever
/// fed by, the consented node. No new crypto: every framed chunk rides the existing
/// gift-wrapped + ratcheted mesh as an ordinary message (SPEC §2).
actor RelayMCPHost {
    /// The phone's end of the relay MCP transport. Its `send` publishes framed
    /// `MCP1|` chunks to the node; `deliverInbound` feeds it the node's request frames.
    let transport: RelayMCPTransport
    /// The redacting + window-gating MCP server (the SAME one the loopback path hosts).
    private let server: MCPServer
    private var pumpTask: Task<Void, Never>?
    private var started = false

    /// - Parameters:
    ///   - bridge: the firewall-redacted data source (`RuntimeSecureChatBridge`). The
    ///     ONLY thing that touches raw chat; everything it returns is egress-safe.
    ///   - maxFrameBytes: the relay's per-message byte budget for framing/chunking MCP
    ///     lines (matches the ACP transport's).
    ///   - publish: publishes ONE framed `MCP1|` chunk to the node over the relay.
    ///     Wired by `PersonaRuntime` to `messenger.send(_, to: nodeHex)` (agent-typed).
    init(
        bridge: any SecureChatBridge,
        maxFrameBytes: Int,
        publish: @escaping @Sendable (String) async -> Void
    ) {
        self.server = MCPServer(bridge: bridge)
        self.transport = RelayMCPTransport(maxFrameBytes: maxFrameBytes, send: publish)
    }

    /// Begin pumping inbound MCP request lines through the server, framing each
    /// response back over the transport. Idempotent. A request that produces no
    /// response (an MCP notification) is silently dropped, like the loopback path.
    func start() {
        guard !started else { return }
        started = true
        let transport = self.transport
        let server = self.server
        pumpTask = Task {
            for await line in transport.inboundLines() {
                // `server.handle` runs the request against the REDACTING bridge and
                // returns the response line (or nil for a notification). Framing the
                // result back is the ONLY thing that touches the relay — and it only
                // ever carries what the bridge already redacted.
                guard let response = await server.handle(line: line) else { continue }
                transport.send(response)
            }
        }
    }

    /// Deliver one inbound `MCP1|` frame (a node request chunk) for reassembly. The
    /// caller (`PersonaRuntime`) has ALREADY verified `isMCPFrame` + the C-3 owner pin.
    func deliverInbound(_ framedBody: String) async {
        await transport.deliverInbound(framedBody)
    }

    /// Tear down: close the transport (finishes the pump) and cancel it. Called when
    /// the node's consent is revoked / unpaired, or the silo shuts down.
    func stop() {
        transport.close()
        pumpTask?.cancel()
        pumpTask = nil
        started = false
    }
}
