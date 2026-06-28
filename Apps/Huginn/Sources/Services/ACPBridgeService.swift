import Crypto
import Foundation
import PQRCACP
import PQRCAgent
import PQRCCore
import PQRCNostr

// MARK: - Pure, testable bridge pieces

/// The QR pairing payload EldrChat scans to add the coding agent as a contact:
/// the agent's Nostr pubkey (hex) and an optional preferred relay. JSON so it's
/// trivially scannable and forward-compatible.
struct PairingPayload: Codable, Equatable, Sendable {
    let pubkey: String
    let relay: String?

    func jsonString() -> String {
        guard let data = try? JSONEncoder().encode(self),
            let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    static func decode(_ string: String) -> PairingPayload? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PairingPayload.self, from: data)
    }
}

/// Formats an ACP activity into the human-readable text the agent sends as an
/// EldrChat message. Pure (no truncation — SPEC §7 chunking handles large payloads
/// inside the messenger), so it's unit-testable.
enum AgentActivity {
    static func toolCall(name: String, argsJSON: String, result: String, isError: Bool) -> String {
        let status = isError ? "⚠️ failed" : "ran"
        return "🔧 \(status): \(name)\n\(argsJSON)\n→ \(result)"
    }

    static func buildResult(command: String, exitCode: Int, output: String) -> String {
        let verdict = exitCode == 0 ? "✅ build succeeded" : "❌ build failed (exit \(exitCode))"
        return "\(verdict)\n$ \(command)\n\(output)"
    }

    static func sessionSummary(summary: String, filesChanged: Int) -> String {
        "📝 Session summary (\(filesChanged) file(s) changed):\n\(summary)"
    }
}

/// The seam to the PQRC ratchet session. The agent's reports are sent as ordinary
/// PQRC messages with `participant_type: .agent` (invariant 8) over the existing
/// PQXDH + Double Ratchet + gift-wrap stack.
///
/// Standing up a full PQRC node in the Configurator (identity + prekeys published to
/// a relay, then a live PQXDH pairing handshake with EldrChat over Multipeer) is the
/// runtime integration boundary — it needs a second peer and the app's identity
/// stack, so it can't be exercised headlessly (see docs/DEVIATIONS.md). Production
/// wires a `PQRCMessenger`-backed implementation here; until paired, sends throw.
protocol BridgeMessaging: Sendable {
    func send(_ body: MessageBody, to peerIdentityHex: String, participantType: ParticipantType)
        async throws
}

struct UnpairedMessaging: BridgeMessaging {
    struct NotPaired: Error {}
    func send(_ body: MessageBody, to peerIdentityHex: String, participantType: ParticipantType)
        async throws
    { throw NotPaired() }
}

/// Production `BridgeMessaging` backed by a live `PQRCMessenger` (the Mac's PQRC node).
/// Sends ride the same PQXDH + Double Ratchet + gift-wrap stack as EldrChat (so every
/// invariant — agent signature, padding, fuzzed timestamp — holds), addressed pairwise
/// by the recipient's identity hex.
struct PQRCMessengerMessaging: BridgeMessaging {
    let messenger: PQRCMessenger
    func send(_ body: MessageBody, to peerIdentityHex: String, participantType: ParticipantType)
        async throws
    {
        try await messenger.send(body, to: peerIdentityHex, participantType: participantType)
    }
}

/// Everything a runner needs to answer one turn with continuity.
struct ConversationContext: Sendable {
    /// Stable, opaque per-conversation id (see `ACPBridgeService.gatewaySessionKey(for:)`):
    /// the gateway session selector AND the encrypted-transcript key.
    let sessionKey: String
    /// The rendered, byte-capped prior transcript Huginn injects into backends that DON'T
    /// keep their own history (eldr-acp). nil for backends that self-persist (sybilclaw keeps
    /// it server-side) or when there's no prior context. Owner-side plaintext, handed to the
    /// owner's own model in memory only — never on the wire, never to disk in the clear.
    let priorContext: String?
}

/// Drives an AI backend for one prompt and returns its COMPLETE final answer.
/// Deliberately NON-streaming: per-recipient redaction (§10) must scrub a whole message —
/// a secret split across two streamed deltas could evade a naive scrubber.
protocol BridgeAgentRunner: Sendable {
    func run(prompt: String, workdir: String?, context: ConversationContext) async throws -> String
    /// True ⇒ the backend keeps its OWN conversation history (e.g. sybilclaw's gateway), so
    /// Huginn records its canonical encrypted copy but does NOT re-inject `priorContext`
    /// (the backend would otherwise see the history twice). Default false: Huginn owns memory.
    var selfPersistsHistory: Bool { get }
}

extension BridgeAgentRunner {
    var selfPersistsHistory: Bool { false }
}

/// Default until the agent binary is located/configured — driving fails closed.
struct UnavailableAgentRunner: BridgeAgentRunner {
    struct NotConfigured: Error {}
    func run(prompt: String, workdir: String?, context: ConversationContext) async throws -> String { throw NotConfigured() }
}

/// Thrown when a single agent run exceeds the watch-along wall-clock cap.
struct AgentRunTimeout: Error {}

/// Production runner: spawns `eldr-acp` through `ACPClientDriver`, with streaming OFF
/// (`ELDR_ACP_STREAM=0`) so the agent emits the whole answer in one piece, and collects
/// it. The agent's own permission-gated fs tools do any local file reads on the Mac;
/// the owner window governs *sending*, not local access (§11).
struct ACPDriverAgentRunner: BridgeAgentRunner {
    let executableURL: URL
    var environmentOverrides: [String: String] = [:]

    // eldr-acp spawns a fresh, stateless process per run, so Huginn supplies cross-turn
    // memory: `context.priorContext` (the decrypted, capped transcript) is injected as an
    // in-memory system-prompt preamble via `ELDR_ACP_PROMPT_PREAMBLE`. It rides the spawned
    // process's environment and lands in the anchored system prompt — it is NEVER written to
    // disk (that's why we don't use the eldr.md/context-file path here). `context.sessionKey`
    // isn't needed: eldr-acp owns its own ephemeral workspace, and Huginn owns the transcript.
    func run(prompt: String, workdir: String?, context: ConversationContext) async throws -> String {
        let collected = AgentAnswerCollector()
        // CR-1: this watch-along / Mac-responder runner has no interactive client to
        // approve a mutating tool, so the default `requestPermission` ({ _,_ in true })
        // AUTO-APPROVED run_shell / write_file / edit_file UNATTENDED — an owner-window-open
        // + prompt-injected task could run arbitrary shell on the Mac. This path is a
        // chat-participant / drafting role that needs only file READS for context, and
        // reads never request permission, so DENY every permission request (which denies
        // exactly the mutating tools). Real mutating work goes through the phone-driven
        // relay-ACP path (ACPRelayHost), which routes each request to the owner's phone
        // for an explicit Allow / Deny.
        let handler = ACPClientHandler(
            onAgentMessageChunk: { await collected.append($0) },
            requestPermission: { _, _ in false })
        var env = environmentOverrides
        env["ELDR_ACP_STREAM"] = "0"  // need the complete message to scrub it (§10)
        // Cross-turn memory: prior transcript as an in-memory system-prompt preamble. Never
        // written to disk (SPEC §3.4) — it lives only in this child process's environment.
        if let preamble = context.priorContext, !preamble.isEmpty {
            env["ELDR_ACP_PROMPT_PREAMBLE"] = preamble
        }
        let driver = ACPClientDriver(
            executableURL: executableURL, environmentOverrides: env, handler: handler)
        _ = try await driver.start(cwd: workdir)
        _ = try await driver.prompt(prompt)
        await driver.shutdown()
        return await collected.value
    }
}

/// Accumulates the agent's answer chunks into one complete string.
actor AgentAnswerCollector {
    private(set) var value = ""
    func append(_ s: String) { value += s }
}

/// A no-op `AgentMessageSink`. The bridge uses its `AgentEngine` purely as the
/// owner-authority ORACLE (verify owner-signed windows, answer `isAuthorizedForOwner`)
/// and does its OWN per-recipient fan-out (§9), so the engine never posts anything.
struct NoopAgentSink: AgentMessageSink {
    func postAgentMessage(_ body: MessageBody, threadID: String, agentName: String?) async throws {}
    func postAgentReply(_ body: MessageBody, agentName: String?) async throws {}
}

// MARK: - Service

@MainActor
final class ACPBridgeService: ObservableObject {

    enum BridgeState: Equatable {
        case unpaired
        case advertising
        case paired(contactName: String)
        case error(String)
    }

    /// How the watch-along agent participates in the group (Path 2 §9 vs SPEC §13.5).
    enum WatchAlongMode: String, Sendable, CaseIterable, Identifiable {
        /// The Mac is a group participant: it pairs with everyone and fans the answer
        /// out itself (owner raw, others redacted). Mac-enforced redaction. (AC20)
        case direct
        /// The Mac drafts privately to the owner's PHONE, which redacts + voices it to
        /// the group as the owner's signed agent. Hardened: the raw secret never
        /// reaches a non-owner link, and the message is cryptographically the owner's
        /// agent. (AC24 — needs the iOS endpoint glue.)
        case endpoint
        var id: String { rawValue }
    }

    /// One EldrChat conversation the agent can report into, with the user's opt-in.
    struct BridgeConversation: Identifiable, Equatable {
        let id: String  // peer identity hex / group id
        var name: String
        var enabled: Bool
        /// Member identity hexes for per-recipient fan-out (§9). Empty ⇒ a 1:1 chat,
        /// so the single recipient is `id`.
        var members: [String] = []
        /// Thread id when this conversation routes a shared AI thread; nil ⇒
        /// conversation scope (the owner's ai_window governs), set ⇒ the owner's
        /// ai_invite for this thread governs.
        var threadID: String? = nil

        /// The recipients to fan a message out to (the roster, or just the peer for 1:1).
        var recipients: [String] { members.isEmpty ? [id] : members }
    }

    @Published private(set) var bridgeState: BridgeState = .unpaired
    /// JSON for the QR code shown while advertising; nil when the bridge is off.
    @Published private(set) var pairingPayloadJSON: String?
    /// The `pqrc:add?npub=…` deep link EldrChat understands — what the QR encodes
    /// and what "Copy pairing link" / "Open in EldrChat" use. A bare JSON blob (the
    /// old QR payload) is read as plain text by the Camera, which "helpfully" web-
    /// searches it; a registered URL scheme deep-links straight into the app, and
    /// also lets you pair on the SAME Mac (no second device to scan with). nil off.
    @Published private(set) var pairingLink: String?
    @Published var activeConversations: [BridgeConversation] = []
    /// Inbound messages the group sent back (instructions/context), newest last.
    @Published private(set) var inbound: [String] = []

    /// The PINNED OWNER's identity hex (Path 2 §7). The Mac agent acts autonomously
    /// ONLY while THIS identity holds a live, signed ai_window/ai_invite. Persisted in
    /// the config dir (authorization-relevant, not secret). No owner ⇒ the bridge fails
    /// closed (never "first peer wins").
    @Published private(set) var ownerIdentityHex: String?

    /// Watch-along participation mode. Defaults to `.direct` — the Mac broadcasts the
    /// agent's reply itself (owner raw, others redacted), so it appears in the chat with
    /// no extra gate. `.endpoint` (the §13.5 hardening — the Mac drafts to the owner's
    /// phone, which redacts + voices it as the owner's own signed agent) is stronger but
    /// REQUIRES an ACTIVE ai_window to voice the draft (`voiceAgentDraft` →
    /// `authorizeAutonomousSend`); without one the reply is DROPPED (only a "your AI
    /// window is off" system note shows). So `.endpoint` is an opt-in for group
    /// watch-along WITH a live window — NOT the default: defaulting to it (the reverted
    /// A3) broke the ordinary 1:1 drive (reply generated in LM Studio, never displayed).
    @Published var watchAlongMode: WatchAlongMode = .direct

    /// Who answers the owner's chat on the Mac: our own `eldr-acp` agent (its configured
    /// LLM), or the user's **sybilclaw** assistant via its local Gateway (the "chat to
    /// sybilclaw" path — its own model, persona, memory, tools). A Huginn-only pref
    /// (persisted to UserDefaults). Switching it re-wires the live runner with no restart.
    enum Responder: String, Sendable, CaseIterable, Identifiable {
        case eldrAcp = "eldr-acp"
        case sybilclaw = "sybilclaw"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .eldrAcp: return "eldr-acp (our agent)"
            case .sybilclaw: return "sybilclaw assistant"
            }
        }
    }
    static let responderKey = "bridgeResponder"
    static func loadResponder() -> Responder {
        Responder(rawValue: UserDefaults.standard.string(forKey: responderKey) ?? "") ?? .eldrAcp
    }
    @Published var responder: Responder = ACPBridgeService.loadResponder() {
        didSet {
            UserDefaults.standard.set(responder.rawValue, forKey: Self.responderKey)
            // Re-wire the live runner immediately if the node is already up.
            if messenger != nil { applyProductionRunner() }
        }
    }

    // Per-message-type opt-in — OFF by default (the user chooses to share).
    @Published var shareToolCalls = false
    @Published var shareBuildResults = false
    @Published var shareFileDiffs = false
    @Published var shareSessionSummary = false

    private let keychain: KeychainBox
    private let keyAccount = "bridge-nostr-identity"
    private let serviceType: String
    private let preferredRelay: String?
    private let clock: any Clock = SystemClock()
    private var messaging: BridgeMessaging
    /// The owner-authority oracle: verifies owner-signed windows/invites and answers
    /// "is the owner authorizing right now". A `PQRCAgent.AgentEngine` in production
    /// (standing up the Mac's PQRC node is the runtime boundary — see the type doc
    /// above); nil ⇒ the gate fails closed. Injected via `setOwnerAuthority`.
    private var ownerEngine: AgentEngine?
    /// Drives the local agent for the watch-along flow. Injected via `setAgentRunner`.
    private var agentRunner: BridgeAgentRunner = UnavailableAgentRunner()
    /// Where the agent runs (project dir the coding tools operate on). nil ⇒ the
    /// runner's default cwd (which is useless for real tasks — set it in the UI).
    /// Published so the Bridge panel can show/pick it; persisted in the config dir.
    @Published private(set) var agentWorkdir: String?
    /// True while an agent run is in flight — a guard so queued messages don't each
    /// spawn a fresh agent (which stacked up and looked "dead").
    private var agentRunInFlight = false
    /// Wall-clock cap for one watch-along agent run. **0 (default) = no cap** — a
    /// self-hosted model doing real work legitimately runs long, so the whole turn
    /// isn't bounded here; it's still bounded by the agent's own iteration limit and
    /// the per-LLM-request timeout. Set a positive value to re-enable a hard ceiling
    /// (e.g. to fail fast on a known-weak looping model).
    @Published var agentRunTimeout: Double = 0
    /// File holding the pinned owner hex (`<configDir>/owner`).
    private let ownerFilePath: String?
    /// File holding the agent's project working directory (`<configDir>/workdir`).
    private let workdirFilePath: String?
    /// Encrypted-at-rest conversation transcripts dir (`<configDir>/transcripts`),
    /// owned by `conversationMemory`. nil when there's no config dir (e.g. some tests).
    private let transcriptsDir: URL?
    /// Owns the encrypted conversation transcript (SPEC §3.4, D9, invariant 12): every
    /// owner↔AI turn is recorded here, SE-wrapped + AES-GCM, so the Mac AI endpoint
    /// holds conversations at the same at-rest bar as EldrChat itself. nil ⇒ no config
    /// dir ⇒ recording is a no-op. Phase 1 records both backends' turns; Phase 2 feeds
    /// it back to eldr-acp as in-memory context. `var` only so tests can inject a
    /// Keychain-free instance via `setConversationMemory`.
    private var conversationMemory: ConversationMemory?

    private var keypair: NostrKeypair?
    private var link: MultipeerNearbyLink?
    private var eventsTask: Task<Void, Never>?

    /// The Mac's live PQRC node (publishes keys, pairs, sends/receives). nil until
    /// `startMessagingNode` runs. The reusable messaging path the watch-along rides.
    private var messenger: PQRCMessenger?
    private var nodeTask: Task<Void, Never>?
    /// The relay the node publishes to / subscribes on. MUST match the phone's relay.
    static let defaultRelayURL = "wss://relay.lerants.com"

    /// The relay-carried ACP host (Phase 3 LIVE node side): serves the FULL ACP protocol
    /// to the OWNER's phone over the relay, so the phone can drive the agent REMOTELY.
    /// Complements the watch-along drafts (this path) and `ACPNodeHost` (local Multipeer).
    /// Stood up alongside the messenger once an owner is pinned + an LLM is configured;
    /// nil otherwise (fail-closed — no owner / no model ⇒ no remote agent host). The C-3
    /// gate lives inside it.
    private var relayHost: ACPRelayHost?
    /// True while `relayHostStreamingEnabled` should stream the agent's answer over the
    /// relay. OFF by default to match the watch-along's whole-message redaction doctrine,
    /// though the relay ACP path is the OWNER's own E2EE session (no fan-out redaction).
    private let relayHostStreamingEnabled = false
    /// Whether the relay ACP host is currently serving the owner. Drives the BridgeView
    /// status row alongside the existing pairing state.
    @Published private(set) var relayACPServing = false

    init(
        keychain: KeychainBox = KeychainBox(),
        serviceType: String = MultipeerNearbyLink.bridgeServiceType,
        preferredRelay: String? = nil,
        messaging: BridgeMessaging = UnpairedMessaging(),
        configDir: String? = AgentConfig.defaultConfigDir(ProcessInfo.processInfo.environment)
    ) {
        self.keychain = keychain
        self.serviceType = serviceType
        self.preferredRelay = preferredRelay
        self.messaging = messaging
        self.ownerFilePath = configDir.map { ($0 as NSString).appendingPathComponent("owner") }
        self.workdirFilePath = configDir.map { ($0 as NSString).appendingPathComponent("workdir") }
        let transcripts = configDir.map {
            URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("transcripts", isDirectory: true)
        }
        self.transcriptsDir = transcripts
        self.conversationMemory = transcripts.map { ConversationMemory(directory: $0) }
        self.ownerIdentityHex = Self.loadOwner(from: ownerFilePath)
        self.agentWorkdir = Self.loadOwner(from: workdirFilePath)
    }

    /// Set (or clear) the project directory the agent's tools operate in, and persist it.
    /// Without this, the agent runs in an undefined dir and real file/build tasks fail.
    func setAgentWorkdir(_ path: String?) {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        agentWorkdir = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard let workdirFilePath else { return }
        if let agentWorkdir {
            let dir = (workdirFilePath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? agentWorkdir.write(toFile: workdirFilePath, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(atPath: workdirFilePath)
        }
    }

    /// True once the agent has a stored Nostr identity (whether or not advertising).
    var hasIdentity: Bool { keypair != nil || keychain.load(account: keyAccount) != nil }

    // MARK: Identity

    /// Load the stored Nostr identity, generating + persisting one on first use.
    /// SPEC §3.1 access rules are enforced by KeychainBox.
    @discardableResult
    func loadOrCreateKeypair() throws -> NostrKeypair {
        if let keypair { return keypair }
        if let data = keychain.load(account: keyAccount) {
            let kp = try NostrKeypair(privateKey: data)
            keypair = kp
            return kp
        }
        let kp = try NostrKeypair(randomSource: SystemRandomSource())
        try keychain.save(kp.privateKeyData, account: keyAccount)
        keypair = kp
        return kp
    }

    // MARK: Lifecycle

    /// Generate/load the identity, publish the QR payload, and start advertising over
    /// Multipeer so a nearby EldrChat can discover the agent.
    func enable() {
        // Tear down any prior advertiser first so re-enabling (e.g. retrying from the
        // `.error` state, where the Enable button is still shown) can't orphan a live
        // MultipeerNearbyLink + its events Task. Idempotent.
        if link != nil || eventsTask != nil { disable() }
        do {
            let kp = try loadOrCreateKeypair()
            pairingPayloadJSON = PairingPayload(pubkey: kp.publicKeyHex, relay: preferredRelay)
                .jsonString()
            pairingLink = Self.deepLink(pubkeyHex: kp.publicKeyHex, relay: preferredRelay)
            let link = MultipeerNearbyLink(serviceType: serviceType)
            self.link = link
            bridgeState = .advertising
            eventsTask = Task { [weak self] in
                do {
                    try await link.start()
                    for await event in await link.events() {
                        await self?.handle(linkEvent: event)
                    }
                } catch {
                    await MainActor.run { self?.bridgeState = .error("\(error)") }
                }
            }
            // Stand up the live PQRC node (publishes keys to the relay, subscribes,
            // pairs) and wires the production runner + owner engine to its identity.
            // This is what makes "Pair with EldrChat" actually resolve our keys.
            Task { [weak self] in await self?.startMessagingNode() }
        } catch {
            bridgeState = .error("Could not create the agent identity: \(error)")
        }
    }

    /// Stop advertising + tear down the PQRC node (keeps the persisted identity/keys).
    func disable() {
        eventsTask?.cancel()
        eventsTask = nil
        let link = self.link
        self.link = nil
        Task { await link?.stop() }
        stopMessagingNode()
        pairingPayloadJSON = nil
        pairingLink = nil
        if case .error = bridgeState {} else { bridgeState = .unpaired }
    }

    /// Build the `pqrc:add?npub=…` deep link EldrChat's `handleDeepLink` parses.
    /// The pubkey is bech32-encoded to `npub1…` (what the app's New-conversation
    /// scan expects); a preferred relay rides along as a forward-compatible query
    /// item the app ignores until it wires relay hints in.
    nonisolated static func deepLink(pubkeyHex: String, relay: String?) -> String {
        // Always mark the agent as a coding agent so the phone tags the contact
        // (`contactType = "coding_agent"`) — the phone uses that to recognize watch-along
        // drafts and voice them as the owner's agent (§13.5). Older app builds ignore
        // the unknown `type` query item.
        var link = "pqrc:add?npub=\(Bech32.npub(pubkeyHex))&type=coding_agent"
        if let relay, !relay.isEmpty,
            let encoded = relay.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        {
            link += "&relay=\(encoded)"
        }
        return link
    }

    /// Revoke pairing: stop, delete ALL node identity material, and forget
    /// conversations. Must clear every bridge-* Keychain item the node persists
    /// (`startMessagingNode` loads four of them); deleting only the Nostr key left the
    /// PQRC identity seed, the identity-DH key, and the prekey state behind, so the
    /// next pair reused a stale PQRC identity under a fresh Nostr key and the handshake
    /// silently mismatched. Clearing all four makes re-pair a clean slate.
    func unpair() {
        disable()
        for account in [
            keyAccount,                    // bridge-nostr-identity
            "bridge-pqrc-identity-seed",
            "bridge-identity-dh",
            "bridge-prekey-state",
            // Transcript secrets: deleting the wrapped master key cryptographically
            // shreds every recorded conversation even if files linger (SPEC §3.4, D9).
            ConversationMemory.masterKeyAccount,
            MacSecureEnclaveKeyWrapper.seKeyAccount,
            MacSecureEnclaveKeyWrapper.softwareKEKAccount,
        ] {
            keychain.delete(account: account)
        }
        // Drop the live ConversationMemory so its in-memory (already-unwrapped) master key
        // is released and any in-flight/queued record() no-ops instead of resurrecting a
        // transcript file under the just-shredded key (the cached store is gone).
        conversationMemory = nil
        // Belt-and-suspenders: remove the (now-undecryptable) transcript files, and the
        // still-cleartext learning sinks (events.jsonl + per-project eldr.md) so unpair is a
        // true clean slate (AC72 — those two aren't encrypted yet).
        if let transcriptsDir {
            try? FileManager.default.removeItem(at: transcriptsDir)
            let configDir = transcriptsDir.deletingLastPathComponent()
            try? FileManager.default.removeItem(at: configDir.appendingPathComponent("events.jsonl"))
            try? FileManager.default.removeItem(at: configDir.appendingPathComponent("projects"))
        }
        keypair = nil
        activeConversations.removeAll()
        inbound.removeAll()
        setOwnerIdentity(nil)  // forget the pinned owner (fail closed until re-pinned)
        bridgeState = .unpaired
    }

    /// Inject the production messaging implementation once a session is established.
    func setMessaging(_ messaging: BridgeMessaging) { self.messaging = messaging }

    /// Inject the owner-authority oracle (the Mac's `AgentEngine`) once the PQRC node
    /// is stood up. Until then the owner gate fails closed.
    func setOwnerAuthority(_ engine: AgentEngine) { self.ownerEngine = engine }

    /// Inject the agent runner + its working directory (e.g. the project the agent
    /// operates on).
    func setAgentRunner(_ runner: BridgeAgentRunner, workdir: String? = nil) {
        self.agentRunner = runner
        self.agentWorkdir = workdir
    }

    /// Test seam: inject a conversation-memory store (the tests use a Keychain-free,
    /// `EncryptedStore`-injected instance so they run on a headless host).
    func setConversationMemory(_ memory: ConversationMemory) { self.conversationMemory = memory }

    // MARK: Production wiring (Path 2 §8/§11 — narrows the AC21 runtime boundary)

    /// Stand up the production agent runner + owner-authority engine in the live app,
    /// unless test doubles were already injected. Idempotent. Called from `enable()`.
    ///
    /// The runner spawns the installed `eldr-acp` launcher (which sources the LLM env);
    /// the answer is collected whole regardless of streaming, so redaction always scrubs
    /// a complete message. The engine is the owner-authority ORACLE only — the owner-gate
    /// path (`receiveWindow`/`isAuthorizedForOwner`) never reads the engine's OWN
    /// identity (it keys on the owner's), so a fresh identity is correct and needs no
    /// persistence. What remains the boundary: a live `BridgeMessaging` and the inbound
    /// receive path that would call `receiveOwnerWindow`/`handleInboundPrompt`.
    func configureProduction() {
        // Don't clobber a test-injected runner; otherwise wire the selected responder.
        if agentRunner is UnavailableAgentRunner { applyProductionRunner() }
        if ownerEngine == nil, let identity = try? PQRCIdentity(randomSource: SystemRandomSource()) {
            ownerEngine = AgentEngine(myIdentity: identity, clock: clock, sink: NoopAgentSink())
        }
    }

    /// Point `agentRunner` at the selected responder: `eldr-acp` spawns the installed
    /// launcher (its own LLM); `sybilclaw` forwards the owner's chat to sybilclaw's local
    /// Gateway and returns its assistant's reply. Called at startup (only when not
    /// test-injected) and on a live responder switch (its `didSet`).
    private func applyProductionRunner() {
        switch responder {
        case .eldrAcp:
            if let executable = Self.resolveAgentExecutable(
                paths: .standard,
                bundled: Bundle.main.url(forResource: "eldr-acp", withExtension: nil))
            {
                agentRunner = ACPDriverAgentRunner(
                    executableURL: executable, environmentOverrides: Self.llmTokenEnvironment())
            }
        case .sybilclaw:
            agentRunner = SybilclawAgentRunner(
                client: SybilclawGatewayClient(
                    port: Self.sybilclawGatewayPort(), token: Self.sybilclawGatewayToken()))
        }
    }

    /// sybilclaw gateway port — the SAME Huginn pref the Connections panel writes
    /// (`ConfigurationStore.gatewayPortKey`), default 18789.
    static func sybilclawGatewayPort() -> Int {
        (UserDefaults.standard.object(forKey: ConfigurationStore.gatewayPortKey) as? Int)
            ?? ConfigurationStore.defaultGatewayPort
    }
    /// Optional gateway auth token from the Keychain (nil = no auth, typical for localhost).
    static func sybilclawGatewayToken() -> String? {
        KeychainBox().load(account: "sybilclaw-gateway-token").flatMap {
            String(data: $0, encoding: .utf8)
        }
    }

    /// Stable, opaque gateway session key for one conversation/thread. Deterministic (so the
    /// assistant keeps context across messages and app restarts) and salted with a
    /// per-install secret (so the gateway's plaintext on-disk session files never expose
    /// which PQRC identity / thread the owner talks to — SPEC §0). The `eldr:` namespace +
    /// opaque hash also guarantees these never collide with another channel's keys (e.g.
    /// Discord's `agent:…:direct:<id>`). Thread-scoped when the conversation routes a shared
    /// AI thread, else conversation-scoped (peer hex / group id).
    /// Byte cap for the prior-transcript context injected into stateless backends
    /// (eldr-acp). ~16 KB keeps continuity meaningful while staying well within the model
    /// context budget and ARG_MAX for the spawned process's environment. The renderer is
    /// tail-biased, so the most recent turns survive the cap.
    static let transcriptContextMaxBytes = 16_384

    static func gatewaySessionKey(for conversation: BridgeConversation) -> String {
        let scope = conversation.threadID ?? conversation.id
        var hasher = SHA256()
        hasher.update(data: gatewaySessionSalt())
        hasher.update(data: Data(scope.utf8))
        return "eldr:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Process-lifetime cache of the session salt, so derivation stays stable within a run
    /// even if the Keychain is unavailable (e.g. an unsigned test host).
    private static var cachedSessionSalt: Data?

    /// 32-byte per-install salt for gateway session-key derivation. Generated once and
    /// persisted in the Keychain (stable across app restarts); never logged, never leaves
    /// the device. Persistence is best-effort: if the Keychain is unavailable we still cache
    /// the salt in memory, so keys stay stable for this process — they just won't survive a
    /// relaunch on that (atypical) device.
    private static func gatewaySessionSalt() -> Data {
        if let cached = cachedSessionSalt { return cached }
        let account = "sybilclaw-session-salt"
        let box = KeychainBox()
        if let existing = box.load(account: account), existing.count == 32 {
            cachedSessionSalt = existing
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let salt = Data(bytes)
        try? box.save(salt, account: account)
        cachedSessionSalt = salt
        return salt
    }

    /// C-8: the LLM token lives in the Keychain, not the cleartext env file. Inject it
    /// into the agent's environment when WE spawn the launcher (the launcher's own
    /// Keychain read covers external clients like Xcode). Account/service MUST match
    /// ConfigurationStore's (default KeychainBox service + "llm-token").
    nonisolated static func llmTokenEnvironment() -> [String: String] {
        guard let data = KeychainBox().load(account: "llm-token"),
            let token = String(data: data, encoding: .utf8), !token.isEmpty
        else { return [:] }
        return ["ELDR_LLM_TOKEN": token]
    }

    /// Resolve the agent executable: prefer the installed launcher (it sources the env
    /// file → LLM config), then the bare installed binary, then the app-bundled binary.
    nonisolated static func resolveAgentExecutable(
        paths: ConfigPaths, bundled: URL?, fileManager: FileManager = .default
    ) -> URL? {
        if fileManager.isExecutableFile(atPath: paths.launcher) {
            return URL(fileURLWithPath: paths.launcher)
        }
        if fileManager.isExecutableFile(atPath: paths.installedBinary) {
            return URL(fileURLWithPath: paths.installedBinary)
        }
        return bundled
    }

    /// The PRODUCTION in-process LLM config for the relay ACP host. The watch-along path
    /// SPAWNS `eldr-acp` (the launcher sources the env file); the relay host instead drives
    /// `runACPAgent` in-process, so it needs the same LLM config materialized here: the
    /// `ELDR_LLM_URL`/`ELDR_LLM_MODEL` from the shared env file, the token from the Keychain
    /// (C-8 — never the cleartext env file). An empty URL ⇒ no usable model ⇒ the caller
    /// does NOT stand up the relay host (fail-closed).
    static func relayHostLLMConfig(paths: ConfigPaths = .standard) -> LLMConfig {
        var env = ConfigurationStore.parseEnvFile(at: paths.envFile)
        // Layer the Keychain token over the env file (the env file omits it by C-8).
        for (k, v) in llmTokenEnvironment() { env[k] = v }
        return LLMConfig.fromEnvironment(env)
    }

    /// The relay's per-message byte budget for framing/chunking ACP lines: the relay's
    /// event-size cap minus gift-wrap overhead. 16 KiB matches the proven e2e budget and
    /// stays well under the relay's 65 535-byte limit even after wrapping. `nonisolated`
    /// so the host construction and tests share one source of truth off the main actor.
    nonisolated static let relayACPMaxFrameBytes = 16 * 1024

    // MARK: PQRC messaging node (AC25 — the live BridgeMessaging seam)

    /// Stand up the Mac's PQRC node: load/persist the identity + prekeys (under the SAME
    /// Nostr key the QR advertises, so the phone's `fetchVerifiedPeer(npub)` resolves us),
    /// connect to the relay, subscribe to our gift-wrap inbox, publish our 10420/10421,
    /// and inject a `PQRCMessenger`-backed `BridgeMessaging`. Mirrors `PersonaRuntime.bootstrap`.
    /// Idempotent. `transports`/`relayURLs` are injectable so tests drive it through a
    /// `LocalRelaySimulator`; production builds a `NostrWebSocketTransport`.
    func startMessagingNode(
        transports injectedTransports: [any RelayTransport]? = nil,
        relayURLs overrideRelayURLs: [String]? = nil
    ) async {
        guard messenger == nil else { return }
        do {
            let nostrKeypair = try loadOrCreateKeypair()
            let identity = try loadOrCreatePQRCIdentity()
            let identityDH = try loadOrCreateIdentityDH()
            let prekeyManager = try await loadOrCreatePrekeyManager(identity: identity)
            let relayURLs = overrideRelayURLs ?? [preferredRelay ?? Self.defaultRelayURL]

            let transports: [any RelayTransport]
            if let injectedTransports {
                transports = injectedTransports
            } else {
                var built: [any RelayTransport] = []
                for raw in relayURLs {
                    if let url = URL(string: raw) {
                        built.append(await NostrWebSocketTransport(url: url).connect())
                    }
                }
                transports = built
            }

            let messenger = try PQRCMessenger(
                identity: identity, nostrKeypair: nostrKeypair, prekeyManager: prekeyManager,
                identityDH: identityDH, transports: transports, clock: clock,
                randomSource: SystemRandomSource(), nonceSource: SystemNonceSource())
            self.messenger = messenger

            // Now that we have a real device-bound identity + messenger, wire the
            // production seams to it (the owner-authority engine uses this identity; the
            // agent runner + messaging are live).
            if ownerEngine == nil {
                ownerEngine = AgentEngine(myIdentity: identity, clock: clock, sink: NoopAgentSink())
            }
            configureProduction()
            messaging = PQRCMessengerMessaging(messenger: messenger)

            let events = try await messenger.start()
            nodeTask = Task { [weak self] in
                for await event in events { await self?.handleMessengerEvent(event) }
            }
            // Stand up the relay-carried ACP host so the OWNER's phone can drive the agent
            // REMOTELY over this same messenger (Phase 3 LIVE node side). Needs the pinned
            // owner (the C-3 gate target) + a usable LLM; absent either, it stays off
            // (fail-closed) and only the watch-along path runs.
            startRelayACPHost(messenger: messenger)
            // Publish our keys so the phone can find us and start the encrypted chat.
            try await messenger.announce(relayURLs: relayURLs)
        } catch {
            bridgeState = .error("Messaging node failed: \(error)")
        }
    }

    /// Tear down the node (relay subscriptions + pump). Keeps the persisted keys.
    private func stopMessagingNode() {
        nodeTask?.cancel()
        nodeTask = nil
        stopRelayACPHost()
        let messenger = self.messenger
        self.messenger = nil
        Task { await messenger?.stop() }
        messaging = UnpairedMessaging()
    }

    // MARK: Relay-carried ACP host (Phase 3 LIVE node side)

    /// Stand up the relay ACP host over `messenger`: serve the FULL ACP protocol to the
    /// OWNER's phone over the relay (remote drive), with the C-3 gate admitting ONLY the
    /// owner's frames and the permission gate left fail-closed. No-op (fail-closed) unless
    /// an owner is pinned AND a usable LLM is configured — without an owner there is no
    /// gate target, and without a model the agent can't answer. Idempotent. The host's
    /// publish seam is `messenger.send(framed, to: owner)`; its inbound is fed by
    /// `handleMessengerEvent`'s ACP-frame routing.
    private func startRelayACPHost(messenger: PQRCMessenger) {
        guard relayHost == nil, let ownerIdentityHex else { return }
        let llmConfig = Self.relayHostLLMConfig()
        // No usable endpoint (empty URL) ⇒ don't serve a dead agent over the relay.
        guard !llmConfig.url.isEmpty else { return }
        DiagnosticsLog.shared.post(
            .node, .info, "Relay ACP host starting",
            "owner=\(ownerIdentityHex.prefix(12))… · LLM=\(llmConfig.url) · model=\(llmConfig.model)")
        let llm = InspectingLLMClient(
            wrapping: OpenAICompatibleLLMClient(config: llmConfig), model: llmConfig.model)
        let toolEnvironment = ToolEnvironment(
            workdir: agentWorkdir, baseEnvironment: ProcessInfo.processInfo.environment)
        let host = ACPRelayHost(
            ownerIdentityHex: ownerIdentityHex,
            maxFrameBytes: Self.relayACPMaxFrameBytes,
            llm: llm,
            toolEnvironment: toolEnvironment,
            config: .default,
            streamingEnabled: relayHostStreamingEnabled,
            publish: { [weak messenger] framed in
                // The transport's send seam: publish ONE framed chunk to the owner as an
                // ordinary PQRC message. participant_type stays .human — the frame is the
                // node↔owner ACP control channel, not an agent-authored chat message
                // (invariant 8 governs CHAT authorship; this is transport, like the phone's
                // outbound frames in the proven e2e). Send failures are swallowed so a
                // relay hiccup doesn't wedge the agent's turn loop.
                try? await messenger?.send(
                    MessageBody(text: framed, sentAt: Int64(Date().timeIntervalSince1970)),
                    to: ownerIdentityHex)
            })
        relayHost = host
        host.start()
        relayACPServing = host.currentStatus() == .serving
    }

    /// Tear down the relay ACP host (stops the agent loop + closes its transport).
    private func stopRelayACPHost() {
        relayHost?.stop()
        relayHost = nil
        relayACPServing = false
    }

    /// Restart the relay host so a freshly-pinned owner (or a changed workdir/LLM) takes
    /// effect on the live node. No live messenger ⇒ a no-op (the host comes up with the
    /// node next time). Call after `setOwnerIdentity`/`setAgentWorkdir` while serving.
    func refreshRelayACPHost() {
        guard let messenger else { return }
        stopRelayACPHost()
        startRelayACPHost(messenger: messenger)
    }

    /// Route one inbound messenger event. New peers are auto-accepted (the user
    /// initiated pairing from their phone); owner-signed windows/grants open the gate;
    /// a human message becomes a watch-along prompt.
    private func handleMessengerEvent(_ event: MessengerEvent) async {
        switch event {
        case .messageRequest(let senderNostrPubkeyHex, _):
            // The agent is a service the user paired from their phone — accept it.
            guard let messenger else { break }
            if let contact = try? await messenger.acceptRequest(
                senderNostrPubkeyHex: senderNostrPubkeyHex)
            {
                addPairedConversation(identityHex: contact.identityHex)
                bridgeState = .paired(contactName: shortHex(contact.identityHex))
            }
        case .message(let received):
            // Relay-carried ACP frame? Route it to the relay host (Phase 3 LIVE node
            // side) and STOP — an ACP frame is the node↔owner control channel, never a
            // chat message: it must not become a watch-along prompt or a paired
            // conversation. The host's C-3 gate admits ONLY the owner's frames; a
            // non-owner's `ACP1|…` frame is swallowed here (returns from routeInbound as
            // a drop) and goes no further (so a non-owner can't probe the agent either).
            if ACPRelayHost.wasACPFrame(received.body.text) {
                await relayHost?.routeInbound(
                    senderIdentityHex: received.senderIdentityHex, body: received.body.text)
                return
            }
            // Owner-signed window/grant → into the engine (gate opens only for the
            // pinned owner; non-owner senders are rejected inside these).
            if let window = received.aiWindow {
                await receiveOwnerWindow(
                    window, fromSenderIdentityHex: received.senderIdentityHex)
            }
            if let grant = received.aiContextGrant {
                await receiveOwnerContextGrant(
                    grant, fromSenderIdentityHex: received.senderIdentityHex)
            }
            let conversationID = received.body.group?.id ?? received.senderIdentityHex
            addPairedConversation(identityHex: conversationID)
            // A human message is a prompt for the agent — UNLESS it's a control message
            // (one carrying a window/grant, e.g. the "enabled always-on AI" system row,
            // whose boilerplate text must NOT be fed to the agent as a task).
            if received.participantType == .human, !received.body.text.isEmpty,
                received.aiWindow == nil, received.aiContextGrant == nil
            {
                let conversation = BridgeConversation(
                    id: conversationID, name: shortHex(conversationID), enabled: true,
                    members: received.body.group != nil ? [] : [received.senderIdentityHex],
                    threadID: received.body.thread?.id)
                await handleInboundPrompt(
                    received.body.text, conversation: conversation,
                    senderIdentityHex: received.senderIdentityHex)
            }
        default:
            break  // protocolViolation / quarantined / nearbyContact — not used here
        }
    }

    /// Add a conversation to the published list (so it shows in the UI + Owner panel),
    /// de-duplicated by id.
    private func addPairedConversation(identityHex: String) {
        guard !activeConversations.contains(where: { $0.id == identityHex }) else { return }
        activeConversations.append(
            BridgeConversation(
                id: identityHex, name: shortHex(identityHex), enabled: true,
                members: [identityHex]))
        // Auto-select the owner: the FIRST device to pair becomes the owner so the
        // Mac-Tethered-AI is usable immediately, with no manual pin. Fail-safe — only
        // ever auto-pins when NO owner is set, so it can never silently steal an
        // existing owner binding (a human can re-assign/remove below). Pairing already
        // required QR/verification, so a paired device is one the Mac operator trusts.
        if ownerIdentityHex == nil {
            setOwnerIdentity(identityHex)
        }
    }

    /// Remove a paired device. If it was the pinned owner, clear the owner too —
    /// fail-closed: the agent goes silent (no autonomous sends) until a new owner is
    /// pinned. The device can re-pair later (and would auto-select if no owner is set).
    func removePairedConversation(identityHex: String) {
        activeConversations.removeAll { $0.id == identityHex }
        if ownerIdentityHex == identityHex {
            setOwnerIdentity(nil)
        }
    }

    private func shortHex(_ hex: String) -> String {
        hex.count > 18 ? "\(hex.prefix(8))…\(hex.suffix(8))" : hex
    }

    // MARK: PQRC node key material (persisted in the Keychain)

    private func loadOrCreatePQRCIdentity() throws -> PQRCIdentity {
        if let seed = keychain.load(account: "bridge-pqrc-identity-seed") {
            return try PQRCIdentity(seed: seed)
        }
        let identity = try PQRCIdentity(randomSource: SystemRandomSource())
        try keychain.save(identity.privateKey.rawRepresentation, account: "bridge-pqrc-identity-seed")
        return identity
    }

    private func loadOrCreateIdentityDH() throws -> Curve25519.KeyAgreement.PrivateKey {
        if let seed = keychain.load(account: "bridge-identity-dh") {
            return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: seed)
        }
        let dh = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: SystemRandomSource().bytes(32))
        try keychain.save(dh.rawRepresentation, account: "bridge-identity-dh")
        return dh
    }

    private func loadOrCreatePrekeyManager(identity: PQRCIdentity) async throws -> PrekeyManager {
        let manager: PrekeyManager
        if let blob = keychain.load(account: "bridge-prekey-state"),
            let state = try? JSONDecoder().decode(PrekeyState.self, from: blob)
        {
            manager = try PrekeyManager(
                identity: identity, randomSource: SystemRandomSource(), state: state)
        } else {
            manager = try PrekeyManager(
                identity: identity, randomSource: SystemRandomSource(), oneTimeCount: 16)
        }
        _ = try await manager.replenish(to: 16)
        try keychain.save(
            JSONEncoder().encode(await manager.snapshot()), account: "bridge-prekey-state")
        return manager
    }

    // MARK: Owner identity (Path 2 §7)

    /// Designate (or clear) the pinned owner and persist it. Clearing fails the gate
    /// closed until a new owner is chosen.
    func setOwnerIdentity(_ hex: String?) {
        let trimmed = hex?.trimmingCharacters(in: .whitespacesAndNewlines)
        ownerIdentityHex = (trimmed?.isEmpty ?? true) ? nil : trimmed
        saveOwner()
        // A changed owner re-targets the C-3 gate; restart the live relay host so the new
        // owner can drive it (and the old one can't). No-op when the node isn't running.
        refreshRelayACPHost()
    }

    private func saveOwner() {
        guard let ownerFilePath else { return }
        if let ownerIdentityHex {
            let dir = (ownerFilePath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
            try? ownerIdentityHex.write(toFile: ownerFilePath, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(atPath: ownerFilePath)
        }
    }

    private static func loadOwner(from path: String?) -> String? {
        guard let path, let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Owner authority routing + gate (Path 2 §8)

    /// Route an inbound ai_window: accept ONLY when it's from the pinned owner, then
    /// forward to the engine (which re-verifies the owner signature and bounded
    /// duration before storing it). Any other sender is rejected — never "first peer
    /// wins". No owner pinned / no engine ⇒ dropped (fail closed).
    func receiveOwnerWindow(
        _ announcement: AIWindowAnnouncement, fromSenderIdentityHex sender: String
    ) async {
        guard let ownerIdentityHex, sender == ownerIdentityHex, let ownerEngine else {
            return  // not from the owner (or no owner/engine): ignore
        }
        try? await ownerEngine.receiveWindow(announcement, fromSenderIdentityHex: sender)
    }

    /// Route an inbound ai_context_grant from the pinned owner into the engine.
    func receiveOwnerContextGrant(
        _ grant: AIContextGrant, fromSenderIdentityHex sender: String
    ) async {
        guard let ownerIdentityHex, sender == ownerIdentityHex, let ownerEngine else { return }
        try? await ownerEngine.receiveContextGrant(grant, fromSenderIdentityHex: sender)
    }

    /// Whether the pinned owner currently authorizes autonomous sends for this scope.
    /// Fail closed: no owner pinned, no engine, or no live owner window/invite ⇒ false.
    func ownerAuthorized(threadID: String? = nil) async -> Bool {
        guard let ownerIdentityHex, let ownerEngine else { return false }
        return await ownerEngine.isAuthorizedForOwner(ownerIdentityHex, threadID: threadID)
    }

    private func handle(linkEvent: NearbyLinkEvent) {
        // The full PQXDH pairing handshake is the runtime boundary; here we only
        // reflect link-level connectivity so the UI isn't silent.
        switch linkEvent {
        case .connected:
            if case .advertising = bridgeState {
                bridgeState = .paired(contactName: "EldrChat")
            }
        case .disconnected:
            if case .paired = bridgeState { bridgeState = .advertising }
        case .data:
            break  // inbound PQRC payloads are decoded by the messenger seam
        }
    }

    // MARK: Reporting ACP activity (gated by the per-type toggles)

    func reportToolCall(name: String, argsJSON: String, result: String, isError: Bool) async {
        guard shareToolCalls else { return }
        await broadcast(AgentActivity.toolCall(
            name: name, argsJSON: argsJSON, result: result, isError: isError))
    }

    func reportBuildResult(command: String, exitCode: Int, output: String) async {
        guard shareBuildResults else { return }
        await broadcast(AgentActivity.buildResult(
            command: command, exitCode: exitCode, output: output))
    }

    func reportSessionSummary(summary: String, filesChanged: Int) async {
        guard shareSessionSummary else { return }
        await broadcast(AgentActivity.sessionSummary(
            summary: summary, filesChanged: filesChanged))
    }

    /// Send a formatted report to every enabled conversation as an agent message.
    private func broadcast(_ text: String) async {
        // Owner sees the raw report; every other recipient gets the credential-scrubbed
        // copy — tool args / build output / session summaries routinely carry tokens and
        // paths, and these reports fan out to every enabled conversation incl. non-owner
        // peers (H-4). Mirrors the DIRECT-mode agent-message per-recipient fan-out.
        let redacted = CredentialRedactor.scrub(text)
        for conversation in activeConversations where conversation.enabled {
            let visible = conversation.id == ownerIdentityHex ? text : redacted
            let body = MessageBody(text: visible, sentAt: clock.now())
            do {
                try await messaging.send(body, to: conversation.id, participantType: .agent)
            } catch {
                // Surface but don't crash the coding session over a delivery hiccup.
                bridgeState = .error("Send failed: \(error)")
            }
        }
    }

    // MARK: - Watch-along: owner-gated per-recipient fan-out (Path 2 §9, §11)

    /// Codename labeling the producing AI in a draft (local only; never load-bearing).
    private let agentCodename = "eldr-acp"

    /// The distinguishing feature: treat an inbound prompt as a request to the agent,
    /// drive it to a COMPLETE answer (never streamed — §10), and deliver it per the
    /// active watch-along mode:
    ///  - `.direct`: gate on the owner's window here, then fan out (owner raw, others
    ///    redacted) — the Mac is the group participant (AC20).
    ///  - `.endpoint`: send the answer privately to the owner's PHONE as a draft; the
    ///    phone gates + redacts + voices it to the group as the owner's signed agent
    ///    (§13.5). No Mac-side window gate — the draft is private to the owner.
    func handleInboundPrompt(
        _ text: String, conversation: BridgeConversation, senderIdentityHex: String
    ) async {
        // C-3: only the pinned owner may task the agent. Autonomous agent activity is
        // owner-authorized (SPEC §9/§13); a non-owner message in a watch-along
        // conversation must NEVER become an agent prompt — otherwise any group member
        // could drive run_shell/xcodebuild on the node (confused-deputy → RCE on the
        // host). Fail closed: no owner pinned, or sender ≠ owner ⇒ drop silently (don't
        // even ack, so a non-owner can't probe whether an agent is attached).
        guard let ownerIdentityHex, senderIdentityHex == ownerIdentityHex else { return }
        // One run at a time: a weak/looping model can take a while, and spawning an
        // agent per queued message stacked up and read as "dead". Tell the user instead.
        guard !agentRunInFlight else {
            if watchAlongMode == .direct {
                await broadcastAgentMessage(
                    "🤖 Still working on your previous request — one moment.",
                    conversation: conversation)
            }
            return
        }
        agentRunInFlight = true
        defer { agentRunInFlight = false }

        // Capture Sendable values so the timed run closure needs no actor hop.
        let runner = agentRunner
        let workdir = agentWorkdir
        let timeout = agentRunTimeout
        // Stable, opaque per-conversation session id so the assistant keeps this
        // conversation's context across turns and separate from every other one.
        let sessionKey = Self.gatewaySessionKey(for: conversation)

        // Cross-turn memory is injected ONLY when this turn's answer will NOT reach a
        // non-owner. In a mixed-group `.direct` watch-along the answer fans out to other
        // members (redacted by the per-message syntactic scrubber); injecting prior turns
        // would let the model paraphrase an EARLIER turn's secret into a new answer in a
        // shape the scrubber misses — a cross-turn leak the cardinal rule (SPEC §0) forbids.
        // So we withhold prior context unless recipients are owner-only, or the answer is the
        // `.endpoint` draft that goes to the owner's phone alone. Self-persisting backends
        // (sybilclaw) keep their own history and are never re-injected. Loaded BEFORE the
        // prompt is recorded so the current prompt isn't duplicated into its own context.
        let recipientsAreOwnerOnly = conversation.recipients.allSatisfy { $0 == ownerIdentityHex }
        let mayInjectMemory =
            !runner.selfPersistsHistory && (watchAlongMode == .endpoint || recipientsAreOwnerOnly)
        let priorContext: String? = mayInjectMemory
            ? (await conversationMemory?.priorContext(
                sessionKey: sessionKey, maxBytes: Self.transcriptContextMaxBytes) ?? nil)
            : nil
        let agentContext = ConversationContext(sessionKey: sessionKey, priorContext: priorContext)

        switch watchAlongMode {
        case .direct:
            guard await ownerAuthorized(threadID: conversation.threadID) else { return }
            // Record the owner's prompt only once we're committed to answering it (past the
            // owner-window gate), so the transcript never accumulates a dangling User turn
            // (SPEC §3.4, D9). Best-effort: record never throws and never blocks the turn.
            await conversationMemory?.record(
                text, as: .human, senderIdentity: senderIdentityHex,
                sessionKey: sessionKey, threadID: conversation.threadID, agentName: nil)
            // Immediate feedback so silence (a slow/looping model) never looks dead.
            await broadcastAgentMessage("🤖 On it…", conversation: conversation)
            do {
                let answer = try await Self.runWithTimeout(seconds: timeout) {
                    try await runner.run(prompt: text, workdir: workdir, context: agentContext)
                }
                await conversationMemory?.record(
                    answer, as: .agent, senderIdentity: responder.rawValue,
                    sessionKey: sessionKey, threadID: conversation.threadID, agentName: nil)
                await broadcastAgentMessage(answer, conversation: conversation)
            } catch is AgentRunTimeout {
                await broadcastAgentMessage(
                    "⚠️ The model didn't finish within \(Int(timeout))s — it may be looping or overloaded. Try a simpler request, or a stronger tool-calling model.",
                    conversation: conversation)
            } catch {
                bridgeState = .error("Agent run failed: \(error)")
                await broadcastAgentMessage(
                    "⚠️ The agent run failed: \(error.localizedDescription)",
                    conversation: conversation)
            }
        case .endpoint:
            // The draft goes to the owner's phone alone — record the prompt up front.
            await conversationMemory?.record(
                text, as: .human, senderIdentity: senderIdentityHex,
                sessionKey: sessionKey, threadID: conversation.threadID, agentName: nil)
            do {
                let answer = try await Self.runWithTimeout(seconds: timeout) {
                    try await runner.run(prompt: text, workdir: workdir, context: agentContext)
                }
                await conversationMemory?.record(
                    answer, as: .agent, senderIdentity: responder.rawValue,
                    sessionKey: sessionKey, threadID: conversation.threadID, agentName: nil)
                await sendDraftToOwner(answer, conversation: conversation)
            } catch {
                bridgeState = .error("Agent run failed: \(error)")
            }
        }
    }

    /// Run `operation`, throwing `AgentRunTimeout` if it doesn't finish in `seconds`.
    /// Bounds a single agent turn so a looping model can't hang the watch-along.
    nonisolated static func runWithTimeout<T: Sendable>(
        seconds: Double, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        // seconds <= 0 disables the cap: run the operation directly, unbounded.
        guard seconds > 0 else { return try await operation() }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw AgentRunTimeout()
            }
            guard let result = try await group.next() else { throw AgentRunTimeout() }
            group.cancelAll()
            return result
        }
    }

    /// Endpoint mode (§13.5): send the COMPLETE answer to the OWNER ONLY, marked as a
    /// watch-along draft for the owner's phone to redact + voice to the group. No
    /// Mac-side redaction or fan-out (the phone does both), and no window gate (the
    /// draft is private, owner↔agent E2EE). Fails closed if no owner is pinned.
    func sendDraftToOwner(_ answer: String, conversation: BridgeConversation) async {
        guard let ownerIdentityHex else { return }  // no owner pinned ⇒ nothing to draft to
        let draft = AgentDraft(
            agentName: agentCodename, voiceInto: conversation.id, threadID: conversation.threadID)
        let body = MessageBody(text: answer, sentAt: clock.now(), agentDraft: draft)
        do {
            try await messaging.send(body, to: ownerIdentityHex, participantType: .agent)
        } catch {
            bridgeState = .error("Draft send failed: \(error)")
        }
    }

    /// Per-recipient agent send (§9): confirm the owner gate is open, scrub once, then
    /// loop the roster sending the RAW text to the owner's session and the
    /// `‹redacted:…›` copy to everyone else. Each pairwise link is separately encrypted
    /// (PQXDH + Double Ratchet), so divergent bodies are natural and only the owner's
    /// session ever carries the secret, E2E-encrypted to the owner.
    func broadcastAgentMessage(_ text: String, conversation: BridgeConversation) async {
        guard await ownerAuthorized(threadID: conversation.threadID), let ownerIdentityHex
        else { return }  // fail closed — no live owner window ⇒ no send
        let redacted = CredentialRedactor.scrub(text)
        for member in conversation.recipients {
            let visible = member == ownerIdentityHex ? text : redacted
            let body = MessageBody(text: visible, sentAt: clock.now())
            do {
                try await messaging.send(body, to: member, participantType: .agent)
            } catch {
                bridgeState = .error("Send failed: \(error)")
            }
        }
    }
}
