import Foundation
import PQRCACP
import PQRCCore
import PQRCNostr

// EldrNodeCore — the HEADLESS, reusable serve loop for the standalone `eldr-node`
// (ACPRouterplan Phase 4). It is the no-SwiftUI / no-@MainActor equivalent of the
// Configurator's `ACPRelayHost` (the node-side relay host) FUSED with the e2e tests'
// `MessengerTap` (the sole consumer of the messenger's single event stream):
//
//   phone ACPClient → RelayACPTransport → phone messenger.send ─┐
//                                                               │  (relay: ciphertext only)
//                                                               ▼
//     node messenger inbound .message ──(C-3 gate)──▶ deliverInbound ──▶ RelayACPTransport
//                                                               │
//                                runACPAgent (tool loop on THIS node) ◀──serve──┘
//                                            │
//     node messenger.send(framedBody, to: owner) ◀── RelayACPTransport.send
//
// Because every ACP line rides the existing gift-wrapped + Double-Ratcheted message
// mesh (`PQRCMessenger`), the relay only ever sees the SAME E2EE ciphertext a normal
// chat carries (SPEC §2 — no new crypto; this is the proven wiring from
// `RelayCarriedACPE2ETests`).
//
// `runACPAgent` (and `ACPAgent`/`ToolExecutor`) are macOS-only — the node hosts the
// agent only where `Foundation.Process` file/shell tools exist — and EldrNode targets
// macOS, so the whole loop builds for the node.

/// The minimal messenger surface `EldrNodeCore.serve` needs, so the loop is testable
/// over any messenger (a real `PQRCMessenger` in production, the same type wired to a
/// `LocalRelaySimulator` in tests) without dragging in a network or Keychain.
///
/// `PQRCMessenger` already satisfies this shape (see the `NodeMessenger` conformance in
/// `MessengerAdapter.swift`); the protocol exists only to keep `serve` injectable and
/// the C-3 gate provable in isolation.
public protocol NodeMessenger: Sendable {
    /// Begin the single event stream. Consumed ONCE by `serve` (a second `start()` on a
    /// `PQRCMessenger` would orphan the first continuation), so `serve` is the SOLE
    /// consumer — exactly the `MessengerTap` discipline the e2e proof relies on.
    func start() async throws -> AsyncStream<MessengerEvent>
    /// Publish one already-framed ACP body to `peerIdentityHex` as an ordinary ratcheted
    /// message. The frame is the node↔owner ACP control channel (transport), like the
    /// phone's outbound frames in the proven e2e — chat-authorship rules (invariant 8)
    /// govern CHAT, not this transport line.
    func sendFramed(_ framed: String, to peerIdentityHex: String) async throws
}

/// The headless serve loop. One instance serves one owner over one messenger; create a
/// fresh `EldrNodeCore` per `serve(...)` call (it owns the transport it builds).
public actor EldrNodeCore {

    public init() {}

    /// Serve the FULL ACP agent to `ownerIdentityHex` over `messenger`, until cancelled.
    ///
    /// Wiring (mirrors `ACPRelayHost.start` + the e2e `MessengerTap`):
    /// 1. Build a `RelayACPTransport(maxFrameBytes:)` whose `send` publishes ONE framed
    ///    chunk to the owner via `messenger.sendFramed(_, to: ownerIdentityHex)`.
    /// 2. Launch `runACPAgent(transport:llm:toolEnvironment:config:)` in a child task —
    ///    the AGENT half (the same one the phone drives as the CLIENT half).
    /// 3. Consume the messenger's single event stream as the SOLE consumer. For each
    ///    inbound `.message`, apply the **C-3 gate**: admit the body to the agent ONLY
    ///    when `RelayACPTransport.isACPFrame(body) && sender == ownerIdentityHex`. A
    ///    non-owner's (even byte-perfect, decrypting) ACP frame is DROPPED — the agent
    ///    never sees it. Non-ACP chat is ignored (the node is headless; there is no chat
    ///    UI here).
    /// 4. On exit (the task is cancelled, or the stream finishes), `transport.close()` so
    ///    the agent's `inboundLines()` finishes and `runACPAgent` unwinds.
    ///
    /// **Fail-closed by construction:** `config` is passed THROUGH to `runACPAgent`
    /// unchanged — this loop NEVER sets `allowUngatedTools`, so the agent's C-1 gate
    /// (deny-by-default) stays the only authorizer of a mutating tool, file writes stay
    /// inside the C-2 jail (`toolEnvironment.workdir`), and the C-3 gate here means only
    /// the owner can task the agent at all.
    ///
    /// - Parameters:
    ///   - messenger: the node's live PQRC messenger (or a test double over a simulator).
    ///   - ownerIdentityHex: the pinned owner — the C-3 gate target. Only this sender's
    ///     ACP frames drive the agent. No "first peer wins": there is exactly one owner.
    ///   - maxFrameBytes: the relay's per-message byte budget for framing/chunking ACP
    ///     lines (the relay event-size limit minus gift-wrap overhead). Same value the
    ///     phone's transport uses.
    ///   - llm: the model the agent calls. Production injects the node's local/cloud LLM;
    ///     tests inject a scripted one.
    ///   - toolEnvironment: the C-2 jail (`workdir`) + the spawned-shell environment.
    ///   - config: agent tuning + the C-1 permission knobs. Passed through unchanged.
    ///   - streamingEnabled: stream the final answer token-by-token to the owner's ACP
    ///     client. The node↔owner channel is the owner's own E2EE session, so streaming
    ///     is fine; off by default (no fan-out redaction is involved here).
    public func serve(
        messenger: any NodeMessenger,
        ownerIdentityHex: String,
        maxFrameBytes: Int,
        llm: any LLMClient,
        toolEnvironment: ToolEnvironment,
        config: AgentConfig = .default,
        streamingEnabled: Bool = false
    ) async {
        // The transport's send seam publishes one framed chunk to the owner over the
        // relay. Failures are swallowed so a relay hiccup doesn't wedge the agent's turn
        // loop (the ACP client surfaces it as a timed-out turn, like the proven e2e).
        let transport = RelayACPTransport(maxFrameBytes: maxFrameBytes) {
            [messenger] framed in
            try? await messenger.sendFramed(framed, to: ownerIdentityHex)
        }

        // Serve the AGENT half over the transport, in a child task — a long
        // `session/prompt` turn must not block the inbound read loop below (the owner's
        // permission answer arrives as a LATER inbound frame the in-flight turn awaits).
        let agentTask = Task {
            await runACPAgent(
                transport: transport, llm: llm, toolEnvironment: toolEnvironment,
                config: config, configDir: nil, streamingEnabled: streamingEnabled)
        }

        // Begin the messenger's single event stream and consume it as the SOLE consumer.
        // A start() failure means there is nothing to serve — tear the agent down and
        // return (fail-closed, no silent half-up node).
        let events: AsyncStream<MessengerEvent>
        do {
            events = try await messenger.start()
        } catch {
            transport.close()
            agentTask.cancel()
            return
        }

        // Drain inbound events until cancelled / the stream finishes. The C-3 gate is the
        // ONLY intake authorizer: a frame reaches the agent iff it is an ACP frame AND
        // its sender is the pinned owner.
        for await event in events {
            if Task.isCancelled { break }
            guard case .message(let received) = event else {
                continue  // protocolViolation / messageRequest / quarantined / nearby — not served
            }
            await Self.routeInbound(
                senderIdentityHex: received.senderIdentityHex,
                body: received.body.text,
                ownerIdentityHex: ownerIdentityHex,
                transport: transport)
        }

        // The stream finished or we were cancelled: close the transport (finishes the
        // agent's inbound stream → `runACPAgent` returns) and cancel the agent task.
        transport.close()
        agentTask.cancel()
    }

    // MARK: - The C-3 gate (the only intake authorizer; fail-closed)

    /// Route one inbound message body. **C-3 gate:** forward to the agent's transport
    /// ONLY when the body is an ACP frame AND `senderIdentityHex` exactly equals the
    /// pinned `ownerIdentityHex`.
    ///
    /// Every other case is dropped and never reaches the agent:
    /// - a non-ACP chat line (the node has no chat surface);
    /// - an ACP frame from a NON-owner (even one that is byte-perfect and decrypts) — a
    ///   non-owner could otherwise drive `run_shell`/`xcodebuild` on the host
    ///   (confused-deputy → RCE), so this is the relay-path equivalent of `ACPNodeHost`'s
    ///   sealed point-to-point peer check.
    ///
    /// `static` + `nonisolated` (a pure function of its inputs): the comparison is exact
    /// hex equality and nothing else, so the gate is trivially auditable and unit-testable
    /// without standing up an actor.
    ///
    /// - Returns: `true` iff the frame was admitted (owner-signed ACP) and forwarded;
    ///   `false` for a non-ACP line or a non-owner ACP frame (both dropped).
    @discardableResult
    static func routeInbound(
        senderIdentityHex: String,
        body: String,
        ownerIdentityHex: String,
        transport: RelayACPTransport
    ) async -> Bool {
        guard RelayACPTransport.isACPFrame(body) else { return false }  // not ACP → ignore
        // C-3: only the pinned owner may drive the agent. A non-owner ACP frame is
        // dropped silently — do not even surface that an agent is attached.
        guard senderIdentityHex == ownerIdentityHex else { return false }
        await transport.deliverInbound(body)
        return true
    }
}
