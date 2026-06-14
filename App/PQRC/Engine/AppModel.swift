import Foundation
import Observation
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
}

struct ThreadVM: Identifiable, Hashable {
    let id: String
    let conversationID: String
    var title: String
    var messageCount: Int
}

/// A nearby (binding-verified, relay-free) peer for the New Conversation list.
struct NearbyVM: Identifiable, Hashable {
    var id: String { identityHex }
    let identityHex: String
    let name: String
}

/// Main-actor view state for one persona, fed by its `PersonaRuntime`.
@MainActor
@Observable
final class AppModel {
    let runtime: PersonaRuntime
    let personaName: String

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
    var loopGuardPaused: Set<String> = []
    var protocolViolations: [String] = []
    /// Conversations with a pending safety-code-change warning (APP-SPEC §6.2).
    var safetyCodeChangedFor: Set<String> = []
    var prekeyCount = 0
    var contactNames: [String: String] = [:]
    /// Nearby peers discovered over the local link (SPEC §10) — startable with
    /// no relay. Populated only when the Nearby setting is on.
    var nearbyContacts: [NearbyVM] = []
    /// Whether the Nearby (local-link) path is active; set at start. Drives the
    /// relay-free "Nearby" section in New Conversation.
    var localLinkEnabled = false

    private var pumpTask: Task<Void, Never>?

    init(runtime: PersonaRuntime, personaName: String) {
        self.runtime = runtime
        self.personaName = personaName
    }

    func start(
        inMemoryStore: Bool, storeURL: URL? = nil,
        relayURLs: [String] = ["local://relay"]
    ) async throws {
        let events = try await runtime.bootstrap(
            inMemoryStore: inMemoryStore, storeURL: storeURL, relayURLs: relayURLs)
        myNpub = await runtime.npub
        myIdentityHex = await runtime.identityHex
        prekeyCount = await runtime.oneTimePrekeyCount()
        contactNames[myIdentityHex] = personaName
        localLinkEnabled = await runtime.isLocalLinkEnabled
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
        case .loopGuardChanged(let threadID, let paused):
            if paused {
                loopGuardPaused.insert(threadID)
            } else {
                loopGuardPaused.remove(threadID)
            }
        case .safetyCodeChanged(let identityHex):
            safetyCodeChangedFor.insert(identityHex)
        case .nearbyDiscovered:
            nearbyContacts = await runtime.nearbyList().map {
                NearbyVM(identityHex: $0.identityHex, name: $0.name)
            }
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
        }
        contactNames[id] = title
        var row = conversations.first { $0.id == id }
            ?? ConversationVM(
                id: id, title: title, isGroup: roster != nil, lastMessage: "",
                lastActivity: 0, pinned: false, verified: false,
                memberCount: roster?.members.count ?? 2)
        row.title = title
        row.verified = verified
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

    private var lastReadAt: [String: Int64] {
        get {
            ((UserDefaults.standard.dictionary(forKey: "lastReadAt") as? [String: Int]) ?? [:])
                .mapValues(Int64.init)
        }
        set {
            UserDefaults.standard.set(newValue.mapValues(Int.init), forKey: "lastReadAt")
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

    func sendAsAI(_ text: String, conversationID: String) async {
        try? await runtime.sendAsMyAI(text, conversationID: conversationID)
    }

    /// Surfaced when an AI action fails (e.g. a bad Anthropic key or network),
    /// so the user sees *why* instead of silently getting nothing.
    var agentError: String?

    func draft(conversationID: String, threadID: String? = nil) async -> String? {
        do {
            return try await runtime.draftReply(
                conversationID: conversationID, threadID: threadID).text
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

    func createThread(conversationID: String, title: String) async -> String? {
        try? await runtime.createThread(conversationID: conversationID, title: title)
    }

    func inviteAI(threadID: String, minutes: Int) async {
        try? await runtime.inviteMyAI(threadID: threadID, durationSeconds: Int64(minutes * 60))
    }

    func withdrawAI(threadID: String) async {
        await runtime.withdrawMyAI(threadID: threadID)
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

    func threadMessages(_ threadID: String) -> [StoredMessage] {
        (messagesByConversation.values.flatMap { $0 }).filter { $0.threadID == threadID }
    }

    func activeWindowBanner(conversationID: String, now: Int64) -> (name: String, until: Int64)? {
        guard let windows = aiWindows[conversationID] else { return nil }
        for (identityHex, until) in windows where until > now {
            return (contactNames[identityHex] ?? "Contact", until)
        }
        return nil
    }
}
