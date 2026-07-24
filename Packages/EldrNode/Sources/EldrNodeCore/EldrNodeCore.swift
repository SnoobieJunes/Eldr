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

    // MARK: - WS-G1 A2A town-plane state (dormant unless a `TownA2AService` is injected)

    /// One `RelayA2ATransport` per authorized peer town, created lazily on that peer's
    /// FIRST admitted frame. Per-peer rather than one shared transport because an A2A
    /// reply must go back to the town that asked — unlike `ACP1|`/`MCP1|`, whose single
    /// counterparty is always the pinned owner, so their transports can hard-code the
    /// destination. A shared transport here would send every town's answers to whichever
    /// address it was built with, which is a cross-town data leak, not a routing bug.
    private var a2aTransports: [String: RelayA2ATransport] = [:]
    /// The drain task per peer transport: pumps reassembled lines into the injected
    /// `TownA2AService`. Held so `serve`'s shutdown can cancel them; without a drainer the
    /// transport's inbound `AsyncStream` would buffer without bound, which is why a
    /// transport is never created unless a service exists to consume it.
    private var a2aDrains: [Task<Void, Never>] = []

    /// How many peer towns currently hold an A2A transport. Exposed for tests and operator
    /// status: it is 0 on every node that has not enabled the plane, and it never counts a
    /// peer the authorizer refused (nothing is allocated for a denied sender).
    public var townPeerCount: Int { a2aTransports.count }

    /// Ceiling on simultaneous peer towns, so an over-broad authorizer (or a future
    /// grant-backed one with a bug) cannot turn "admitted" into unbounded per-peer state.
    /// Eight matches GOOSEWORLD §6 WS-G5's honest scaling note — pairwise fan-out is fine
    /// to about eight towns, past which MLS groups (SPEC §12) are the v2 answer. Reaching
    /// the cap denies further NEW peers; already-admitted ones are unaffected.
    static let maxTownPeers = 8

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
    /// 3b. WS-G1 — a THIRD frame class, `A2A1|`, the cross-town task plane. It is gated by
    ///    `townAuthorizer`, **not** by C-3, because the sender is a peer town rather than
    ///    the owner; it defaults to deny-all AND requires an injected `townService`, so
    ///    with no town configuration this branch is unreachable and `serve` behaves
    ///    exactly as it did before WS-G1. See `routeInboundA2A`.
    /// 4. On exit (the task is cancelled, or the stream finishes), `transport.close()` so
    ///    the agent's `inboundLines()` finishes and `runACPAgent` unwinds; every per-town
    ///    A2A transport is closed and its drain task cancelled the same way.
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
    ///   - townAuthorizer: WS-G1 — who may reach the **A2A town plane** (`A2A1|`). This is
    ///     deliberately NOT the C-3 owner check: a cross-town delegation arrives from a
    ///     peer town, a non-owner by definition (see `TownAuthorizer.swift` for the full
    ///     argument, and for where WS-G4's `StandingGrant` plugs in). Defaults to
    ///     `DenyAllTownAuthorizer`, so a caller that passes nothing gets today's behavior
    ///     exactly: no A2A frame admitted, no transport allocated.
    ///   - townService: WS-G1 — what services an admitted A2A line. `nil` (the default)
    ///     means the plane does not exist on this node: `A2A1|` frames are dropped before
    ///     any transport is built, so an unconfigured node cannot buffer, answer, or leak.
    ///     BOTH this and a permissive `townAuthorizer` must be supplied for a single
    ///     cross-town frame to be acted on.
    public func serve(
        messenger: any NodeMessenger,
        ownerIdentityHex: String,
        maxFrameBytes: Int,
        llm: any LLMClient,
        toolEnvironment: ToolEnvironment,
        config: AgentConfig = .default,
        streamingEnabled: Bool = false,
        descriptor: HarnessDescriptor = .builtIn,
        townAuthorizer: any TownAuthorizer = DenyAllTownAuthorizer(),
        townService: (any TownA2AService)? = nil
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
        //
        // WS-L4: the agent host (`runHarness` → ACPAgent/ToolExecutor/PTYProcess) runs on
        // Linux too, so a Linux town serves the cross-town DELEGATE/coding plane, not just
        // the wall. The one platform split left is the delegation FACTORY: `.a2aRemote`
        // descriptors need `A2AHarnessFactory` (SwiftA2A's URLSession-HTTP A2AClient, kept
        // off the Linux compile path — AC139), so a Linux node keeps the default
        // `.stdioSpawn`-only factory and an `.a2aRemote` delegation there fails LOUDLY with
        // `HarnessTransportError.unsupportedKind` (fail-closed, never a hang). The town A2A
        // plane below is unaffected — it rides `RelayA2ATransport`, not A2AClient HTTP.
        #if os(macOS)
        let harnessFactory: any HarnessTransportFactory = A2AHarnessFactory()
        #else
        let harnessFactory: any HarnessTransportFactory = DefaultHarnessTransportFactory()
        #endif
        let agentTask = Task {
            await runHarness(
                descriptor: descriptor, client: transport, llm: llm,
                toolEnvironment: toolEnvironment, config: config, configDir: nil,
                streamingEnabled: streamingEnabled, extraTools: mcpClient,
                factory: harnessFactory)
        }

        // Begin the messenger's single event stream and consume it as the SOLE consumer.
        // A start() failure means there is nothing to serve — tear the agent down and
        // return (fail-closed, no silent half-up node).
        let events: AsyncStream<MessengerEvent>
        do {
            events = try await messenger.start()
        } catch {
            // Nothing has been routed yet, so the town plane is empty — but never leave an
            // exit path that skips its teardown. (This branch's pre-existing handling of
            // `mcpTransport`/`mcpClient` is left exactly as it was: WS-G1 changes no
            // existing behavior, and neither is observable here since no frame ever
            // reached them.)
            shutdownTownPlane()
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
                // Route ACP control frames and MCP chat-tool frames — both gated by the
                // SAME C-3 owner check — and A2A town frames, gated by `townAuthorizer`
                // instead. A body is at most ONE of the three (the magics `ACP1|`,
                // `MCP1|`, `A2A1|` differ in their first byte and none can begin a
                // JSON-RPC line), or none of them (ordinary chat the headless node
                // ignores). The cascade below relies on that mutual exclusivity only for
                // efficiency: each router re-tests its own magic, so a mis-ordering here
                // could never route a body to the wrong plane.
                let admittedACP = await Self.routeInbound(
                    senderIdentityHex: received.senderIdentityHex,
                    body: received.body.text,
                    ownerIdentityHex: ownerIdentityHex,
                    transport: transport)
                var admittedMCP = false
                if !admittedACP {
                    admittedMCP = await Self.routeInboundMCP(
                        senderIdentityHex: received.senderIdentityHex,
                        body: received.body.text,
                        ownerIdentityHex: ownerIdentityHex,
                        transport: mcpTransport)
                }
                if !admittedACP && !admittedMCP {
                    await routeInboundA2A(
                        senderIdentityHex: received.senderIdentityHex,
                        body: received.body.text,
                        authorizer: townAuthorizer,
                        service: townService,
                        messenger: messenger,
                        maxFrameBytes: maxFrameBytes)
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

        // The stream finished or we were cancelled: close every transport (the ACP one
        // finishes the agent's inbound stream → `runACPAgent` returns) + the MCP client,
        // and cancel the agent task. The A2A town transports go down the same way — their
        // drain tasks are cancelled first so a partially-serviced remote line cannot keep
        // running after the node has stopped serving.
        shutdownTownPlane()
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

    // MARK: - WS-G1: the A2A town gate (a SEPARATE authorizer; also fail-closed)

    /// Route one inbound **A2A town frame**. This is the third frame class on the shared
    /// inbound stream and the only one NOT governed by C-3 — see `TownAuthorizer.swift`
    /// for why, in short: a cross-town delegation comes from a peer town, so an owner
    /// check would either kill the plane or, if widened, hand strangers the ACP/MCP
    /// planes as well.
    ///
    /// The gate, in order, every one of which fails closed:
    /// 1. **Is it even A2A?** `RelayA2ATransport.isA2AFrame` — a prefix test on `A2A1|`,
    ///    which no JSON-RPC line and no `ACP1|`/`MCP1|` frame can satisfy. Ordinary chat
    ///    and the other two planes stop here.
    /// 2. **Does this node have an A2A plane at all?** No `service` ⇒ drop. Not "queue
    ///    it", not "allocate a transport and buffer": a node that was never given a town
    ///    service must not accumulate a single byte of remote state.
    /// 3. **Is the sender identified?** An empty identity hex is refused outright rather
    ///    than handed to an authorizer that might, in some future implementation, treat
    ///    "" as a wildcard.
    /// 4. **Is the sender authorized?** `authorizer.authorizes(peerIdentityHex:)`, asked
    ///    fresh for EVERY frame — never cached, never memoized per session. That is what
    ///    makes revocation actually work: a peer removed from the allowlist (or whose
    ///    WS-G4 grant expires) stops being admitted on its very next chunk, even mid-line.
    ///    A line already half-reassembled simply never completes, because completion
    ///    requires another chunk and that chunk will not get through.
    /// 5. **Is there room?** `maxTownPeers` bounds how many peers can hold per-peer state.
    ///
    /// Only after all five does a transport get resolved — creation happens strictly
    /// downstream of authorization, so an unauthorized peer never causes an allocation,
    /// let alone a delivery. `deliverInbound` is the FIRST thing that touches remote
    /// bytes, and it is reached only by an authorized peer's frame.
    ///
    /// Note what this does NOT do: it grants no tool scope. An admitted line is still
    /// untrusted remote input (GOOSEWORLD §4 class 1); whatever the service does with it
    /// remains behind the unchanged C-1 permission gate and C-2 path jail, exactly as an
    /// owner-driven turn is.
    ///
    /// - Returns: `true` iff the frame was admitted and handed to that peer's transport;
    ///   `false` for a non-A2A body, an unconfigured plane, an unauthorized/unidentified
    ///   sender, or a full peer table. A `true` return means *admitted*, not *understood*
    ///   — a malformed or absurdly-chunked frame from an authorized peer is admitted here
    ///   and then dropped by the transport's own parser, which is the correct division of
    ///   labour (this gate answers "who", the transport answers "well-formed").
    @discardableResult
    func routeInboundA2A(
        senderIdentityHex: String,
        body: String,
        authorizer: any TownAuthorizer,
        service: (any TownA2AService)?,
        messenger: any NodeMessenger,
        maxFrameBytes: Int
    ) async -> Bool {
        guard RelayA2ATransport.isA2AFrame(body) else { return false }  // not A2A → ignore
        guard let service else { return false }  // no town plane on this node → inert
        guard !senderIdentityHex.isEmpty else { return false }  // unidentified → refuse
        guard await authorizer.authorizes(peerIdentityHex: senderIdentityHex) else { return false }
        guard
            let transport = townTransport(
                for: senderIdentityHex, service: service, messenger: messenger,
                maxFrameBytes: maxFrameBytes)
        else { return false }  // peer table full → refuse rather than grow
        await transport.deliverInbound(body)
        return true
    }

    /// The per-peer A2A transport for `peerIdentityHex`, creating it (and its drain task)
    /// on first use. Returns nil once `maxTownPeers` distinct peers already hold one.
    ///
    /// **Only ever called after the authorization gate above has passed.** Keeping the
    /// allocation here rather than inline in `routeInboundA2A` is what lets that gate read
    /// as five sequential refusals with the allocation strictly last.
    ///
    /// The transport's `send` seam is bound to THIS peer, so a reply can only ever travel
    /// back to the town that asked; there is no code path by which town A's answer can be
    /// addressed to town B or to the owner.
    private func townTransport(
        for peerIdentityHex: String,
        service: any TownA2AService,
        messenger: any NodeMessenger,
        maxFrameBytes: Int
    ) -> RelayA2ATransport? {
        if let existing = a2aTransports[peerIdentityHex] { return existing }
        guard a2aTransports.count < Self.maxTownPeers else { return nil }

        let transport = RelayA2ATransport(maxFrameBytes: maxFrameBytes) { [messenger] framed in
            // Same failure policy as the ACP/MCP seams: a relay hiccup must not wedge the
            // loop. The peer's A2A client surfaces it as an unanswered request.
            try? await messenger.sendFramed(framed, to: peerIdentityHex)
        }
        a2aTransports[peerIdentityHex] = transport

        // Drain reassembled lines into the service. A transport is NEVER created without
        // this drainer — an unread `AsyncStream` buffers without bound, which would turn
        // an authorized peer into a memory-exhaustion vector.
        a2aDrains.append(
            Task { [service, transport, peerIdentityHex] in
                for await line in transport.inboundLines() {
                    if Task.isCancelled { break }
                    await service.handle(
                        line: line, from: peerIdentityHex,
                        reply: { [transport] out in transport.send(out) })
                }
            })
        return transport
    }

    /// Tear the town plane down: cancel every drain task, then close every per-peer
    /// transport (which finishes its inbound stream and clears its reassembly buffers).
    /// Idempotent — a second call has nothing left to do.
    private func shutdownTownPlane() {
        for drain in a2aDrains { drain.cancel() }
        a2aDrains.removeAll()
        for transport in a2aTransports.values { transport.close() }
        a2aTransports.removeAll()
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
