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
    /// An autonomous AI reply (solo chat / window) failed for every tethered AI —
    /// surfaced so the user sees WHY instead of silence (the Bug-2 philosophy).
    case agentError(String)
    /// Feature 6 / decision #5: I @-mentioned a single one of MY AIs in a shared chat
    /// where it isn't live (no active window / not a solo chat). Posting to the other
    /// people without a window would break fail-closed, so the UI asks me to choose:
    /// draft it privately, or open a brief window for just that AI and post.
    case aiMentionNeedsChoice(conversationID: String, aiID: String, aiName: String)
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
    private var reachabilityEnabled = false
    /// T3 throttle: last time (unix seconds) we re-checked a contact's published
    /// binding for a safety-code change. Bounds relay re-fetches to ~once/24h/contact.
    private var lastBindingCheck: [String: Int64] = [:]
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
    /// C6: My-AI per-AI sub-threads → the tethered AI (ConfiguredAI id) each is
    /// pinned to. Drives the no-invite solo reply + the suppressed-countdown UI.
    private var soloThreadAIID: [String: String] = [:]
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
                // Phase D4 / feature 9 (decision D6) — an INTERACTIVE PTY (open_terminal)
                // may be approved ONCE, not only via the standing autonomous-changes
                // consent. It routes through the SAME human prompt as any mutating tool
                // (Allow once / Always / Deny): standing consent still skips the prompt;
                // "Allow once" opens THIS one shell without flipping standing consent;
                // "Always" flips it. Recognized from the title for the card's wording, but
                // no longer a consent-only fail-closed gate. The node's C-1 timeout still
                // denies an ignored prompt, and the prominent Stop control kills the shell.
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

    /// Resize a live interactive terminal on `nodeHex` (the phone's terminal view
    /// reported a new column/row size). No-op if the node has no live ACP provider.
    func resizeACPTerminal(nodeHex: String, terminalID: String, cols: Int, rows: Int) async {
        await relayACPProviders[nodeHex]?.resizeTerminal(
            terminalId: terminalID, cols: cols, rows: rows)
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
        // Manage ONLY the policies WE install (Default / Capability / Composite);
        // never clobber one a host or test set explicitly via setAISelectionPolicy.
        let oursToManage =
            aiSelection is DefaultAISelectionPolicy<TetheredAI>
            || aiSelection is CapabilityRoutingPolicy<TetheredAI>
            || aiSelection is CompositeAISelectionPolicy<TetheredAI>
            || aiSelection is ConversationRosterPolicy<TetheredAI>
        guard oursToManage else { return }
        // WHO answers: a consented coding-agent node's conversation requires "code"
        // (routes to the acp engine). Empty otherwise ⇒ default selection.
        var map: [String: Set<String>] = [:]
        let codingNodes = verifiedContacts.keys.filter { isConsentedCodingAgentNode($0) }
        if !codingNodes.isEmpty, ais.contains(where: { $0.kind == "acp" }) {
            for node in codingNodes { map[node] = Set(["code"]) }
        }
        // ORDER + MEMBERSHIP: the per-chat roster (the per-AI hub) is the OUTERMOST
        // policy — it filters the candidates to the AIs the user chose for THIS scope
        // and reorders them to the user's reply order (features 4 & 5). Inside it,
        // capability routing (the acp coding node) and the "AIs reply in order"
        // role-tag toggle still apply to the rostered subset. All read LIVE per turn,
        // so changing the roster / toggle needs no policy rebuild. With no roster, an
        // empty map, and no ordered scopes, this behaves exactly like the default.
        let silo = siloID
        aiSelection = ConversationRosterPolicy<TetheredAI>(
            aiID: { $0.id },
            roster: { conversationID, threadID in
                AppSession.conversationAIRoster(threadID ?? conversationID, siloID: silo)
            },
            base: CompositeAISelectionPolicy<TetheredAI>(
                base: CapabilityRoutingPolicy<TetheredAI>(byConversation: map),
                orderedScope: { conversationID, _ in
                    AppSession.orderedCritique(conversationID, siloID: silo)
                }))
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

    /// The owner's paired `coding_agent` node — identity hex + local name — REGARDLESS of
    /// consent. Mirror of `consentedCodingAgentNodeInfo()` WITHOUT the `remoteDevControlConsent`
    /// filter, so a UI (the "My AI" hub) can OFFER to enable its tools, not just report an
    /// already-consented one — the discoverability gap. Deterministic pick (lowest hex) when
    /// more than one is paired. nil when none is paired.
    func pairedCodingAgentNode() -> (identityHex: String, name: String)? {
        guard let hex = verifiedContacts.keys
            .filter({ contactType($0) == "coding_agent" })
            .sorted().first
        else { return nil }
        return (hex, contactName(hex))
    }

    func setFirewallEnabled(_ enabled: Bool) {
        firewallEnabled = enabled
    }

    /// Set the user's per-thread loop-guard limit ("max AI turns", C1). Clamped to
    /// 0…9999 (0 = unlimited); persisted per-silo+thread and applied live to the
    /// engine so a running thread picks it up on its next turn.
    func setThreadLoopGuardLimit(_ value: Int, threadID: String) async {
        let clamped = max(0, min(9999, value))
        AppSession.setThreadLoopGuardLimit(clamped, threadID: threadID, siloID: siloID)
        await engine.setThreadLoopGuardLimit(clamped, threadID: threadID)
    }

    /// T3 — real safety-code-change detection. On a message from a known contact,
    /// re-fetch their published kind-10420 binding (throttled ~24h/contact) and
    /// compare its identity key to the one we verified at pairing. A mismatch means
    /// the contact's identity key rotated — a legit device change OR a MITM — so we
    /// raise the persistent "verify again" banner. Uses `peekBinding` (no auto-adopt:
    /// a changed key must NOT be silently trusted). Degrades safely: a relay failure
    /// SKIPS the check (no false alarm) and clears the throttle so the next message
    /// retries. WARNS, never blocks (the user re-verifies in person to clear it).
    func checkSafetyCode(forContact identityHex: String) async {
        guard let contact = verifiedContacts[identityHex] else { return }
        let now = clock.now()
        if let last = lastBindingCheck[identityHex], now - last < 86_400 { return }
        lastBindingCheck[identityHex] = now
        guard let fresh = try? await messenger.peekBinding(nostrPubkeyHex: contact.nostrPubkeyHex)
        else {
            lastBindingCheck[identityHex] = nil  // relay failed → allow a retry next time
            return
        }
        if fresh.identityPubkey != contact.binding.identityPubkey {
            eventContinuation?.yield(.safetyCodeChanged(identityHex: identityHex))
        }
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
        _ ai: TetheredAI, conversationID: String, threadID: String?, aiRole: String = "primary"
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
        // The user's OWN trusted Mac coding agent (paired + consented) defaults to
        // RAW + CONDUIT: it's their device behind the app's E2EE, not a cloud model
        // to guard against. So the egress firewall defaults OFF for it, and the
        // hard-coded guardrail/window "chaff" is skipped — it gets only the raw
        // transcript + the user's own instructions. An explicit per-conversation
        // setting still wins either way (the user can re-enable the firewall).
        // The auto-OFF firewall + raw "conduit" prompt is for the owner's OWN trusted
        // Mac agent — so it applies ONLY when the AI receiving this context is the
        // "acp" conduit driving the paired node, NOT to any co-tethered cloud AI that
        // happens to reply in the same conversation. Keying it on the conversation
        // alone would fail OPEN: a Claude/OpenAI AI in a consented coding-agent
        // conversation would receive un-redacted real names. Gate on the receiving
        // AI's kind so every remote vendor stays firewalled here (privacy cardinal rule).
        let trustedNode = ai.kind == "acp" && isConsentedCodingAgentNode(conversationID)
        // Per-conversation override (Settings → conversation details) wins over the
        // account default — a private, paired chat with your own agents can pass raw.
        let firewallOn = AppSession.conversationFirewall(conversationID, siloID: siloID)
            ?? (trustedNode ? false : firewallEnabled)
        let redactNames = ai.appliesEgressFirewall && firewallOn
        let promptDisplayName = redactNames ? "you" : displayName
        let promptPeerName =
            redactNames
            ? (contactRecords[conversationID]?.autoName ?? "a contact")
            : (groupRosters[conversationID]?.name ?? contactName(conversationID))
        let override: String?
        if trustedNode {
            // Pure conduit to your own agent: no guardrail/window preamble. The
            // provider falls back to the instructions-only system prompt (empty
            // unless the user set instructions for this AI).
            override = nil
        } else if let tid = threadID {
            let base = AgentSkills.threadSystemPrompt(
                displayName: promptDisplayName,
                contextDomain: AppSession.aiContextDomain(siloID: siloID),
                peerName: promptPeerName,
                threadID: tid,
                activeSkillIDs: AppSession.threadSkills(tid, siloID: siloID),
                instructions: ai.instructions,
                aiRole: aiRole)
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
        // Per-AI isolation gate (feature 1 + D2): build THIS AI's capability so the
        // assembler includes only what it may unseal — its own + my own messages,
        // reply-order siblings, thread co-members, and grant-authorized peer content.
        let cap = await buildCapability(forAI: ai, conversationID: conversationID, threadID: threadID)
        let ctx = await agentContext(
            conversationID: conversationID, threadID: threadID, depth: ai.contextDepth,
            strict: policy == "strict", instructions: ai.instructions, summarize: ai.summarizes,
            systemPromptOverride: override, forAI: cap)
        guard ai.appliesEgressFirewall, firewallOn else { return ctx }
        return redactedForRemote(ctx)
    }

    /// System prompt for a conversation-scope `ai_window` reply. EldrChat is a
    /// conduit: the user's own `instructions` ARE the system prompt — empty by
    /// default, so an active window hands the model the raw transcript and nothing
    /// the user didn't write (the user-request "stop passing chaff"). The old
    /// hard-coded "you are X's AI assistant … reply PASS only if …" preamble is no
    /// longer auto-injected; it's restorable from Settings (`ConfiguredAI`
    /// default-instructions). `displayName`/`peerName` are retained for signature
    /// stability and any future restore-default that wants them. Returns "" when
    /// there's nothing to send; `contextFor` passes it as an explicit (empty)
    /// override so `turnSystemPrompt()` emits no built-in text either.
    private func windowReplySystemPrompt(
        displayName: String, peerName: String, instructions: String?, summarize: Bool
    ) -> String {
        var parts: [String] = []
        if let instructions, !instructions.isEmpty { parts.append(instructions) }
        if summarize {
            parts.append("Prefer a brief summary of the relevant context over verbatim quoting.")
        }
        return parts.joined(separator: "\n\n")
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
            // Loop guard ARMED (plan C1). Multi-AI collaboration means AIs reply to
            // each other IN A THREAD, so an unbounded cascade could run forever (and
            // cost). The guard pauses a thread after N consecutive agent messages and
            // resets the instant a human speaks — a human always stays in the loop
            // (the cardinal rule). AI-to-AI happens only in threads; the main
            // conversation stays human-triggered (see handleReceived dispatch).
            // This account-wide default (50) is the fallback; each thread can override
            // it with a user-set "max AI turns" (0–9999, 0 = unlimited) restored below.
            loopGuardLimit: AppSession.defaultThreadLoopGuardLimit)

        // Restore persisted state: contacts (bindings re-verified — invariant 7
        // survives persistence), ratchet sessions, group rosters, threads, and
        // the processed-envelope set (so relay replays don't re-process).
        if let aliasData = loadSecret("my-alias") {
            myAlias = String(decoding: aliasData, as: UTF8.self)
        }
        // Reachability (permanent open-inbox toggle). Migrate the legacy timed
        // "open-inbox-until" window: a still-future value becomes the toggle ON.
        if loadSecret("reachability-enabled") != nil {
            reachabilityEnabled = true
        } else if let untilData = loadSecret("open-inbox-until"),
            let until = Int64(String(decoding: untilData, as: UTF8.self)), until > clock.now()
        {
            reachabilityEnabled = true
            try? saveSecret(Data("1".utf8), account: "reachability-enabled")
            keychain.delete(account: "open-inbox-until")
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
            if meta.isSoloThread == true, let aid = meta.soloAIID {
                soloThreadAIID[threadID] = aid  // C6: restore the pinned-AI mapping
            }
            // Restore the user's per-thread loop-guard limit (C1); engine falls back
            // to the account-wide default for threads the user never customized.
            await engine.setThreadLoopGuardLimit(
                AppSession.threadLoopGuardLimit(threadID, siloID: siloID), threadID: threadID)
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

    /// True ONLY when this node's ACP channel is carried over a LOCAL link
    /// (NearbyACPTransport / Multipeer LAN), never the relay. The 64 KB context
    /// byte-cap is lifted only here — the relay path must keep it (SPEC §7/§11:
    /// content >64 KB is never inlined on the wire; Blossom pointer / chunking
    /// only, padded to fixed buckets). Conservative by construction: a node we hold
    /// a relay-ACP transport for is, by definition, relayed → not local; otherwise
    /// lift only for a peer present on the local nearby link. Today coding-agent
    /// nodes are relay-bound (`ensureRelayACPTransport`), so this is false for them
    /// and the relayed Huginn path stays capped until a local ACP link is wired.
    private func isLocalTransportNode(_ identityHex: String) -> Bool {
        if relayACPTransports[identityHex] != nil { return false }
        return nearbyContactNames[identityHex] != nil
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

    /// Reachability (open inbox): when ON, messages from anyone are auto-accepted
    /// instead of waiting in Message Requests. A PERMANENT toggle (no timer) that
    /// survives relaunch; the privacy trade is the user's explicit choice
    /// (THREAT_MODEL note). Replaces the legacy time-bounded window.
    func setReachability(_ enabled: Bool) {
        reachabilityEnabled = enabled
        if enabled {
            try? saveSecret(Data("1".utf8), account: "reachability-enabled")
        } else {
            keychain.delete(account: "reachability-enabled")
        }
    }

    func reachabilityIsOpen() -> Bool { reachabilityEnabled }

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
    /// Parse @-mentions (people + tethered AIs) from message text. Matches a single
    /// @token (letters/digits/-/_) against contact display names and AI names
    /// (case-insensitive; an AI wins a name tie so "@<ai>" routes to the AI). At most
    /// one Mention per distinct name. Multi-word display names match only their first
    /// token (MVP). (C2)
    private func resolveMentions(in text: String) -> [MessageBody.Mention] {
        guard text.contains("@") else { return [] }
        var byName: [String: (id: String, kind: String)] = [:]
        for hex in verifiedContacts.keys {
            let n = contactName(hex).lowercased()
            if !n.isEmpty { byName[n] = (hex, "person") }
            // A peer's AI codename routes to THAT PEER's AI (cross-identity @mention,
            // D4) — id is the peer's identity hex, kind "ai". MY own AI still wins a
            // name tie (added after, below).
            if let aiName = contactRecords[hex]?.autoAIName?.lowercased(), !aiName.isEmpty {
                byName[aiName] = (hex, "ai")
            }
        }
        for ai in ais {
            let n = ai.name.lowercased()
            if !n.isEmpty { byName[n] = (ai.id, "ai") }  // MY AI wins a name tie
        }
        var out: [MessageBody.Mention] = []
        var seen = Set<String>()
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            guard chars[i] == "@" else { i += 1; continue }
            var j = i + 1
            var token = ""
            while j < chars.count,
                chars[j].isLetter || chars[j].isNumber || chars[j] == "-" || chars[j] == "_"
            {
                token.append(chars[j])
                j += 1
            }
            let key = token.lowercased()
            if !key.isEmpty, !seen.contains(key), let hit = byName[key] {
                seen.insert(key)
                out.append(MessageBody.Mention(id: hit.id, displayName: token, kind: hit.kind))
            }
            i = j
        }
        return out
    }

    /// @-mention autocomplete candidates for a conversation's composer (feature 6):
    /// MY AIs first, then the conversation's people and THEIR AIs. Names only — the
    /// composer inserts "@name " and `resolveMentions` resolves it on send.
    func mentionCandidates(conversationID: String) -> [(name: String, kind: String)] {
        var out: [(name: String, kind: String)] = []
        var seen = Set<String>()
        func add(_ name: String, _ kind: String) {
            let key = name.lowercased()
            guard !name.isEmpty, !seen.contains(key) else { return }
            seen.insert(key)
            out.append((name, kind))
        }
        for ai in ais { add(ai.name, "ai") }
        let peers: [String]
        if let roster = groupRosters[conversationID] {
            peers = roster.members.filter { $0 != identityHex }
        } else {
            peers = verifiedContacts.keys.contains(conversationID) ? [conversationID] : []
        }
        for hex in peers {
            add(contactName(hex), "person")
            if let aiName = contactRecords[hex]?.autoAIName { add(aiName, "ai") }
        }
        return out
    }

    func sendMessage(
        _ text: String, conversationID: String, participantType: ParticipantType = .human,
        threadID: String? = nil, isContext: Bool = false, aiContext: Bool = false,
        aiWindow: AIWindowAnnouncement? = nil, aiInvite: AIInvite? = nil,
        aiContextGrant: AIContextGrant? = nil,
        threadCreate: ThreadCreate? = nil, groupCreate: GroupCreate? = nil,
        asSystemRow: Bool = false, agentName: String? = nil,
        agentAIID: String? = nil, suppressAutoReply: Bool = false,
        localTextOverride: String? = nil, coauthored: Bool = false
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
            alias: participantType == .human ? myAlias : nil,
            // "Made with you and your AI" co-authorship rides inside the
            // ciphertext so every participant sees it (and only participants —
            // SPEC §0). Set only on the human-directed draft path; autonomous
            // agent sends leave it nil.
            coauthored: coauthored ? true : nil)

        // @-mentions (C2): parse people + tethered AIs from the text and carry them
        // INSIDE the ciphertext (never wire metadata — SPEC §0). Human messages only.
        let mentions = (participantType == .human && !asSystemRow)
            ? resolveMentions(in: text) : []
        if !mentions.isEmpty { body.mentions = mentions }

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
        // Per-AI gate (feature 1): record WHICH of my AIs authored an agent message
        // by its stable ConfiguredAI id. Resolve from the explicit param, else map
        // the friendly `agentName` (the sink paths carry only the name) to its id at
        // authorship time — stable thereafter (a later rename can't retro-change a
        // stored message). nil for human messages; peer agents never author here.
        let resolvedAgentAIID: String? =
            participantType == .agent
            ? (agentAIID ?? ais.first(where: { $0.name == agentName })?.id)
            : nil
        let message = StoredMessage(
            id: messageID, conversationID: conversationID,
            senderIdentity: identityHex, participantType: participantType,
            text: localTextOverride ?? body.text, sentAt: body.sentAt, threadID: threadID,
            isContext: isContext, aiContext: aiContext,
            localStatus: asSystemRow ? "system" : "sent", agentName: agentName,
            coauthored: coauthored, agentAIID: resolvedAgentAIID)
        try await store.save(message)
        if let threadID {
            await engine.recordThreadMessage(threadID: threadID, participantType: participantType)
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
        if participantType == .human, !asSystemRow, !suppressAutoReply, threadID == nil,
            isSoloConversation(conversationID), !soloRepliesInFlight.contains(conversationID)
        {
            soloRepliesInFlight.insert(conversationID)
            Task { [weak self] in await self?.runSelfAIReplies(conversationID: conversationID) }
        }

        // My-AI per-AI sub-thread (C6): a human message in a solo sub-thread → its
        // pinned AI replies (no invite/timer; a 1:1 with my own AI, no other human).
        if participantType == .human, !asSystemRow, !suppressAutoReply, let threadID,
            isSoloThread(threadID), !soloRepliesInFlight.contains(threadID)
        {
            soloRepliesInFlight.insert(threadID)
            Task { [weak self] in await self?.runSoloThreadReply(threadID: threadID) }
        }

        // @-mention of one of MY tethered AIs in a THREAD → that AI takes a turn now
        // (the thread send path doesn't otherwise self-trigger my AIs). Matched by
        // NAME so it targets MY AI of that name; still engine-gated (no active invite
        // ⇒ the turn fails closed and posts nothing). (C2)
        if participantType == .human, !asSystemRow, !suppressAutoReply, let threadID {
            let wanted = Set(mentions.filter { $0.kind == "ai" }.map { $0.displayName.lowercased() })
            let mine = wanted.intersection(Set(ais.map { $0.name.lowercased() }))
            if !mine.isEmpty {
                Task { [weak self] in
                    await self?.takeAgentThreadTurn(threadID: threadID, mentionedAINames: mine)
                }
            }
        }

        // @-mention routing in a REGULAR (non-thread, non-solo) chat (feature 6 + D4):
        //  - 2+ AIs, or ANY peer's AI → spin up / reuse a thread and let them
        //    collaborate there (mutual visibility, bounded by the AI turn limiter);
        //  - exactly one of MY AIs → route per decision #5 (narrow a live window, or
        //    ask the human to draft / open a window when none is live).
        if participantType == .human, !asSystemRow, !suppressAutoReply, threadID == nil,
            !isSoloConversation(conversationID)
        {
            let myAIMentions = mentions.filter { m in m.kind == "ai" && ais.contains { $0.id == m.id } }
            let peerAIMentions = mentions.filter { m in
                m.kind == "ai" && verifiedContacts.keys.contains(m.id)
            }
            if myAIMentions.count + peerAIMentions.count >= 2 || !peerAIMentions.isEmpty {
                let myIDs = myAIMentions.map { $0.id }
                let peerHexes = peerAIMentions.map { $0.id }
                Task { [weak self] in
                    await self?.routeMentionsToCollabThread(
                        conversationID: conversationID, myAIIDs: myIDs, peerHexes: peerHexes,
                        seedText: text)
                }
            } else if let only = myAIMentions.first {
                let aiID = only.id
                Task { [weak self] in
                    await self?.routeSingleMyAIMention(aiID: aiID, conversationID: conversationID)
                }
            }
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
                // TOCTOU guard (H-2): the "solo chat" decision was made BEFORE this 30 s
                // await, during which a human may have been added to the conversation
                // (addMembers → reviseRoster mutates groupRosters, read live by
                // isSoloConversation). An autonomous agent send to a peer with no
                // human-opened ai_window MUST fail closed (invariant #9) — so if this is
                // no longer a solo chat, drop the in-flight reply rather than publish it.
                guard isSoloConversation(conversationID) else { break }
                try await sendMessage(
                    text, conversationID: conversationID, participantType: .agent,
                    agentName: ai.name, agentAIID: ai.id)
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

    /// C6: the pinned AI's reply in a "My AI" per-AI sub-thread. Mirrors
    /// `runSelfAIReplies` (the no-invite solo path — there is no other human to gate
    /// against) but scoped to ONE AI and posted INTO the thread. Gated only by the
    /// solo-thread pin + the AI's own "off" policy; never goes through the engine
    /// invite/window gate — invariant 9 still holds because a solo thread has no other
    /// human (re-checked after the await, in case a human was just added to the parent).
    private func runSoloThreadReply(threadID: String) async {
        defer { soloRepliesInFlight.remove(threadID) }
        guard let conversationID = threadConversations[threadID],
            let aiID = soloThreadAIID[threadID],
            let ai = ais.first(where: { $0.id == aiID }),
            !aiSuppressed(in: conversationID),
            resolvedPolicy(ai, conversationID: conversationID) != "off"
        else { return }
        let context = await contextFor(ai, conversationID: conversationID, threadID: threadID)
        do {
            let draft = try await withThrowingTimeout(seconds: 30) {
                try await ai.provider.draftReply(context: context)
            }
            let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            // Still a solo thread with no other human? (TOCTOU: a human could have been
            // added to the parent during the await — then an ungated agent send must
            // fail closed, invariant 9.)
            guard isSoloThread(threadID), isSoloConversation(conversationID) else { return }
            try await sendMessage(
                text, conversationID: conversationID, participantType: .agent,
                threadID: threadID, agentName: ai.name, agentAIID: ai.id)
        } catch {
            let detail: String
            if case AgentProviderError.unavailable(let d) = error {
                detail = d
            } else if case TimeoutError.timedOut = error {
                detail = "Your AI took too long to respond. Check Settings ▸ AI."
            } else {
                detail = (error as NSError).localizedDescription
            }
            eventContinuation?.yield(.agentError(detail))
        }
    }

    /// Creates a solo AI chat: a group with only me, where my tethered AIs
    /// engage by default. People can be added later (it becomes a normal group).
    /// The AI is "on" from creation, so it ingests messages from here forward.
    func createSelfChat() async throws -> String {
        // createGroup turns the AI on for a member-less group, so this is just a
        // named solo group.
        let groupID = try await createGroup(name: "My AI", memberIdentityHexes: [])
        // C6: a per-AI 1:1 sub-thread for each tethered AI — like a 1:1 chat with that
        // one AI, while the root "My AI" keeps ALL AIs replying. Best-effort; a failure
        // for one AI never blocks the others or the chat itself.
        for ai in ais {
            _ = try? await createSoloAIThread(conversationID: groupID, aiID: ai.id, title: ai.name)
        }
        return groupID
    }

    /// C6: create a "My AI" per-AI sub-thread pinned to ONE tethered AI. Behaves like a
    /// 1:1 with that AI — it replies with no invite/timer (there is no other human to
    /// gate against, same as the solo chat). The pin is recorded so the reply path and
    /// the suppressed-countdown UI can find it.
    @discardableResult
    func createSoloAIThread(conversationID: String, aiID: String, title: String) async throws
        -> String
    {
        let threadID = UUID().uuidString
        threadConversations[threadID] = conversationID
        threadTitles[threadID] = title
        soloThreadAIID[threadID] = aiID
        aiActiveSince[threadID] = clock.now()
        persistThread(threadID)
        let create = ThreadCreate(
            threadID: threadID, title: title, anchorMessageID: nil, createdBy: identityHex)
        try await sendMessage(
            "started a 1:1 with \(title)", conversationID: conversationID,
            threadID: threadID, threadCreate: create, asSystemRow: true)
        eventContinuation?.yield(
            .threadCreated(conversationID: conversationID, threadID: threadID, title: title))
        return threadID
    }

    /// C6: whether a thread is a "My AI" per-AI sub-thread (drives no-invite replies +
    /// the suppressed-countdown UI).
    func isSoloThread(_ threadID: String) -> Bool { soloThreadAIID[threadID] != nil }

    /// Adds verified contacts to a group/solo conversation (the "add people at
    /// any time" path). Once a real human is in, my AIs stop auto-replying and
    /// the window/invite rules apply again.
    func addMembers(conversationID: String, add identityHexes: [String]) async throws {
        guard let roster = groupRosters[conversationID] else { return }
        let members = Array(Set(roster.members + identityHexes))
        try await reviseRoster(groupID: conversationID, name: roster.name, members: members)
    }

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

    // MARK: - Context inspector (read-only, per-AI; backs AIInspectionView)

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
        // Per-conversation firewall override wins over the account default, and a
        // consented coding-agent node defaults OFF — same resolution as contextFor,
        // so the inspector shows the EFFECTIVE state (real names, not codenames, for
        // a trusted node).
        let trustedNode = isConsentedCodingAgentNode(conversationID)
        let firewallOn = AppSession.conversationFirewall(conversationID, siloID: siloID)
            ?? (trustedNode ? false : firewallEnabled)
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
                // The SAME per-AI gate the real assembly uses, so "what THIS AI sees"
                // in the inspector is exactly what it gets (feature 1, P14).
                let cap = await buildCapability(
                    forAI: ai, conversationID: conversationID, threadID: threadID)
                let visible = await visibleContextMessages(
                    conversationID: conversationID, threadID: threadID,
                    depth: ai.contextDepth, strict: policy == "strict", forAI: cap)
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
        let soloAI = soloThreadAIID[threadID]
        let meta = ThreadMeta(
            title: threadTitles[threadID] ?? "Thread", createdBy: identityHex, anchorMessageID: nil,
            isSoloThread: soloAI != nil ? true : nil, soloAIID: soloAI)
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

    func createThread(
        conversationID: String, title: String, anchorMessageID: String? = nil
    ) async throws -> String {
        let threadID = UUID().uuidString
        threadConversations[threadID] = conversationID
        threadTitles[threadID] = title
        persistThread(threadID)
        let create = ThreadCreate(
            threadID: threadID, title: title, anchorMessageID: anchorMessageID,
            createdBy: identityHex)
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

    /// Draft privately with a SPECIFIC one of my AIs (feature 6, decision #5 "Draft
    /// privately"). Falls back to the policy primary if the id is unknown.
    func draftReply(conversationID: String, withAIID aiID: String) async throws -> Draft {
        guard let ai = ais.first(where: { $0.id == aiID }) else {
            return try await draftReply(conversationID: conversationID)
        }
        let context = await contextFor(ai, conversationID: conversationID, threadID: nil)
        return try await engine.draft(provider: ai.provider, context: context)
    }

    /// Open a brief window for the conversation and have ONE of my AIs post now
    /// (feature 6, decision #5 "Open window & post"). The window announcement is the
    /// usual human-signed, visible affordance — this just also fires that AI's turn.
    func openWindowAndPost(
        aiID: String, conversationID: String, durationSeconds: Int64 = 15 * 60
    ) async throws {
        try await startAIWindow(conversationID: conversationID, durationSeconds: durationSeconds)
        guard let ai = ais.first(where: { $0.id == aiID }),
            resolvedPolicy(ai, conversationID: conversationID) != "off"
        else { return }
        _ = await engine.runWindowReply(
            provider: ai.provider,
            context: await contextFor(ai, conversationID: conversationID, threadID: nil),
            conversationID: conversationID, agentName: ai.name, agentAIID: ai.id)
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

    /// Stop MY AI from autonomously replying in this conversation, NOW — the honest,
    /// single "off switch" behind the in-chat control. It (1) closes the on-wire
    /// ai_window for this conversation so every peer's "AI active" indicator AND any
    /// owner-gated Mac bridge node (`isAuthorizedForOwner`) clear; (2) withdraws the
    /// conversation-scope context-sharing grant (the old button's only job); and
    /// (3) for a solo "My AI" chat — which has no window, only `runSelfAIReplies`
    /// gated by `aiSuppressed` — flips the per-conversation context mode to "off".
    /// Message-driven and fail-closed: the closing announcement carries a past
    /// `activeUntil`, so it can only ever REVOKE, never self-activate (SPEC §13,
    /// invariant 9). Idempotent — safe to call when nothing is active.
    func endMyAIWindow(conversationID: String) async {
        // Solo "My AI" space: replies come from `runSelfAIReplies`, gated ONLY by
        // `aiSuppressed` (context mode "off") — there is no window to close. Mute it
        // so the AI actually goes silent. (The re-enable path clears this again.)
        if isSoloConversation(conversationID) {
            AppSession.setConversationContextMode(
                "off", conversationID: conversationID, siloID: siloID)
        }
        // Does a live window for THIS conversation need an on-wire close (so peers +
        // the bridge node drop it)? Only my own window, only for this conversation.
        // (Compute the await separately — `&&` takes an autoclosure that can't await.)
        let windowLive = (await engine.activeWindow(for: identityHex)) != nil
        // The engine holds ONE global window slot keyed on my identity, so it must be
        // cleared ONLY when the window belongs to THIS conversation. `mineHere` is that
        // test; `hadWindow` additionally requires it to be live (for the on-wire close).
        let mineHere = myWindowConversationID == conversationID
        let hadWindow = mineHere && windowLive
        // Clear the engine gate iff the window is mine-here — live OR a stale local
        // pointer for this same conversation (that entry must stop authorizing me). An
        // UNCONDITIONAL clear was F2: "stop" tapped in a conversation that does NOT hold
        // the window would tear down a DIFFERENT conversation's still-live window, with
        // no closing announcement to its peer.
        let closing = mineHere ? (try? await engine.endMyWindowEarly()) : nil
        if hadWindow, let closing {
            try? await sendMessage(
                "turned off always-on AI", conversationID: conversationID,
                aiWindow: closing, asSystemRow: true)
        }
        if myWindowConversationID == conversationID { myWindowConversationID = nil }
        aiActiveSince[conversationID] = nil
        eventContinuation?.yield(
            .aiWindowChanged(
                conversationID: conversationID, identityHex: identityHex, activeUntil: nil))
        // Withdraw the conversation-scope sharing grant too, so the "AI context
        // sharing is on" indicator clears alongside the window.
        await withdrawAIContext(scope: .conversation(conversationID))
    }

    func sendAsMyAI(_ text: String, conversationID: String) async throws {
        // The only caller is the "Draft with AI ▸ Send as my AI" flow: the human
        // directed and approved this AI draft, so it is co-authored ("made with
        // you and your AI"). Autonomous agent sends use the engine sink, not this.
        try await sendMessage(
            text, conversationID: conversationID, participantType: .agent, coauthored: true)
    }

    /// The EXACT messages the AI would see for this scope, with the per-message
    /// `shared` flag — the single source of truth for both `agentContext` (what's
    /// actually sent) and the read-only context inspector (what the user is
    /// shown). Pure read: store + grants + settings, no engine mutation.
    /// `strict` forces marked-context-only even while the AI is active.
    // MARK: - Per-AI context capability gate (feature 1 + D2)

    /// What ONE tethered AI is permitted to unseal when its context is assembled for
    /// a scope. Built once per (AI, scope) by `buildCapability`, consumed by
    /// `aiAuthorGate`. Content-blind (derived only from roster / grant / thread state).
    private struct AIContextCapability {
        let aiID: String
        /// My OTHER AIs co-rostered with this one here — reply-order co-membership is
        /// the consent to chain (D5).
        let siblingRosterAIIDs: Set<String>
        /// This AI is an invited member of THIS thread → the thread free-for-all
        /// (feature 3): it may unseal any author within the thread.
        let threadMember: Bool
        /// My ai_window is live for THIS conversation — I opened the floor for my AI,
        /// which (D2 step 1) authorizes it to read the PEER's words I already received.
        let conversationWindowActive: Bool
        /// A live bilateral human-axis grant — the standing/inactive path to consuming
        /// a PEER's marked words (D2 step 1 without an open window).
        let humanAxisAuthorized: Bool
        /// A live bilateral ai-axis grant authorizes consuming a PEER's AI (D2 step 2).
        let peerAIAxisAuthorized: Bool
    }

    /// The author "bucket" a message belongs to: `human:<senderHex>` (any human's
    /// message), `self:<agentAIID>` (one of MY AIs, by stable id), or
    /// `peerAI:<senderHex>` (a peer's AI). A legacy agent message of mine with no
    /// `agentAIID` buckets as `self:` and is handled specially in `aiAuthorGate`.
    private func authorBucket(_ message: StoredMessage) -> String {
        guard message.participantType == .agent else { return "human:\(message.senderIdentity)" }
        if message.senderIdentity == identityHex { return "self:\(message.agentAIID ?? "")" }
        return "peerAI:\(message.senderIdentity)"
    }

    /// Build the capability for one AI in a scope.
    private func buildCapability(
        forAI ai: TetheredAI, conversationID: String, threadID: String?
    ) async -> AIContextCapability {
        // Siblings: my OTHER AIs that share visibility with this one here. A roster
        // (an explicit reply order) IS the consent to chain (D5) — so siblings come
        // ONLY from a configured roster. With no roster set, a regular chat keeps the
        // AIs ISOLATED from each other (feature 1's default); the my-own-AI solo chat
        // / trusted conduit get their fuller behavior from the D1 exemption in
        // `visibleContextMessages`, not from siblings.
        let scopeID = threadID ?? conversationID
        let rosterIDs = AppSession.conversationAIRoster(scopeID, siloID: siloID) ?? []
        let siblings = Set(rosterIDs).subtracting([ai.id])
        // Thread membership: my active invite (per identity → covers all my AIs) or a
        // solo thread. Conversation scope has none.
        let threadMember: Bool
        let windowActive: Bool
        if let threadID {
            threadMember =
                (await engine.activeInvite(threadID: threadID, identityHex: identityHex) != nil)
                || isSoloThread(threadID)
            windowActive = false  // threads use the invite (threadMember) path
        } else {
            threadMember = false
            // My ai_window for THIS conversation authorizes my AI to read the live
            // conversation — including the peer's words (D2 step 1; original window
            // behavior restored). Peer AI content stays separately gated below.
            windowActive =
                (await engine.activeWindow(for: identityHex) != nil)
                && myWindowConversationID == conversationID
        }
        let humanScope: AIContextGrant.Scope =
            threadID.map { .thread($0, axis: AIContextGrant.Scope.humanAxis) }
            ?? .conversation(conversationID, axis: AIContextGrant.Scope.humanAxis)
        let aiScope: AIContextGrant.Scope =
            threadID.map { .thread($0, axis: AIContextGrant.Scope.aiAxis) }
            ?? .conversation(conversationID, axis: AIContextGrant.Scope.aiAxis)
        return AIContextCapability(
            aiID: ai.id,
            siblingRosterAIIDs: siblings,
            threadMember: threadMember,
            conversationWindowActive: windowActive,
            humanAxisAuthorized: await engine.contextSharingAuthorized(scope: humanScope),
            peerAIAxisAuthorized: await engine.contextSharingAuthorized(scope: aiScope))
    }

    /// The per-AI AUTHOR gate (feature 1 + D2). Default-deny: a message is included
    /// only when THIS AI holds the capability for its author bucket.
    private func aiAuthorGate(
        _ message: StoredMessage, cap: AIContextCapability, conversationID: String
    ) -> Bool {
        // Legacy agent message of mine (no recorded author id): visible to all my AIs
        // — per-AI isolation applies to messages written from now on.
        if message.participantType == .agent, message.senderIdentity == identityHex,
            message.agentAIID == nil {
            return true
        }
        // Thread free-for-all (feature 3): an invited thread member sees every author.
        if cap.threadMember { return true }
        let bucket = authorBucket(message)
        if bucket == "self:\(cap.aiID)" { return true }      // its own prior replies
        if bucket == "human:\(identityHex)" { return true }  // my own messages
        if bucket.hasPrefix("self:") {
            // A sibling of mine — reply-order roster co-membership or a per-AI mark.
            let sibling = String(bucket.dropFirst("self:".count))
            return cap.siblingRosterAIIDs.contains(sibling) || markedForMe(message, aiID: cap.aiID)
        }
        if bucket.hasPrefix("human:") {
            // A PEER's WORDS (D2 step 1): my open ai_window is the consent for my AI to
            // read the conversation I'm in (the peer SENT me these); a standing
            // human-axis grant covers the inactive/marked case. This is the original
            // window behavior — only the peer's AI content (below) is the new 2nd step.
            return cap.conversationWindowActive || cap.humanAxisAuthorized
        }
        if bucket.hasPrefix("peerAI:") {
            // A PEER's AI (D2 step 2): genuinely cross-party, so it needs the explicit
            // bilateral ai-axis grant — NOT merely an open window. Optional per-AI
            // allowlist narrows WHICH of my AIs may consume it.
            guard cap.peerAIAxisAuthorized else { return false }
            return aiInAllowlist(
                cap.aiID, axis: AIContextGrant.Scope.aiAxis,
                peerHex: message.senderIdentity, conversationID: conversationID)
        }
        return false
    }

    /// Whether a message is explicitly marked into THIS AI's context (feature 7). A
    /// non-nil `aiMarks` is the authoritative per-AI set; a legacy message with no
    /// `aiMarks` falls back to the single `aiContext` "all my AIs" flag.
    private func markedForMe(_ message: StoredMessage, aiID: String) -> Bool {
        if let marks = message.aiMarks { return marks.contains(aiID) }
        return message.aiContext
    }

    /// Whether this AI may consume a peer's content on an axis, per the LOCAL
    /// allowlist (D2). nil = all my AIs (the grant, already checked, is the gate).
    private func aiInAllowlist(
        _ aiID: String, axis: String, peerHex: String, conversationID: String
    ) -> Bool {
        guard
            let allow = AppSession.aiConsumeAllowlist(
                axis: axis, conversationID: conversationID, peerHex: peerHex, siloID: siloID)
        else { return true }
        return allow.contains(aiID)
    }

    private func visibleContextMessages(
        conversationID: String, threadID: String?, depth: Int, strict: Bool,
        forAI cap: AIContextCapability? = nil
    ) async -> [(message: StoredMessage, shared: Bool)] {
        let stored: [StoredMessage]
        if let threadID {
            stored = (try? await store.messages(threadID: threadID)) ?? []
        } else {
            stored = (try? await store.messages(conversationID: conversationID)) ?? []
        }
        // Scope for context-sharing authorization (DEVIATIONS N24). The legacy
        // single-grant check uses the default (human) axis; the per-AI gate below
        // splits human vs ai (D2).
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
        // The user's OWN trusted Mac coding agent (paired + consented) is not a
        // cloud model to be guarded against — it's their device behind the app's
        // E2EE. For it, lift the "only messages since the AI turned on" floor so it
        // can see the full recent conversation (still bounded by `depth`). A "marked
        // only" override (strict) still wins — that's an explicit user choice.
        let trustedNode = isConsentedCodingAgentNode(conversationID)
        let liftWindow = trustedNode && !strict
        // D1 exemption: a solo "My AI" chat / solo sub-thread has no other human and
        // is entirely my OWN AIs, so it keeps today's fuller, shared-context behavior
        // (my AIs chain freely). The per-AI isolation gate is for chats with OTHER
        // people. A "marked only" (strict) override still narrows it — an explicit
        // user choice — matching the trusted-node rule.
        let soloScope =
            !strict && (isSoloConversation(conversationID) || (threadID.map { isSoloThread($0) } ?? false))
        let since = aiActiveSince[threadID ?? conversationID] ?? Int64.max
        let recent = stored.filter { message in
            // Trusted node / solo my-AI scope: full recent history, no per-AI gate.
            if liftWindow || soloScope { return true }
            // LAYER 1 — WHEN: is this message time-eligible at all?
            //   active+since: the live conversation from when the AI turned on; or
            //   a marked message (its eligibility in time, not yet WHO).
            let timeOK: Bool
            if effectiveActive, message.sentAt >= since {
                timeOK = true
            } else if message.aiContext {
                // Marked content is time-eligible. With a per-AI capability the WHO
                // gate (below) enforces the per-axis grant for peer content; without
                // one (generic preview / trusted MCP view) fall back to the original
                // single-grant check.
                timeOK = (cap != nil) ? true : (message.senderIdentity == identityHex || sharingAuthorized)
            } else {
                timeOK = false
            }
            guard timeOK else { return false }
            // LAYER 2 — WHO: the per-AI author gate (feature 1 + D2 axes). Excludes
            // other AIs' messages unless this AI holds the capability, and splits a
            // peer's words (human axis) from a peer's AI (ai axis). nil capability ⇒
            // no author gate (generic preview / trusted conduit, D1).
            if let cap { return aiAuthorGate(message, cap: cap, conversationID: conversationID) }
            return true
        }.suffix(depth)
        // Byte-bound the window: keep the most recent entries whose combined text
        // fits a budget, so a few multi-MB pastes can't balloon memory or a remote
        // payload (the AI-to-AI OOM cap). Always keep at least the newest message.
        //
        // The cap is lifted ONLY for a trusted coding-agent node reached over a
        // LOCAL link (NearbyACPTransport / LAN) — never the relay. Over the relay
        // the cap (and SPEC §7/§11: content >64 KB is never inlined — Blossom
        // pointer / chunking only, everything padded to fixed buckets) MUST hold,
        // so a relayed Huginn node still caps at 64 KB. Today coding-agent nodes are
        // relay-bound, so this stays capped until a local ACP link is wired.
        let liftByteCap = trustedNode && isLocalTransportNode(conversationID)
        var budget = 64 * 1024
        var bounded: [StoredMessage] = []
        for message in recent.reversed() {
            let cost = message.text.utf8.count
            if !liftByteCap, !bounded.isEmpty, budget - cost < 0 { break }
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
        systemPromptOverride: String? = nil, forAI cap: AIContextCapability? = nil
    ) async -> AgentContext {
        let visible = await visibleContextMessages(
            conversationID: conversationID, threadID: threadID, depth: depth, strict: strict,
            forAI: cap)
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
    /// Returns the number of messages my AIs posted this turn (0 if none were eligible or the
    /// engine gate stayed closed) so callers can detect convergence without re-scanning the store.
    @discardableResult
    func takeAgentThreadTurn(threadID: String, mentionedAINames: Set<String>? = nil) async -> Int {
        let conversationID = threadConversations[threadID] ?? ""
        guard !conversationID.isEmpty, !aiSuppressed(in: conversationID) else { return 0 }
        // Ordered critique panel (C3) when the active selection policy supplies one
        // — each AI tagged with a role (primary → reviewer/critic → synthesizer),
        // and the role flows into the thread system prompt. Otherwise the flat
        // autonomous participant set, all "primary" (the default, unchanged).
        var ordered: [(ai: TetheredAI, role: String)]
        if let critique = aiSelection.critiqueTurn(
            from: ais, conversationID: conversationID, threadID: threadID)
        {
            ordered = critique
        } else {
            ordered = aiSelection.participants(
                from: ais, conversationID: conversationID, threadID: threadID
            ).map { ($0, "primary") }
        }
        // @-mention routing (C2): if the triggering message named specific AIs, run
        // ONLY my AIs of those names (matched by name across devices). nil ⇒ no AI
        // mention ⇒ all participants (the default). Empty after filter ⇒ none here.
        if let names = mentionedAINames {
            ordered = ordered.filter { names.contains($0.ai.name.lowercased()) }
        }
        var posted = 0
        for (ai, role) in ordered {
            // "off" is the silence contract — never let a provider run here.
            guard resolvedPolicy(ai, conversationID: conversationID) != "off" else { continue }
            posted += await engine.runThreadTurn(
                provider: ai.provider,
                context: await contextFor(
                    ai, conversationID: conversationID, threadID: threadID, aiRole: role),
                threadID: threadID,
                agentName: ai.name, agentAIID: ai.id)
        }
        return posted
    }

    /// A single @-mention of one of MY AIs in a regular chat (feature 6, decision #5).
    /// If a window is already live here, narrow the reply to JUST that AI; otherwise
    /// emit the ask-each-time choice (draft privately vs. open a window & post) — never
    /// an unbidden autonomous send to the other people (invariant 9).
    private func routeSingleMyAIMention(aiID: String, conversationID: String) async {
        guard !aiSuppressed(in: conversationID), let ai = ais.first(where: { $0.id == aiID }),
            resolvedPolicy(ai, conversationID: conversationID) != "off"
        else { return }
        let windowLive =
            await engine.activeWindow(for: identityHex) != nil
            && myWindowConversationID == conversationID
        if windowLive {
            _ = await engine.runWindowReply(
                provider: ai.provider,
                context: await contextFor(ai, conversationID: conversationID, threadID: nil),
                conversationID: conversationID, agentName: ai.name, agentAIID: ai.id)
        } else {
            eventContinuation?.yield(
                .aiMentionNeedsChoice(conversationID: conversationID, aiID: aiID, aiName: ai.name))
        }
    }

    /// @-mentioning 2+ AIs (mine and/or a peer's) opens — or reuses — a THREAD where
    /// they collaborate with mutual visibility (feature 3), seeded with my prompt and
    /// bounded by the per-thread AI turn limiter (D4). A peer's AI can't be invited by
    /// me (only its owner can sign its invite); the seed naming it surfaces on their
    /// device for a tap-to-invite.
    private func routeMentionsToCollabThread(
        conversationID: String, myAIIDs: [String], peerHexes: [String], seedText: String
    ) async {
        let setKey = (myAIIDs + peerHexes).sorted().joined(separator: "+")
        let threadID: String
        if let existing = AppSession.collabThreadID(
            conversationID: conversationID, aiSetKey: setKey, siloID: siloID),
            threadConversations[existing] != nil
        {
            threadID = existing
        } else {
            let names =
                myAIIDs.compactMap { id in ais.first { $0.id == id }?.name }
                + peerHexes.compactMap { contactRecords[$0]?.autoAIName }
            let title = names.isEmpty ? "AI collaboration" : names.joined(separator: " ⨯ ")
            guard let created = try? await createThread(conversationID: conversationID, title: title)
            else { return }
            threadID = created
            AppSession.setCollabThreadID(
                threadID, conversationID: conversationID, aiSetKey: setKey, siloID: siloID)
        }
        // The mentioned AIs (mine) are the thread roster, in mention order (features 4/5).
        if !myAIIDs.isEmpty {
            AppSession.setConversationAIRoster(myAIIDs, scopeID: threadID, siloID: siloID)
            // One human-signed invite covers all my AIs (keyed by my identity).
            try? await inviteMyAI(threadID: threadID, durationSeconds: 30 * 60)
        }
        // Seed the thread with my prompt; suppress its one-off auto-turn — the bounded
        // loop below drives the rounds.
        try? await sendMessage(
            seedText, conversationID: conversationID, threadID: threadID, suppressAutoReply: true)
        let names = Set(myAIIDs.compactMap { id in ais.first { $0.id == id }?.name.lowercased() })
        await runBoundedThreadCollaboration(
            threadID: threadID, mentionedAINames: names.isEmpty ? nil : names)
    }

    /// Run a thread's invited AIs round after round — each rebuilding context so it
    /// sees the prior posts — until a round adds nothing new (converged) or the
    /// per-thread AI turn limiter (`ThreadTurnLimitView`, the existing feature) pauses
    /// it. A hard backstop bounds it even when the limiter is set to unlimited.
    func runBoundedThreadCollaboration(threadID: String, mentionedAINames: Set<String>?) async {
        let backstop = 12
        for _ in 0..<backstop {
            // `takeAgentThreadTurn` reports how many messages its AIs posted this round, so the
            // loop no longer brackets each round with two whole-thread `store.messages(threadID:)`
            // decrypt-all scans just to diff the count. 0 posted ⇒ converged or loop-guard paused.
            let posted = await takeAgentThreadTurn(
                threadID: threadID, mentionedAINames: mentionedAINames)
            if posted == 0 { break }
        }
    }

    /// "Bring the answer back" (D4): copy a thread message into the PARENT conversation
    /// as MY human message, co-authored (made with the AI in the thread). An HONEST
    /// human send — not a relabeled agent (invariant 8), not an autonomous agent send
    /// (invariant 9). Visible to everyone in the conversation.
    func promoteThreadMessageToMain(messageID: String) async {
        guard let msg = try? await store.message(id: messageID), let threadID = msg.threadID,
            let conversationID = threadConversations[threadID]
        else { return }
        // An agent thread message's text may still carry the AgentSkills `⟡⟡ … ⟡⟡ end` envelope.
        // Posted as .human it would bypass the agent-only bubble stripper and surface that
        // scaffolding in the main chat — strip it here (a no-op for un-enveloped text) so the
        // human co-authored send shows just the answer. Human sources pass through untouched.
        let text =
            msg.participantType == .agent
            ? MessageBubble.strippedEnvelopeBody(msg.text) : msg.text
        try? await sendMessage(
            text, conversationID: conversationID, participantType: .human,
            suppressAutoReply: true, coauthored: true)
    }

    // NOTE: there is deliberately no bare `engineActiveWindow(identityHex:)` passthrough.
    // The engine's ai_window is GLOBAL — keyed `conversationWindows[myIdentityHex]`, one
    // per identity, NOT per conversation — so a raw `engine.activeWindow(for:)` is TRUE in
    // every conversation once a window is open anywhere. Gating a reply on it alone posts
    // conversation B's context into conversation A. Conversation scope comes from ANDing it
    // with `myWindowConversationID`; use `aiWindowActive(conversationID:)`, which does.
    // (A dead unguarded passthrough lived here and was removed — it had no callers, but it
    // was a footgun a future gate could pick up.)

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

    /// Per-AI context mark (feature 7): include/exclude THIS message in a SPECIFIC
    /// of MY AIs' context, independent of the global "Add to AI Context"
    /// shareability flag. Read-modify-write of the local `aiMarks` set. When the
    /// message had no explicit marks yet, the current effective set is materialized
    /// first (a globally-marked message means "all my AIs", so excluding one writes
    /// the rest). PURELY LOCAL — never mirrored to a peer (it only routes among MY
    /// own AIs, SPEC §0).
    func setAIMark(messageID: String, aiID: String, value: Bool) async {
        guard let message = try? await store.message(id: messageID) else { return }
        var marks: Set<String> =
            message.aiMarks.map(Set.init) ?? (message.aiContext ? Set(ais.map { $0.id }) : [])
        if value { marks.insert(aiID) } else { marks.remove(aiID) }
        try? await store.setAIMarks(messageID: messageID, aiIDs: Array(marks))
        if let updated = try? await store.message(id: messageID) {
            eventContinuation?.yield(.messageChanged(updated))
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
            // Reachability: the user opted into an open inbox — auto-accept
            // instead of gating (a permanent toggle, no time bound).
            if reachabilityEnabled {
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
            localStatus: isSystemRow ? "system" : "received",
            coauthored: body.coauthored ?? false)
        try? await store.save(message)
        eventContinuation?.yield(.messageAdded(message))

        // T3: a known contact's identity key may have rotated (a device change, or a
        // MITM republishing a binding). Re-check (throttled, off the receive path) and
        // WARN via the persistent banner — never block.
        if verifiedContacts[senderHex] != nil, senderHex != identityHex, !isSystemRow {
            Task { await self.checkSafetyCode(forContact: senderHex) }
        }

        // Agent reactions — every gate lives in the engine (fail closed).
        if let threadID = body.thread?.id {
            await engine.recordThreadMessage(
                threadID: threadID, participantType: received.participantType)
            // @-mention routing (C2): if this message named specific AIs, only MY AI
            // of that name responds; otherwise all participant AIs (the default).
            let aiNames = (body.mentions ?? []).filter { $0.kind == "ai" }
                .map { $0.displayName.lowercased() }
            await takeAgentThreadTurn(
                threadID: threadID, mentionedAINames: aiNames.isEmpty ? nil : Set(aiNames))
        } else if received.participantType == .human, senderHex != identityHex,
            myWindowConversationID == conversationID, !aiSuppressed(in: conversationID)
        {
            // Conversation scope: only during MY active ai_window FOR THIS
            // conversation. The engine's window gate is keyed on my identity alone
            // (global), and a reply posts to `windowConversation()` — so without the
            // `myWindowConversationID == conversationID` guard, a message arriving in
            // conversation B while my window is open in A would build context from B
            // and post the reply into A, leaking B's content/participants into A
            // (SPEC §0). The guard pins replies to the conversation the window is for.
            // Each participating tethered AI then replies in turn (the engine gate
            // still fails closed when no window; draft-only/off AIs never auto-post).
            for ai in aiSelection.participants(
                from: ais, conversationID: conversationID, threadID: nil)
            {
                // "off" is the silence contract — never let a provider run here.
                guard resolvedPolicy(ai, conversationID: conversationID) != "off" else { continue }
                _ = await engine.runWindowReply(
                    provider: ai.provider,
                    context: await contextFor(ai, conversationID: conversationID, threadID: nil),
                    conversationID: conversationID, agentName: ai.name, agentAIID: ai.id)
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

    func postAgentMessage(
        _ body: MessageBody, threadID: String, agentName: String?, agentAIID: String?
    ) async throws {
        guard let info = await runtime.threadInfo(threadID: threadID) else {
            throw PQRCError.sessionNotEstablished
        }
        try await runtime.sendMessage(
            body.text, conversationID: info.conversationID, participantType: .agent,
            threadID: threadID, isContext: body.isContext ?? false, agentName: agentName,
            agentAIID: agentAIID)
    }

    func postAgentReply(
        _ body: MessageBody, conversationID: String, agentName: String?, agentAIID: String?
    ) async throws {
        // Post to the conversation pinned at GATE-check time (threaded through the engine),
        // NOT whatever `windowConversation()` happens to be NOW. The provider call suspends
        // across an actor hop, during which the human can switch the (single, global) window
        // to another chat; resolving the destination here from the live pointer was F1 — it
        // would publish chat A's peer content, agent-signed, into chat B. Re-verify the
        // window is STILL this conversation's and drop the stale reply otherwise (fail
        // closed): a reply built for a window that has since moved must not post at all.
        guard await runtime.windowConversation() == conversationID else { return }
        try await runtime.sendMessage(
            body.text, conversationID: conversationID, participantType: .agent, agentName: agentName,
            agentAIID: agentAIID)
    }

    /// §13.5 voicing: `body` (redacted) goes on the wire to the group; `rawText` is the
    /// owner's local-only view. Thread scope routes via the thread's conversation;
    /// conversation scope routes via the draft's target (`voiceInto`, stashed on the
    /// runtime). Signs as the owner's agent (sendMessage `.agent` → owner's agent key).
    func postAgentDraft(
        _ body: MessageBody, rawText: String, threadID: String?, agentName: String?,
        agentAIID: String?
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
            threadID: threadID, agentName: agentName, agentAIID: agentAIID,
            localTextOverride: rawText)
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
