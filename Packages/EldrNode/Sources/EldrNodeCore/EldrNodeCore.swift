// SPDX-License-Identifier: Apache-2.0
import A2AHarness
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

    /// Accept a pending message-request from `senderNostrPubkeyHex`: fetch + fully verify
    /// the sender's 10420/10421 binding (both directions — invariant 7), add them as a
    /// verified contact, replay any held envelopes, and return the **identity hex** the
    /// verified binding resolves to.
    ///
    /// `serve` calls this for the FIRST frame of a never-before-seen sender (the owner's
    /// opening handshake arrives this way, since the headless daemon starts with an empty
    /// contact table). The returned identity hex is what lets `serve` decide whether the
    /// sender that just paired is the pinned owner — without it, the owner's very first
    /// frame is a dropped `.messageRequest` and the node serves no one.
    ///
    /// A default implementation throws `NodeMessengerError.requestsUnsupported`: doubles
    /// that pre-pair the owner out-of-band (e.g. the test harness, which seeds the
    /// contact via `addContact` before `serve` runs) never surface a `.messageRequest`,
    /// so they need not implement it.
    func acceptRequest(senderNostrPubkeyHex: String) async throws -> String

    /// Decline a pending message-request: drop the sender's held envelopes WITHOUT
    /// establishing a session. `serve` calls this when an `acceptRequest` FAILS (the
    /// binding could not be verified / the relay was unreachable), so the sender's opening
    /// frames are discarded rather than left pending — no contact was added in that case.
    /// No-op by default.
    func declineRequest(senderNostrPubkeyHex: String) async
}

extension NodeMessenger {
    /// Default: a messenger that admits no message-requests (the contact is paired
    /// out-of-band). `serve`'s `.messageRequest` handling treats a throw here as "could
    /// not pair this sender" and drops the request — fail-closed, exactly as if the
    /// sender were a non-owner.
    public func acceptRequest(senderNostrPubkeyHex: String) async throws -> String {
        throw NodeMessengerError.requestsUnsupported
    }

    /// Default: nothing to decline (no request inbox in this double).
    public func declineRequest(senderNostrPubkeyHex: String) async {}
}

/// Errors the `NodeMessenger` seam can raise.
public enum NodeMessengerError: Error, Sendable {
    /// `acceptRequest` was called on a messenger that does not implement message-request
    /// acceptance (the default protocol implementation). The request is dropped.
    case requestsUnsupported
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
    ///   - descriptor: WS3c — which backend answers. `.builtIn` (default) is byte-for-byte
    ///     the prior direct `runACPAgent` call; a `.stdioSpawn` descriptor (already
    ///     carrying its vendor key via `HarnessDescriptor.withVendorKey`, resolved by the
    ///     caller from ITS OWN Keychain) spawns an external cloud CLI instead. Either way
    ///     the C-3 gate above is unchanged — it decides what reaches the transport, not
    ///     what runs behind it.
    public func serve(
        messenger: any NodeMessenger,
        ownerIdentityHex: String,
        maxFrameBytes: Int,
        llm: any LLMClient,
        toolEnvironment: ToolEnvironment,
        config: AgentConfig = .default,
        streamingEnabled: Bool = false,
        descriptor: HarnessDescriptor = .builtIn
    ) async {
        // The transport's send seam publishes one framed chunk to the owner over the
        // relay. Failures are swallowed so a relay hiccup doesn't wedge the agent's turn
        // loop (the ACP client surfaces it as a timed-out turn, like the proven e2e).
        let transport = RelayACPTransport(maxFrameBytes: maxFrameBytes) {
            [messenger] framed in
            try? await messenger.sendFramed(framed, to: ownerIdentityHex)
        }

        // Phase D3 — MCP passthrough over the relay. A SECOND relay line transport
        // (magic `MCP1|`, un-confusable with the ACP one) carries the node's MCP chat
        // requests to the OWNER's phone and the phone's REDACTED responses back. The
        // `MCPOverRelayClient` over it is injected as the agent's `extraTools`, so the
        // coding agent can read/draft/search the owner's chat — every call answered by
        // the phone's redacting + ai_window-gating MCP server (the node never sees raw
        // chat). It is only ACTIVE for a session where the phone advertised
        // `mcpServers` (its "share chat context" consent), so when the phone hasn't
        // opted in this whole channel is dormant: the agent advertises nothing extra
        // and the phone services no MCP frames.
        let mcpTransport = RelayMCPTransport(maxFrameBytes: maxFrameBytes) {
            [messenger] framed in
            try? await messenger.sendFramed(framed, to: ownerIdentityHex)
        }
        let mcpClient = MCPOverRelayClient(seam: mcpTransport)

        // Serve the AGENT half over the transport, in a child task — a long
        // `session/prompt` turn must not block the inbound read loop below (the owner's
        // permission answer arrives as a LATER inbound frame the in-flight turn awaits).
        let agentTask = Task {
            await runHarness(
                descriptor: descriptor, client: transport, llm: llm,
                toolEnvironment: toolEnvironment, config: config, configDir: nil,
                streamingEnabled: streamingEnabled, extraTools: mcpClient,
                factory: A2AHarnessFactory())
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
            switch event {
            case .message(let received):
                // Route ACP control frames AND MCP chat-tool frames, each gated by the
                // SAME C-3 owner check. A body is at most one of the two (distinct
                // magics) or neither (ordinary chat the headless node ignores).
                let admittedACP = await Self.routeInbound(
                    senderIdentityHex: received.senderIdentityHex,
                    body: received.body.text,
                    ownerIdentityHex: ownerIdentityHex,
                    transport: transport)
                if !admittedACP {
                    await Self.routeInboundMCP(
                        senderIdentityHex: received.senderIdentityHex,
                        body: received.body.text,
                        ownerIdentityHex: ownerIdentityHex,
                        transport: mcpTransport)
                }
            case .messageRequest(let senderNostrPubkeyHex, _):
                // The headless daemon starts with an EMPTY contact table (no app/Keychain
                // contact store to seed it), so the OWNER's opening handshake arrives as an
                // unknown-sender message-request — held, not decryptable, until the sender
                // becomes a verified contact. Bootstrap that contact here so the owner's
                // frames decrypt and attribute as `.message(sender: owner)`, which the C-3
                // gate (`routeInbound`, above) then admits. Owner-pinned: only the PINNED
                // owner is reported paired; any other sender stays undrivable behind C-3
                // (see `bootstrapOwnerFromRequest`). This is the relay-path equivalent of
                // the bootstrap the test harness performs out-of-band via `addContact`.
                await Self.bootstrapOwnerFromRequest(
                    senderNostrPubkeyHex: senderNostrPubkeyHex,
                    ownerIdentityHex: ownerIdentityHex,
                    messenger: messenger)
            default:
                continue  // protocolViolation / quarantined / nearbyContact — not served
            }
        }

        // The stream finished or we were cancelled: close both transports (the ACP one
        // finishes the agent's inbound stream → `runACPAgent` returns) + the MCP client,
        // and cancel the agent task.
        transport.close()
        mcpTransport.close()
        await mcpClient.shutdown()
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

    /// Phase D3 — route one inbound MCP chat-tool frame. **Same C-3 gate as ACP:**
    /// deliver to the node's MCP client transport ONLY when the body is an `MCP1|`
    /// frame AND `senderIdentityHex` is the pinned owner. These are the phone's
    /// REDACTED responses to the node's chat-tool requests (the phone is the MCP
    /// server here); a non-owner's MCP frame is dropped, so a stranger can neither
    /// answer the node's chat queries nor inject a forged transcript.
    ///
    /// - Returns: `true` iff the frame was admitted (owner-signed MCP) and forwarded;
    ///   `false` for a non-MCP line or a non-owner MCP frame (both dropped).
    @discardableResult
    static func routeInboundMCP(
        senderIdentityHex: String,
        body: String,
        ownerIdentityHex: String,
        transport: RelayMCPTransport
    ) async -> Bool {
        guard RelayMCPTransport.isMCPFrame(body) else { return false }  // not MCP → ignore
        guard senderIdentityHex == ownerIdentityHex else { return false }  // C-3
        await transport.deliverInbound(body)
        return true
    }

    // MARK: - Owner contact bootstrap (makes the daemon actually drivable)

    /// Bootstrap a verified, message-able contact for an unknown sender's first frame —
    /// but ONLY when that sender is the pinned owner.
    ///
    /// The headless daemon has no contact store to seed, so the owner's opening PQXDH
    /// handshake reaches the messenger as a `.messageRequest` (its sender's binding is not
    /// yet known), is held, and cannot decrypt — the owner's subsequent ACP frames would
    /// stay invisible and the C-3 gate would have nothing to admit. Accepting the request
    /// fetches + fully verifies the sender's binding (both directions — invariant 7), adds
    /// the contact, and replays the held handshake so the responder session is built; from
    /// then on the owner's frames arrive as `.message(sender: ownerIdentityHex)` and pass
    /// `routeInbound`'s C-3 check.
    ///
    /// **Owner-pinned, fail-closed (keeps C-3 intact):** the request carries only the
    /// sender's Nostr pubkey, and the sender's IDENTITY (what the owner is pinned by) is
    /// known only after verifying their binding — which `acceptRequest` does. So this
    /// accepts, then compares the *verified identity hex* to the pinned owner:
    /// - sender == owner → the owner is now a verified contact; return `true`. The owner
    ///   is drivable, and `routeInbound`'s C-3 check admits their frames.
    /// - sender ≠ owner → return `false`. C-3 in `routeInbound` already refuses every
    ///   non-owner ACP frame, so the stranger can NEVER drive the agent — accepting them
    ///   does not widen who is authorized. (There is no contact-removal seam, so the
    ///   stranger remains a dormant, undrivable contact — the SAME posture the shipped
    ///   Configurator relay host has, where all requests are accepted and C-3 is the sole
    ///   authorizer. This bootstrap is strictly tighter: it only reports the OWNER as
    ///   paired, and the daemon acts on nothing else.)
    /// - accept fails (unverifiable binding / relay unreachable) → drop the held frames
    ///   and return `false`; nothing is paired.
    ///
    /// `static` + a pure function of its inputs + the injected messenger, so the
    /// owner-pinning policy sits next to the C-3 gate and is auditable in one place.
    ///
    /// - Returns: `true` iff the accepted sender is the pinned owner (now a verified,
    ///   message-able contact); `false` for a non-owner or a failed accept.
    @discardableResult
    static func bootstrapOwnerFromRequest(
        senderNostrPubkeyHex: String,
        ownerIdentityHex: String,
        messenger: any NodeMessenger
    ) async -> Bool {
        // Accept to learn the sender's VERIFIED identity (the request only carries a Nostr
        // pubkey; the identity hex comes from the verified binding). A failure means the
        // sender could not be verified/reached — drop the held frames, pair nothing.
        guard
            let acceptedIdentityHex = try? await messenger.acceptRequest(
                senderNostrPubkeyHex: senderNostrPubkeyHex)
        else {
            await messenger.declineRequest(senderNostrPubkeyHex: senderNostrPubkeyHex)
            return false
        }
        // Owner-pinned: report ONLY the pinned owner as paired. A non-owner stays
        // undrivable behind the C-3 gate (see the doc above — no contact-removal seam).
        return acceptedIdentityHex == ownerIdentityHex
    }
}
