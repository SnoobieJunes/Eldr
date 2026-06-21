import Foundation
import PQRCACP
import PQRCCore
import PQRCNostr

/// The NODE end of the sealed ACP router — the other side of the channel the phone's
/// `ACPAgentProvider` drives.
///
/// Full path (ACPRouterplan P-4/P-8):
/// ```
/// phone ACPAgentProvider → ACPClient → sealed NearbyACPTransport → (radio)
///       → node NearbyACPTransport → runACPAgent → ACPAgent (tool loop, on THIS Mac)
/// ```
/// The phone is the ACP *client* and never hosts the agent; the Mac is the ACP *agent
/// host* and never the client. This actor owns the node's end of a sealed
/// `NearbyACPTransport` (one `NearbyLink` connection to the paired phone) and serves an
/// `ACPAgent` over it via `runACPAgent`. The transport gives every ACP line
/// confidentiality + authenticity (the `pqrc-seal-v1` AEAD + the identity-signed hello);
/// `runACPAgent` runs the tool-calling loop, doing all file/shell I/O on this machine.
///
/// **Permission model stays fail-closed.** The host passes the caller's `AgentConfig`
/// straight through to `runACPAgent` and NEVER sets `allowUngatedTools`: the agent's C-1
/// gate (deny-by-default; a missing/late `session/request_permission` answer is a denial)
/// is the only thing that authorizes a mutating tool, and this host does not weaken it.
/// File writes additionally stay inside the C-2 jail (`ToolEnvironment.workdir`). A node
/// operator who explicitly wants ungated tools sets that on the `AgentConfig` they pass —
/// it is never the host's default.
///
/// `runACPAgent` (and `ACPAgent`) are macOS-only — the phone never compiles this path —
/// but the Configurator is a macOS app, so this whole file builds for the node.
///
/// **What is device-dependent (NOT exercised here):** standing up the *live* Multipeer
/// radio handshake between two physical devices — discovery, the MC session, and the
/// real `.connected` event that kicks off the sealed hello. That needs a second device.
/// `ACPNodeHost` is transport-injectable precisely so the host LOGIC + the full sealed
/// composition are proven headlessly over a `LocalLinkSimulator` loopback
/// `NearbyACPTransport` (see `ACPNodeHostTests`), while the real-radio layer is the
/// remaining device-dependent piece. The `makeProductionTransport` helper builds the
/// production transport over `MultipeerNearbyLink`, but it is the radio underneath that
/// is unproven here, not the host.
public actor ACPNodeHost {

    /// Observable host state. Mirrors the start/stop/status shape `ACPBridgeService`
    /// surfaces so `BridgeView` can drive a simple toggle.
    public enum Status: Equatable, Sendable {
        /// Built but not started — no link, no agent loop.
        case idle
        /// Link + pump started and the agent loop is running; awaiting / serving the
        /// paired phone. (The sealed hello completes asynchronously once the peer
        /// connects; `isPeerProven()` on the transport reflects that.)
        case serving
        /// `runACPAgent` returned because the transport closed (peer gone / stop()).
        case stopped
    }

    /// The node's end of the sealed ACP transport (its `NearbyLink` to the phone).
    private let transport: any ACPTransport
    private let llm: any LLMClient
    private let toolEnvironment: ToolEnvironment
    private let config: AgentConfig
    private let configDir: String?
    private let streamingEnabled: Bool

    /// The `runACPAgent` driver task. nil until `start()`, cancelled by `stop()`.
    private var serveTask: Task<Void, Never>?
    private var status: Status = .idle

    /// - Parameters:
    ///   - transport: the node's end of the sealed channel. In production a
    ///     `NearbyACPTransport` over `MultipeerNearbyLink`; in tests the same
    ///     `NearbyACPTransport` over a `LocalLinkSimulator` loopback (both are
    ///     `NearbyLink`, so ONE host type covers both backends). The transport must be
    ///     `start()`-ed before ACP frames flow; `ACPNodeHost.start()` is what does that
    ///     when given a `NearbyACPTransport` (via `startNearby`), or the caller starts a
    ///     bare `ACPTransport` itself.
    ///   - llm: the model the agent calls. Production injects the Mac's local/cloud LLM;
    ///     tests inject a scripted one.
    ///   - toolEnvironment: the C-2 jail + advertised tool caps. Its `workdir` bounds
    ///     every file tool to the chosen project folder.
    ///   - config: agent tuning + the C-1 permission knobs. Passed THROUGH unchanged —
    ///     the host never flips `allowUngatedTools`, so the gate stays fail-closed.
    ///   - streamingEnabled: stream the final answer token-by-token. The node may stream
    ///     to the ACP client freely; the watch-along redaction (which needs whole
    ///     messages) lives in `ACPBridgeService`, a separate path.
    public init(
        transport: any ACPTransport,
        llm: any LLMClient,
        toolEnvironment: ToolEnvironment = .fromEnvironment(),
        config: AgentConfig = .fromEnvironment(),
        configDir: String? = nil,
        streamingEnabled: Bool = true
    ) {
        self.transport = transport
        self.llm = llm
        self.toolEnvironment = toolEnvironment
        self.config = config
        self.configDir = configDir
        self.streamingEnabled = streamingEnabled
    }

    public func currentStatus() -> Status { status }

    // MARK: Lifecycle

    /// Start serving ACP over the (already-startable) transport. Idempotent: a second
    /// call while serving is a no-op. Returns immediately; the agent loop runs until the
    /// transport closes (peer gone) or `stop()` is called.
    ///
    /// The agent's permission gate is fail-closed by construction (the `config` passed at
    /// init governs it and is never weakened here), so an unattended start cannot
    /// auto-authorize a mutating tool.
    public func start() {
        guard serveTask == nil else { return }
        status = .serving
        let transport = self.transport
        let llm = self.llm
        let toolEnvironment = self.toolEnvironment
        let config = self.config
        let configDir = self.configDir
        let streamingEnabled = self.streamingEnabled
        serveTask = Task {
            // Serve the AGENT half over the node's transport — the exact mirror of the
            // phone's CLIENT half. Returns when `transport.inboundLines()` finishes.
            await runACPAgent(
                transport: transport, llm: llm, toolEnvironment: toolEnvironment,
                config: config, configDir: configDir, streamingEnabled: streamingEnabled)
            await self.markStopped()
        }
    }

    /// Start the node's `NearbyACPTransport` link + pump, THEN serve ACP over it. Use
    /// this when the transport is a `NearbyACPTransport` (it needs its link started
    /// before any frame flows); for a pre-started/bare transport use `start()`.
    public func startNearby(_ nearby: NearbyACPTransport) async throws {
        guard serveTask == nil else { return }
        try await nearby.start()  // bring up the link + the sealed-frame pump
        start()
    }

    private func markStopped() {
        // Only fall to .stopped from .serving; a concurrent stop() may have already run.
        if status == .serving { status = .stopped }
        serveTask = nil
    }

    /// Stop serving: close the transport (which finishes `inboundLines()` → `runACPAgent`
    /// returns) and cancel the driver task. Idempotent.
    public func stop() {
        status = .stopped
        transport.close()
        serveTask?.cancel()
        serveTask = nil
    }

    // MARK: Production transport construction (the radio layer is device-dependent)

    /// Build the node's PRODUCTION sealed transport over `MultipeerNearbyLink`.
    ///
    /// This wires the SAME `NearbyACPTransport` the loopback test uses, only over the
    /// real radio instead of `LocalLinkSimulator`. The transport + host LOGIC are proven
    /// headlessly; what this helper adds — the live MC discovery/session and the real
    /// `.connected` event — is the remaining DEVICE-DEPENDENT layer (two physical
    /// devices), deliberately NOT faked under test.
    ///
    /// - Parameters:
    ///   - identity: the node's Ed25519 PQRC identity (proves who the node is in the
    ///     sealed hello).
    ///   - nostrKeypair: the node's secp256k1 Nostr keypair (the seal's ECDH private
    ///     half) — the SAME key the bridge's QR advertises, so the phone seals to it.
    ///   - peerIdentityKey: the paired phone's Ed25519 identity pubkey (raw 32 bytes).
    ///     ACP is point-to-point: frames are only ever sealed to / accepted from this
    ///     peer.
    ///   - serviceType: the Multipeer service type (defaults to the bridge's).
    public nonisolated static func makeProductionTransport(
        identity: PQRCIdentity,
        nostrKeypair: NostrKeypair,
        peerIdentityKey: Data,
        serviceType: String = MultipeerNearbyLink.bridgeServiceType,
        randomSource: any RandomSource = SystemRandomSource(),
        nonceSource: any NonceSource = SystemNonceSource()
    ) -> NearbyACPTransport {
        let link = MultipeerNearbyLink(serviceType: serviceType, randomSource: randomSource)
        return NearbyACPTransport(
            identity: identity, nostrKeypair: nostrKeypair, link: link,
            peerIdentityKey: peerIdentityKey, randomSource: randomSource,
            nonceSource: nonceSource)
    }
}
