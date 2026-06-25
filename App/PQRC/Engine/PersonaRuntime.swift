import Crypto
import Foundation
import PQRCACP
import PQRCAgent
import PQRCCore
import PQRCMCP
import PQRCNostr
import SwiftData

/// Events the runtime surfaces to the UI layer (already persisted).
enum RuntimeEvent: Sendable {
    case messageAdded(StoredMessage)
    /// An existing message's local state changed (e.g. its AI-context marker).
    case messageChanged(StoredMessage)
    case conversationChanged(String)
    case messageRequest(senderNostrPubkeyHex: String)
    case protocolViolation(conversationID: String, reason: String)
    case aiWindowChanged(conversationID: String, identityHex: String, activeUntil: Int64?)
    case aiInviteChanged(threadID: String, identityHex: String, activeUntil: Int64?)
    /// A context-sharing grant changed for a scope (DEVIATIONS N24). `scopeTag`
    /// is `AIContextGrant.Scope.tag` ("conversation:<id>" | "thread:<id>").
    case aiContextGrantChanged(scopeTag: String, identityHex: String, activeUntil: Int64?)
    case threadCreated(conversationID: String, threadID: String, title: String)
    case loopGuardChanged(threadID: String, paused: Bool)
    /// An autonomous AI reply (solo chat / window) failed for every tethered AI —
    /// surfaced so the user sees WHY instead of silence (the Bug-2 philosophy).
    case agentError(String)
    case safetyCodeChanged(identityHex: String)
    /// A co-present peer was discovered + binding-verified over the local link
    /// (SPEC §10, Nearby setting) — startable with no relay.
    case nearbyDiscovered(identityHex: String)
    /// My own key publish (10420/10421/10050) succeeded or failed — the
    /// relay-liveness signal the UI shows.
    case keyPublishChanged(KeyPublishStatus)
    /// A paired coding-agent node reported its plan/TODO checklist for the turn it
    /// is running (Phase D1). Display-only — the entries are agent output, shown as
    /// a checklist in that node's conversation; never trusted beyond a bubble. The
    /// node re-sends the whole plan on each change, so this carries the full state.
    case acpPlan(conversationID: String, entries: [ACPPlanEntry])
    /// Phase D4 — a live INTERACTIVE terminal (PTY) opened on the node for this
    /// conversation. The UI shows a terminal view + a prominent Stop control.
    case acpTerminalOpened(conversationID: String, terminalID: String, title: String)
    /// Phase D4 — a streamed chunk of an interactive terminal's output (incremental).
    /// Display-only agent output (like an agent bubble). NEVER logged at rest.
    case acpTerminalOutput(conversationID: String, terminalID: String, chunk: String)
    /// Phase D4 — an interactive terminal ended (child exited or killed via Stop /
    /// fail-closed teardown). The UI removes the terminal view.
    case acpTerminalClosed(conversationID: String, terminalID: String, exitCode: Int?)
}

/// One configured relay's URL paired with its current connection health.
struct RelayStatusInfo: Sendable, Equatable {
    let url: String
    let status: RelayStatus
}

/// Outcome of publishing my keys to the relay. A `.published` result doubles as
/// proof the relay is reachable; `.failed` means peers can't find me there yet.
enum KeyPublishStatus: Sendable, Equatable {
    case pending
    case published(at: Int64)
    case failed
}

/// One local persona: identity + messenger + agent engine + encrypted store.
/// The app has one; the Local Universe runs several over a shared relay.
actor PersonaRuntime {
    let displayName: String
    let keychain: KeychainStore
    /// When set, this is a passphrase-derived account "silo": every secret in the
    /// Keychain is AES-GCM-sealed under this key, so the silo is unreadable (and
    /// its content unprovable) without the passphrase (deniable multi-account).
    /// nil = the legacy device-bound (Secure Enclave) path, used only to READ a
    /// pre-silo account during migration.
    private let siloKEK: SymmetricKey?
    /// This silo's id, used to namespace per-account UserDefaults (per-conversation
    /// AI mode, thread skills, context domain) so accounts never read or
    /// accumulate each other's settings (deniability — A33). Empty in tests/demo,
    /// which use the bare (un-suffixed) keys.
    private let siloID: String

    private(set) var identity: PQRCIdentity!
    private(set) var nostrKeypair: NostrKeypair!
    private var messenger: PQRCMessenger!
    private var engine: AgentEngine!
    /// The human's tethered AIs (multi-AI tethering). At least one; the first is
    /// the "primary" used for private drafts and the Settings probe. All of them
    /// take a turn in the solo chat, in active windows, and in invited threads.
    private var ais: [TetheredAI]
    private let clock: any Clock
    private let randomSource: any RandomSource
    private let nonceSource: any NonceSource
    private let transports: [any RelayTransport]
    private let blobStore: any BlobStore
    /// SPEC §10 / S1: when enabled, co-present peers exchange seals directly
    /// over MultipeerConnectivity, with automatic relay fallback. Debug-only
    /// at the app layer (TESTFLIGHT-GUIDE §A6).
    private let enableLocalLink: Bool
    private var localLink: MultipeerLinkTransport?

    /// Relay-carried ACP transports (ACPRouterplan Phase 3), one per paired
    /// `coding_agent` node, keyed by the node's PQRC identity hex. Each carries the
    /// ACP line protocol to that node over the SAME gift-wrapped + Double-Ratcheted
    /// message mesh a normal chat uses (`RelayACPTransport`): the relay only ever
    /// sees the same E2EE ciphertext, never the ACP frames. The transport's `send`
    /// closure publishes a framed chunk via `messenger.send(_, to: nodeHex)`; inbound
    /// ACP frames received FROM that node are fed to `deliverInbound` in
    /// `handleReceived` (and NEVER stored/rendered as chat). Created lazily by
    /// `ensureRelayACPTransport(nodeHex:)` only when the node is consented (C-3 /
    /// `AppSession.remoteDevControlConsent`); torn down on `shutdown()`.
    private var relayACPTransports: [String: RelayACPTransport] = [:]
    /// The relay's per-message byte budget for an ACP frame chunk. Sized well under
    /// the strict-relay event ceiling so a framed chunk fits one gift-wrapped event
    /// even after the wrap overhead; `RelayACPTransport` chunks longer ACP lines to
    /// fit. Conservative on purpose (correctness over throughput).
    private let relayACPMaxFrameBytes = 16 * 1024

    /// Phase D3 — relay-carried MCP hosts, one per CONSENTED `coding_agent` node,
    /// keyed by the node's PQRC identity hex. Each serves the phone's redacting +
    /// window-gating `MCPServer` to that node's coding agent over the SAME mesh: the
    /// node's `MCP1|` chat-tool requests arrive on the message stream, are fed to the
    /// host (which answers from `RuntimeSecureChatBridge` — redaction enforced HERE,
    /// phone-side), and the responses are framed back. Created lazily by
    /// `ensureRelayMCPHost(nodeHex:)` ONLY when the node is a consented coding agent
    /// AND `shareChatContextConsent` is on; torn down on revoke / `shutdown()`. nil
    /// `secureChatBridge` (the bridge not yet injected by `AppModel`) ⇒ no host is
    /// ever created, so the path is inert until the app wires the redacting source.
    private var relayMCPHosts: [String: RelayMCPHost] = [:]
    /// The firewall-redacted data source the relay MCP hosts serve. Injected by
    /// `AppModel` once it exists (`setSecureChatBridge`); the SAME bridge the local
    /// loopback MCP server uses, so the relay path's redaction/window-gating is
    /// byte-identical. `Sendable`; holds `AppModel` weakly.
    private var secureChatBridge: (any SecureChatBridge)?

    private var store: SwiftDataMessageStore!
    private var crypter: EncryptedStore!

    /// Verified contacts by identity hex. The parallel `contactRecords` map
    /// carries nicknames/aliases/flags and is persisted encrypted — both are
    /// restored at bootstrap so contacts survive relaunch.
    private(set) var verifiedContacts: [String: VerifiedContact] = [:] {
        didSet { publishPairedPubkeys() }
    }
    private(set) var contactRecords: [String: ContactRecord] = [:]
    /// Nearby peers discovered + binding-verified over the local link (SPEC §10),
    /// identity hex -> display name. Not yet contacts — the user starts the
    /// conversation, which establishes a session with no relay.
    private var nearbyContactNames: [String: String] = [:]
    /// Open-inbox window: unknown senders are auto-accepted until this time
    /// (Settings → Reachability). nil/past = normal message-request gate.
    private var openInboxUntil: Int64?
    /// My self-chosen alias — travels only inside established encrypted
    /// sessions, so only connected contacts ever learn it.
    private var myAlias: String?
    /// 1:1 conversation id == peer identity hex; groups use the group UUID.
    private var groupRosters: [String: GroupRoster] = [:]
    private var threadConversations: [String: String] = [:]  // threadID -> conversationID
    private var threadTitles: [String: String] = [:]
    /// Conversation my active ai_window was started in (window replies route here).
    private var myWindowConversationID: String?
    /// The conversation a watch-along draft is currently being voiced into (§13.5).
    /// Stashed across the `engine.voiceAgentDraft` → `RuntimeSink.postAgentDraft` hop so
    /// the sink resolves the target the Mac's draft named (`voiceInto`). Set/cleared
    /// synchronously around a single voicing on this actor, so no concurrent draft races.
    private var pendingDraftTarget: String?
    /// conversationID / threadID -> when MY AI was turned on here. The AI only
    /// ingests messages from this point forward — NEVER prior chat history — plus
    /// any message the human manually marked "Add to AI Context" (b7: stream
    /// context only from on→off; privacy-first SPEC §0).
    private var aiActiveSince: [String: Int64] = [:]
    /// Conversations with a solo self-reply run currently in flight — coalesces
    /// rapid sends so tethered AIs don't stack overlapping reply storms.
    private var soloRepliesInFlight: Set<String> = []
    /// Reassembly buffers for chunked large messages (relay chunking). Keyed by
    /// chunk id; an entry holds the parts seen so far plus a template body (the
    /// first-arriving chunk, text cleared) used to rebuild the whole message
    /// once every part is present. Bounded by `maxChunkBuffers` so a peer can't
    /// exhaust memory with dangling, never-completed chunk sets.
    private var chunkBuffers: [String: ChunkAccumulator] = [:]
    private let maxChunkBuffers = 32
    struct ChunkAccumulator {
        var template: MessageBody
        var total: Int
        var parts: [Int: String] = [:]
        var receivedOrder: Int  // monotonic tag for LRU eviction
    }
    private var chunkArrivalCounter = 0
    private var pumpTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<RuntimeEvent>.Continuation?
    /// Outcome of the last attempt to publish my own keys (10420/10421/10050).
    /// A successful publish is ALSO our relay-liveness signal — one round-trip
    /// proves the relay is reachable AND now holds my keys. We do NOT re-publish
    /// to poll liveness (that would make publishing an online-presence beacon —
    /// SPEC §0); ongoing status uses the cheap connection check instead.
    private(set) var keyPublish: KeyPublishStatus = .pending
    /// Below this many unused one-time prekeys, replenish + republish so peers
    /// don't fall back to the last-resort key (invariant 11). This is a
    /// need-based trigger, never a timer.
    private let prekeyLowWaterMark = 3
    private let prekeyReplenishTarget = 10
    private var localSentAtBase: Int64 { clock.now() }

    init(
        displayName: String,
        transports: [any RelayTransport],
        blobStore: any BlobStore,
        ais: [TetheredAI],
        clock: any Clock = SystemClock(),
        randomSource: any RandomSource = SystemRandomSource(),
        nonceSource: any NonceSource = SystemNonceSource(),
        keychainService: String,
        siloKEK: SymmetricKey? = nil,
        siloID: String = "",
        enableLocalLink: Bool = false,
        aiSelection: (any AISelectionPolicy<TetheredAI>)? = nil
    ) {
        if let aiSelection { self.aiSelection = aiSelection }
        self.siloKEK = siloKEK
        self.siloID = siloID
        self.displayName = displayName
        self.transports = transports
        self.blobStore = blobStore
        // Always keep at least one AI so drafting never crashes on an empty list.
        self.ais = ais.isEmpty
            ? [TetheredAI(id: "demo", name: "demo-otter-naps-000", provider: DemoAgentProvider())]
            : ais
        self.clock = clock
        self.randomSource = randomSource
        self.nonceSource = nonceSource
        self.keychain = KeychainStore(service: keychainService)
        self.enableLocalLink = enableLocalLink
    }

    var identityHex: String { identity.publicKeyData.hexString }
    var npub: String { nostrKeypair.npub }

    /// Router policy (Phase 2): decides the PRIMARY AI (private drafts / Settings
    /// probe) and the PARTICIPATION set (solo/window/thread autonomous turns).
    /// Injectable; the default reproduces today's behavior EXACTLY (`ais.first` +
    /// the `participatesAutonomously` filter). A future policy can route by task —
    /// e.g. code/dev requests to the paired Mac ("acp") backend.
    private var aiSelection: any AISelectionPolicy<TetheredAI> = DefaultAISelectionPolicy<TetheredAI>()

    /// The primary AI for a private draft or the Settings probe, routed via the
    /// policy for the given scope (`conversationID`/`threadID` — empty/nil for the
    /// probe). Falls back to the first AI so it is NEVER nil (the runtime guarantees
    /// `ais` is non-empty, matching the old `ais[0]`). The default policy ignores
    /// the scope; `CapabilityRoutingPolicy` uses it to route the engine by task.
    private func primaryAI(conversationID: String, threadID: String?) -> TetheredAI {
        aiSelection.primary(from: ais, conversationID: conversationID, threadID: threadID) ?? ais[0]
    }
    private func primaryProvider(conversationID: String, threadID: String?) -> any AgentProvider {
        primaryAI(conversationID: conversationID, threadID: threadID).provider
    }
    /// Egress firewall: when on, context handed to a REMOTE AI is name-redacted
    /// (real names → local codenames) and byte-bounded before it leaves the
    /// device. On-device AIs always bypass it.
    private var firewallEnabled = true

    func setAIs(_ newAIs: [TetheredAI]) {
        ais = newAIs.isEmpty
            ? [TetheredAI(id: "demo", name: "demo-otter-naps-000", provider: DemoAgentProvider())]
            : newAIs
        rebindRelayACPProviders()
        refreshRoutingPolicy()
    }

    /// Make any enabled "acp" backend LIVE over the relay (ACPRouterplan Phase 3).
    /// The static `makeProvider` cannot reach the messenger or the node identity, so
    /// it hands back a Demo stub for "acp"; here, where both are available, we swap in
    /// a relay-backed `ACPAgentProvider` driving the owner's CONSENTED `coding_agent`
    /// node over its `RelayACPTransport`. Until a node is paired AND consented (C-3),
    /// the Demo stub stays — the `acp` tier is selectable and visibly responds, but
    /// nothing reaches a node. Idempotent: re-binds in place; called after bootstrap
    /// and on every `setAIs` (Settings refresh), so toggling consent / pairing a node
    /// flips the backend live without a reboot.
    private func rebindRelayACPProviders() {
        guard ais.contains(where: { $0.kind == "acp" }) else { return }
        guard let nodeHex = consentedCodingAgentNode(),
            let transport = ensureRelayACPTransport(nodeHex: nodeHex)
        else {
            // No consented node (e.g. remote dev-control revoked): revert any live `acp`
            // provider to the inert stub so the relay path goes fully inert again
            // (privacy-first — revoking consent must actually disconnect, not linger).
            ais = ais.map { ai in
                guard ai.kind == "acp" else { return ai }
                var inert = ai
                inert.provider = DemoAgentProvider()
                return inert
            }
            // Phase D4 — fail-closed: shut down any now-detached ACP providers (fire-and-
            // forget; this method is sync). Shutting a provider closes its transport →
            // the node terminates any live PTY. The Settings revoke path also calls
            // `teardownRelayACPTransport` (which awaits this), so this is a backstop for
            // any other route into the revert branch.
            let detached = relayACPProviders
            relayACPProviders.removeAll()
            for (_, provider) in detached {
                Task { await provider.shutdown() }
            }
            return
        }
        // Phone-side permission decision (statusreport §2.3, P0). The `kind` is the
        // ACP ToolKind the node attaches to its `session/request_permission`
        // (`ToolExecutor.kind(for:)`): `read` (read_file/list_dir/search) is the only
        // NON-mutating kind; `edit` (write_file/edit_file), `execute` (run_shell), and
        // anything else MUTATE or run code. Only `read` is auto-allowed; EVERY other
        // kind FAILS CLOSED unless the owner gave the SEPARATE per-node
        // autonomous-changes consent — an allowlist, not a denylist, so an unknown /
        // future tool kind defaults to denied (cardinal rule: privacy-/safety-
        // maximizing). Having merely consented to DRIVE the node (the gate that
        // admitted this path: `remoteDevControlConsent`, checked in
        // `isConsentedCodingAgentNode`) does NOT authorize silent file/shell mutation.
        // The node keeps enforcing its own C-2 cwd jail; this is the last brake the
        // PHONE owns. Captures only `Sendable` strings (no `self`) so the `@Sendable`
        // handler stays strict-concurrency clean.
        let silo = siloID
        // Capture the event continuation (it's `Sendable`) so the live-event observer
        // can forward a node's plan straight into the runtime's stream WITHOUT hopping
        // back onto the actor — the observer is a synchronous `@Sendable` closure. The
        // node's conversationID is its identity hex (1:1 conversation id == peer hex).
        let plansContinuation = eventContinuation
        // Phase D3: advertise the phone's MCP chat tools to THIS node only when the
        // owner gave the per-node "share chat context" consent. The phone then serves
        // those tool calls back over the relay from its redacting `RelayMCPHost` (set
        // up lazily on the first inbound MCP frame). Off ⇒ no `mcpServers` advertised,
        // so the node never even discovers the chat tools exist.
        let shareChat = AppSession.shareChatContextConsent(nodeID: nodeHex, siloID: silo)
        // Idempotent: if this node already has a live provider, REUSE it rather than
        // rebuilding — rebuilding would orphan a provider that may be streaming a live
        // interactive terminal (Phase D4), detaching the PTY from its Stop control. A
        // benign refresh (setAIs/refreshACPBindings) just re-installs the existing
        // provider into `ais`. A genuine consent change goes through
        // `teardownRelayACPTransport` first, which drops the entry, so this won't mask one.
        if let existing = relayACPProviders[nodeHex] {
            ais = ais.map { ai in
                guard ai.kind == "acp" else { return ai }
                var live = ai
                live.provider = existing
                return live
            }
            return
        }
        let provider = ACPAgentProvider(
            transport: transport,
            permissionHandler: { [weak self] title, kind in
                guard Self.isMutatingACPToolKind(kind) else { return true }
                guard let self else { return false }  // runtime gone → fail closed
                // Phase D4 — an INTERACTIVE PTY (open_terminal) is a SPECIAL, higher gate:
                // an open-ended shell can't be meaningfully approved per-keystroke, so it
                // requires the STANDING autonomous-changes consent and FAILS CLOSED
                // otherwise — NO per-action allow-once prompt. Recognized purely from the
                // tool title (the ACP `execute` kind is too coarse to tell it from
                // run_shell). Cardinal rule: the dangerous escape hatch needs the explicit,
                // standing opt-in, never a one-tap allow.
                if Self.isInteractiveTerminalTitle(title) {
                    return Self.decideInteractivePTY(nodeHex: nodeHex, silo: silo)
                }
                return await self.decidePermission(
                    nodeHex: nodeHex, silo: silo, title: title, kind: kind)
            },
            eventObserver: { event in
                switch event {
                case .plan(let entries):
                    // Phase D1: surface the plan checklist. Other folded events
                    // (assistant text, tool lifecycle) already arrive as the reply
                    // message, so re-forwarding them would double them.
                    plansContinuation?.yield(.acpPlan(conversationID: nodeHex, entries: entries))
                // Phase D4 — the live INTERACTIVE-terminal stream. These are NOT folded
                // into the reply (the PTY is its own surface), so the observer is the only
                // path the UI gets them by. The output chunk is display-only and never
                // logged at rest (CLAUDE.md inv. 12).
                case .terminalOpened(let terminalId, let title):
                    plansContinuation?.yield(
                        .acpTerminalOpened(
                            conversationID: nodeHex, terminalID: terminalId, title: title))
                case .terminalOutput(let terminalId, let chunk):
                    plansContinuation?.yield(
                        .acpTerminalOutput(
                            conversationID: nodeHex, terminalID: terminalId, chunk: chunk))
                case .terminalClosed(let terminalId, let exitCode):
                    plansContinuation?.yield(
                        .acpTerminalClosed(
                            conversationID: nodeHex, terminalID: terminalId, exitCode: exitCode))
                case .assistantText, .toolCall, .toolCallUpdate, .availableCommands:
                    break  // folded into the reply message; not a live UI signal here
                }
            },
            advertiseChatTools: shareChat)
        relayACPProviders[nodeHex] = provider
        ais = ais.map { ai in
            guard ai.kind == "acp" else { return ai }
            var live = ai
            live.provider = provider
            return live
        }
    }

    /// Phase D4 — the live `ACPAgentProvider` per consented node, so the UI can drive an
    /// interactive terminal's stdin/Stop back to the node. Reset alongside the relay-ACP
    /// transport. Kept separate from `ais[].provider` (typed as `any AgentProvider`) so
    /// the terminal-control methods are reachable without a downcast.
    private var relayACPProviders: [String: ACPAgentProvider] = [:]

    /// Write stdin to a live interactive terminal on `nodeHex` (the user typing into the
    /// PTY view). No-op if the node has no live ACP provider.
    func sendACPTerminalInput(nodeHex: String, terminalID: String, data: String) async {
        await relayACPProviders[nodeHex]?.sendTerminalInput(terminalId: terminalID, data: data)
    }

    /// KILL a live interactive terminal on `nodeHex` (the phone's Stop control). The node
    /// terminates the PTY's child process group + closes its fds. Always available.
    func killACPTerminal(nodeHex: String, terminalID: String) async {
        await relayACPProviders[nodeHex]?.killTerminal(terminalId: terminalID)
    }

    /// Decide one mutating ACP tool call (Phase 3 item 3 — "ask each time"). Allowlist
    /// ladder (cardinal rule): blanket per-node autonomous-changes consent → allow without
    /// prompting; else ASK the human (allow once / always / deny); if no asker is wired
    /// (headless / tests) → FAIL CLOSED. "Allow always" flips the autonomous-changes
    /// consent (the SAME store the Settings toggle writes) so the node stops prompting.
    /// Read-only kinds never reach here (the handler short-circuits them). The node also
    /// independently denies on its own C-1 timeout, so an unanswered prompt never runs.
    private func decidePermission(
        nodeHex: String, silo: String, title: String, kind: String
    ) async -> Bool {
        if AppSession.autonomousChangesConsent(nodeID: nodeHex, siloID: silo) { return true }
        guard let asker = permissionAsker else { return false }  // no UI → fail closed
        let decision = await asker.request(
            PermissionRequest(id: UUID().uuidString, nodeHex: nodeHex, title: title, kind: kind))
        if decision == .allowAlways {
            AppSession.setAutonomousChangesConsent(true, nodeID: nodeHex, siloID: silo)
        }
        return decision != .deny
    }

    /// Phase D4 — the GATE for opening an interactive PTY terminal on the node (the
    /// project's highest-risk surface: a persistent interactive shell on the user's Mac,
    /// driven from the phone). Unlike `decidePermission` for one-shot mutating tools,
    /// there is NO per-action allow-once path: an open-ended shell can't be meaningfully
    /// approved one keystroke at a time, so it requires the SAME standing
    /// `autonomousChangesConsent` the user explicitly opted into (Settings ▸ the node's
    /// "autonomous changes" toggle). With that consent OFF, PTY creation FAILS CLOSED — no
    /// terminal is ever opened. `nonisolated static` + pure so the `@Sendable` permission
    /// handler can call it without hopping the actor (matching `isMutatingACPToolKind`).
    /// The node independently re-checks C-1 (deny-on-timeout) and keeps its own cwd jail,
    /// so this is the phone-owned last brake on the escape hatch, not the only one.
    nonisolated static func decideInteractivePTY(nodeHex: String, silo: String) -> Bool {
        AppSession.autonomousChangesConsent(nodeID: nodeHex, siloID: silo)
    }

    /// Whether an ACP permission request's `title` is an interactive-PTY (`open_terminal`)
    /// request — matched against `ACPTerminal.interactiveTerminalTitlePrefix` (iOS-available,
    /// the same prefix the node attaches to every such request). The ACP ToolKind
    /// (`execute`) can't distinguish it from `run_shell`, so the title is the signal that
    /// routes it to the stronger `decideInteractivePTY` gate. `nonisolated static` + pure.
    nonisolated static func isInteractiveTerminalTitle(_ title: String) -> Bool {
        title.hasPrefix(ACPTerminal.interactiveTerminalTitlePrefix)
    }

    /// (Phase 3 — intelligent task routing.) Keep the AI-selection policy in sync with the
    /// consented coding nodes: ≥1 remote-dev-control-consented `coding_agent` node AND an
    /// `acp` AI tethered → route that node's conversation's drafts/turns to the
    /// code-capable engine (`CapabilityRoutingPolicy`); otherwise the default policy.
    /// Auto-managed (no toggle) — drafting in your Mac-agent chat uses the Mac, every other
    /// chat unchanged. Called from setAIs, bootstrap, and setContactType.
    private func refreshRoutingPolicy() {
        let codingNodes = verifiedContacts.keys.filter { isConsentedCodingAgentNode($0) }
        guard !codingNodes.isEmpty, ais.contains(where: { $0.kind == "acp" }) else {
            // No consented coding node: if WE installed a capability policy, revert to the
            // default; never clobber a policy someone else set (a test / future feature
            // via setAISelectionPolicy).
            if aiSelection is CapabilityRoutingPolicy<TetheredAI> {
                aiSelection = DefaultAISelectionPolicy<TetheredAI>()
            }
            return
        }
        let map = Dictionary(uniqueKeysWithValues: codingNodes.map { ($0, Set(["code"])) })
        aiSelection = CapabilityRoutingPolicy<TetheredAI>(byConversation: map)
    }

    /// Whether an ACP ToolKind needs autonomous-changes consent before the phone
    /// will allow it. ALLOWLIST semantics: only `read` (read_file / list_dir /
    /// search, per `ToolExecutor.kind(for:)`) is non-mutating and auto-allowed;
    /// `edit`, `execute`, `other`, and any unrecognized/future kind are treated as
    /// mutating and fail closed without consent (cardinal rule — an unknown tool is
    /// never silently trusted). `nonisolated static` + pure so the `@Sendable`
    /// permission handler can call it without capturing the actor.
    nonisolated static func isMutatingACPToolKind(_ kind: String) -> Bool {
        kind != "read"
    }

    /// The owner's paired `coding_agent` node to drive over the relay, if one is
    /// consented (C-3). Deterministic pick (lowest identity hex) when more than one
    /// is consented, so the choice is stable across refreshes.
    private func consentedCodingAgentNode() -> String? {
        verifiedContacts.keys
            .filter { isConsentedCodingAgentNode($0) }
            .sorted()
            .first
    }

    /// Read-only view of the `acp` backend's live connectedness for the Settings
    /// status line — the SAME signal `rebindRelayACPProviders` keys off, so the UI
    /// can't claim "connected" while the backend is still on its Demo stub. Returns
    /// the consented `coding_agent` node's identity hex + local display name, or nil
    /// when none is paired AND consented (C-3) — i.e. when replies are simulated.
    /// Delegates to the private `consentedCodingAgentNode()` (no duplicated logic).
    func consentedCodingAgentNodeInfo() -> (identityHex: String, name: String)? {
        guard let hex = consentedCodingAgentNode() else { return nil }
        return (hex, contactName(hex))
    }

    func setFirewallEnabled(_ enabled: Bool) {
        firewallEnabled = enabled
    }

    /// Inject a routing policy at runtime (Phase 2). Defaults to
    /// `DefaultAISelectionPolicy` (today's behavior) until set.
    func setAISelectionPolicy(_ policy: any AISelectionPolicy<TetheredAI>) {
        aiSelection = policy
    }

    /// The phone-side interactive permission asker (Phase 3 item 3 — "ask each time").
    /// Wired at app bootstrap to the `@MainActor ACPPermissionCoordinator`; nil in
    /// headless/tests, where `decidePermission` then fails closed on any mutating tool the
    /// owner hasn't pre-consented to.
    private var permissionAsker: (any ACPPermissionAsking)?

    func setPermissionAsker(_ asker: any ACPPermissionAsking) {
        permissionAsker = asker
    }

    /// Re-bind the relay-ACP provider + refresh routing for the CURRENT AI set, without
    /// rebuilding every AI. Call after a per-node consent flip (remote dev-control on/off)
    /// so the `acp` backend binds live (ON) or reverts to the inert stub (OFF) with no
    /// reboot. Idempotent.
    func refreshACPBindings() {
        rebindRelayACPProviders()
        refreshRoutingPolicy()
    }

    // MARK: - Nearby AUTH allowlist (C-5)

    /// The PAIRED peers' NOSTR pubkeys (hex) — the key space a kind-22242 AUTH is
    /// signed by (NOT the PQRC identity hex). This is the `NearbyRelayHost`
    /// allowlist: only a peer you've bidirectionally bound (kind-10420) may AUTH.
    func pairedNostrPubkeys() -> Set<String> {
        Set(verifiedContacts.values.map(\.nostrPubkeyHex))
    }
    private var pairedPubkeysPublisher: (@Sendable (Set<String>) -> Void)?
    /// Wire the live allowlist snapshot: republishes the paired Nostr pubkeys now
    /// and on every subsequent change to `verifiedContacts` (via its didSet).
    func setPairedPubkeysPublisher(_ publisher: @escaping @Sendable (Set<String>) -> Void) {
        pairedPubkeysPublisher = publisher
        publishPairedPubkeys()
    }
    private func publishPairedPubkeys() {
        pairedPubkeysPublisher?(pairedNostrPubkeys())
    }

    /// Apply a changed per-silo loop-guard threshold (DEVIATIONS D14) to the live
    /// engine so it takes effect without re-booting the silo. `0` turns the guard
    /// off (unbounded). Persistence is the caller's (Settings) responsibility;
    /// this only pushes the value into the running engine.
    func setLoopGuardLimit(_ limit: Int) async {
        await engine?.setLoopGuardLimit(limit)
    }

    /// Builds the context for one AI: the normal (byte-bounded) context for an
    /// on-device AI, or the firewalled (name-redacted) context for a remote AI
    /// when the firewall is on. This is the single boundary every byte crosses
    /// before reaching an off-device model.
    /// The AI's resolved context policy for this conversation: the AI's own gather
    /// policy with a per-conversation override (Settings → conversation details)
    /// layered on top. "off" is the SILENCE contract — the AI must neither gather
    /// context nor post. `contextFor` AND every autonomous turn consult this, so the
    /// in-chat "AI off here" chip and the actual behavior can never disagree.
    private func resolvedPolicy(_ ai: TetheredAI, conversationID: String) -> String {
        switch AppSession.conversationContextMode(conversationID, siloID: siloID) {
        case "off": return "off"
        case "marked": return "strict"
        case "full": return "active"
        default: return ai.contextPolicy
        }
    }

    private func contextFor(
        _ ai: TetheredAI, conversationID: String, threadID: String?
    ) async -> AgentContext {
        // A per-conversation override (Settings → conversation details) wins over
        // the AI's own gather policy.
        let policy = resolvedPolicy(ai, conversationID: conversationID)
        guard policy != "off" else {
            // Gathers nothing here — an empty transcript (still carrying the AI's
            // instructions so a manual draft can respond generically).
            return AgentContext(
                myIdentityHex: identityHex, myDisplayName: displayName, transcript: [],
                threadID: threadID, threadTitle: threadID.flatMap { threadTitles[$0] },
                instructions: ai.instructions, summarize: ai.summarizes)
        }
        // Shared-thread turns get the agent-skills guardrail injection + any
        // skills the humans pinned to this thread (docs/eldrchat-agent-skills.md):
        // channel/scope/context-boundary/bounded-autonomy/transparency + the
        // shared envelope. Solo/window turns keep the plain prompt.
        // Names in the guardrail prompt obey the egress firewall too: for a
        // REMOTE AI with the firewall on, use codenames ("you" / a contact's
        // local autoName) instead of real display names — otherwise the skills
        // prompt would leak the very social graph the firewall withholds from the
        // redacted transcript (DEVIATIONS A19/A20).
        // Per-conversation override (Settings → conversation details) wins over the
        // account default — a private, paired chat with your own agents can pass raw.
        let firewallOn = AppSession.conversationFirewall(conversationID, siloID: siloID) ?? firewallEnabled
        let redactNames = ai.appliesEgressFirewall && firewallOn
        let promptDisplayName = redactNames ? "you" : displayName
        let promptPeerName =
            redactNames
            ? (contactRecords[conversationID]?.autoName ?? "a contact")
            : (groupRosters[conversationID]?.name ?? contactName(conversationID))
        let override: String?
        if let tid = threadID {
            let base = AgentSkills.threadSystemPrompt(
                displayName: promptDisplayName,
                contextDomain: AppSession.aiContextDomain(siloID: siloID),
                peerName: promptPeerName,
                threadID: tid,
                activeSkillIDs: AppSession.threadSkills(tid, siloID: siloID),
                instructions: ai.instructions)
            // App-layer overlay: append any pinned CUSTOM skills' instruction text
            // the same way the package appends a built-in's fragment. The package
            // catalog stays the built-in source of truth; these are merged in only
            // for the prompt. Still just message text — no wire/privacy exception.
            let custom = customSkillFragments(threadID: tid)
            override = custom.isEmpty ? base : base + "\n\n" + custom
        } else {
            // Conversation-scope WINDOW reply prompt (BUG-6 fix). Without this, an
            // `ai_window` turn fell through to the generic `turnSystemPrompt()` — "you
            // are X's AI in a shared thread with ANOTHER person's AI … reply exactly
            // PASS to stay silent" — which is wrong here (the latest message is a HUMAN
            // guest's; there is no other AI), so real providers PASSed and the owner's
            // AI silently never answered. The Mock/Demo providers are eager and ignore
            // the prompt, which is why the engine tests stayed green while live failed.
            override = windowReplySystemPrompt(
                displayName: promptDisplayName, peerName: promptPeerName,
                instructions: ai.instructions, summarize: ai.summarizes)
        }
        let ctx = await agentContext(
            conversationID: conversationID, threadID: threadID, depth: ai.contextDepth,
            strict: policy == "strict", instructions: ai.instructions, summarize: ai.summarizes,
            systemPromptOverride: override)
        guard ai.appliesEgressFirewall, firewallOn else { return ctx }
        return redactedForRemote(ctx)
    }

    /// System prompt for a conversation-scope `ai_window` reply (BUG-6 fix). The owner
    /// has explicitly turned their AI ON for everyone in this conversation for a bounded
    /// time, so the AI SHOULD answer the latest message rather than default to silence.
    /// PASS stays available, but only for a message that genuinely warrants no reply.
    /// `peerName` is already firewall-safe (a codename when redacting for a remote AI);
    /// mirrors the summarize + user-instructions augmentation of `turnSystemPrompt()`.
    private func windowReplySystemPrompt(
        displayName: String, peerName: String, instructions: String?, summarize: Bool
    ) -> String {
        var p = """
            You are \(displayName)'s AI assistant, and \(displayName) has turned you ON \
            for this conversation with \(peerName) — everyone here knows you're an AI \
            taking part. Read the recent messages and reply helpfully to the most recent \
            one, in one short, natural message, as \(displayName)'s assistant. Reply \
            exactly PASS (nothing else) ONLY if the latest message clearly needs no \
            response — a bare acknowledgement like "ok" or "thanks", or something plainly \
            not meant for a reply. Otherwise, answer.
            """
        if summarize {
            p += " Prefer a brief summary of the relevant context over verbatim quoting."
        }
        if let instructions, !instructions.isEmpty {
            p += "\n\nYour user's instructions: \(instructions)"
        }
        return p
    }

    /// Replaces real display names with each identity's LOCAL codename (and self
    /// with "you"), so a remote vendor never receives a labeled social graph
    /// (DEVIATIONS A19/A20: names are device-local). ALSO scrubs credential-shaped
    /// secrets from the message text via `CredentialRedactor` (G4/P-6) — an API
    /// key / token pasted into a chat must not reach a third-party cloud AI. The
    /// byte bound was already applied in `agentContext`. (When the per-chat
    /// firewall is OFF this path is skipped — the user chose to send that chat raw
    /// to their own trusted agents.)
    private func redactedForRemote(_ context: AgentContext) -> AgentContext {
        let entries = context.transcript.map { entry -> TranscriptEntry in
            let codename =
                entry.senderIdentityHex == identityHex
                ? "you"
                : (contactRecords[entry.senderIdentityHex]?.autoName ?? "a contact")
            return TranscriptEntry(
                senderIdentityHex: entry.senderIdentityHex,
                senderDisplayName: codename,
                participantType: entry.participantType,
                text: CredentialRedactor.scrub(entry.text),
                isContext: entry.isContext,
                isSharedContext: entry.isSharedContext)
        }
        return AgentContext(
            myIdentityHex: context.myIdentityHex, myDisplayName: "you",
            transcript: entries, threadID: context.threadID, threadTitle: context.threadTitle,
            instructions: context.instructions, summarize: context.summarize,
            systemPromptOverride: context.systemPromptOverride)
    }

    /// The pinned CUSTOM skills' instruction text for a thread, formatted exactly
    /// like the built-in `ACTIVE SKILLS` block so the model treats them the same.
    /// Resolves the per-silo overlay (`AppSession.loadCustomSkills`); built-in ids
    /// are handled by the package and skipped here. Empty when none are pinned.
    private func customSkillFragments(threadID: String) -> String {
        let pinned = AppSession.threadSkills(threadID, siloID: siloID)
        guard !pinned.isEmpty else { return "" }
        let custom = AppSession.loadCustomSkills(siloID: siloID)
        let active = pinned.compactMap { id in custom.first { $0.id == id } }
        guard !active.isEmpty else { return "" }
        return "CUSTOM SKILLS — use the one whose trigger fits; reply in the same envelope:\n"
            + active.map { "## \($0.id)\n\($0.instruction)" }.joined(separator: "\n\n")
    }

    // MARK: - Bootstrap

    /// Loads a Keychain secret, AES-GCM-decrypting it under the silo key when in
    /// silo mode (so secrets are unreadable without the passphrase). Returns nil
    /// if absent or if it can't be opened with this silo's key.
    private func loadSecret(_ account: String) -> Data? {
        guard let raw = keychain.loadIfPresent(account: account) else { return nil }
        guard let siloKEK else { return raw }
        return try? SiloKey.open(raw, kek: siloKEK)
    }

    /// Saves a Keychain secret, AES-GCM-sealing it under the silo key in silo mode.
    private func saveSecret(_ data: Data, account: String) throws {
        if let siloKEK {
            try keychain.save(SiloKey.seal(data, kek: siloKEK), account: account)
        } else {
            try keychain.save(data, account: account)
        }
    }

    /// The wrapper that protects the store master key: passphrase-derived in silo
    /// mode (AES-GCM under the silo KEK — deniable, device-portable), or the
    /// device-bound Secure Enclave wrapper for a legacy account.
    private func masterKeyWrapper() -> any MasterKeyWrapper {
        if let siloKEK {
            return SoftwareKeyWrapper(
                keyEncryptionKey: siloKEK.withUnsafeBytes { Data($0) }, nonceSource: nonceSource)
        }
        return SecureEnclaveKeyWrapper(keychain: keychain)
    }

    /// Creates or restores the identity and starts everything.
    /// First launch generates keys (SPEC §3.1) and publishes 10420/10421/10050.
    func bootstrap(
        inMemoryStore: Bool, storeURL: URL? = nil,
        relayURLs: [String] = ["local://relay"]
    ) async throws -> AsyncStream<RuntimeEvent> {
        // Keys: load from Keychain (silo-sealed in silo mode) or generate.
        if let seed = loadSecret("identity-seed") {
            identity = try PQRCIdentity(seed: seed)
        } else {
            identity = try PQRCIdentity(randomSource: randomSource)
            try saveSecret(identity.privateKey.rawRepresentation, account: "identity-seed")
        }
        if let nostrPriv = loadSecret("nostr-key") {
            nostrKeypair = try NostrKeypair(privateKey: nostrPriv)
        } else {
            nostrKeypair = try NostrKeypair(randomSource: randomSource)
            try saveSecret(nostrKeypair.privateKeyData, account: "nostr-key")
        }
        let identityDH: Curve25519.KeyAgreement.PrivateKey
        if let dhSeed = loadSecret("identity-dh") {
            identityDH = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: dhSeed)
        } else {
            identityDH = try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: randomSource.bytes(32))
            try saveSecret(identityDH.rawRepresentation, account: "identity-dh")
        }

        // Master storage key: unwrap (silo KEK or Secure Enclave) or create fresh.
        let wrapper = masterKeyWrapper()
        if let wrapped = keychain.loadIfPresent(account: "wrapped-master-key"),
            let masterKey = try? wrapper.unwrap(wrapped: wrapped)
        {
            crypter = EncryptedStore(masterKey: masterKey, nonceSource: nonceSource)
        } else {
            crypter = EncryptedStore(randomSource: randomSource, nonceSource: nonceSource)
            try keychain.save(try crypter.wrappedMasterKey(using: wrapper), account: "wrapped-master-key")
        }

        let container = try SwiftDataMessageStore.makeContainer(inMemory: inMemoryStore, url: storeURL)
        store = SwiftDataMessageStore(modelContainer: container)
        await store.configure(crypter: crypter)

        // Prekey state (T2): restore from the Keychain so handshakes addressed
        // to a previously published bundle still resolve after relaunch, then
        // top the one-time pools back up before republishing.
        let prekeyManager: PrekeyManager
        if let stateBlob = loadSecret("prekey-state"),
            let state = try? JSONDecoder().decode(PrekeyState.self, from: stateBlob)
        {
            prekeyManager = try PrekeyManager(
                identity: identity, randomSource: randomSource, state: state)
        } else {
            prekeyManager = try PrekeyManager(
                identity: identity, randomSource: randomSource, oneTimeCount: 16)
        }
        _ = try await prekeyManager.replenish(to: 16)
        try keychain.save(
            JSONEncoder().encode(await prekeyManager.snapshot()), account: "prekey-state")

        messenger = try PQRCMessenger(
            identity: identity, nostrKeypair: nostrKeypair, prekeyManager: prekeyManager,
            identityDH: identityDH, transports: transports, clock: clock,
            randomSource: randomSource, nonceSource: nonceSource)
        engine = AgentEngine(
            myIdentity: identity, clock: clock, sink: RuntimeSink(runtime: self),
            loopGuardLimit: AppSession.agentLoopGuardLimit(siloID: siloID))

        // Restore persisted state: contacts (bindings re-verified — invariant 7
        // survives persistence), ratchet sessions, group rosters, threads, and
        // the processed-envelope set (so relay replays don't re-process).
        if let aliasData = loadSecret("my-alias") {
            myAlias = String(decoding: aliasData, as: UTF8.self)
        }
        if let untilData = loadSecret("open-inbox-until"),
            let until = Int64(String(decoding: untilData, as: UTF8.self)), until > clock.now()
        {
            openInboxUntil = until
        }
        for record in (try? await store.contacts()) ?? [] {
            guard
                let verified = try? BindingVerifier.verify(record.binding, outerSignatureValid: true)
            else { continue }  // tampered store record: never trust its keys
            let contact = VerifiedContact(binding: verified)
            verifiedContacts[contact.identityHex] = contact
            contactRecords[contact.identityHex] = record
            await messenger.addContact(contact)
            if record.blocked {
                await messenger.setBlocked(contact.identityHex, blocked: true)
            }
            // Backfill friendly codenames for contacts saved before this field
            // existed, so they stop showing as "Contact 1a2b3c4d".
            ensureFriendlyNames(contact.identityHex)
        }
        for (peerIdentityHex, snapshot) in (try? await store.sessions()) ?? [] {
            guard let contact = verifiedContacts[peerIdentityHex] else { continue }
            try? await messenger.restoreSession(
                with: contact, snapshot: snapshot,
                usedLastResortPrekey: contactRecords[peerIdentityHex]?.usedLastResortPrekey ?? false)
        }
        for (id, type, meta, _) in (try? await store.conversationMetas()) ?? [] where type == "group" {
            let create = GroupCreate(
                groupID: meta.groupID ?? id, name: meta.name,
                members: meta.memberIdentityHexes, revision: meta.rosterRevision)
            groupRosters[id] = GroupRoster(create: create, assertedBy: meta.rosterAssertedBy ?? identityHex)
        }
        for (threadID, conversationID, meta) in (try? await store.threadMetas()) ?? [] {
            threadConversations[threadID] = conversationID
            threadTitles[threadID] = meta.title
        }
        await messenger.seedProcessedWrapIDs((try? await store.processedEventIDs()) ?? [])

        // S1 local-first transport: constructed here because the hello proof
        // needs the (just-loaded) identity key, started before the messenger
        // so its receive pump catches every early connection.
        if enableLocalLink {
            let link = MultipeerLinkTransport(
                identity: identity,
                link: MultipeerNearbyLink(randomSource: randomSource),
                randomSource: randomSource)
            localLink = link
            await messenger.setLocalLink(link)
            try await link.start()
        }

        // Publish identity (10420/10421/10050) once at launch, in the
        // background so key generation never blocks on relay availability. The
        // result is recorded as our relay-liveness signal (a successful publish
        // proves the relay is reachable). We publish on launch, on relay-list
        // change, and when prekeys run low — NEVER on a timer or on every
        // foreground, so publishing can't become an online-presence beacon
        // (SPEC §0). Ongoing "is the relay up" status uses the connection check.
        let publishURLs = relayURLs
        let messengerEvents = try await messenger.start()
        let (stream, continuation) = AsyncStream.makeStream(of: RuntimeEvent.self)
        eventContinuation = continuation
        pumpTask = Task { [weak self] in
            for await event in messengerEvents {
                await self?.handle(event)
            }
        }
        // Dispatched AFTER the continuation is wired so the publish-status event
        // is never yielded into a nil continuation and lost.
        Task { [weak self] in await self?.publishKeys(relayURLs: publishURLs) }
        // Now that contacts (incl. any consented `coding_agent` node) and the
        // messenger are up, make any enabled "acp" backend live over the relay.
        rebindRelayACPProviders()
        refreshRoutingPolicy()
        return stream
    }

    func shutdown() async {
        // Final persistence sweep: any in-flight ratchet/prekey state lands
        // before the pumps die.
        if messenger != nil {
            for peer in verifiedContacts.keys {
                await persistSession(peer)
            }
            await persistPrekeyState()
        }
        pumpTask?.cancel()
        // Phase D4 — FAIL-CLOSED teardown: shut every live ACP provider down FIRST. Each
        // provider's shutdown finishes its client, which closes the transport, which ends
        // the node's runACPAgent inbound loop → the node terminates every live interactive
        // PTY. So locking the silo / backgrounding-into-shutdown kills any shell the node
        // is running — nothing interactive outlives the session (the #1 safeguard).
        for provider in relayACPProviders.values { await provider.shutdown() }
        relayACPProviders.removeAll()
        // Close every relay-ACP transport so its inbound stream finishes and any
        // ACP client/consumer awaiting it unwinds (no orphaned reassembly state).
        for transport in relayACPTransports.values { transport.close() }
        relayACPTransports.removeAll()
        // Phase D3: stop every relay-MCP host (closes its transport + pump) so the
        // node's chat-tool channel goes dark with the silo — nothing MCP-serving may
        // outlive the unlocked, redacting state it depends on.
        for host in relayMCPHosts.values { await host.stop() }
        relayMCPHosts.removeAll()
        await localLink?.stop()
        await messenger?.stop()
        eventContinuation?.finish()
    }

    /// Settings → wipe identity (double-confirmed in UI): destroys keys + store.
    func wipeIdentity() async throws {
        try await store.wipeAll()
        keychain.deleteAll()
        await shutdown()
    }

    // MARK: - Contacts & sessions

    /// Registers a verified contact in memory + messenger and persists the
    /// encrypted record. Single funnel for every way a contact can appear.
    /// The record stores the raw binding so restore can re-run
    /// `BindingVerifier.verify` — a record without one (shouldn't happen) is
    /// kept in memory but not persisted, never persisted unverifiable.
    private func registerContact(
        _ contact: VerifiedContact, localNickname: String? = nil
    ) async {
        verifiedContacts[contact.identityHex] = contact
        if var record = contactRecords[contact.identityHex] {
            if let localNickname { record.localNickname = localNickname }
            contactRecords[contact.identityHex] = record
        } else if let raw = contact.raw {
            contactRecords[contact.identityHex] = ContactRecord(
                binding: raw, localNickname: localNickname, peerAlias: nil,
                verified: false, blocked: false, usedLastResortPrekey: false)
        }
        await messenger.addContact(contact)
        ensureFriendlyNames(contact.identityHex)
        persistContact(contact.identityHex)
    }

    /// Every locally-generated name already in use — across all contacts'
    /// person/AI codenames, user renames, and my own display name/alias — so a
    /// freshly generated name can REGENERATE until it's unique (the fix for
    /// look-alike names). `excluding` drops one identity's own current names so
    /// re-applying an upgrade for that contact isn't counted as a self-collision.
    private func takenAutoNames(excluding identityHex: String? = nil) -> Set<String> {
        var taken: Set<String> = [displayName]
        if let alias = myAlias { taken.insert(alias) }
        for (hex, record) in contactRecords where hex != identityHex {
            if let name = record.autoName { taken.insert(name) }
            if let aiName = record.autoAIName { taken.insert(aiName) }
            if let nickname = record.localNickname { taken.insert(nickname) }
        }
        return taken
    }

    /// Assigns local, never-broadcast friendly codenames to a contact and their
    /// AI if they don't have any yet. The deterministic local name is set
    /// instantly (so the UI never shows a raw key), then an on-device Core AI
    /// name is attempted off the critical path and swapped in if it succeeds —
    /// never blocking, never leaving the device.
    private func ensureFriendlyNames(_ identityHex: String) {
        guard var record = contactRecords[identityHex] else { return }
        var changed = false
        // Build the taken set once and grow it as we assign, so this contact's
        // own person- and AI-name can't collide with each other either.
        var taken = takenAutoNames(excluding: identityHex)
        if record.autoName == nil {
            let name = FriendlyName.unique(seed: identityHex, taken: taken)
            record.autoName = name
            taken.insert(name)
            changed = true
        }
        if record.autoAIName == nil {
            record.autoAIName = FriendlyName.unique(seed: identityHex + ":ai", taken: taken)
            changed = true
        }
        guard changed else { return }
        contactRecords[identityHex] = record
        persistContact(identityHex)
        // Upgrade to on-device AI codenames when the model is available. Stays
        // on device (FriendlyName.generate never calls a remote API). The upgraded
        // names are re-rolled for uniqueness against everyone else's.
        Task { [weak self] in
            guard let self else { return }
            let taken = await self.takenAutoNames(excluding: identityHex)
            let person = await FriendlyName.generate(seed: identityHex, taken: taken)
            let ai = await FriendlyName.generate(
                seed: identityHex + ":ai", taken: taken.union([person]))
            await self.applyAutoNames(identityHex, person: person, ai: ai)
        }
    }

    /// Swaps in upgraded auto-names (from the on-device model). A user rename
    /// always wins, so we never clobber an explicit `localNickname`.
    private func applyAutoNames(_ identityHex: String, person: String, ai: String) {
        guard var record = contactRecords[identityHex] else { return }
        record.autoName = person
        record.autoAIName = ai
        contactRecords[identityHex] = record
        persistContact(identityHex)
        eventContinuation?.yield(.conversationChanged(identityHex))
    }

    private func persistContact(_ identityHex: String) {
        guard let record = contactRecords[identityHex] else { return }
        let store = store
        Task { try? await store?.saveContact(record) }
    }

    /// Persists the ratchet snapshot for one peer (after every send/receive
    /// that advances the ratchet — FS means old state is worthless, so the
    /// latest snapshot is the only one that matters).
    private func persistSession(_ peerIdentityHex: String) async {
        guard let snapshot = await messenger.sessionSnapshot(peerIdentityHex: peerIdentityHex)
        else { return }
        try? await store.saveSession(peerIdentityHex: peerIdentityHex, snapshot: snapshot)
    }

    private func persistPrekeyState() async {
        // `snapshot()` returns a fresh copy of the private halves (every field
        // deep-copied), so wiping it here leaves the live PrekeyManager actor's
        // state intact. Wipe the transient plaintext only after the encrypted
        // blob has been produced and handed to the Keychain (AC40).
        var state = await messenger.prekeyManager.snapshot()
        defer { state.zeroize() }
        if let blob = try? JSONEncoder().encode(state) {
            try? saveSecret(blob, account: "prekey-state")
        }
    }

    func addVerifiedPeer(_ runtimePeer: PersonaRuntime) async throws {
        let binding = try IdentityBinding.make(
            identity: await runtimePeer.identity,
            nostrPubkey: hexToData(await runtimePeer.nostrKeypair.publicKeyHex))
        let verified = try BindingVerifier.verify(binding, outerSignatureValid: true)
        let contact = VerifiedContact(binding: verified)
        contactRecords[contact.identityHex] = ContactRecord(
            binding: binding, localNickname: await runtimePeer.displayName,
            peerAlias: nil, verified: false, blocked: false, usedLastResortPrekey: false)
        await registerContact(contact)
    }

    /// New chat by npub: fetch 10420/10421 from relays, verify BOTH directions,
    /// verify prekey signatures, then PQXDH with message #0 (D10).
    func startConversation(npub: String, firstMessage: String) async throws -> String {
        guard let nostrHex = Bech32.pubkeyHex(fromNpub: npub) else {
            throw PQRCError.handshakeMalformed
        }
        let (contact, bundle) = try await messenger.fetchVerifiedPeer(nostrPubkeyHex: nostrHex)
        await registerContact(contact)
        // First message carries my alias so the peer sees a name, not a key.
        let body = MessageBody(text: firstMessage, sentAt: clock.now(), alias: myAlias)
        try await messenger.establishSession(with: contact, bundle: bundle, firstMessage: body)
        await persistSession(contact.identityHex)
        let message = StoredMessage(
            id: UUID().uuidString, conversationID: contact.identityHex,
            senderIdentity: identityHex, participantType: .human, text: firstMessage,
            sentAt: clock.now(), localStatus: "sent")
        try await store.save(message)
        eventContinuation?.yield(.messageAdded(message))
        return contact.identityHex
    }

    /// Direct establishment between Local Universe personas (no QR scan).
    func establishWith(_ peer: PersonaRuntime, firstMessage: String) async throws {
        let peerIdentityHex = await peer.identityHex
        guard let contact = verifiedContacts[peerIdentityHex] else {
            throw PQRCError.sessionNotEstablished
        }
        let bundle = try await peer.publicBundle()
        try bundle.verifySignatures(identityPubkey: contact.binding.identityPubkey)
        let body = MessageBody(text: firstMessage, sentAt: clock.now(), alias: myAlias)
        try await messenger.establishSession(with: contact, bundle: bundle, firstMessage: body)
        await persistSession(peerIdentityHex)
        let message = StoredMessage(
            id: UUID().uuidString, conversationID: peerIdentityHex,
            senderIdentity: identityHex, participantType: .human, text: firstMessage,
            sentAt: clock.now(), localStatus: "sent")
        try await store.save(message)
        eventContinuation?.yield(.messageAdded(message))
    }

    func publicBundle() async throws -> PrekeyBundle {
        try await messenger.prekeyManager.publicBundle()
    }

    func oneTimePrekeyCount() async -> Int {
        await messenger.prekeyManager.oneTimePrekeyCount
    }

    func setBlocked(_ identityHex: String, blocked: Bool) async {
        await messenger.setBlocked(identityHex, blocked: blocked)
        contactRecords[identityHex]?.blocked = blocked
        persistContact(identityHex)
    }

    /// D13: "Mark as verified" — persisted so the shield badge survives
    /// relaunch, and clears any pending safety-code-change warning.
    func setVerified(_ identityHex: String, verified: Bool) async {
        contactRecords[identityHex]?.verified = verified
        persistContact(identityHex)
        eventContinuation?.yield(.conversationChanged(identityHex))
    }

    /// Local rename: takes precedence over the peer's self-chosen alias (D11 —
    /// your address book is yours; nothing is published).
    func renameContact(_ identityHex: String, nickname: String?) async {
        contactRecords[identityHex]?.localNickname =
            (nickname?.isEmpty ?? true) ? nil : nickname
        persistContact(identityHex)
        eventContinuation?.yield(.conversationChanged(identityHex))
    }

    /// Phase 4: this contact's local type tag (`"coding_agent"` for a paired Eldr
    /// ACP Configurator). PURELY LOCAL — never broadcast (SPEC §0).
    func contactType(_ identityHex: String) -> String? {
        contactRecords[identityHex]?.contactType
    }

    /// Tag (or clear) a contact as a coding agent — set when pairing the Configurator
    /// so its conversation renders with the wrench icon. Local-only; persisted.
    func setContactType(_ identityHex: String, type: String?) async {
        contactRecords[identityHex]?.contactType = (type?.isEmpty ?? true) ? nil : type
        persistContact(identityHex)
        eventContinuation?.yield(.conversationChanged(identityHex))
        refreshRoutingPolicy()
    }

    // MARK: - Relay-carried ACP (ACPRouterplan Phase 3 — drive a paired Mac node)

    /// C-3 gate: an identity may be an ACP peer ONLY when it is the owner's paired
    /// `coding_agent` node AND remote dev-control is consented for it. This is the
    /// SINGLE predicate every relay-ACP path (inbound routing, transport binding, the
    /// live provider) checks, so the path stays inert (privacy-first) until the owner
    /// opts in. A node that is un-tagged, or consent revoked, fails closed.
    private func isConsentedCodingAgentNode(_ identityHex: String) -> Bool {
        contactType(identityHex) == "coding_agent"
            && AppSession.remoteDevControlConsent(nodeID: identityHex, siloID: siloID)
    }

    /// The live relay-ACP transport bound to a consented `coding_agent` node, creating
    /// it on first use. Returns nil (fails closed) when the node is not a consented
    /// coding agent (C-3) — so no transport is ever wired to a non-owner-node peer.
    /// The transport's `send` closure publishes each framed chunk to the node over the
    /// relay as an ordinary ratcheted message; inbound frames are delivered by
    /// `handleReceived`. Idempotent: the same transport is reused across turns so the
    /// node's reassembly ids stay coherent.
    func ensureRelayACPTransport(nodeHex: String) -> RelayACPTransport? {
        guard isConsentedCodingAgentNode(nodeHex) else { return nil }
        if let existing = relayACPTransports[nodeHex] { return existing }
        let transport = RelayACPTransport(maxFrameBytes: relayACPMaxFrameBytes) {
            [weak self] framedBody in
            guard let self else { return }
            // Publish the framed chunk as a normal message to the node. Best-effort:
            // a relay hiccup surfaces to the ACP client as a timed-out turn, not a
            // crash. `sentAt` is the live clock so each chunk is a distinct ratchet
            // message number.
            try? await self.sendRelayACPFrame(framedBody, to: nodeHex)
        }
        relayACPTransports[nodeHex] = transport
        return transport
    }

    /// Publish ONE framed ACP chunk to the node over the relay as an ordinary
    /// (agent-typed) ratcheted message. Hops onto the actor so `messenger.send` is
    /// serialized with every other send; persists the advanced ratchet afterwards.
    private func sendRelayACPFrame(_ framedBody: String, to nodeHex: String) async throws {
        let body = MessageBody(text: framedBody, sentAt: clock.now())
        try await messenger.send(body, to: nodeHex, participantType: .agent)
        await persistSession(nodeHex)
    }

    /// Tear down a node's relay-ACP transport (and drop it), e.g. when consent is
    /// revoked or the node is unpaired. Safe when none exists.
    func teardownRelayACPTransport(nodeHex: String) async {
        // Resolve any prompts awaiting the human for this node with .deny — never strand a
        // continuation when the path goes away (item 3 fail-closed hygiene).
        await permissionAsker?.cancelAll(nodeHex: nodeHex)
        // Phase D4 — FAIL-CLOSED: shut the node's ACP provider down (finishes its client
        // → closes the transport → the node's runACPAgent terminates every live PTY). This
        // is the phone-side trigger for "no orphaned interactive shell on the Mac" on
        // consent-revoke / unpair. Belt-and-suspenders with the transport.close() below.
        if let provider = relayACPProviders.removeValue(forKey: nodeHex) {
            await provider.shutdown()
        }
        guard let transport = relayACPTransports.removeValue(forKey: nodeHex) else { return }
        transport.close()
    }

    // MARK: - Relay-carried MCP (Phase D3 — serve the phone's chat tools to a node)

    /// Inject the firewall-redacted MCP data source (the SAME `RuntimeSecureChatBridge`
    /// the loopback MCP server uses). Called once by `AppModel` after it exists. Until
    /// this is set, `ensureRelayMCPHost` returns nil and NO node's MCP frames are ever
    /// serviced (fail-closed: no redacting source ⇒ no service).
    func setSecureChatBridge(_ bridge: any SecureChatBridge) {
        secureChatBridge = bridge
    }

    /// C-3 + Phase-D3 gate: an identity may have the phone's MCP chat tools served to
    /// it ONLY when it is the owner's paired `coding_agent` node (so it can be driven
    /// at all — `isConsentedCodingAgentNode`) AND the SEPARATE "share chat context"
    /// consent is on for it. Chat context ≠ dev-control: BOTH must be granted. The
    /// single predicate every relay-MCP path checks, so the path stays inert until the
    /// owner opts in.
    private func isMCPSharingNode(_ identityHex: String) -> Bool {
        isConsentedCodingAgentNode(identityHex)
            && AppSession.shareChatContextConsent(nodeID: identityHex, siloID: siloID)
    }

    /// The live relay-MCP host bound to a node sharing chat context, creating it on
    /// first use. Returns nil (fails closed) when the node is NOT an MCP-sharing node
    /// (C-3 + share-chat-context) OR no redacting bridge has been injected — so a host
    /// is never wired for a node the owner hasn't opted into, and never without a
    /// redacting source. The host's `send` publishes each framed `MCP1|` chunk to the
    /// node over the relay as an ordinary (agent-typed) message; inbound frames are
    /// delivered by `handleReceived`. Idempotent: the same host is reused so the MCP
    /// session/reassembly stay coherent.
    func ensureRelayMCPHost(nodeHex: String) async -> RelayMCPHost? {
        guard isMCPSharingNode(nodeHex), let bridge = secureChatBridge else { return nil }
        if let existing = relayMCPHosts[nodeHex] { return existing }
        let host = RelayMCPHost(
            bridge: bridge,
            maxFrameBytes: relayACPMaxFrameBytes,
            publish: { [weak self] framedBody in
                guard let self else { return }
                // Publish the framed MCP chunk to the node, exactly like an ACP frame:
                // an agent-typed ratcheted message (transport, not chat). Best-effort.
                try? await self.sendRelayACPFrame(framedBody, to: nodeHex)
            })
        await host.start()
        relayMCPHosts[nodeHex] = host
        return host
    }

    /// Tear down a node's relay-MCP host (and drop it), e.g. when the share-chat-context
    /// consent is revoked or the node is unpaired. Safe when none exists.
    func teardownRelayMCPHost(nodeHex: String) async {
        guard let host = relayMCPHosts.removeValue(forKey: nodeHex) else { return }
        await host.stop()
    }

    /// Sets my alias and broadcasts it to every connected contact over the
    /// existing encrypted sessions (an empty-text control message — never a
    /// public profile; only established contacts learn the name).
    func setMyAlias(_ alias: String?) async {
        myAlias = (alias?.isEmpty ?? true) ? nil : alias
        if let myAlias {
            try? saveSecret(Data(myAlias.utf8), account: "my-alias")
        } else {
            keychain.delete(account: "my-alias")
        }
        guard let myAlias else { return }
        let body = MessageBody(text: "", sentAt: clock.now(), alias: myAlias)
        for peer in verifiedContacts.keys {
            guard await messenger.hasSession(peerIdentityHex: peer) else { continue }
            try? await messenger.send(body, to: peer, participantType: .human)
            await persistSession(peer)
        }
    }

    var currentAlias: String? { myAlias }

    // MARK: - Message requests (D12) & open inbox

    /// Accepts a pending request: the messenger fetches + verifies the
    /// sender's binding, replays held envelopes (handshake → message #0), and
    /// the contact is persisted. Returns the new conversation id.
    func acceptMessageRequest(senderNostrPubkeyHex: String) async throws -> String {
        let contact = try await messenger.acceptRequest(senderNostrPubkeyHex: senderNostrPubkeyHex)
        await registerContact(contact)
        await persistSession(contact.identityHex)
        await persistPrekeyState()
        eventContinuation?.yield(.conversationChanged(contact.identityHex))
        return contact.identityHex
    }

    func declineMessageRequest(senderNostrPubkeyHex: String) async {
        await messenger.declineRequest(senderNostrPubkeyHex: senderNostrPubkeyHex)
    }

    // MARK: - Nearby (relay-free establishment, SPEC §10)

    var isLocalLinkEnabled: Bool { enableLocalLink }

    /// Discovered co-present peers not yet in your contacts (identity hex + name).
    func nearbyList() -> [(identityHex: String, name: String)] {
        nearbyContactNames
            .filter { verifiedContacts[$0.key] == nil }
            .map { ($0.key, $0.value) }
            .sorted { $0.name < $1.name }
    }

    /// Starts a conversation with a nearby peer using the bundle verified over
    /// the local link — NO relay. Identity-of-human is confirmed afterwards via
    /// the safety code, exactly as on the relay path.
    func startNearbyConversation(identityHex: String, firstMessage: String) async throws -> String {
        let body = MessageBody(text: firstMessage, sentAt: clock.now(), alias: myAlias)
        let contact = try await messenger.establishWithNearby(
            identityHex: identityHex, firstMessage: body)
        await registerContact(contact)
        await persistSession(contact.identityHex)
        nearbyContactNames[identityHex] = nil
        let message = StoredMessage(
            id: UUID().uuidString, conversationID: contact.identityHex,
            senderIdentity: self.identityHex, participantType: .human, text: firstMessage,
            sentAt: clock.now(), localStatus: "sent")
        try await store.save(message)
        eventContinuation?.yield(.messageAdded(message))
        return contact.identityHex
    }

    /// Open-inbox window: messages from anyone are auto-accepted until
    /// `until` (nil disables). Survives relaunch; the privacy trade is the
    /// user's explicit, time-bounded choice (THREAT_MODEL note).
    func setOpenInbox(until: Int64?) {
        openInboxUntil = until
        if let until {
            try? saveSecret(Data(String(until).utf8), account: "open-inbox-until")
        } else {
            keychain.delete(account: "open-inbox-until")
        }
    }

    func openInboxActiveUntil() -> Int64? {
        guard let openInboxUntil, openInboxUntil > clock.now() else { return nil }
        return openInboxUntil
    }

    /// Replenishes one-time prekeys and republishes 10420/10421/10050. Used by
    /// Settings → Republish and on a relay-list change. Throws on publish
    /// failure so the caller can surface it.
    func republishBundle(relayURLs: [String]) async throws {
        lastPublishRelayURLs = relayURLs
        _ = try await messenger.prekeyManager.replenish(to: prekeyReplenishTarget)
        await persistPrekeyState()
        try await messenger.announce(relayURLs: relayURLs)
        recordPublish(.published(at: clock.now()))
    }

    /// Publishes my keys and records the outcome as the relay-liveness signal.
    /// Best-effort: never throws (used from background tasks); the recorded
    /// status is how failure surfaces. Bounded attempts so a down relay logs a
    /// few lines, not a flood.
    private func publishKeys(relayURLs: [String]) async {
        lastPublishRelayURLs = relayURLs
        do {
            try await messenger.announce(relayURLs: relayURLs, maxAttempts: 6)
            recordPublish(.published(at: clock.now()))
        } catch {
            recordPublish(.failed)
        }
    }

    private func recordPublish(_ status: KeyPublishStatus) {
        keyPublish = status
        eventContinuation?.yield(.keyPublishChanged(status))
    }

    /// Need-based republish: when unused one-time prekeys run low, replenish and
    /// republish so incoming handshakes don't fall back to the last-resort key
    /// (invariant 11). Called after the receive path consumes a prekey — driven
    /// by message activity, never by a timer.
    private func republishIfPrekeysLow() async {
        let remaining = await messenger.prekeyManager.oneTimePrekeyCount
        guard remaining <= prekeyLowWaterMark else { return }
        let generated = (try? await messenger.prekeyManager.replenish(to: prekeyReplenishTarget)) ?? false
        guard generated else { return }
        await persistPrekeyState()
        await publishKeys(relayURLs: lastPublishRelayURLs)
    }

    /// Relays used for the most recent publish, so prekey-low republishes reach
    /// the same servers without re-plumbing the URL list.
    private var lastPublishRelayURLs: [String] = []

    // MARK: - Sending

    /// Sends a human (or agent) message into a conversation, fanning out for
    /// groups. >64 KB content takes the blob path automatically (SPEC §11).
    func sendMessage(
        _ text: String, conversationID: String, participantType: ParticipantType = .human,
        threadID: String? = nil, isContext: Bool = false, aiContext: Bool = false,
        aiWindow: AIWindowAnnouncement? = nil, aiInvite: AIInvite? = nil,
        aiContextGrant: AIContextGrant? = nil,
        threadCreate: ThreadCreate? = nil, groupCreate: GroupCreate? = nil,
        asSystemRow: Bool = false, agentName: String? = nil,
        localTextOverride: String? = nil
    ) async throws {
        let recipients = recipientsFor(conversationID: conversationID)
        // A group I'm a member of with no other humans (the "solo AI chat") is a
        // valid local-only conversation: store and render, just publish to no
        // one. Only a 1:1 with no established session is a hard error.
        let isLocalGroup = groupRosters[conversationID]?.members.contains(identityHex) ?? false
        guard !recipients.isEmpty || isLocalGroup else { throw PQRCError.sessionNotEstablished }

        // One stable id for this message, carried inside the ciphertext so the
        // recipient stores the SAME id (cross-device controls like the
        // ai_context_mark retro-flag reference a message by id — DEVIATIONS N25).
        let messageID = UUID().uuidString
        var body = MessageBody(
            text: text, sentAt: clock.now(), messageID: messageID,
            group: groupRosters[conversationID].map { _ in RumorContent.GroupRef(id: conversationID) },
            thread: threadID.map { RumorContent.ThreadRef(id: $0) },
            groupCreate: groupCreate, threadCreate: threadCreate, aiInvite: aiInvite,
            isContext: isContext ? true : nil,
            aiContext: aiContext ? true : nil,
            aiContextGrant: aiContextGrant,
            // Self-chosen alias rides along inside the ciphertext so every
            // connected peer stays current (and ONLY connected peers — D11).
            alias: participantType == .human ? myAlias : nil)

        // Large text is split into ordered, ratcheted chunks carried over the
        // relay (SPEC §11 chunking — the privacy-preserving alternative to a
        // Blossom pointer, which needs a shared blob server). Reassembly
        // metadata rides INSIDE the ciphertext, so relays never see that a
        // message was chunked. Each chunk is a full ratchet message key. Binary
        // attachments will use the Blossom pointer path; text never does, so it
        // works on a bare relay with no blob server.
        // Adaptive: size chunks to the relay set's content limit (big on
        // permissive relays, safe-small on strict ones).
        let parts = MessageChunker.split(text, budgetBytes: await messenger.chunkTextBudget())
        guard parts.count <= PQRCConstants.maxChunksPerMessage else {
            throw PQRCError.plaintextExceedsInlineLimit(size: text.utf8.count)
        }

        // Show the sender's OWN copy immediately, BEFORE publishing. Delivery
        // (especially a large, chunked paste over a slow/flaky relay) must never
        // leave you staring at an empty chat: the bubble is local and shouldn't
        // depend on the relay round-trip succeeding. Status is local-only and
        // never claims "delivered" (D5).
        // `localTextOverride` lets the locally-stored copy differ from the wire body —
        // the §13.5 watch-along path stores the OWNER's RAW answer locally while the
        // wire carries the redacted text (only the owner ever sees the secret).
        let message = StoredMessage(
            id: messageID, conversationID: conversationID,
            senderIdentity: identityHex, participantType: participantType,
            text: localTextOverride ?? body.text, sentAt: body.sentAt, threadID: threadID,
            isContext: isContext, aiContext: aiContext,
            localStatus: asSystemRow ? "system" : "sent", agentName: agentName)
        try await store.save(message)
        if let threadID {
            await engine.recordThreadMessage(threadID: threadID, participantType: participantType)
            eventContinuation?.yield(
                .loopGuardChanged(
                    threadID: threadID, paused: await engine.loopGuardActive(threadID: threadID)))
        }
        eventContinuation?.yield(.messageAdded(message))

        // Publish to each recipient (chunked for large text). Best-effort: the
        // message is already on screen, so a per-recipient delivery failure
        // doesn't erase it. `messenger.send` already retries via the outbox.
        var reachedRelay = false
        for recipient in recipients {
            do {
                if parts.count == 1 {
                    try await messenger.send(
                        body, to: recipient, participantType: participantType,
                        aiWindow: aiWindow)
                } else {
                    // Build all chunk bodies and hand them to the batch sender,
                    // which encrypts in order then publishes concurrently.
                    let chunkID = UUID().uuidString
                    let chunkBodies = parts.enumerated().map { i, part -> MessageBody in
                        var chunkBody = body
                        chunkBody.text = part
                        chunkBody.chunk = MessageChunk(id: chunkID, index: i, total: parts.count)
                        return chunkBody
                    }
                    try await messenger.sendBatch(
                        chunkBodies, to: recipient, participantType: participantType,
                        aiWindow: aiWindow)
                }
                await persistSession(recipient)
                reachedRelay = true
            } catch {
                // Delivery to this recipient failed after the outbox's retries.
            }
        }
        // Surface a total publish failure (no recipient reached the relay) as a
        // visible "Not sent" status instead of a silent drop — so the user (and
        // diagnostics) can tell a send failure from a receive failure.
        if !reachedRelay, !asSystemRow, !isLocalGroup {
            try? await store.updateStatus(messageID: message.id, status: "failed")
            if let updated = try? await store.message(id: message.id) {
                eventContinuation?.yield(.messageChanged(updated))
            }
        }

        // Solo AI chat: when I (the tethered human) post into a conversation with
        // no other humans, my AIs reply to me by default — no window needed,
        // because there is no other human to gate against (SPEC §13: the gate
        // protects OTHER people from an unbidden agent; here there are none).
        // Detached so inference never blocks the send. Threads use the invite
        // path instead.
        if participantType == .human, !asSystemRow, threadID == nil,
            isSoloConversation(conversationID), !soloRepliesInFlight.contains(conversationID)
        {
            soloRepliesInFlight.insert(conversationID)
            Task { [weak self] in await self?.runSelfAIReplies(conversationID: conversationID) }
        }
    }

    /// A group I belong to that currently has no other reachable humans — the
    /// "solo AI chat". Becomes a normal group the moment a real contact is added
    /// (then my AIs revert to the window/invite rules).
    private func isSoloConversation(_ conversationID: String) -> Bool {
        groupRosters[conversationID] != nil
            && recipientsFor(conversationID: conversationID).isEmpty
    }

    /// A per-conversation override of "off" (Settings → conversation details)
    /// disables ALL AI activity here — no autonomous posting and no context.
    private func aiSuppressed(in conversationID: String) -> Bool {
        AppSession.conversationContextMode(conversationID, siloID: siloID) == "off"
    }

    /// Each tethered AI replies to me in turn, rebuilding context each time so a
    /// later AI sees what an earlier one just said (Claude + on-device sharing
    /// context). Stays entirely local: a solo conversation has no recipients, so
    /// nothing is published.
    private func runSelfAIReplies(conversationID: String) async {
        defer { soloRepliesInFlight.remove(conversationID) }
        guard !aiSuppressed(in: conversationID) else { return }
        var posted = 0
        var lastError: String?
        for ai in aiSelection.participants(
            from: ais, conversationID: conversationID, threadID: nil)
        {
            // "off" is the silence contract: never invoke a provider whose resolved
            // policy is off here, even if a future selection policy lets it through.
            guard resolvedPolicy(ai, conversationID: conversationID) != "off" else { continue }
            let context = await contextFor(ai, conversationID: conversationID, threadID: nil)
            do {
                // Race generation against a timeout so a wedged/slow on-device
                // model can't leave the chat hanging forever (also frees the
                // in-flight guard). 30 s matches the user-draft timeout budget.
                let draft = try await withThrowingTimeout(seconds: 30) {
                    try await ai.provider.draftReply(context: context)
                }
                let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                try await sendMessage(
                    text, conversationID: conversationID, participantType: .agent, agentName: ai.name)
                posted += 1
            } catch {
                // Keep the precise reason from the provider (e.g. the on-device
                // "Resource unavailable" or a bad API key) for the user.
                if case AgentProviderError.unavailable(let detail) = error {
                    lastError = detail
                } else if case TimeoutError.timedOut = error {
                    lastError = "Your AI took too long to respond. Check Settings ▸ AI."
                } else {
                    lastError = (error as NSError).localizedDescription
                }
            }
        }
        // Don't leave the user staring at silence when every AI failed — the
        // whole point of Bug-2's fix is that the AI never claims to work and then
        // does nothing.
        if posted == 0, let lastError {
            eventContinuation?.yield(.agentError(lastError))
        }
    }

    /// Creates a solo AI chat: a group with only me, where my tethered AIs
    /// engage by default. People can be added later (it becomes a normal group).
    /// The AI is "on" from creation, so it ingests messages from here forward.
    func createSelfChat() async throws -> String {
        // createGroup turns the AI on for a member-less group, so this is just a
        // named solo group.
        try await createGroup(name: "My AI", memberIdentityHexes: [])
    }

    /// Adds verified contacts to a group/solo conversation (the "add people at
    /// any time" path). Once a real human is in, my AIs stop auto-replying and
    /// the window/invite rules apply again.
    func addMembers(conversationID: String, add identityHexes: [String]) async throws {
        guard let roster = groupRosters[conversationID] else { return }
        let members = Array(Set(roster.members + identityHexes))
        try await reviseRoster(groupID: conversationID, name: roster.name, members: members)
    }

    /// Names of my tethered AIs, for the Settings "AI context" view.
    func tetheredAINames() -> [String] { ais.map(\.name) }

    /// A peer's locally-generated AI codename, if known (never broadcast).
    func contactAIName(_ identityHex: String) -> String? {
        contactRecords[identityHex]?.autoAIName
    }

    /// The exact transcript the tethered LLM(s) receive for a conversation —
    /// surfaced read-only in Settings so the user can see what their AI sees.
    func contextPreview(conversationID: String, threadID: String? = nil) async -> [ContextPreviewLine] {
        let context = await agentContext(conversationID: conversationID, threadID: threadID)
        return context.transcript.map { entry in
            ContextPreviewLine(
                role: entry.participantType == .agent
                    ? "\(entry.senderDisplayName)'s AI" : entry.senderDisplayName,
                text: entry.text,
                shared: entry.isSharedContext)
        }
    }

    // MARK: - Context inspector (read-only, per-AI; backs AIContextInspectorView)

    /// One assembled context window for one tethered AI — EXACTLY what it would
    /// receive for a conversation/thread right now: the system prompt (its honest,
    /// resolved text), the gather policy + depth, and every transcript entry. For
    /// a REMOTE AI with the egress firewall on, names are already codename-redacted
    /// (the same boundary `contextFor` crosses), so the inspector never shows a
    /// remote vendor something the model wouldn't see. Read-only.
    struct AIContextInspection: Sendable, Identifiable {
        let id: String  // the tethered AI's id
        let aiName: String
        let isRemote: Bool
        let firewallOn: Bool
        /// Engine policy actually in effect ("active" | "strict" | "off"), after
        /// the per-conversation override is applied.
        let effectivePolicy: String
        let depth: Int
        /// The system/instructions text the model receives this turn (draft prompt
        /// for a conversation, the composed guardrails+skills override for a thread).
        let systemPrompt: String
        let entries: [Entry]

        struct Entry: Sendable, Identifiable {
            let id: String  // the stored message id — drives the include/exclude toggle
            let role: String
            let text: String
            let isAgent: Bool
            let isMine: Bool
            /// Whether this message is currently marked "Add to AI Context".
            let marked: Bool
            /// Whether it's a peer's message a sharing grant authorized.
            let shared: Bool
            /// True when it's included by the live policy (window/solo) rather than
            /// by an explicit mark — so the UI can explain why excluding it needs
            /// the gather mode changed, not just an un-mark.
            let includedByPolicy: Bool
        }
    }

    /// Assemble the inspector view for every tethered AI for one conversation/
    /// thread. Mirrors `contextFor` precisely (same policy resolution, same depth,
    /// same redaction) so what the user inspects is what the AI gets.
    func contextInspections(conversationID: String, threadID: String? = nil) async
        -> [AIContextInspection]
    {
        var out: [AIContextInspection] = []
        // Per-conversation firewall override wins over the account default (same
        // resolution as contextFor), so the inspector shows the EFFECTIVE state.
        let firewallOn = AppSession.conversationFirewall(conversationID, siloID: siloID) ?? firewallEnabled
        for ai in ais {
            // Resolve the effective gather policy exactly as contextFor does: the
            // per-conversation override (Settings ▸ conversation details) wins.
            var policy = ai.contextPolicy
            switch AppSession.conversationContextMode(conversationID, siloID: siloID) {
            case "off": policy = "off"
            case "marked": policy = "strict"
            case "full": policy = "active"
            default: break
            }
            // The honest system-prompt text + redaction state this AI receives.
            let ctx = await contextFor(ai, conversationID: conversationID, threadID: threadID)
            let systemPrompt = threadID == nil ? ctx.draftSystemPrompt() : ctx.turnSystemPrompt()
            let redact = ai.isRemote && firewallOn

            var entries: [AIContextInspection.Entry] = []
            if policy != "off" {
                let visible = await visibleContextMessages(
                    conversationID: conversationID, threadID: threadID,
                    depth: ai.contextDepth, strict: policy == "strict")
                entries = visible.map { item in
                    let message = item.message
                    let isMine = message.senderIdentity == identityHex
                    let isAgent = message.participantType == .agent
                    // Same codename rule as redactedForRemote, but keep the id.
                    let display: String
                    if redact {
                        display =
                            isMine ? "you" : (contactRecords[message.senderIdentity]?.autoName ?? "a contact")
                    } else {
                        display =
                            isMine ? displayName : (contactRecords[message.senderIdentity]?.displayName ?? "Contact")
                    }
                    return AIContextInspection.Entry(
                        id: message.id,
                        role: isAgent ? "\(display)'s AI" : display,
                        text: message.text,
                        isAgent: isAgent,
                        isMine: isMine,
                        marked: message.aiContext,
                        shared: item.shared,
                        // Included by live policy when it's NOT a marked message
                        // (a marked message would be included even when off/strict).
                        includedByPolicy: policy == "active" && !message.aiContext)
                }
            }
            out.append(
                AIContextInspection(
                    id: ai.id, aiName: ai.name, isRemote: ai.isRemote,
                    firewallOn: firewallOn, effectivePolicy: policy,
                    depth: ai.contextDepth, systemPrompt: systemPrompt, entries: entries))
        }
        return out
    }

    // MARK: - Egress-firewall-redacted accessors for the local MCP server (A35 Phase 2)

    /// The SAME egress firewall the remote-AI path uses (`redactedForRemote`),
    /// reduced to the codename rule a local MCP client may see: my messages →
    /// "you", a peer's → that contact's LOCAL `autoName` (never a real display
    /// name, NEVER identity hex), and text byte-bounded to the 64 KB cap so no
    /// single multi-MB paste can leave the device unbounded. Read-only: no engine
    /// or crypto state is touched. Backs `RuntimeSecureChatBridge`.
    private func mcpCodename(for senderIdentityHex: String) -> String {
        senderIdentityHex == identityHex
            ? "you"
            : (contactRecords[senderIdentityHex]?.autoName ?? "a contact")
    }

    /// A redacted conversation TITLE for the MCP bridge — a group's name or the
    /// contact's local codename, NEVER an identity-hex fallback. The UI's
    /// `displayName` can degrade to "Contact <hex>", and the bridge's "never
    /// identity hex" guarantee must be absolute (security audit, 2026-06-15). Uses
    /// the same source as `mcpCodename` for consistency with sender redaction.
    func mcpConversationTitle(_ conversationID: String) -> String {
        if let group = groupRosters[conversationID]?.name, !group.isEmpty { return group }
        return contactRecords[conversationID]?.autoName ?? "a contact"
    }

    /// At most 64 KB of UTF-8 (invariant 4 bound), truncated on a code-point
    /// boundary so the firewall never emits a torn scalar.
    private func mcpBounded(_ text: String) -> String {
        let cap = 64 * 1024
        guard text.utf8.count > cap else { return text }
        var truncated = ""
        var used = 0
        for character in text {
            let cost = String(character).utf8.count
            if used + cost > cap { break }
            truncated.append(character)
            used += cost
        }
        return truncated
    }

    /// One firewall-redacted message for the MCP bridge (codename sender, honest
    /// role, byte-bounded text). Already egress-safe.
    struct MCPRedactedLine: Sendable {
        let conversationID: String
        let sender: String
        let role: String
        let text: String
        let sentAt: Int64
    }

    /// Recent top-level (non-thread) messages of a conversation, firewall-redacted.
    func mcpMessages(conversationID: String, limit: Int) async -> [MCPRedactedLine] {
        let stored = ((try? await store.messages(conversationID: conversationID)) ?? [])
            .filter { $0.threadID == nil }
            .suffix(max(0, limit))
        return stored.map { message in
            MCPRedactedLine(
                conversationID: conversationID,
                sender: mcpCodename(for: message.senderIdentity),
                role: message.participantType.rawValue,
                text: mcpBounded(message.text),
                sentAt: message.sentAt)
        }
    }

    /// Case-insensitive substring search across every persisted conversation,
    /// firewall-redacted, newest first, capped at `limit`.
    func mcpSearch(query: String, limit: Int) async -> [MCPRedactedLine] {
        guard limit > 0, !query.isEmpty else { return [] }
        var hits: [MCPRedactedLine] = []
        for conversationID in (try? await store.conversationIDsWithMessages()) ?? [] {
            let stored = ((try? await store.messages(conversationID: conversationID)) ?? [])
                .filter { $0.threadID == nil && $0.text.localizedCaseInsensitiveContains(query) }
            for message in stored {
                hits.append(
                    MCPRedactedLine(
                        conversationID: conversationID,
                        sender: mcpCodename(for: message.senderIdentity),
                        role: message.participantType.rawValue,
                        text: mcpBounded(message.text),
                        sentAt: message.sentAt))
            }
        }
        return Array(hits.sorted { $0.sentAt > $1.sentAt }.prefix(limit))
    }

    /// Exactly what the user's AI sees for a conversation, run through the SAME
    /// redaction (`redactedForRemote`) the remote-AI egress path applies — the
    /// "what your AI sees" preview, codename-redacted and already byte-bounded.
    func mcpContextPreview(conversationID: String) async -> [MCPRedactedLine] {
        let context = redactedForRemote(
            await agentContext(conversationID: conversationID, threadID: nil))
        return context.transcript.map { entry in
            MCPRedactedLine(
                conversationID: conversationID,
                sender: entry.senderDisplayName,  // already "you" / autoName via redaction
                role: entry.participantType.rawValue,
                text: entry.text,  // agentContext already applied the 64 KB bound
                sentAt: 0)
        }
    }

    // MARK: - MCP write actions (A35 Phase 3 — reuse existing paths, invariants 8+9)

    /// Whether the human currently has an ai_window OPEN for this conversation —
    /// the SAME source of truth `agentContext` uses to decide the AI may participate
    /// (engine-validated, human-signed, time-bounded). This is the gate for
    /// `mcpSendAsMyAI`: an MCP client may only make my AI speak here while this is
    /// true (CLAUDE.md invariant 9 / SPEC §13).
    private func aiWindowActive(conversationID: String) async -> Bool {
        await engine.activeWindow(for: identityHex) != nil
            && myWindowConversationID == conversationID
    }

    /// Stage a DRAFT reply for the human via the existing `draftReply` path. NEVER
    /// sends — it only returns text the UI/agent can present for the human to send
    /// or discard. The returned body is byte-bounded to the same 64 KB egress cap so
    /// a draft can't smuggle an unbounded payload back to the MCP client.
    func mcpDraftReply(conversationID: String, text proposed: String) async -> MCPDraftOutcome {
        // Prefer a model-drafted reply (the real "draft my reply" feature). If the
        // provider is unavailable, fall back to staging the caller's proposed text —
        // either way nothing is sent.
        if let drafted = try? await draftReply(conversationID: conversationID).text,
            !drafted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return .drafted(mcpBounded(drafted))
        }
        let fallback = mcpBounded(proposed)
        guard !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed("Could not produce a draft (no AI reply and no proposed text).")
        }
        return .staged(fallback)
    }

    /// Outcome of an MCP draft request. The draft is NEVER sent; this only stages it.
    enum MCPDraftOutcome: Sendable {
        /// The AI produced a reply for the human to review.
        case drafted(String)
        /// No AI reply was available; the caller's proposed text was staged as-is.
        case staged(String)
        case failed(String)
    }

    /// Mark/unmark messages as AI context via the existing `markAsAIContext` path
    /// (mirrors my own marks to the peer, author-guarded). Local marker change only.
    func mcpMarkAIContext(conversationID: String, messageIDs: [String], value: Bool) async -> Int {
        guard !messageIDs.isEmpty else { return 0 }
        await markAsAIContext(messageIDs: messageIDs, value: value, conversationID: conversationID)
        return messageIDs.count
    }

    /// Post an AGENT-LABELED message via the existing `sendAsMyAI` path
    /// (`participant_type == .agent`, so it renders as AI-authored — invariant 8),
    /// but ONLY while an ai_window is active for this conversation. With no active
    /// window it FAILS CLOSED: it sends nothing and returns the refusal reason, so
    /// an MCP client can never make EldrChat speak to others outside a visible,
    /// human-opened window (invariant 9 / SPEC §13).
    func mcpSendAsMyAI(conversationID: String, text: String) async -> MCPSendOutcome {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failedClosed("Refused: empty message.")
        }
        guard await aiWindowActive(conversationID: conversationID) else {
            return .failedClosed(
                "No active AI window for this conversation — EldrChat will not send autonomously. "
                    + "Ask the human to open an AI window for this conversation first, then retry.")
        }
        do {
            // Reuses sendMessage(.agent): same wire format, same crypto, honest label.
            try await sendAsMyAI(text, conversationID: conversationID)
            return .sent
        } catch {
            return .failedClosed("Send failed: \(error.localizedDescription)")
        }
    }

    /// Outcome of an MCP `send_as_my_ai`. `failedClosed` is the window-gate refusal
    /// (or a delivery error) — surfaced to the client, never a silent drop.
    enum MCPSendOutcome: Sendable {
        case sent
        case failedClosed(String)
    }

    /// Removes a stored message (tap-to-retry drops the failed copy first).
    func deleteMessage(_ id: String) async {
        try? await store.deleteMessage(messageID: id)
    }

    private func recipientsFor(conversationID: String) -> [String] {
        if let roster = groupRosters[conversationID] {
            return roster.members.filter { $0 != identityHex && verifiedContacts[$0] != nil }
        }
        return verifiedContacts[conversationID] != nil ? [conversationID] : []
    }

    // MARK: - Groups (D1)

    func createGroup(name: String, memberIdentityHexes: [String]) async throws -> String {
        let groupID = UUID().uuidString
        let members = [identityHex] + memberIdentityHexes
        let create = GroupCreate(groupID: groupID, name: name, members: members, revision: 1)
        groupRosters[groupID] = GroupRoster(create: create, assertedBy: identityHex)
        persistRoster(groupID)
        // A group with no other humans is a solo AI space: turn my AIs "on" from
        // creation so they ingest messages from here forward (without this the
        // context filter starts at Int64.max and the AI sees an empty transcript
        // until a window is opened — the "AI replied but ignored what I said"
        // bug). A group WITH other humans stays gated behind a window/invite.
        if memberIdentityHexes.isEmpty {
            aiActiveSince[groupID] = clock.now()
        }
        try await sendMessage(
            "created the group \"\(name)\"", conversationID: groupID, groupCreate: create,
            asSystemRow: true)
        eventContinuation?.yield(.conversationChanged(groupID))
        return groupID
    }

    private func persistRoster(_ groupID: String) {
        guard let roster = groupRosters[groupID] else { return }
        let meta = ConversationMeta(
            name: roster.name, memberIdentityHexes: roster.members,
            rosterAssertedBy: roster.assertedBy, rosterRevision: roster.revision,
            groupID: roster.groupID)
        let store = store
        Task { try? await store?.saveConversationMeta(id: groupID, type: "group", meta: meta) }
    }

    private func persistThread(_ threadID: String) {
        guard let conversationID = threadConversations[threadID] else { return }
        let meta = ThreadMeta(
            title: threadTitles[threadID] ?? "Thread", createdBy: identityHex, anchorMessageID: nil)
        let store = store
        Task {
            try? await store?.saveThreadMeta(
                threadID: threadID, conversationID: conversationID, meta: meta)
        }
    }

    func groupRoster(_ groupID: String) -> GroupRoster? {
        groupRosters[groupID]
    }

    func reviseRoster(groupID: String, name: String, members: [String]) async throws {
        guard let roster = groupRosters[groupID] else { return }
        let create = GroupCreate(
            groupID: groupID, name: name, members: members, revision: roster.revision + 1)
        var updated = roster
        _ = updated.apply(create, assertedBy: identityHex)
        groupRosters[groupID] = updated
        persistRoster(groupID)
        // Announce to the union of old and new members so removed members learn.
        let union = Set(roster.members + members).filter { $0 != identityHex && verifiedContacts[$0] != nil }
        let body = MessageBody(
            text: "updated the group", sentAt: clock.now(),
            group: RumorContent.GroupRef(id: groupID), groupCreate: create)
        for member in union {
            try await messenger.send(body, to: member, participantType: .human)
        }
        eventContinuation?.yield(.conversationChanged(groupID))
    }

    // MARK: - Threads & AI (SPEC §13, APP-SPEC §8–9)

    func createThread(conversationID: String, title: String) async throws -> String {
        let threadID = UUID().uuidString
        threadConversations[threadID] = conversationID
        threadTitles[threadID] = title
        persistThread(threadID)
        let create = ThreadCreate(
            threadID: threadID, title: title, anchorMessageID: nil, createdBy: identityHex)
        try await sendMessage(
            "started the thread \"\(title)\"", conversationID: conversationID,
            threadID: threadID, threadCreate: create, asSystemRow: true)
        eventContinuation?.yield(
            .threadCreated(conversationID: conversationID, threadID: threadID, title: title))
        return threadID
    }

    func draftReply(
        conversationID: String, threadID: String? = nil, focus: String? = nil
    ) async throws -> Draft {
        let primary = primaryAI(conversationID: conversationID, threadID: threadID)
        var context = await contextFor(
            primary, conversationID: conversationID, threadID: threadID)
        if let focus, !focus.isEmpty {
            // "Have my AI answer this" — focus the draft on the specific message the user
            // long-pressed. It's already in `context.transcript` (redacted there for a
            // remote AI); a directive points the model at THAT one. Scrub it for a remote
            // AI with the firewall on so a secret in the message can't ride along raw.
            let firewallOn =
                AppSession.conversationFirewall(conversationID, siloID: siloID) ?? firewallEnabled
            let safe =
                (primary.appliesEgressFirewall && firewallOn)
                ? CredentialRedactor.scrub(focus) : focus
            let directive =
                "Answer THIS specific message from the conversation, directly and helpfully: \"\(safe)\""
            let merged = [context.instructions, directive].compactMap { $0 }
                .joined(separator: "\n\n")
            context = AgentContext(
                myIdentityHex: context.myIdentityHex, myDisplayName: context.myDisplayName,
                transcript: context.transcript, threadID: context.threadID,
                threadTitle: context.threadTitle, instructions: merged,
                summarize: context.summarize, systemPromptOverride: context.systemPromptOverride)
        }
        return try await engine.draft(provider: primary.provider, context: context)
    }

    /// Diagnostic for Settings "Test AI now": run the active provider against a
    /// fixed sample so the user sees a real reply or the precise failure reason,
    /// independent of whether any conversation exists yet.
    func probeAI() async throws -> String {
        let sample = AgentContext(
            myIdentityHex: identityHex, myDisplayName: displayName,
            transcript: [
                TranscriptEntry(
                    senderIdentityHex: "sample", senderDisplayName: "Test",
                    participantType: .human, text: "Hi! Are you working? Reply in one short sentence.")
            ])
        return try await engine.draft(
            provider: primaryProvider(conversationID: "", threadID: nil), context: sample).text
    }

    func startAIWindow(conversationID: String, durationSeconds: Int64) async throws {
        let announcement = try await engine.startMyWindow(durationSeconds: durationSeconds)
        myWindowConversationID = conversationID
        // AI is on as of now: it ingests messages from here forward, not history.
        aiActiveSince[conversationID] = clock.now()
        try await sendMessage(
            "enabled always-on AI", conversationID: conversationID, aiWindow: announcement,
            asSystemRow: true)
        eventContinuation?.yield(
            .aiWindowChanged(
                conversationID: conversationID, identityHex: identityHex,
                activeUntil: announcement.activeUntil))
    }

    func inviteMyAI(threadID: String, durationSeconds: Int64) async throws {
        guard let conversationID = threadConversations[threadID] else { return }
        let invite = try await engine.startMyInvite(
            threadID: threadID, durationSeconds: durationSeconds)
        aiActiveSince[threadID] = clock.now()
        try await sendMessage(
            "invited their AI to the thread", conversationID: conversationID,
            threadID: threadID, aiInvite: invite)
        eventContinuation?.yield(
            .aiInviteChanged(
                threadID: threadID, identityHex: identityHex, activeUntil: invite.activeUntil))
        // My agent may open the thread conversation immediately.
        await takeAgentThreadTurn(threadID: threadID)
    }

    func withdrawMyAI(threadID: String) async {
        await engine.withdrawMyInvite(threadID: threadID)
        eventContinuation?.yield(
            .aiInviteChanged(threadID: threadID, identityHex: identityHex, activeUntil: nil))
    }

    func sendAsMyAI(_ text: String, conversationID: String) async throws {
        try await sendMessage(text, conversationID: conversationID, participantType: .agent)
    }

    /// The EXACT messages the AI would see for this scope, with the per-message
    /// `shared` flag — the single source of truth for both `agentContext` (what's
    /// actually sent) and the read-only context inspector (what the user is
    /// shown). Pure read: store + grants + settings, no engine mutation.
    /// `strict` forces marked-context-only even while the AI is active.
    private func visibleContextMessages(
        conversationID: String, threadID: String?, depth: Int, strict: Bool
    ) async -> [(message: StoredMessage, shared: Bool)] {
        let stored: [StoredMessage]
        if let threadID {
            stored = (try? await store.messages(threadID: threadID)) ?? []
        } else {
            stored = (try? await store.messages(conversationID: conversationID)) ?? []
        }
        // Scope for context-sharing authorization (DEVIATIONS N24).
        let scope: AIContextGrant.Scope =
            threadID.map { AIContextGrant.Scope.thread($0) } ?? .conversation(conversationID)
        let sharingAuthorized = await engine.contextSharingAuthorized(scope: scope)

        // Is my AI actively engaged here? Only then does it ingest live messages
        // — and even then ONLY from the moment it was turned on (aiActiveSince),
        // never prior chat history. When off (the DEFAULT) it sees ONLY messages
        // the human explicitly marked "Add to AI Context". Either way, a peer's
        // message is included only when a bilateral grant authorizes it
        // (DEVIATIONS A21, b7 user request, privacy-first SPEC §0).
        let aiActive: Bool
        if let threadID {
            aiActive = await engine.activeInvite(threadID: threadID, identityHex: identityHex) != nil
        } else {
            let windowLive =
                await engine.activeWindow(for: identityHex) != nil
                && myWindowConversationID == conversationID
            aiActive = windowLive || isSoloConversation(conversationID)
        }
        // A "strict" gather policy (per-AI or a per-conversation "marked only"
        // override) forces marked-context-only even while the AI is active.
        let effectiveActive = aiActive && !strict
        let since = aiActiveSince[threadID ?? conversationID] ?? Int64.max
        let recent = stored.filter { message in
            // While the AI is on, it reads the LIVE conversation from the moment
            // it was turned on (the window/invite/solo state is the authorization
            // to participate) — but never messages from before that.
            if effectiveActive, message.sentAt >= since { return true }
            // Otherwise only manually-marked context: mine always; a peer's only
            // under an active bilateral grant.
            if message.aiContext {
                return message.senderIdentity == identityHex || sharingAuthorized
            }
            return false
        }.suffix(depth)
        // Byte-bound the window: keep the most recent entries whose combined text
        // fits a budget, so a few multi-MB pastes can't balloon memory or a remote
        // payload (the AI-to-AI OOM cap). Always keep at least the newest message.
        var budget = 64 * 1024
        var bounded: [StoredMessage] = []
        for message in recent.reversed() {
            let cost = message.text.utf8.count
            if !bounded.isEmpty, budget - cost < 0 { break }
            bounded.append(message)
            budget -= cost
        }
        let visible = Array(bounded.reversed())
        return visible.map { message in
            let isMine = message.senderIdentity == identityHex
            // A message flagged "Add to AI Context" is elevated to shared
            // context the agent treats specially: my own marked messages always
            // (my AI, my content); a peer's only when BOTH humans granted in
            // this scope — default-deny otherwise (invariant 9, privacy).
            let shared = message.aiContext && (isMine || sharingAuthorized)
            return (message, shared)
        }
    }

    private func agentContext(
        conversationID: String, threadID: String?, depth: Int = ConfiguredAI.defaultDepth,
        strict: Bool = false, instructions: String? = nil, summarize: Bool = false,
        systemPromptOverride: String? = nil
    ) async -> AgentContext {
        let visible = await visibleContextMessages(
            conversationID: conversationID, threadID: threadID, depth: depth, strict: strict)
        let transcript = visible.map { entry -> TranscriptEntry in
            let message = entry.message
            let isMine = message.senderIdentity == identityHex
            return TranscriptEntry(
                senderIdentityHex: message.senderIdentity,
                senderDisplayName: isMine
                    ? displayName : (contactRecords[message.senderIdentity]?.displayName ?? "Contact"),
                participantType: message.participantType,
                text: message.text,
                isContext: message.isContext,
                isSharedContext: entry.shared)
        }
        return AgentContext(
            myIdentityHex: identityHex, myDisplayName: displayName,
            transcript: Array(transcript), threadID: threadID,
            threadTitle: threadID.flatMap { threadTitles[$0] },
            instructions: instructions, summarize: summarize,
            systemPromptOverride: systemPromptOverride)
    }

    /// Runs my agents' turns in a thread (gated entirely by the engine). Each of
    /// my tethered AIs takes a turn in order, rebuilding the context each time so
    /// a later AI sees what an earlier one just posted — that's how multiple AIs
    /// share context back and forth in a thread.
    func takeAgentThreadTurn(threadID: String) async {
        let conversationID = threadConversations[threadID] ?? ""
        guard !conversationID.isEmpty, !aiSuppressed(in: conversationID) else { return }
        for ai in aiSelection.participants(
            from: ais, conversationID: conversationID, threadID: threadID)
        {
            // "off" is the silence contract — never let a provider run here.
            guard resolvedPolicy(ai, conversationID: conversationID) != "off" else { continue }
            _ = await engine.runThreadTurn(
                provider: ai.provider,
                context: await contextFor(ai, conversationID: conversationID, threadID: threadID),
                threadID: threadID,
                agentName: ai.name)
        }
        eventContinuation?.yield(
            .loopGuardChanged(
                threadID: threadID, paused: await engine.loopGuardActive(threadID: threadID)))
    }

    func engineActiveWindow(identityHex: String) async -> Int64? {
        await engine.activeWindow(for: identityHex)
    }

    func engineActiveInvite(threadID: String, identityHex: String) async -> Int64? {
        await engine.activeInvite(threadID: threadID, identityHex: identityHex)
    }

    // MARK: - AI context marking & sharing grants (Features 3–4)

    /// Toggle the "Add to AI Context" marker on local messages. For messages I
    /// authored, mirror the flag to the peer (author-guarded on their side).
    func markAsAIContext(messageIDs: [String], value: Bool, conversationID: String) async {
        for id in messageIDs {
            try? await store.setAIContext(messageID: id, value: value)
            guard let updated = try? await store.message(id: id) else { continue }
            eventContinuation?.yield(.messageChanged(updated))
            if updated.senderIdentity == identityHex {
                await sendContextMark(messageID: id, value: value, conversationID: conversationID)
            }
        }
    }

    /// Content-free control telling the peer to mirror my marker (DEVIATIONS
    /// N25). Not persisted locally — it renders no bubble on either side.
    private func sendContextMark(messageID: String, value: Bool, conversationID: String) async {
        let body = MessageBody(
            text: "", sentAt: clock.now(),
            group: groupRosters[conversationID].map { _ in RumorContent.GroupRef(id: conversationID) },
            aiContextMark: AIContextMark(messageID: messageID, value: value))
        for recipient in recipientsFor(conversationID: conversationID) {
            try? await messenger.send(body, to: recipient, participantType: .human)
            await persistSession(recipient)
        }
    }

    /// Human-only: sign + broadcast a context-sharing grant for a scope, and
    /// record a visible system row (transparency-as-privacy).
    func grantAIContext(
        scope: AIContextGrant.Scope, durationSeconds: Int64,
        conversationID: String, threadID: String? = nil
    ) async throws {
        let grant = try await engine.startMyContextGrant(
            scope: scope, durationSeconds: durationSeconds)
        try await sendMessage(
            "enabled AI context sharing", conversationID: conversationID,
            threadID: threadID, aiContextGrant: grant, asSystemRow: true)
        eventContinuation?.yield(
            .aiContextGrantChanged(
                scopeTag: scope.tag, identityHex: identityHex, activeUntil: grant.activeUntil))
    }

    func withdrawAIContext(scope: AIContextGrant.Scope) async {
        await engine.withdrawMyContextGrant(scope: scope)
        eventContinuation?.yield(
            .aiContextGrantChanged(scopeTag: scope.tag, identityHex: identityHex, activeUntil: nil))
    }

    func engineActiveContextGrant(scope: AIContextGrant.Scope, identityHex: String) async -> Int64? {
        await engine.activeContextGrant(scope: scope, identityHex: identityHex)
    }

    // MARK: - Relay status (Feature 5)

    /// Last-known status of each configured relay (for the Settings indicator).
    func relayStatuses() async -> [RelayStatusInfo] {
        var out: [RelayStatusInfo] = []
        for transport in transports {
            out.append(RelayStatusInfo(url: Self.relayURL(transport), status: await transport.currentStatus()))
        }
        return out
    }

    /// Actively re-check every relay now ("Check now").
    func checkRelays() async -> [RelayStatusInfo] {
        var out: [RelayStatusInfo] = []
        for transport in transports {
            out.append(RelayStatusInfo(url: Self.relayURL(transport), status: await transport.checkConnection()))
        }
        return out
    }

    private static func relayURL(_ transport: any RelayTransport) -> String {
        (transport as? NostrWebSocketTransport)?.url.absoluteString ?? "local"
    }

    // MARK: - Receive pipeline

    private func handle(_ event: MessengerEvent) async {
        switch event {
        case .message(let received):
            await handleReceived(received)
        case .messageRequest(let sender, _):
            // Open-inbox window: the user opted into being reachable by
            // anyone for a bounded time — auto-accept instead of gating.
            if let until = openInboxUntil, until > clock.now() {
                if (try? await acceptMessageRequest(senderNostrPubkeyHex: sender)) != nil {
                    return
                }
            }
            eventContinuation?.yield(.messageRequest(senderNostrPubkeyHex: sender))
        case .protocolViolation(let sender, let reason, _):
            // Red system row (SPEC §13.4) — persisted so it renders in place.
            let row = StoredMessage(
                id: UUID().uuidString, conversationID: sender,
                senderIdentity: sender, participantType: .human,
                text: "⚠️ Protocol violation: \(reason)", sentAt: clock.now(),
                localStatus: "violation")
            try? await store.save(row)
            eventContinuation?.yield(.protocolViolation(conversationID: sender, reason: reason))
            eventContinuation?.yield(.messageAdded(row))
        case .quarantined(_, let reason):
            Log.engine.info("envelope quarantined: \(reason, privacy: .public)")
        case .nearbyContact(let identityHex, _):
            // Binding-verified co-present peer (SPEC §10). Surface it; nothing
            // is established until the user starts a conversation.
            if nearbyContactNames[identityHex] == nil {
                nearbyContactNames[identityHex] = "Nearby · \(String(identityHex.prefix(8)))"
                eventContinuation?.yield(.nearbyDiscovered(identityHex: identityHex))
            }
        }
    }

    /// Buffers one chunk of a chunked message. Returns the fully reassembled
    /// body (text joined in index order, `chunk` cleared) once the final part
    /// arrives, or nil while parts are still outstanding. Buffers are namespaced
    /// per sender so peers can't collide ids, and bounded by `maxChunkBuffers`.
    private func accumulateChunk(_ body: MessageBody, from senderHex: String) -> MessageBody? {
        guard let chunk = body.chunk else { return nil }
        // Reject nonsensical metadata (defensive — a peer can lie about totals).
        guard chunk.total >= 1, chunk.total <= PQRCConstants.maxChunksPerMessage,
            chunk.index >= 0, chunk.index < chunk.total
        else { return nil }

        // A 1-of-1 chunk is just a whole message.
        if chunk.total == 1 {
            var whole = body
            whole.chunk = nil
            return whole
        }

        let key = "\(senderHex):\(chunk.id)"
        chunkArrivalCounter += 1
        var acc =
            chunkBuffers[key]
            ?? {
                var template = body
                template.text = ""
                template.chunk = nil
                return ChunkAccumulator(
                    template: template, total: chunk.total, receivedOrder: chunkArrivalCounter)
            }()
        // Ignore a part whose total disagrees with the first one we saw.
        guard acc.total == chunk.total else { return nil }
        acc.parts[chunk.index] = body.text
        acc.receivedOrder = chunkArrivalCounter

        guard acc.parts.count == acc.total else {
            chunkBuffers[key] = acc
            evictStaleChunkBuffersIfNeeded()
            return nil
        }

        // Complete: join in index order and clear the buffer.
        chunkBuffers[key] = nil
        let ordered = (0..<acc.total).compactMap { acc.parts[$0] }
        guard ordered.count == acc.total else { return nil }  // a gap — drop, don't render partial
        var whole = acc.template
        whole.text = MessageChunker.join(ordered)
        return whole
    }

    /// Bounds the reassembly map: when over capacity, drop the least-recently
    /// touched incomplete buffer. Dangling chunk sets (sender vanished mid-send)
    /// are abandoned rather than retained forever.
    private func evictStaleChunkBuffersIfNeeded() {
        guard chunkBuffers.count > maxChunkBuffers else { return }
        if let oldest = chunkBuffers.min(by: { $0.value.receivedOrder < $1.value.receivedOrder })?.key {
            chunkBuffers[oldest] = nil
        }
    }

    private func handleReceived(_ received: ReceivedMessage) async {
        let senderHex = received.senderIdentityHex
        var conversationID = senderHex
        var body = received.body

        // The ratchet advanced and an envelope was consumed: both survive
        // relaunch (FS makes the old snapshot worthless; the relay will
        // replay this envelope to every fresh subscription).
        await persistSession(senderHex)
        await persistPrekeyState()
        // If that inbound handshake drained our one-time prekeys, top them up
        // and republish — need-based (invariant 11). This MUST run off the
        // receive critical path: it awaits a relay publish, and blocking here
        // would stall message delivery (relay AND Nearby both funnel through
        // handleReceived) whenever the relay is slow. Detached, fire-and-forget.
        Task { [weak self] in await self?.republishIfPrekeysLow() }
        // Persist the dedup id SYNCHRONOUSLY (was fire-and-forget): if the app is
        // killed right after rendering #0, a detached write could be lost, so on
        // relaunch the relay replays the handshake — which, before the
        // processHandshake guard (13d2f86), silently desynced the session. This is
        // a cheap LOCAL write (no relay round-trip, unlike the prekey republish
        // above), so awaiting it doesn't stall delivery. (Security-audit
        // defense-in-depth for the replay-desync fix.)
        let dedupeStore = store
        try? await dedupeStore?.markProcessed(eventID: received.wrapEventID)

        // Chunked large message: each part advanced the ratchet (handled above);
        // buffer until every part is present, then continue with the whole text.
        // Until then there is nothing to render or act on, so we return early.
        if body.chunk != nil {
            guard let whole = accumulateChunk(body, from: senderHex) else { return }
            body = whole
        }

        // Relay-carried MCP frame (Phase D3): an MCP chat-tool REQUEST from the
        // owner's chat-context-sharing `coding_agent` node, riding the message mesh.
        // The C-3 + share-chat-context gate (`isMCPSharingNode`, via
        // `ensureRelayMCPHost`) is what makes this safe: ONLY the paired node the owner
        // explicitly opted into is serviced, and the host answers from the redacting +
        // ai_window-gating `MCPServer` (redaction enforced phone-side, here). A
        // recognized `MCP1|` frame is ALWAYS swallowed (returned), never rendered as
        // chat: if no host exists (consent off / not a coding agent / wrong sender) the
        // phone REFUSES to service it AND drops it — it never reaches the chat path and
        // the node gets no answer. So an un-opted-in or non-owner node learns nothing.
        if RelayMCPTransport.isMCPFrame(body.text) {
            if let host = await ensureRelayMCPHost(nodeHex: senderHex) {
                await host.deliverInbound(body.text)
            }
            return
        }

        // Relay-carried ACP frame (ACPRouterplan Phase 3): an ACP line from the
        // owner's consented `coding_agent` node, riding the message mesh. Route it to
        // that node's transport and RETURN — it is the ACP control channel, NEVER a
        // chat message, so it is neither stored nor rendered. The C-3 gate
        // (`isConsentedCodingAgentNode`) is what makes this safe: only the paired,
        // consented node's frames are admitted; anyone else's "ACP1|…" text falls
        // through to the normal chat path (and renders as the literal text it is).
        // `ensureRelayACPTransport` returns nil for a non-consented sender, so an
        // un-consented node's frame is NOT swallowed here — it stays visible as chat,
        // never silently routed.
        if RelayACPTransport.isACPFrame(body.text),
            let transport = ensureRelayACPTransport(nodeHex: senderHex)
        {
            await transport.deliverInbound(body.text)
            return
        }

        // Watch-along DRAFT (SPEC §13.5 endpoint model): the owner's Mac coding agent
        // produced an answer for THIS phone to voice to the group. Recognize it
        // (agent-signed, from a pinned coding_agent contact, carrying the draft marker),
        // voice it REDACTED as the owner's signed agent, and return — the raw draft is
        // never stored as a 1:1 message; only the owner's local group echo holds the raw.
        if let draft = body.agentDraft, received.participantType == .agent,
            contactType(senderHex) == "coding_agent"
        {
            await voiceCodingAgentDraft(rawText: body.text, draft: draft)
            return
        }

        // Peer self-chosen alias (D11-preserving: arrived over the encrypted
        // session, visible only to us). Local rename still wins.
        if let alias = body.alias, contactRecords[senderHex]?.peerAlias != alias {
            contactRecords[senderHex]?.peerAlias = alias
            persistContact(senderHex)
            eventContinuation?.yield(.conversationChanged(senderHex))
        }
        // Retro-flag control (DEVIATIONS N25): mirror a marker the sender set on
        // their OWN prior message. Author guard — the target must be a message we
        // received from this same sender. Renders nothing.
        if let mark = body.aiContextMark {
            if let target = try? await store.message(id: mark.messageID),
                target.senderIdentity == senderHex
            {
                try? await store.setAIContext(messageID: mark.messageID, value: mark.value)
                if let updated = try? await store.message(id: mark.messageID) {
                    eventContinuation?.yield(.messageChanged(updated))
                }
            }
            return
        }

        // Alias-only control message: nothing to render, nothing to store.
        if body.text.isEmpty, body.alias != nil, body.groupCreate == nil,
            body.threadCreate == nil, body.aiInvite == nil, received.aiWindow == nil
        {
            return
        }

        // Group routing/roster (D1).
        if let create = body.groupCreate {
            var roster = groupRosters[create.groupID]
                ?? GroupRoster(create: create, assertedBy: senderHex)
            _ = roster.apply(create, assertedBy: senderHex)
            groupRosters[create.groupID] = roster
            conversationID = create.groupID
            persistRoster(create.groupID)
            eventContinuation?.yield(.conversationChanged(create.groupID))
        } else if let group = body.group {
            conversationID = group.id
        }

        // Thread bookkeeping (D7).
        if let create = body.threadCreate {
            threadConversations[create.threadID] = conversationID
            threadTitles[create.threadID] = create.title
            persistThread(create.threadID)
            eventContinuation?.yield(
                .threadCreated(
                    conversationID: conversationID, threadID: create.threadID, title: create.title))
        }

        // ai_window announcements: engine-validated; invalid ones are dropped
        // (agents cannot self-activate, SPEC §13.3).
        if let window = received.aiWindow {
            if (try? await engine.receiveWindow(window, fromSenderIdentityHex: senderHex)) != nil {
                eventContinuation?.yield(
                    .aiWindowChanged(
                        conversationID: conversationID, identityHex: senderHex,
                        activeUntil: window.activeUntil))
            }
        }
        if let invite = body.aiInvite {
            if (try? await engine.receiveInvite(invite, fromSenderIdentityHex: senderHex)) != nil {
                eventContinuation?.yield(
                    .aiInviteChanged(
                        threadID: invite.thread.id, identityHex: senderHex,
                        activeUntil: invite.activeUntil))
            }
        }
        // Context-sharing grant (validated at the messenger; engine re-checks —
        // defense in depth). Invalid grants were already stripped to nil.
        if let grant = received.aiContextGrant {
            if (try? await engine.receiveContextGrant(grant, fromSenderIdentityHex: senderHex)) != nil {
                eventContinuation?.yield(
                    .aiContextGrantChanged(
                        scopeTag: grant.scope.tag, identityHex: senderHex,
                        activeUntil: grant.activeUntil))
            }
        }

        // Blob path: resolve the pointer to the real content (SPEC §11).
        // Large content is stored as a bounded preview — rendering hundreds of
        // KB inline produces a six-figure-point bubble that breaks the list.
        var text = body.text
        if let pointer = received.contentPointer,
            let blob = try? await BlobCipher.fetchAndDecrypt(pointer, store: blobStore)
        {
            let full = String(decoding: blob, as: UTF8.self)
            if full.utf8.count > 4096 {
                text = full.prefix(600)
                    + "\n… [\(pointer.sizeBytes / 1024) KB encrypted attachment]"
            } else {
                text = full
            }
        }

        // Control messages render as neutral system rows, not bubbles.
        let isSystemRow =
            received.aiWindow != nil || received.aiContextGrant != nil
            || body.groupCreate != nil || body.threadCreate != nil
        let message = StoredMessage(
            // Reuse the sender's stable id so both devices key this message the
            // same way (older senders omit it → fall back to a fresh id). This is
            // what lets a later ai_context_mark from the peer resolve our copy.
            id: body.messageID ?? UUID().uuidString, conversationID: conversationID,
            senderIdentity: senderHex, participantType: received.participantType,
            text: text, sentAt: body.sentAt, threadID: body.thread?.id,
            isContext: body.isContext ?? false, aiContext: body.aiContext ?? false,
            localStatus: isSystemRow ? "system" : "received")
        try? await store.save(message)
        eventContinuation?.yield(.messageAdded(message))

        // Agent reactions — every gate lives in the engine (fail closed).
        if let threadID = body.thread?.id {
            await engine.recordThreadMessage(
                threadID: threadID, participantType: received.participantType)
            eventContinuation?.yield(
                .loopGuardChanged(
                    threadID: threadID, paused: await engine.loopGuardActive(threadID: threadID)))
            await takeAgentThreadTurn(threadID: threadID)
        } else if received.participantType == .human, senderHex != identityHex,
            !aiSuppressed(in: conversationID)
        {
            // Conversation scope: only during MY active ai_window. Each tethered
            // AI that participates replies in turn (the engine gate fails closed
            // when no window; draft-only/off AIs never auto-post).
            for ai in aiSelection.participants(
                from: ais, conversationID: conversationID, threadID: nil)
            {
                // "off" is the silence contract — never let a provider run here.
                guard resolvedPolicy(ai, conversationID: conversationID) != "off" else { continue }
                _ = await engine.runWindowReply(
                    provider: ai.provider,
                    context: await contextFor(ai, conversationID: conversationID, threadID: nil),
                    agentName: ai.name)
            }
        }
    }

    // MARK: - Store access for the UI

    func messages(conversationID: String) async -> [StoredMessage] {
        (try? await store.messages(conversationID: conversationID)) ?? []
    }

    func messages(threadID: String) async -> [StoredMessage] {
        (try? await store.messages(threadID: threadID)) ?? []
    }

    func threadInfo(threadID: String) -> (conversationID: String, title: String)? {
        guard let conversation = threadConversations[threadID] else { return nil }
        return (conversation, threadTitles[threadID] ?? "Thread")
    }

    /// UI-restore seeds: every conversation with stored messages, and every
    /// known thread — the data behind the relaunch fix.
    func persistedConversationIDs() async -> [String] {
        (try? await store.conversationIDsWithMessages()) ?? []
    }

    func setPinned(_ conversationID: String, pinned: Bool) async {
        try? await store.setPinned(conversationID: conversationID, pinned: pinned)
    }

    /// Deletes a conversation's local history (messages + meta). The contact
    /// and session survive — deleting history is not unfriending.
    func deleteConversation(_ conversationID: String) async {
        try? await store.deleteConversation(conversationID)
    }

    func allThreads() -> [(threadID: String, conversationID: String, title: String)] {
        threadConversations.map { ($0.key, $0.value, threadTitles[$0.key] ?? "Thread") }
    }

    func contactName(_ identityHex: String) -> String {
        identityHex == self.identityHex
            ? (myAlias ?? displayName)
            : (contactRecords[identityHex]?.displayName ?? "Contact")
    }

    func contactInfo(_ identityHex: String) -> (name: String, verified: Bool, blocked: Bool) {
        let record = contactRecords[identityHex]
        return (contactName(identityHex), record?.verified ?? false, record?.blocked ?? false)
    }

    func allContactRecords() -> [ContactRecord] {
        contactRecords.values.sorted { $0.displayName < $1.displayName }
    }

    /// 60-digit safety code in 12 groups (APP-SPEC §6.4, D13).
    func safetyCode(with peerIdentityHex: String) -> String {
        guard let contact = verifiedContacts[peerIdentityHex] else { return "" }
        let keys = [identity.publicKeyData, contact.binding.identityPubkey]
            .sorted { $0.hexString < $1.hexString }
        var digest = sha256(keys[0] + keys[1])
        // Stretch to 60 decimal digits from repeated hashing (display encoding only).
        var digits = ""
        while digits.count < 60 {
            for byte in digest where digits.count < 60 {
                digits += String(byte % 10)
            }
            digest = sha256(digest)
        }
        return stride(from: 0, to: 60, by: 5).map {
            String(digits.dropFirst($0).prefix(5))
        }.joined(separator: " ")
    }
}

/// The engine's only output path, bound to the runtime (recording guarantee).
private struct RuntimeSink: AgentMessageSink {
    let runtime: PersonaRuntime

    func postAgentMessage(_ body: MessageBody, threadID: String, agentName: String?) async throws {
        guard let info = await runtime.threadInfo(threadID: threadID) else {
            throw PQRCError.sessionNotEstablished
        }
        try await runtime.sendMessage(
            body.text, conversationID: info.conversationID, participantType: .agent,
            threadID: threadID, isContext: body.isContext ?? false, agentName: agentName)
    }

    func postAgentReply(_ body: MessageBody, agentName: String?) async throws {
        // The engine only calls this during MY active window; the reply goes to
        // the conversation the window was started in (single scope in v1).
        guard let conversationID = await runtime.windowConversation() else { return }
        try await runtime.sendMessage(
            body.text, conversationID: conversationID, participantType: .agent, agentName: agentName)
    }

    /// §13.5 voicing: `body` (redacted) goes on the wire to the group; `rawText` is the
    /// owner's local-only view. Thread scope routes via the thread's conversation;
    /// conversation scope routes via the draft's target (`voiceInto`, stashed on the
    /// runtime). Signs as the owner's agent (sendMessage `.agent` → owner's agent key).
    func postAgentDraft(
        _ body: MessageBody, rawText: String, threadID: String?, agentName: String?
    ) async throws {
        let conversationID: String
        if let threadID, let info = await runtime.threadInfo(threadID: threadID) {
            conversationID = info.conversationID
        } else if let target = await runtime.draftTargetConversation() {
            conversationID = target
        } else {
            throw PQRCError.sessionNotEstablished
        }
        try await runtime.sendMessage(
            body.text, conversationID: conversationID, participantType: .agent,
            threadID: threadID, agentName: agentName, localTextOverride: rawText)
    }

    /// Surface an autonomous-reply provider failure (window/thread) to the conversation
    /// UI. The engine already logs it and calls this, but the protocol's default impl is
    /// a no-op, so a window reply that failed (unavailable model / bad key) left the user
    /// staring at silence with a running countdown — the "the timer doesn't work" symptom
    /// (BUG-5). The solo path already yields `.agentError`; this gives the window/thread
    /// paths the same visible feedback.
    func reportAgentFailure(_ reason: String, threadID: String?, agentName: String?) async {
        await runtime.surfaceAgentFailure(reason)
    }
}

extension PersonaRuntime {
    /// Bridge `RuntimeSink.reportAgentFailure` to the UI event stream (BUG-5).
    func surfaceAgentFailure(_ reason: String) {
        eventContinuation?.yield(.agentError(reason))
    }

    func windowConversation() -> String? {
        myWindowConversationID
    }

    /// The conversation a watch-along draft is currently being voiced into — read by
    /// `RuntimeSink.postAgentDraft` to route a conversation-scope voicing (§13.5).
    func draftTargetConversation() -> String? {
        pendingDraftTarget
    }

    /// Voice a watch-along DRAFT from the owner's Mac coding agent (§13.5 endpoint
    /// model). Stashes the Mac-named target conversation so the sink can route it, then
    /// runs the raw answer through the engine — which gates on MY (the owner's) active
    /// window/invite and REDACTS the wire copy while preserving the raw for my local
    /// view (the owner sees the real answer; the group sees `‹redacted:…›`, signed with
    /// MY agent key). Fail closed + visible: if my window is off, drop a LOCAL-ONLY note
    /// (never published) so I know to enable it.
    func voiceCodingAgentDraft(rawText: String, draft: AgentDraft) async {
        guard let target = draft.voiceInto, !target.isEmpty else { return }
        pendingDraftTarget = target
        defer { pendingDraftTarget = nil }

        let posted = await engine.voiceAgentDraft(
            rawText: rawText, threadID: draft.threadID, agentName: draft.agentName)
        guard !posted else { return }

        let note = StoredMessage(
            id: UUID().uuidString, conversationID: target, senderIdentity: identityHex,
            participantType: .human,
            text: "Your coding agent replied, but your AI window is off — turn it on to share its answer.",
            sentAt: clock.now(), threadID: draft.threadID, isContext: false, aiContext: false,
            localStatus: "system", agentName: nil)
        try? await store.save(note)
        eventContinuation?.yield(.messageAdded(note))
    }
}

func hexToData(_ hex: String) -> Data {
    Data(hexString: hex) ?? Data()
}

enum TimeoutError: Error { case timedOut }

/// Runs `operation`, throwing `TimeoutError.timedOut` if it doesn't finish in
/// `seconds`. Used to bound autonomous on-device generation so a wedged model
/// can't hang a detached reply task (and keep an in-flight guard stuck).
func withThrowingTimeout<T: Sendable>(
    seconds: Double, _ operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError.timedOut
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
