import Foundation
import Observation
import PQRCACP
import PQRCAgent
import PQRCCore
import PQRCNostr

/// UI-facing conversation summary.
struct ConversationVM: Identifiable, Hashable {
    let id: String
    var title: String
    var isGroup: Bool
    var lastMessage: String
    var lastActivity: Int64
    var pinned: Bool
    var verified: Bool
    var memberCount: Int
    var unread: Int = 0
    /// A paired Eldr ACP coding agent (local tag only) — drives the wrench icon.
    var isCodingAgent: Bool = false
}

struct ThreadVM: Identifiable, Hashable {
    let id: String
    let conversationID: String
    var title: String
    var messageCount: Int
}

/// A compact reference to one of MY configured AIs' backend type, cached on the
/// model so a chat bubble can show the right type badge (AITypeIcon) without
/// re-decoding the AI config per row.
struct AITypeRef: Sendable, Equatable {
    let kind: String
    let model: String?
}

/// A nearby (binding-verified, relay-free) peer for the New Conversation list.
struct NearbyVM: Identifiable, Hashable {
    var id: String { identityHex }
    let identityHex: String
    let name: String
}

/// Phase D4 — the live INTERACTIVE terminal (PTY) a paired coding-agent node is running.
/// Append-only `output` (the streamed combined stdout+stderr), display-only — agent text,
/// trusted no further than a bubble, and NEVER persisted (the live stream isn't written
/// at rest, CLAUDE.md inv. 12). The view renders `output` monospace and offers a Stop
/// control wired to `terminalID`.
struct LiveACPTerminal: Identifiable, Equatable {
    var id: String { terminalID }
    let terminalID: String
    let title: String
    var output: String = ""
    /// Set once the node reports the terminal closed (child exited / killed). The view
    /// shows it as ended; the row is cleared shortly after.
    var closed: Bool = false
    var exitCode: Int?
    /// Cap on retained output so a chatty process can't grow the string unbounded in the
    /// view (the live stream is unbounded; the on-screen scrollback is not). Head-trimmed.
    static let maxOutputBytes = 256 * 1024
}

/// Main-actor view state for one persona, fed by its `PersonaRuntime`.
@MainActor
@Observable
final class AppModel {
    let runtime: PersonaRuntime
    let personaName: String

    /// The interactive ACP tool-permission queue (Phase 3 item 3 — "ask each time"). A
    /// SwiftUI alert drives off `acpPermissions.pending.first`; the runtime's permission
    /// handler awaits it. Owned here so it lives for the whole app session and is reachable
    /// from any view via the model.
    let acpPermissions = ACPPermissionCoordinator()

    var onboarded = false
    var myNpub = ""
    var myIdentityHex = ""
    var conversations: [ConversationVM] = []
    var messagesByConversation: [String: [StoredMessage]] = [:]
    var threadsByConversation: [String: [ThreadVM]] = [:]
    var messageRequests: [String] = []
    /// conversationID -> (identityHex -> activeUntil): drives the pinned banner.
    var aiWindows: [String: [String: Int64]] = [:]
    /// threadID -> (identityHex -> activeUntil): drives the thread header.
    var aiInvites: [String: [String: Int64]] = [:]
    /// scopeTag ("conversation:<id>" | "thread:<id>") -> (identityHex -> activeUntil):
    /// drives the "AI context sharing active" indicator.
    var aiContextGrants: [String: [String: Int64]] = [:]
    /// Live relay connection health for the Settings indicator (Feature 5).
    var relayStatuses: [RelayStatusInfo] = []
    /// Outcome of publishing my keys to the relay — shown in Settings so the
    /// user can see at a glance whether peers can reach their keys.
    var keyPublish: KeyPublishStatus = .pending
    var protocolViolations: [String] = []
    /// Conversations with a pending safety-code-change warning (APP-SPEC §6.2).
    var safetyCodeChangedFor: Set<String> = []
    var prekeyCount = 0
    var contactNames: [String: String] = [:]
    /// identityHex -> a peer's locally-generated AI codename (never broadcast),
    /// used to label their assistant's bubbles. My own AIs label via the
    /// message's stored `agentName`.
    var aiNames: [String: String] = [:]
    /// Cached `agentName -> (backend kind, model)` for MY OWN configured AIs, so a
    /// chat bubble can show the right type badge (AITypeIcon) without re-reading +
    /// decoding UserDefaults per row. Rebuilt by `refreshAITypes()` (on start and on
    /// conversation appear, after Settings may have changed).
    private(set) var aiTypeByName: [String: AITypeRef] = [:]
    /// conversationID -> the latest plan/TODO checklist a paired coding-agent node
    /// reported for the turn it's running (Phase D1). Display-only; the node re-sends
    /// the whole plan on each change, so this is replaced wholesale, never merged.
    var acpPlansByConversation: [String: [ACPPlanEntry]] = [:]
    /// conversationID -> the live INTERACTIVE terminal (PTY) a paired coding-agent node is
    /// running for this conversation (Phase D4), or nil when none is live. The UI shows a
    /// monospace output view + a prominent Stop control while present. At most one live
    /// terminal per conversation is surfaced (a coding chat drives one node). The output
    /// is display-only agent text and is NEVER persisted (CLAUDE.md inv. 12 — the live
    /// stream is not written at rest).
    var acpTerminalByConversation: [String: LiveACPTerminal] = [:]
    /// Nearby peers discovered over the local link (SPEC §10) — startable with
    /// no relay. Populated only when the Nearby setting is on.
    var nearbyContacts: [NearbyVM] = []
    /// Whether the Nearby (local-link) path is active; set at start. Drives the
    /// relay-free "Nearby" section in New Conversation.
    var localLinkEnabled = false

    private var pumpTask: Task<Void, Never>?

    /// The unlocked silo this model belongs to — namespaces local-only UI state
    /// (read receipts) so accounts never share or accumulate it at rest (A33).
    /// Empty/distinct for the demo universe's in-memory personas.
    let siloID: String

    init(runtime: PersonaRuntime, personaName: String, siloID: String = "") {
        self.runtime = runtime
        self.personaName = personaName
        self.siloID = siloID
    }

    func start(
        inMemoryStore: Bool, storeURL: URL? = nil,
        relayURLs: [String] = ["local://relay"]
    ) async throws {
        // Wire the interactive permission asker BEFORE bootstrap, so the first relay-ACP
        // rebind (inside bootstrap) builds a handler that can prompt the human.
        await runtime.setPermissionAsker(acpPermissions)
        let events = try await runtime.bootstrap(
            inMemoryStore: inMemoryStore, storeURL: storeURL, relayURLs: relayURLs)
        myNpub = await runtime.npub
        myIdentityHex = await runtime.identityHex
        prekeyCount = await runtime.oneTimePrekeyCount()
        contactNames[myIdentityHex] = personaName
        localLinkEnabled = await runtime.isLocalLinkEnabled
        refreshAITypes()
        await restorePersistedUI()
        onboarded = true
        pumpTask = Task { [weak self] in
            for await event in events {
                await self?.apply(event)
            }
        }
        // One-shot relay health check at launch (Feature 5). The Settings
        // indicator is populated from this and not refreshed again until the
        // user taps "Check connection" — repeatedly re-pinging on every Settings
        // open was getting the client throttled by the relay. Runs detached so
        // it never blocks first paint.
        Task { [weak self] in await self?.checkRelaysNow() }
    }

    /// Rebuilds the conversation list, message history and threads from the
    /// encrypted store — the relaunch path (messages used to vanish because
    /// nothing ever read them back).
    private func restorePersistedUI() async {
        for conversationID in await runtime.persistedConversationIDs() {
            let stored = await runtime.messages(conversationID: conversationID)
            guard !stored.isEmpty else { continue }
            messagesByConversation[conversationID] = stored
            await refreshConversationRow(
                conversationID, lastMessage: stored.last { $0.threadID == nil })
        }
        for (threadID, conversationID, title) in await runtime.allThreads() {
            var threads = threadsByConversation[conversationID] ?? []
            guard !threads.contains(where: { $0.id == threadID }) else { continue }
            let count = (messagesByConversation[conversationID] ?? [])
                .filter { $0.threadID == threadID }.count
            threads.append(
                ThreadVM(
                    id: threadID, conversationID: conversationID,
                    title: title, messageCount: count))
            threadsByConversation[conversationID] = threads
        }
    }

    private func apply(_ event: RuntimeEvent) async {
        switch event {
        case .messageAdded(let message):
            // Upsert by id: the runtime can yield the same message twice
            // (restore + a live push, or local send + relay echo). A plain
            // append leaves the list with duplicate StoredMessage.ids, which
            // SwiftUI's ForEach hard-warns about and renders unpredictably.
            var list = messagesByConversation[message.conversationID] ?? []
            if let idx = list.firstIndex(where: { $0.id == message.id }) {
                list[idx] = message
            } else {
                list.append(message)
            }
            messagesByConversation[message.conversationID] = list
            await refreshConversationRow(message.conversationID, lastMessage: message)
            if let threadID = message.threadID {
                refreshThreadCounts(conversationID: message.conversationID, threadID: threadID)
            }
        case .messageChanged(let message):
            // A marker flip (no new row): replace in place if we have it.
            if var list = messagesByConversation[message.conversationID],
                let idx = list.firstIndex(where: { $0.id == message.id })
            {
                list[idx] = message
                messagesByConversation[message.conversationID] = list
            }
        case .conversationChanged(let id):
            await refreshConversationRow(id, lastMessage: nil)
        case .messageRequest(let sender):
            if !messageRequests.contains(sender) {
                messageRequests.append(sender)
            }
        case .protocolViolation(_, let reason):
            protocolViolations.append(reason)
        case .aiWindowChanged(let conversationID, let identityHex, let activeUntil):
            var windows = aiWindows[conversationID] ?? [:]
            windows[identityHex] = activeUntil
            aiWindows[conversationID] = windows
        case .aiInviteChanged(let threadID, let identityHex, let activeUntil):
            var invites = aiInvites[threadID] ?? [:]
            invites[identityHex] = activeUntil
            aiInvites[threadID] = invites
        case .aiContextGrantChanged(let scopeTag, let identityHex, let activeUntil):
            var grants = aiContextGrants[scopeTag] ?? [:]
            grants[identityHex] = activeUntil
            aiContextGrants[scopeTag] = grants
        case .threadCreated(let conversationID, let threadID, let title):
            var threads = threadsByConversation[conversationID] ?? []
            if !threads.contains(where: { $0.id == threadID }) {
                threads.append(
                    ThreadVM(id: threadID, conversationID: conversationID, title: title, messageCount: 0))
                threadsByConversation[conversationID] = threads
            }
        case .agentError(let message):
            agentError = message
        case .safetyCodeChanged(let identityHex):
            safetyCodeChangedFor.insert(identityHex)
        case .nearbyDiscovered:
            nearbyContacts = await runtime.nearbyList().map {
                NearbyVM(identityHex: $0.identityHex, name: $0.name)
            }
        case .keyPublishChanged(let status):
            keyPublish = status
        case .acpPlan(let conversationID, let entries):
            // Full snapshot from the node — replace, don't merge. An empty plan
            // (turn produced no steps) clears the checklist.
            if entries.isEmpty {
                acpPlansByConversation[conversationID] = nil
            } else {
                acpPlansByConversation[conversationID] = entries
            }
        case .acpTerminalOpened(let conversationID, let terminalID, let title):
            // A live interactive terminal opened — show its view + Stop control.
            acpTerminalByConversation[conversationID] = LiveACPTerminal(
                terminalID: terminalID, title: title)
        case .acpTerminalOutput(let conversationID, let terminalID, let chunk):
            // Append streamed output to the matching live terminal (display-only; never
            // persisted). Ignore a chunk for a terminal we aren't showing (a stale id).
            guard var term = acpTerminalByConversation[conversationID],
                term.terminalID == terminalID
            else { break }
            term.output += chunk
            // Bound the on-screen scrollback (head-trim) so a chatty process can't grow
            // the retained string without limit.
            if term.output.utf8.count > LiveACPTerminal.maxOutputBytes {
                term.output = String(term.output.suffix(LiveACPTerminal.maxOutputBytes / 2))
            }
            acpTerminalByConversation[conversationID] = term
        case .acpTerminalClosed(let conversationID, let terminalID, let exitCode):
            guard var term = acpTerminalByConversation[conversationID],
                term.terminalID == terminalID
            else { break }
            term.closed = true
            term.exitCode = exitCode
            acpTerminalByConversation[conversationID] = term
        }
    }

    private func refreshConversationRow(_ id: String, lastMessage: StoredMessage?) async {
        let roster = await runtime.groupRoster(id)
        let title: String
        var verified = false
        if let roster {
            title = roster.name
        } else {
            let info = await runtime.contactInfo(id)
            title = info.name
            verified = info.verified
            if let aiName = await runtime.contactAIName(id) { aiNames[id] = aiName }
        }
        contactNames[id] = title
        var isCodingAgent = false
        if roster == nil { isCodingAgent = await runtime.contactType(id) == "coding_agent" }
        var row = conversations.first { $0.id == id }
            ?? ConversationVM(
                id: id, title: title, isGroup: roster != nil, lastMessage: "",
                lastActivity: 0, pinned: false, verified: false,
                memberCount: roster?.members.count ?? 2)
        row.title = title
        row.verified = verified
        row.isCodingAgent = isCodingAgent
        row.memberCount = roster?.members.count ?? 2
        if let lastMessage, lastMessage.threadID == nil {
            row.lastMessage = lastMessage.text
            row.lastActivity = lastMessage.sentAt
        }
        row.unread = unreadCount(for: id, lastActivity: row.lastActivity)
        conversations.removeAll { $0.id == id }
        conversations.append(row)
        conversations.sort { ($0.pinned ? 1 : 0, $0.lastActivity) > ($1.pinned ? 1 : 0, $1.lastActivity) }
    }

    // MARK: - Read state (local-only; D5 — no remote receipts of any kind)

    private var lastReadKey: String { AppSession.siloDefaultsKey("lastReadAt", siloID) }
    private var lastReadAt: [String: Int64] {
        get {
            ((UserDefaults.standard.dictionary(forKey: lastReadKey) as? [String: Int]) ?? [:])
                .mapValues(Int64.init)
        }
        set {
            UserDefaults.standard.set(newValue.mapValues(Int.init), forKey: lastReadKey)
        }
    }

    private func unreadCount(for conversationID: String, lastActivity: Int64) -> Int {
        let lastRead = lastReadAt[conversationID] ?? 0
        return (messagesByConversation[conversationID] ?? [])
            .filter { $0.threadID == nil && $0.sentAt > lastRead && $0.senderIdentity != myIdentityHex }
            .count
    }

    func markRead(_ conversationID: String) {
        var read = lastReadAt
        read[conversationID] = (messagesByConversation[conversationID] ?? [])
            .map(\.sentAt).max() ?? Int64(Date().timeIntervalSince1970)
        lastReadAt = read
        if let index = conversations.firstIndex(where: { $0.id == conversationID }) {
            conversations[index].unread = 0
        }
    }

    private func refreshThreadCounts(conversationID: String, threadID: String) {
        guard var threads = threadsByConversation[conversationID],
            let index = threads.firstIndex(where: { $0.id == threadID })
        else { return }
        threads[index].messageCount += 1
        threadsByConversation[conversationID] = threads
    }

    // MARK: - Intents

    func send(_ text: String, conversationID: String, threadID: String? = nil) async {
        try? await runtime.sendMessage(text, conversationID: conversationID, threadID: threadID)
    }

    /// Tap-to-retry a "Not sent" message: drop the failed copy (UI + store),
    /// then send the same text fresh (re-uses the full optimistic-echo path).
    func retry(_ message: StoredMessage) async {
        if var list = messagesByConversation[message.conversationID] {
            list.removeAll { $0.id == message.id }
            messagesByConversation[message.conversationID] = list
        }
        await runtime.deleteMessage(message.id)
        await send(message.text, conversationID: message.conversationID, threadID: message.threadID)
    }

    func sendAsAI(_ text: String, conversationID: String) async {
        try? await runtime.sendAsMyAI(text, conversationID: conversationID)
    }

    /// Surfaced when an AI action fails (e.g. a bad Anthropic key or network),
    /// so the user sees *why* instead of silently getting nothing.
    var agentError: String?

    func draft(conversationID: String, threadID: String? = nil, focus: String? = nil) async -> String? {
        do {
            let text = try await runtime.draftReply(
                conversationID: conversationID, threadID: threadID, focus: focus).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // A blank draft (some providers return "" instead of erroring) would
            // insert nothing and read as "the AI silently did nothing". Treat it
            // as a failure with a visible reason.
            guard !text.isEmpty else {
                agentError = "The AI returned an empty reply. Try again, or check your provider in Settings ▸ AI."
                return nil
            }
            return text
        } catch {
            agentError = Self.describeAgentError(error)
            return nil
        }
    }

    static func describeAgentError(_ error: Error) -> String {
        if case AgentProviderError.unavailable(let detail) = error { return detail }
        if case AgentProviderError.notConfigured = error {
            return "No AI provider configured. Pick one in Settings → AI."
        }
        return (error as NSError).localizedDescription
    }

    func startWindow(conversationID: String, minutes: Int) async {
        try? await runtime.startAIWindow(
            conversationID: conversationID, durationSeconds: Int64(minutes * 60))
    }

    func createThread(
        conversationID: String, title: String, anchorMessageID: String? = nil
    ) async -> String? {
        try? await runtime.createThread(
            conversationID: conversationID, title: title, anchorMessageID: anchorMessageID)
    }

    /// Set the user's per-thread "max AI turns" loop-guard limit (C1; 0 = unlimited).
    func setThreadLoopGuardLimit(_ value: Int, threadID: String) async {
        await runtime.setThreadLoopGuardLimit(value, threadID: threadID)
    }

    /// C6: whether a thread is a "My AI" per-AI sub-thread (no invite/countdown UI).
    func isSoloThread(_ threadID: String) async -> Bool {
        await runtime.isSoloThread(threadID)
    }

    func inviteAI(threadID: String, minutes: Int) async {
        try? await runtime.inviteMyAI(threadID: threadID, durationSeconds: Int64(minutes * 60))
    }

    func withdrawAI(threadID: String) async {
        await runtime.withdrawMyAI(threadID: threadID)
    }

    // MARK: - Interactive terminal (Phase D4)

    /// Send a line of stdin to the live interactive terminal in `conversationID` (the user
    /// typed into the PTY view). Appends a newline. No-op if no terminal is live.
    func sendACPTerminalInput(_ text: String, conversationID: String) async {
        guard let term = acpTerminalByConversation[conversationID], !term.closed else { return }
        await runtime.sendACPTerminalInput(
            nodeHex: conversationID, terminalID: term.terminalID, data: text + "\n")
    }

    /// STOP/KILL the live interactive terminal in `conversationID` (the prominent Stop
    /// control). Tells the node to terminate the PTY's child process group + close its
    /// fds. Always available while a terminal is live.
    func stopACPTerminal(conversationID: String) async {
        guard let term = acpTerminalByConversation[conversationID] else { return }
        await runtime.killACPTerminal(nodeHex: conversationID, terminalID: term.terminalID)
    }

    /// Dismiss a CLOSED terminal's view (clears the row). Only meaningful once closed —
    /// while live, the Stop control is the way out.
    func dismissACPTerminal(conversationID: String) {
        if acpTerminalByConversation[conversationID]?.closed == true {
            acpTerminalByConversation[conversationID] = nil
        }
    }

    // MARK: - AI context (Features 3–4)

    /// Mark/unmark messages as "AI context".
    func markAIContext(messageIDs: [String], value: Bool, conversationID: String) async {
        await runtime.markAsAIContext(messageIDs: messageIDs, value: value, conversationID: conversationID)
    }

    /// Allow the other party's AI to consume my marked context (and reciprocally
    /// my AI to consume theirs) for a bounded duration, in this scope.
    func grantContextSharing(
        scope: AIContextGrant.Scope, minutes: Int, conversationID: String, threadID: String? = nil
    ) async {
        try? await runtime.grantAIContext(
            scope: scope, durationSeconds: Int64(minutes * 60),
            conversationID: conversationID, threadID: threadID)
    }

    func withdrawContextSharing(scope: AIContextGrant.Scope) async {
        await runtime.withdrawAIContext(scope: scope)
    }

    /// Whether my own grant is currently live for a scope (drives the toggle UI).
    func iGrantedContext(scope: AIContextGrant.Scope, now: Int64) -> Bool {
        guard let until = aiContextGrants[scope.tag]?[myIdentityHex] else { return false }
        return until > now
    }

    /// Stop MY AI from replying in this conversation — the single honest off-switch.
    /// Closes the on-wire ai_window, withdraws the conversation sharing grant, and
    /// mutes a solo "My AI" chat to "off". See `PersonaRuntime.endMyAIWindow`.
    func stopAIHere(conversationID: String) async {
        await runtime.endMyAIWindow(conversationID: conversationID)
    }

    /// Whether MY AI is currently set up to reply here — a live window, a live
    /// context grant, OR a solo "My AI" group (just me) that isn't muted to "off".
    /// Drives whether the single "Stop my AI replying here" control is shown.
    func aiActiveHere(conversationID: String, now: Int64) -> Bool {
        if let until = aiWindows[conversationID]?[myIdentityHex], until > now { return true }
        if iGrantedContext(scope: .conversation(conversationID), now: now) { return true }
        if let row = conversations.first(where: { $0.id == conversationID }),
            row.isGroup, row.memberCount <= 1,
            AppSession.conversationContextMode(conversationID, siloID: siloID) != "off"
        {
            return true  // a solo AI chat auto-replies unless explicitly muted
        }
        return false
    }

    /// A one-shot diagnostic: runs the active provider on a sample transcript
    /// and returns its reply, or the precise error (Settings "Test AI now").
    func testAI() async -> String {
        do { return try await runtime.probeAI() }
        catch { return "⚠️ " + Self.describeAgentError(error) }
    }

    // MARK: - Relay status (Feature 5)

    func refreshRelayStatuses() async {
        relayStatuses = await runtime.relayStatuses()
    }

    func checkRelaysNow() async {
        relayStatuses = await runtime.checkRelays()
    }

    func createGroup(name: String, members: [String]) async -> String? {
        try? await runtime.createGroup(name: name, memberIdentityHexes: members)
    }

    /// Creates a solo AI chat (just you + your tethered AIs). Refreshes the row
    /// so it appears immediately, then returns its id for navigation.
    func createSelfChat() async -> String? {
        guard let id = try? await runtime.createSelfChat() else { return nil }
        await refreshConversationRow(id, lastMessage: nil)
        return id
    }

    /// Adds verified contacts to a group/solo conversation at any time.
    func addMembers(_ conversationID: String, add identityHexes: [String]) async {
        try? await runtime.addMembers(conversationID: conversationID, add: identityHexes)
        await refreshConversationRow(conversationID, lastMessage: nil)
    }

    /// Per-AI assembled context windows — exactly what each tethered AI receives
    /// for a conversation (system prompt + policy + depth + transcript), for the
    /// Context inspector. Remote AIs are already codename-redacted.
    func contextInspections(conversationID: String) async
        -> [PersonaRuntime.AIContextInspection]
    {
        await runtime.contextInspections(conversationID: conversationID)
    }

    /// The `acp` ("Mac coding harness") backend's live connectedness for the
    /// Settings status line: the consented `coding_agent` node's identity hex +
    /// local name, or nil when none is paired AND consented (C-3). This is the
    /// SAME signal `PersonaRuntime.rebindRelayACPProviders` uses to decide whether
    /// to swap in the live `ACPAgentProvider`, so the status line agrees exactly
    /// with what the backend is actually running — never "connected" while it's
    /// still on the Demo stub.
    func consentedCodingAgentNode() async -> (identityHex: String, name: String)? {
        await runtime.consentedCodingAgentNodeInfo()
    }

    /// Read-only summary of the PRIMARY AI's effective gather mode for a
    /// conversation, for the in-chat "AI here" glance chip and the Details echo.
    /// Resolves the per-conversation override over the AI's own policy exactly as
    /// the engine does (PersonaRuntime.contextFor: override "off"/"marked"/"full"
    /// maps the AI's "off"/"strict"/"active"). No engine/crypto state is touched —
    /// it reads the same persisted settings (`loadConfiguredAIs`,
    /// `conversationContextMode`, `firewallEnabled`) the runtime reads each turn,
    /// so the chip and Details stay in lockstep with what the AI actually does.
    ///
    /// - `mode` is one of "off" | "strict" | "active" (engine vocabulary).
    /// - `isRemote` is true when the primary AI sends context off-device.
    /// - `firewallOn` is the egress-firewall state (name redaction + byte bound).
    func primaryAIContextSummary(_ conversationID: String)
        -> (mode: String, isRemote: Bool, firewallOn: Bool)
    {
        // The primary AI is the first ENABLED one, matching the runtime's
        // `makeRuntimeAIs(...).filter(\.isEnabled)` → `ais[0]`.
        let enabled = AppSession.loadConfiguredAIs(siloID: siloID).filter(\.isEnabled)
        let primary = enabled.first
        // Honest at-a-glance state: "off" must mean NO enabled AI gathers or responds
        // here — not merely that the FIRST AI is off. With two AIs (primary "off", a
        // second "active") the chip used to read "AI off here" while the second AI still
        // replied — the user's "the off in this chat is still going to the AI". Resolve
        // from the STRONGEST policy across ALL enabled AIs (active > strict > off) so the
        // chip never under-reports a participating AI. A per-conversation override below
        // still wins (it forces every AI to the same mode in `resolvedPolicy`).
        func policyRank(_ p: String) -> Int { p == "active" ? 2 : (p == "strict" ? 1 : 0) }
        var mode = enabled.map(\.effectivePolicy).max(by: { policyRank($0) < policyRank($1) }) ?? "off"
        switch AppSession.conversationContextMode(conversationID, siloID: siloID) {
        case "off": mode = "off"
        case "marked": mode = "strict"
        case "full": mode = "active"
        default: break
        }
        let isRemote = primary.map { ConfiguredAI.isRemote($0.kind) } ?? false
        // The user's own trusted Mac coding agent defaults the egress firewall OFF
        // (matches PersonaRuntime.contextFor). `remoteDevControlConsent` is the sync,
        // user-controlled gate — only ever granted to a paired `coding_agent` node —
        // so it's a faithful proxy for `isConsentedCodingAgentNode` here without
        // reaching into actor state. An explicit per-conversation override still wins.
        let trustedNode = AppSession.remoteDevControlConsent(nodeID: conversationID, siloID: siloID)
        let firewallOn =
            AppSession.conversationFirewall(conversationID, siloID: siloID)
            ?? (trustedNode ? false : AppSession.firewallEnabled)
        return (mode, isRemote, firewallOn)
    }

    /// Ensure a "Mac-Tethered-AI" (`acp`) entry exists under Settings ▸ AI once a
    /// node is paired+consented, so it shows in Models AND participates in the "My
    /// AI" solo chat. Idempotent: adds AT MOST one and never overrides the user's own
    /// config (if they already have an `acp` AI, this is a no-op). Returns true if it
    /// added one — the caller should re-resolve providers (`applyAIProvider`) so it
    /// goes live. Persists only; the runtime rebind is the caller's job.
    func ensureMacTetheredAIConfigured(nodeName: String?) -> Bool {
        var ais = AppSession.loadConfiguredAIs(siloID: siloID)
        guard !ais.contains(where: { $0.kind == "acp" }) else { return false }
        let trimmed = (nodeName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        ais.append(
            ConfiguredAI(
                id: UUID().uuidString,
                name: trimmed.isEmpty ? "Mac-Tethered-AI" : trimmed,
                kind: "acp", enabled: true))
        AppSession.saveConfiguredAIs(ais, siloID: siloID)
        refreshAITypes()
        return true
    }

    /// Rebuild the `agentName -> backend type` cache from the persisted AI config.
    /// Cheap; call on conversation appear so a bubble badge reflects Settings edits.
    func refreshAITypes() {
        var map: [String: AITypeRef] = [:]
        for ai in AppSession.loadConfiguredAIs(siloID: siloID) {
            map[ai.name] = AITypeRef(kind: ai.kind, model: ai.model)
        }
        aiTypeByName = map
    }

    /// The backend-type badge (an SF Symbol OR an emoji glyph) for an agent bubble,
    /// resolved from the authoring AI's configured kind. Only MY OWN AIs are
    /// resolvable — a peer's backend isn't broadcast (privacy) — so a peer's AI
    /// bubble returns nil and keeps the generic sparkles signal.
    func aiTypeBadge(agentName: String?, isMine: Bool) -> (symbol: String?, glyph: String?)? {
        guard isMine, let agentName, let ref = aiTypeByName[agentName] else { return nil }
        return AITypeIcon.badge(kind: ref.kind, model: ref.model, name: agentName)
    }

    func block(_ identityHex: String) async {
        await runtime.setBlocked(identityHex, blocked: true)
    }

    /// Accepts a message request: the held handshake replays, the conversation
    /// materializes, and the requests row clears. Returns the conversation id
    /// so the UI can navigate straight into it.
    func acceptRequest(_ senderNostrPubkeyHex: String) async -> String? {
        guard
            let conversationID = try? await runtime.acceptMessageRequest(
                senderNostrPubkeyHex: senderNostrPubkeyHex)
        else { return nil }
        messageRequests.removeAll { $0 == senderNostrPubkeyHex }
        // The replayed envelope's events may have landed already; make sure
        // the row exists even if the held message is still decrypting.
        await refreshConversationRow(
            conversationID,
            lastMessage: messagesByConversation[conversationID]?.last { $0.threadID == nil })
        return conversationID
    }

    func declineRequest(_ senderNostrPubkeyHex: String) async {
        await runtime.declineMessageRequest(senderNostrPubkeyHex: senderNostrPubkeyHex)
        messageRequests.removeAll { $0 == senderNostrPubkeyHex }
    }

    /// Starts a relay-free conversation with a discovered nearby peer.
    func startNearby(_ identityHex: String, firstMessage: String) async -> String? {
        guard
            let conversationID = try? await runtime.startNearbyConversation(
                identityHex: identityHex, firstMessage: firstMessage.isEmpty ? "👋" : firstMessage)
        else { return nil }
        nearbyContacts.removeAll { $0.identityHex == identityHex }
        await refreshConversationRow(
            conversationID,
            lastMessage: messagesByConversation[conversationID]?.last { $0.threadID == nil })
        return conversationID
    }

    func renameContact(_ identityHex: String, nickname: String?) async {
        await runtime.renameContact(identityHex, nickname: nickname)
        await refreshConversationRow(
            identityHex,
            lastMessage: messagesByConversation[identityHex]?.last { $0.threadID == nil })
    }

    func setVerified(_ identityHex: String, verified: Bool) async {
        await runtime.setVerified(identityHex, verified: verified)
        if verified {
            safetyCodeChangedFor.remove(identityHex)
        }
    }

    func setMyAlias(_ alias: String?) async {
        await runtime.setMyAlias(alias)
        contactNames[myIdentityHex] = alias ?? personaName
    }

    func togglePinned(_ conversationID: String) async {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].pinned.toggle()
        let pinned = conversations[index].pinned
        conversations.sort { ($0.pinned ? 1 : 0, $0.lastActivity) > ($1.pinned ? 1 : 0, $1.lastActivity) }
        await runtime.setPinned(conversationID, pinned: pinned)
    }

    func deleteConversation(_ conversationID: String) async {
        conversations.removeAll { $0.id == conversationID }
        messagesByConversation[conversationID] = nil
        threadsByConversation[conversationID] = nil
        await runtime.deleteConversation(conversationID)
    }

    func messages(for conversationID: String) -> [StoredMessage] {
        (messagesByConversation[conversationID] ?? []).filter { $0.threadID == nil }
    }

    /// A thread's recorded messages, in order. Scoped to the thread's OWN
    /// conversation: a thread is created under exactly one conversation
    /// (`threadsByConversation`), and every thread message carries that
    /// `conversationID` (see `apply(.messageAdded)`), so this yields the same
    /// set as scanning every conversation — but at O(messages in this one
    /// conversation) instead of O(all messages across all conversations). The
    /// single conversation's array preserves insertion/`sentAt` order, so the
    /// visible ordering is identical. Pass `conversationID` (the caller —
    /// `ThreadVM` — always has it).
    func threadMessages(_ threadID: String, conversationID: String) -> [StoredMessage] {
        (messagesByConversation[conversationID] ?? []).filter { $0.threadID == threadID }
    }

    func activeWindowBanner(conversationID: String, now: Int64) -> (name: String, until: Int64)? {
        guard let windows = aiWindows[conversationID] else { return nil }
        // My OWN window in a conversation muted to "off" posts nothing — the reply
        // path short-circuits on `aiSuppressed` — so don't claim "AI active" for it.
        // (A peer's window still shows: their AI's activity isn't gated by my mute.)
        let mutedHere = AppSession.conversationContextMode(conversationID, siloID: siloID) == "off"
        for (identityHex, until) in windows where until > now {
            if identityHex == myIdentityHex && mutedHere { continue }
            return (contactNames[identityHex] ?? "Contact", until)
        }
        return nil
    }
}
