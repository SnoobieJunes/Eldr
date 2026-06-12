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
}

struct ThreadVM: Identifiable, Hashable {
    let id: String
    let conversationID: String
    var title: String
    var messageCount: Int
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
    var loopGuardPaused: Set<String> = []
    var protocolViolations: [String] = []
    /// Conversations with a pending safety-code-change warning (APP-SPEC §6.2).
    var safetyCodeChangedFor: Set<String> = []
    var prekeyCount = 0
    var contactNames: [String: String] = [:]

    private var pumpTask: Task<Void, Never>?

    init(runtime: PersonaRuntime, personaName: String) {
        self.runtime = runtime
        self.personaName = personaName
    }

    func start(inMemoryStore: Bool, storeURL: URL? = nil) async throws {
        let events = try await runtime.bootstrap(inMemoryStore: inMemoryStore, storeURL: storeURL)
        myNpub = await runtime.npub
        myIdentityHex = await runtime.identityHex
        prekeyCount = await runtime.oneTimePrekeyCount()
        contactNames[myIdentityHex] = personaName
        onboarded = true
        pumpTask = Task { [weak self] in
            for await event in events {
                await self?.apply(event)
            }
        }
    }

    private func apply(_ event: RuntimeEvent) async {
        switch event {
        case .messageAdded(let message):
            var list = messagesByConversation[message.conversationID] ?? []
            list.append(message)
            messagesByConversation[message.conversationID] = list
            await refreshConversationRow(message.conversationID, lastMessage: message)
            if let threadID = message.threadID {
                refreshThreadCounts(conversationID: message.conversationID, threadID: threadID)
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
        }
    }

    private func refreshConversationRow(_ id: String, lastMessage: StoredMessage?) async {
        let roster = await runtime.groupRoster(id)
        let title: String
        if let roster {
            title = roster.name
        } else {
            title = await runtime.contactName(id)
        }
        contactNames[id] = title
        var row = conversations.first { $0.id == id }
            ?? ConversationVM(
                id: id, title: title, isGroup: roster != nil, lastMessage: "",
                lastActivity: 0, pinned: false, verified: false,
                memberCount: roster?.members.count ?? 2)
        row.title = title
        row.memberCount = roster?.members.count ?? 2
        if let lastMessage, lastMessage.threadID == nil {
            row.lastMessage = lastMessage.text
            row.lastActivity = lastMessage.sentAt
        }
        conversations.removeAll { $0.id == id }
        conversations.append(row)
        conversations.sort { ($0.pinned ? 1 : 0, $0.lastActivity) > ($1.pinned ? 1 : 0, $1.lastActivity) }
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

    func draft(conversationID: String, threadID: String? = nil) async -> String? {
        try? await runtime.draftReply(conversationID: conversationID, threadID: threadID).text
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

    func createGroup(name: String, members: [String]) async -> String? {
        try? await runtime.createGroup(name: name, memberIdentityHexes: members)
    }

    func block(_ identityHex: String) async {
        await runtime.setBlocked(identityHex, blocked: true)
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
