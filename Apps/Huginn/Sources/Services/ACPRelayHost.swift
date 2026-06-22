import Foundation
import PQRCACP
import PQRCCore
import PQRCNostr

/// The NODE end of the **relay-carried** ACP router — the Mac serves the FULL ACP
/// protocol to the owner's phone over the Nostr relay, so the phone can drive the
/// agent REMOTELY (from anywhere with relay reach), not just over local Multipeer
/// (`ACPNodeHost`) and not just via watch-along drafts (`ACPBridgeService`).
///
/// Full path (ACPRouterplan Phase 3 — the LIVE node side):
/// ```
/// phone ACPClient → RelayACPTransport → phone messenger.send ─┐
///                                                             │  (relay: ciphertext only)
///                                                             ▼
///   node messenger inbound .message ──(C-3 gate)──▶ routeInbound ──▶ RelayACPTransport.deliverInbound
///                                                             │
///                              runACPAgent (tool loop on THIS Mac) ◀──serve──┘
///                                          │
///   node messenger.send(framedBody, to: owner) ◀── RelayACPTransport.send
/// ```
/// Because every ACP line rides the existing gift-wrapped + Double-Ratcheted message
/// mesh (`PQRCMessenger`), the relay only ever sees the SAME E2EE ciphertext a normal
/// chat carries (SPEC §2 — no new crypto; this is the proven wiring from
/// `RelayCarriedACPE2ETests`).
///
/// ## The C-3 gate is the only intake authorizer (fail-closed)
///
/// `routeInbound` admits a frame to the agent ONLY when it is an ACP frame
/// (`RelayACPTransport.isACPFrame`) AND its sender is the pinned owner. Anything else —
/// a non-owner's frame, a non-owner's chat, or any frame before an owner is pinned — is
/// dropped silently and never reaches the transport. A non-owner sender could otherwise
/// drive `run_shell`/`xcodebuild` on the host (confused-deputy → RCE), so this gate is
/// the relay-path equivalent of `ACPNodeHost`'s sealed point-to-point peer check.
///
/// ## The permission model stays fail-closed
///
/// The host passes the caller's `AgentConfig` straight through to `runACPAgent` and
/// NEVER sets `allowUngatedTools`: the agent's C-1 gate (deny-by-default; a missing/late
/// `session/request_permission` answer is a denial) is the only thing that authorizes a
/// mutating tool, and this host does not weaken it. File writes additionally stay inside
/// the C-2 jail (`ToolEnvironment.workdir`).
///
/// `runACPAgent` (and `ACPAgent`) are macOS-only — the phone never hosts the agent — but
/// the Configurator is a macOS app, so this whole file builds for the node.
///
/// **What is device-dependent (NOT exercised here):** standing up the live relay
/// (a real `NostrWebSocketTransport` to `relay.lerants.com`) and a second physical
/// device as the phone. `ACPRelayHost` takes its publish seam + inbound routing as
/// injectable closures precisely so the host LOGIC + the C-3 gate are proven headlessly
/// over a `LocalRelaySimulator` loopback between two real messengers (see
/// `ACPRelayHostTests`), while the real-relay layer is the remaining device-dependent
/// piece. `ACPBridgeService` wires the production seams to its live `PQRCMessenger`.
@MainActor
final class ACPRelayHost {

    /// Observable host state. Mirrors `ACPNodeHost.Status` so `BridgeView` can drive the
    /// same simple start/stop/status shape for the relay path.
    enum Status: Equatable, Sendable {
        /// Built but not started — no transport pump, no agent loop.
        case idle
        /// The agent loop is running, serving the owner over the relay. Inbound ACP
        /// frames from the owner now drive turns.
        case serving
        /// `runACPAgent` returned because the transport closed (`stop()`), or the host
        /// was never started.
        case stopped
    }

    /// The node's end of the relay ACP transport. Its `send` publishes framed chunks to
    /// the owner via the injected publish closure; `deliverInbound` feeds it owner frames.
    private let transport: RelayACPTransport
    private let llm: any LLMClient
    private let toolEnvironment: ToolEnvironment
    private let config: AgentConfig
    private let configDir: String?
    private let streamingEnabled: Bool

    /// The pinned owner's identity hex (the C-3 gate target). Only ACP frames whose
    /// `senderIdentityHex` equals this drive the agent. Captured at construction.
    private let ownerIdentityHex: String

    /// The `runACPAgent` driver task. nil until `start()`, cancelled by `stop()`.
    private var serveTask: Task<Void, Never>?
    private(set) var status: Status = .idle

    /// - Parameters:
    ///   - ownerIdentityHex: the pinned owner. The C-3 gate admits ONLY this sender's ACP
    ///     frames; everything else is dropped (fail-closed — no "first peer wins").
    ///   - maxFrameBytes: the relay's per-message byte budget for framing/chunking ACP
    ///     lines (the relay event-size limit minus gift-wrap overhead). The same value
    ///     the phone's transport uses.
    ///   - llm: the model the agent calls. Production injects the Mac's local/cloud LLM;
    ///     tests inject a scripted one.
    ///   - toolEnvironment: the C-2 jail + advertised tool caps. Its `workdir` bounds
    ///     every file tool to the chosen project folder.
    ///   - config: agent tuning + the C-1 permission knobs. Passed THROUGH unchanged — the
    ///     host never flips `allowUngatedTools`, so the gate stays fail-closed.
    ///   - streamingEnabled: stream the final answer token-by-token to the ACP client. The
    ///     node may stream freely over the relay; the watch-along redaction (which needs
    ///     whole messages) lives in `ACPBridgeService`, a separate path.
    ///   - publish: publishes ONE framed chunk to the owner over the relay. Production
    ///     wires this to `messenger.send(MessageBody(text: framed, …), to: ownerIdentityHex)`;
    ///     tests wire it to a `LocalRelaySimulator`-backed messenger.
    init(
        ownerIdentityHex: String,
        maxFrameBytes: Int,
        llm: any LLMClient,
        toolEnvironment: ToolEnvironment,
        config: AgentConfig = .default,
        configDir: String? = nil,
        streamingEnabled: Bool = false,
        publish: @escaping @Sendable (String) async -> Void
    ) {
        self.ownerIdentityHex = ownerIdentityHex
        self.llm = llm
        self.toolEnvironment = toolEnvironment
        self.config = config
        self.configDir = configDir
        self.streamingEnabled = streamingEnabled
        self.transport = RelayACPTransport(maxFrameBytes: maxFrameBytes, send: publish)
    }

    func currentStatus() -> Status { status }

    // MARK: Lifecycle

    /// Start serving ACP over the relay transport. Idempotent: a second call while serving
    /// is a no-op. Returns immediately; the agent loop runs until the transport closes
    /// (`stop()`).
    ///
    /// The agent's permission gate is fail-closed by construction (the `config` passed at
    /// init governs it and is never weakened here), so an unattended start cannot
    /// auto-authorize a mutating tool, and the C-3 gate (`routeInbound`) means only the
    /// owner can task the agent at all.
    func start() {
        guard serveTask == nil else { return }
        status = .serving
        let transport = self.transport
        let llm = self.llm
        let toolEnvironment = self.toolEnvironment
        let config = self.config
        let configDir = self.configDir
        let streamingEnabled = self.streamingEnabled
        serveTask = Task {
            // Serve the AGENT half over the relay transport — the exact mirror of the
            // phone's CLIENT half. Returns when `transport.inboundLines()` finishes.
            await runACPAgent(
                transport: transport, llm: llm, toolEnvironment: toolEnvironment,
                config: config, configDir: configDir, streamingEnabled: streamingEnabled)
            self.markStopped()
        }
    }

    private func markStopped() {
        // Only fall to .stopped from .serving; a concurrent stop() may have already run.
        if status == .serving { status = .stopped }
        serveTask = nil
    }

    /// Stop serving: close the transport (which finishes `inboundLines()` → `runACPAgent`
    /// returns) and cancel the driver task. Idempotent. Keeps no persisted state — the
    /// messenger/keys live in `ACPBridgeService`.
    func stop() {
        status = .stopped
        transport.close()
        serveTask?.cancel()
        serveTask = nil
    }

    // MARK: Inbound routing (the C-3 gate)

    /// True iff this body is a relay ACP frame addressed at the agent — i.e. it carries
    /// the `RelayACPTransport` magic. The integration uses this to split ACP frames
    /// (→ `routeInbound`) from ordinary chat (→ the watch-along path) on the SAME message
    /// stream. Pure prefix test (a JSON-RPC chat line never begins with the magic), so
    /// `nonisolated` — callable off the main actor from the messenger pump.
    nonisolated static func isACPFrame(_ body: String) -> Bool {
        RelayACPTransport.isACPFrame(body)
    }

    /// Route one inbound message body the node's messenger received. **C-3 gate:** the
    /// frame drives the agent ONLY when it is an ACP frame AND `senderIdentityHex` is the
    /// pinned owner; every other case is dropped (returns `false`) and never reaches the
    /// agent. A dropped frame is a no-op — the caller continues with the normal chat path.
    ///
    /// - Returns: `true` if the frame was admitted (owner-signed ACP) and forwarded to the
    ///   transport; `false` if it was NOT an ACP frame, or was an ACP frame from a
    ///   non-owner (dropped). A `false` ACP-frame-from-non-owner result still means "this
    ///   was an ACP frame, do not also feed it to the chat path" is the caller's concern —
    ///   `wasACPFrame` reports that separately.
    @discardableResult
    func routeInbound(senderIdentityHex: String, body: String) async -> Bool {
        guard Self.isACPFrame(body) else { return false }  // not ACP → caller's chat path
        // C-3: only the pinned owner may drive the agent over the relay. A non-owner ACP
        // frame is dropped silently (do not even surface that an agent is attached).
        guard senderIdentityHex == ownerIdentityHex else { return false }
        await transport.deliverInbound(body)
        return true
    }

    /// Whether `body` is an ACP frame at all (owner or not) — so the caller can SWALLOW
    /// any ACP frame (never route it to the watch-along prompt path), while only
    /// owner-signed ones reach the agent via `routeInbound`. Keeps a non-owner's crafted
    /// `ACP1|…` frame from ever being mistaken for a chat prompt.
    nonisolated static func wasACPFrame(_ body: String) -> Bool { isACPFrame(body) }
}
