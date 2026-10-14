// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCAgent
import PQRCCore
import PQRCNostr

// WS-N2/N3 (DEVIATIONS AC174): threads, AI windows, invites, loop guard, standing
// grants and an OpenAI-compatible provider, on the SAME AgentEngine that iOS uses. Every
// gate stays in the engine (fail closed). EldrClient only persists the signed
// announcements and replays them at launch, because each CLI command is its own
// process, and the engine re-verifies every signature during that replay.

/// Conversation ids shared by the CLI, GTK and the engine sink: a contact's identity hex,
/// `group:<groupID>`.
public enum UIConversation {
    public static let groupPrefix = "group:"
    public static func group(_ id: String) -> String { groupPrefix + id }
    public static func groupID(_ conversationID: String) -> String? {
        conversationID.hasPrefix(groupPrefix) ? String(conversationID.dropFirst(groupPrefix.count)) : nil
    }
}

/// Late-bound, weak reference from the engine's sink back to the client (the engine is
/// built inside the client's init, before `self` exists). An actor, so it's Sendable.
actor ClientRef {
    weak var client: EldrClient?
    func set(_ c: EldrClient) { client = c }
}

/// The engine's ONLY output path (APP-SPEC §8 recording guarantee): everything the
/// engine approves goes out through `EldrClient.post` as a signed agent message.
struct ClientAgentSink: AgentMessageSink {
    let ref: ClientRef
    func postAgentMessage(_ body: MessageBody, threadID: String, agentName: String?, agentAIID: String?) async throws {
        guard let c = await ref.client else { throw PQRCError.sessionNotEstablished }
        try await c.postMyAIThreadMessage(body, threadID: threadID, agentName: agentName)
    }
    func postAgentReply(_ body: MessageBody, conversationID: String, agentName: String?, agentAIID: String?) async throws {
        guard let c = await ref.client else { throw PQRCError.sessionNotEstablished }
        try await c.postMyAIWindowReply(body, conversationID: conversationID, agentName: agentName)
    }
    func reportAgentFailure(_ reason: String, threadID: String?, agentName: String?) async {
        await ref.client?.noteMyAIFailure(reason, threadID: threadID)
    }
}

extension EldrClient {
    public static let aiKeyAccount = "ai-key"
    /// The AI-window / invite durations offered (SPEC §13: bounded only).
    public static let aiDurationChoices: [Int64] = [60 * 60, 8 * 60 * 60, 24 * 60 * 60]
    static let maxTranscript = 40

    var aiState: AIState {
        get { state.ai ?? AIState() }
        set { state.ai = newValue }
    }
    public var threads: [ThreadRecord] { state.threads ?? [] }
    public var settings: ClientSettings { state.settings ?? ClientSettings() }
    public var providerConfig: AIProviderConfig? { aiState.provider }
    public var myWindowConversation: String? { aiState.myWindowConversation }
    var myName: String { settings.displayName ?? "me" }

    func emit(_ e: ClientEvent) { eventSink?.yield(e) }

    // MARK: Conversations

    /// A query → conversation id: `group:<q>`, a contact, or else a group.
    public func resolveConversation(_ q: String) throws -> String {
        if let g = UIConversation.groupID(q) { return UIConversation.group(try group(matching: g).groupID) }
        if let c = try? contact(matching: q) { return c.identityHex }
        return UIConversation.group(try group(matching: q).groupID)
    }

    func targets(_ conv: String) throws -> (contacts: [ContactRecord], group: GroupRecord?, skipped: Int) {
        if let gid = UIConversation.groupID(conv) {
            guard let g = groups.first(where: { $0.groupID == gid }) else { throw EldrClientError.unknownGroup(gid) }
            let others = g.members.filter { $0 != identityHex }
            let cs = state.contacts.filter { others.contains($0.identityHex) }
            return (cs, g, others.count - cs.count)
        }
        return ([try contact(matching: conv)], nil, 0)
    }

    /// The one send path for threads and AI. In AI-account mode it attaches the live
    /// sponsorship. A `.agent` post from a human identity rides on that human's own
    /// window or invite, and the receiver checks that per message.
    @discardableResult
    func post(
        _ text: String, conversationID conv: String, threadID: String? = nil,
        participant requested: ParticipantType = .human, aiWindow: AIWindowAnnouncement? = nil,
        aiInvite: AIInvite? = nil, threadCreate: ThreadCreate? = nil, isContext: Bool = false,
        mine: Bool = false, aiContextGrant: AIContextGrant? = nil, aiContext: Bool = false,
        coauthored: Bool = false, aiContextMark: AIContextMark? = nil, agentName: String? = nil
    ) async throws -> (reached: Int, skipped: Int) {
        let t = try targets(conv)
        let participant: ParticipantType = isAgent ? .agent : requested
        var body = MessageBody(
            text: text, sentAt: clock.now(), messageID: UUID().uuidString,
            group: t.group.map { RumorContent.GroupRef(id: $0.groupID) },
            thread: threadID.map { RumorContent.ThreadRef(id: $0) },
            threadCreate: threadCreate, aiInvite: aiInvite, isContext: isContext ? true : nil)
        body.aiContextGrant = aiContextGrant
        body.aiContextMark = aiContextMark
        if aiContext { body.aiContext = true }
        if coauthored { body.coauthored = true }
        if isAgent { body.agentSponsorship = try liveSponsorship() }
        // @-mentions (iOS C2): people and AIs, inside the ciphertext. Human text only.
        if participant == .human, !text.isEmpty {
            let ms = resolveMentions(in: text)
            if !ms.isEmpty { body.mentions = ms }
        }
        var reached = 0
        var lastError: Error?
        for c in t.contacts {
            do { _ = try await deliver(body, to: c, participant: participant, aiWindow: aiWindow); reached += 1 }
            catch { lastError = error }
        }
        var e = HistoryEntry(
            id: body.messageID ?? UUID().uuidString, peerIdentityHex: t.group == nil ? conv : identityHex,
            outgoing: true, text: text, sentAt: body.sentAt, agent: participant == .agent, sponsorship: .human)
        if let s = body.agentSponsorship {
            e.sponsorship = .sponsored(sponsorIdentityHex: s.enabledBy.hexString, label: s.label, activeUntil: s.activeUntil)
        }
        e.groupID = t.group?.groupID
        e.threadID = threadID
        e.mine = mine ? true : nil
        e.aiContext = aiContext ? true : nil
        e.coauthored = coauthored ? true : nil
        e.agentName = agentName
        // "Not sent" (iOS localStatus .failed): there were recipients and none was reached.
        if reached == 0, lastError != nil, !t.contacts.isEmpty { e.failed = true }
        // A content-free control (a context mark) renders nothing (iOS N25).
        if !text.isEmpty { appendHistory(e) }
        // Engine-posted agent turns are counted by the engine itself.
        if let threadID, participant == .human, !text.isEmpty {
            await engine.recordThreadMessage(threadID: threadID, participantType: .human)
        }
        try await persist()
        if reached == 0, let lastError { throw lastError }
        return (reached, t.skipped)
    }

    /// Send text (human) into any conversation or thread.
    @discardableResult
    public func say(_ text: String, in conversationQuery: String, thread: String? = nil) async throws -> (reached: Int, skipped: Int) {
        if let thread {
            let t = try self.thread(matching: thread)
            let r = try await post(text, conversationID: t.conversationID, threadID: t.threadID)
            await afterMySend(text, conversationID: t.conversationID, threadID: t.threadID)
            return r
        }
        let conv = try resolveConversation(conversationQuery)
        let r = try await post(text, conversationID: conv)
        await afterMySend(text, conversationID: conv, threadID: nil)
        return r
    }

    // MARK: Threads (D7)

    public func thread(matching q: String) throws -> ThreadRecord {
        let ql = q.lowercased()
        if let t = threads.first(where: { $0.threadID.lowercased() == ql }) { return t }
        let hits = threads.filter { $0.title.lowercased() == ql || $0.threadID.lowercased().hasPrefix(ql) }
        guard let t = hits.first else { throw EldrClientError.unknownThread(q) }
        guard hits.count == 1 else { throw EldrClientError.ambiguousContact(q) }
        return t
    }

    public func threadHistory(_ threadID: String) -> [HistoryEntry] { history.filter { $0.threadID == threadID } }

    @discardableResult
    public func createThread(in conversationQuery: String, title: String) async throws -> ThreadRecord {
        let conv = try resolveConversation(conversationQuery)
        let id = UUID().uuidString
        let rec = ThreadRecord(threadID: id, conversationID: conv, title: title, createdBy: identityHex)
        state.threads = threads + [rec]
        let create = ThreadCreate(threadID: id, title: title, anchorMessageID: nil, createdBy: identityHex)
        try await post("started the thread \"\(title)\"", conversationID: conv, threadID: id, threadCreate: create)
        return rec
    }

    // MARK: AI window (conversation scope) and invite (thread scope)

    /// Opens MY window for one conversation (my AI replies to humans there). Opening it
    /// elsewhere first closes the old one ON THE WIRE, so the old peers' indicator clears.
    @discardableResult
    public func startAIWindow(in conversationQuery: String, seconds: Int64) async throws -> Int64 {
        // Human-only (SPEC §13.3): an AI account can never sign its own window/invite.
        guard !isAgent else { throw EldrClientError.agentCannotSponsor }
        guard Self.aiDurationChoices.contains(seconds) else { throw EldrClientError.badDuration }
        let conv = try resolveConversation(conversationQuery)
        if let old = myWindowConversation, old != conv { try await endAIWindow() }
        let ann = try await engine.startMyWindow(durationSeconds: seconds)
        var a = aiState
        a.myWindowConversation = conv
        a.windows = (a.windows ?? []).filter { $0.announcement.enabledBy.hexString != identityHex }
            + [StoredWindow(conversationID: conv, announcement: ann)]
        a.activeSince = (a.activeSince ?? [:]).merging([conv: Int64(nextHistorySeq)]) { _, n in n }
        aiState = a
        try await post("turned on their AI for \(seconds / 3600)h", conversationID: conv, aiWindow: ann)
        emit(.aiWindow(identityHex: identityHex, conversationID: conv, until: ann.activeUntil))
        return ann.activeUntil
    }

    /// Closes my window now with a signed closing announcement (it can only revoke).
    public func endAIWindow() async throws {
        guard let conv = myWindowConversation else { return }
        let ann = try await engine.endMyWindowEarly()
        var a = aiState
        a.myWindowConversation = nil
        a.windows = (a.windows ?? []).filter { $0.announcement.enabledBy.hexString != identityHex }
        aiState = a
        try? await post("turned off their AI", conversationID: conv, aiWindow: ann)
        try await persist()
        emit(.aiWindow(identityHex: identityHex, conversationID: conv, until: nil))
    }

    /// Invites MY AI into a thread for a bounded time; it may take a turn at once.
    @discardableResult
    public func inviteMyAI(thread q: String, seconds: Int64) async throws -> Int64 {
        // Human-only (SPEC §13.3): an AI account can never sign its own window/invite.
        guard !isAgent else { throw EldrClientError.agentCannotSponsor }
        guard Self.aiDurationChoices.contains(seconds) else { throw EldrClientError.badDuration }
        let t = try thread(matching: q)
        let inv = try await engine.startMyInvite(threadID: t.threadID, durationSeconds: seconds)
        storeInvite(inv)
        var a = aiState
        a.activeSince = (a.activeSince ?? [:]).merging([t.threadID: Int64(nextHistorySeq)]) { _, n in n }
        aiState = a
        try await post("invited their AI to the thread", conversationID: t.conversationID, threadID: t.threadID, aiInvite: inv)
        emit(.aiInvite(identityHex: identityHex, threadID: t.threadID, until: inv.activeUntil))
        spawnAI(conversationID: t.conversationID, threadID: t.threadID)
        return inv.activeUntil
    }

    /// Withdraws my AI from a thread. Linux also sends a signed invite with
    /// `active_until = now`. Like `endMyWindowEarly`, it can only revoke, so peers'
    /// indicators clear instead of running on until expiry.
    public func withdrawMyAI(thread q: String) async throws {
        let t = try thread(matching: q)
        await engine.withdrawMyInvite(threadID: t.threadID)
        let closing = try AIInvite.make(threadID: t.threadID, activeUntil: clock.now(), identity: identity)
        storeInvite(closing)
        try? await post("withdrew their AI from the thread", conversationID: t.conversationID, threadID: t.threadID, aiInvite: closing)
        try await persist()
        emit(.aiInvite(identityHex: identityHex, threadID: t.threadID, until: nil))
    }

    func storeInvite(_ inv: AIInvite) {
        var a = aiState
        a.invites = (a.invites ?? []).filter {
            !($0.invite.thread.id == inv.thread.id && $0.invite.enabledBy == inv.enabledBy)
        } + [StoredInvite(invite: inv)]
        aiState = a
    }

    /// Live windows (identity → until) for a conversation, and invites for a thread.
    public func activeWindows(in conv: String) async -> [String: Int64] {
        var out: [String: Int64] = [:]
        for w in aiState.windows ?? [] where w.conversationID == conv {
            let who = w.announcement.enabledBy.hexString
            if let u = await engine.activeWindow(for: who) { out[who] = u }
        }
        return out
    }
    public func activeInvites(thread: String) async -> [String: Int64] {
        var out: [String: Int64] = [:]
        for i in aiState.invites ?? [] where i.invite.thread.id == thread {
            let who = i.invite.enabledBy.hexString
            if let u = await engine.activeInvite(threadID: thread, identityHex: who) { out[who] = u }
        }
        return out
    }
    public func loopGuardActive(thread: String) async -> Bool { await engine.loopGuardActive(threadID: thread) }

    // MARK: Receive

    func receiveAI(_ m: ReceivedMessage, conversationID conv: String) async -> (events: [ClientEvent], threadID: String?, authorizedUntil: Int64?) {
        var events: [ClientEvent] = []
        let sender = m.senderIdentityHex
        let now = clock.now()
        if let w = m.aiWindow, (try? await engine.receiveWindow(w, fromSenderIdentityHex: sender)) != nil {
            var a = aiState
            a.windows = (a.windows ?? []).filter { $0.announcement.enabledBy.hexString != sender }
                + [StoredWindow(conversationID: conv, announcement: w)]
            aiState = a
            events.append(.aiWindow(identityHex: sender, conversationID: conv, until: w.activeUntil > now ? w.activeUntil : nil))
        }
        // A thread is adopted only if its creator is the sender, and an existing thread
        // can never be moved to another conversation.
        if let tc = m.body.threadCreate, tc.createdBy == sender, !threads.contains(where: { $0.threadID == tc.threadID }) {
            let rec = ThreadRecord(threadID: tc.threadID, conversationID: conv, title: tc.title, createdBy: sender)
            state.threads = threads + [rec]
            events.append(.threadCreated(rec))
        }
        var threadID: String?
        if let ref = m.body.thread, let t = threads.first(where: { $0.threadID == ref.id }), t.conversationID == conv {
            threadID = t.threadID
        }
        if let inv = m.body.aiInvite, let tid = threadID, inv.thread.id == tid,
            (try? await engine.receiveInvite(inv, fromSenderIdentityHex: sender)) != nil
        {
            storeInvite(inv)
            events.append(.aiInvite(identityHex: sender, threadID: tid, until: inv.activeUntil > now ? inv.activeUntil : nil))
        }
        if let g = m.aiContextGrant, (try? await engine.receiveContextGrant(g, fromSenderIdentityHex: sender)) != nil {
            storeContextGrant(g)
            events.append(.aiContextGrant(identityHex: sender, conversationID: conv, threadID: threadID,
                                          axis: g.scope.axis, until: g.activeUntil > now ? g.activeUntil : nil))
        }
        if let tid = threadID { await engine.recordThreadMessage(threadID: tid, participantType: m.participantType) }
        var authorized: Int64?
        if m.participantType == .agent {
            if let tid = threadID {
                authorized = await engine.activeInvite(threadID: tid, identityHex: sender)
            } else if (aiState.windows ?? []).contains(where: { $0.announcement.enabledBy.hexString == sender && $0.conversationID == conv }) {
                authorized = await engine.activeWindow(for: sender)
            }
        }
        return (events, threadID, authorized)
    }

    /// After a received message: let MY AI take its turn if (and only if) the engine's
    /// gates allow it. The provider runs off the receive pump.
    func scheduleMyAI(after m: ReceivedMessage, conversationID conv: String, threadID: String?) {
        guard m.senderIdentityHex != identityHex, !tetheredAIs().isEmpty else { return }
        if threadID == nil {
            // Conversation scope answers humans only, and only in MY window's conversation.
            guard m.participantType == .human, myWindowConversation == conv else { return }
        }
        // participant_type is sender-asserted: a peer's bot labelled "human" resets the
        // loop guard on every message. Cap autonomous turns per scope regardless of labels.
        guard autoTurnLimiter.allow(scope: threadID ?? conv, now: clock.now()) else { return }
        spawnAI(conversationID: conv, threadID: threadID)
    }

    /// Runs my AIs' autonomous turns for a scope, in roster order (ordered critique
    /// when enabled), each one re-reading the history so it sees the AIs before it.
    /// Every post still passes the engine's window/invite/loop-guard gate. `only`
    /// restricts to the named AIs (an @-mention). `solo` = a chat with no other human.
    func spawnAI(conversationID conv: String, threadID: String?, only: Set<String>? = nil, solo: Bool = false) {
        guard contextMode(conv) != "off" else { return }
        var turn = aiTurnOrder(conversationID: conv, threadID: threadID)
        if let only { turn = turn.filter { only.contains($0.ai.name.lowercased()) } }
        guard !turn.isEmpty else { return }
        let engine = self.engine
        let t = Task { [weak self] in
            for (ai, role) in turn {
                guard let self else { return }
                let ctx = await self.agentContext(conversationID: conv, threadID: threadID, aiRole: role, aiName: ai.name, instructions: ai.instructions)
                if solo {
                    await self.runSoloTurn(ai, context: ctx, conversationID: conv)
                } else if let threadID {
                    _ = await engine.runThreadTurn(provider: ai.provider, context: ctx, threadID: threadID, agentName: ai.name, agentAIID: ai.id)
                } else {
                    _ = await engine.runWindowReply(provider: ai.provider, context: ctx, conversationID: conv, agentName: ai.name, agentAIID: ai.id)
                }
            }
        }
        aiTasks = Array((aiTasks + [t]).suffix(32))
    }

    /// Waits for in-flight AI turns (tests, `stop()`).
    public func settleAI() async {
        let ts = aiTasks
        aiTasks = []
        for t in ts { await t.value }
    }

    /// What the provider may see: this conversation (or thread) since my AI was turned on
    /// there, and never earlier history.
    func agentContext(
        conversationID conv: String, threadID: String?, aiRole: String = AICritiqueRole.primary,
        aiName: String? = nil, instructions: String? = nil
    ) -> AgentContext {
        let mode = contextMode(conv)
        // "marked" (iOS strict): only rows explicitly added to AI context.
        let since = mode == "marked" ? Int64.max : (aiState.activeSince?[threadID ?? conv] ?? Int64.max)
        let gid = UIConversation.groupID(conv)
        let names = Dictionary(state.contacts.map { ($0.identityHex, $0.name ?? String($0.identityHex.prefix(8))) },
                               uniquingKeysWith: { a, _ in a })
        // iOS `aiAuthorGate`: an invited thread member sees every author; outside a
        // thread a PEER's AI content also needs the bilateral ai-axis context grant.
        let peerHumanAllowed = contextSharedNow(conversationID: conv, threadID: threadID, axis: AIContextGrant.Scope.humanAxis)
        let peerAIAllowed = threadID != nil || contextSharedNow(conversationID: conv, threadID: nil, axis: AIContextGrant.Scope.aiAxis)
        let rows = mode == "off" ? [] : history.filter { e in
            let inConv = gid != nil ? e.groupID == gid : (e.peerIdentityHex == conv && e.groupID == nil)
            let peerAI = !e.outgoing && e.agent
            guard inConv, e.threadID == threadID, !peerAI || peerAIAllowed else { return false }
            if Int64(e.seq ?? 0) >= since { return true }
            // "Add to AI Context" (feature 7): my marked messages always; a peer's
            // marked message only under the bilateral human-axis grant (N24/N25).
            guard e.aiContext == true else { return false }
            return e.outgoing || peerHumanAllowed
        }.suffix(Self.maxTranscript)
        let transcript = rows.map { e in
            TranscriptEntry(
                senderIdentityHex: e.outgoing ? identityHex : e.peerIdentityHex,
                senderDisplayName: e.outgoing ? (e.mine == true ? (e.agentName ?? primaryAIName) : myName)
                    : (e.agent ? "\(names[e.peerIdentityHex] ?? "their")'s AI" : (names[e.peerIdentityHex] ?? "them")),
                participantType: (e.agent || e.mine == true) ? .agent : .human, text: e.text)
        }
        return AgentContext(
            myIdentityHex: identityHex, myDisplayName: myName, transcript: Array(transcript),
            threadID: threadID, threadTitle: threads.first { $0.threadID == threadID }?.title,
            instructions: instructions ?? providerConfig?.instructions,
            systemPromptOverride: rolePrompt(aiRole, aiName: aiName, threadID: threadID, conv: conv, instructions: instructions))
    }

    // Sink targets.
    func postMyAIThreadMessage(_ body: MessageBody, threadID: String, agentName: String? = nil) async throws {
        guard let t = threads.first(where: { $0.threadID == threadID }) else { throw EldrClientError.unknownThread(threadID) }
        try await post(body.text, conversationID: t.conversationID, threadID: threadID, participant: .agent,
                       isContext: body.isContext ?? false, mine: true, agentName: agentName)
        emit(.myAI(conversationID: t.conversationID, threadID: threadID, error: nil))
    }
    func postMyAIWindowReply(_ body: MessageBody, conversationID: String, agentName: String? = nil) async throws {
        // Re-check at post time: the window may have moved while the provider ran (F1).
        guard myWindowConversation == conversationID else { return }
        try await post(body.text, conversationID: conversationID, participant: .agent, mine: true, agentName: agentName)
        emit(.myAI(conversationID: conversationID, threadID: nil, error: nil))
    }
    func noteMyAIFailure(_ reason: String, threadID: String?) {
        emit(.myAI(conversationID: threads.first { $0.threadID == threadID }?.conversationID ?? myWindowConversation ?? "",
                   threadID: threadID, error: reason))
    }

    // MARK: Provider (N3)

    /// Test seam (internal): an invite signed by this identity, unsent.
    func signedInvite(threadID: String, activeUntil: Int64) throws -> AIInvite {
        try AIInvite.make(threadID: threadID, activeUntil: activeUntil, identity: identity)
    }

    /// Test seam (internal): replaces the configured provider.
    func setProviderOverride(_ p: (any AgentProvider)?) { providerOverride = p }
    /// Test seam (internal): a provider for one extra AI.
    func setAIOverride(_ id: String, _ p: any AgentProvider) { aiOverrides[id] = p }

    /// Sets (or with nil clears) the OpenAI-compatible endpoint. The key goes into its own
    /// encrypted keystore account. It never goes into the state blob, logs, or argv.
    /// `ELDR_AI_API_KEY` in the environment overrides it at run time.
    public func configureProvider(_ cfg: AIProviderConfig?, apiKey: String?) async throws {
        if let cfg {
            guard AIProviderConfig.kinds.contains(cfg.effectiveKind) else {
                throw EldrClientError.badSetting("unknown AI kind '\(cfg.effectiveKind)' (\(AIProviderConfig.kinds.joined(separator: ", ")))")
            }
            if cfg.effectiveKind == "custom" {
                guard let u = URL(string: cfg.baseURL), let scheme = u.scheme, ["http", "https"].contains(scheme), u.host != nil
                else { throw EldrClientError.badProviderURL(cfg.baseURL) }
            }
            if let apiKey { try store.save(Data(apiKey.utf8), account: Self.aiKeyAccount) }
        } else {
            store.delete(account: Self.aiKeyAccount)
        }
        var a = aiState
        a.provider = cfg
        aiState = a
        try await persist()
    }
    public var hasStoredAPIKey: Bool { store.load(account: Self.aiKeyAccount) != nil }

    func currentProvider() -> (any AgentProvider)? {
        if let providerOverride { return providerOverride }
        guard let cfg = providerConfig else { return nil }
        let key = ProcessInfo.processInfo.environment["ELDR_AI_API_KEY"]
            ?? store.load(account: Self.aiKeyAccount).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return Self.makeProvider(cfg, key: key)
    }

    /// One provider per kind, mirroring iOS `BackendRegistry` (cloud kinds use their
    /// vendor endpoint; an empty model keeps the provider's default).
    static func makeProvider(_ cfg: AIProviderConfig, key: String) -> any AgentProvider {
        let m = cfg.model.isEmpty ? nil : cfg.model
        switch cfg.effectiveKind {
        case "claude": return m.map { AnthropicAPIProvider(apiKey: key, model: $0) } ?? AnthropicAPIProvider(apiKey: key)
        case "openai": return m.map { OpenAIAPIProvider(apiKey: key, model: $0) } ?? OpenAIAPIProvider(apiKey: key)
        case "gemini": return m.map { GeminiAPIProvider(apiKey: key, model: $0) } ?? GeminiAPIProvider(apiKey: key)
        case "openrouter": return m.map { OpenRouterAPIProvider(apiKey: key, model: $0) } ?? OpenRouterAPIProvider(apiKey: key)
        case "groq": return m.map { GroqAPIProvider(apiKey: key, model: $0) } ?? GroqAPIProvider(apiKey: key)
        default:
            return CustomOpenAIProvider(baseURL: cfg.baseURL, apiKey: key, model: cfg.model, requestTimeoutSeconds: cfg.timeoutSeconds ?? 120)
        }
    }

    /// "Test AI now": one draft against a fixed sample. Nothing is sent to anyone.
    public func testProvider() async throws -> String {
        guard let p = currentProvider() else { throw AgentProviderError.notConfigured }
        let sample = AgentContext(
            myIdentityHex: identityHex, myDisplayName: myName,
            transcript: [TranscriptEntry(senderIdentityHex: "sample", senderDisplayName: "Test", participantType: .human,
                                         text: "Hi! Are you working? Reply in one short sentence.")])
        return try await engine.draft(provider: p, context: sample).text
    }

    /// A private draft for me in a conversation or thread. Nothing is sent.
    public func draftWithMyAI(in conversationQuery: String, thread: String? = nil, ai aiName: String? = nil) async throws -> String {
        let ais = tetheredAIs()
        let chosen = try aiName.map { n in
            guard let a = ais.first(where: { $0.name.lowercased() == n.lowercased() || $0.id == n }) else { throw EldrClientError.badSetting("no AI named '\(n)'") }
            return a
        } ?? ais.first
        guard let chosen else { throw AgentProviderError.notConfigured }
        let p = chosen.provider
        let (conv, tid): (String, String?) = try thread.map { let t = try self.thread(matching: $0); return (t.conversationID, t.threadID) }
            ?? (try resolveConversation(conversationQuery), nil)
        // A private draft may read the recent conversation (it never leaves this box
        // except to the provider the user configured).
        var ctx = agentContext(conversationID: conv, threadID: tid, aiName: chosen.name, instructions: chosen.instructions)
        if ctx.transcript.isEmpty, contextMode(conv) == nil || contextMode(conv) == "full" {
            var a = aiState
            a.activeSince = (a.activeSince ?? [:]).merging([tid ?? conv: 0]) { o, _ in o }
            let saved = aiState
            aiState = a
            ctx = agentContext(conversationID: conv, threadID: tid, aiName: chosen.name, instructions: chosen.instructions)
            aiState = saved
        }
        return try await engine.draft(provider: p, context: ctx).text
    }

    // MARK: Settings (N5)

    public func updateSettings(_ s: ClientSettings) async throws {
        if let l = s.loopGuardLimit, l < 0 || l > 1000 { throw EldrClientError.badSetting("loop guard must be 0–1000") }
        if let n = s.displayName, n.count > 64 { throw EldrClientError.badSetting("display name is limited to 64 characters") }
        state.settings = s
        await engine.setLoopGuardLimit(s.loopGuardLimit ?? EldrClient.defaultLoopGuardLimit)
        try await persist()
    }

    /// Relay list for the next launch (wss:// or ws:// only).
    public func setRelays(_ urls: [String]) async throws {
        guard !urls.isEmpty, urls.allSatisfy({ u in
            URL(string: u).map { ($0.scheme == "wss" || $0.scheme == "ws") && $0.host != nil } ?? false
        }) else { throw EldrClientError.badSetting("relays must be ws:// or wss:// URLs") }
        state.relays = urls
        try await persist()
    }

    // MARK: Standing town grants (GOOSEWORLD WS-G4 engine)

    public func issueTownGrant(
        to q: String, planes: [StandingGrant.Plane], days: Int, messagesPerDay: Int = 200,
        bytesPerDay: Int = 2_000_000, maxConcurrentTasks: Int = 2
    ) async throws -> (grant: StandingGrant, exportJSON: String) {
        guard !isAgent else { throw EldrClientError.agentCannotSponsor }
        let c = try contact(matching: q)
        let id = "grant-" + UUID().uuidString.prefix(8).lowercased()
        let g = try await engine.startMyStandingGrant(
            grantID: id, peerIdentityHex: c.identityHex, planes: planes,
            budget: .init(messagesPerDay: messagesPerDay, bytesPerDay: bytesPerDay, maxConcurrentTasks: maxConcurrentTasks),
            durationSeconds: Int64(days) * 24 * 60 * 60)
        var a = aiState
        a.grants = (a.grants ?? []) + [g]
        aiState = a
        try await persist()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (g, String(decoding: try enc.encode(g), as: UTF8.self))
    }

    public func revokeTownGrant(_ grantID: String) async throws -> StandingGrantRevocation {
        guard (aiState.grants ?? []).contains(where: { $0.grantID == grantID }) else { throw EldrClientError.unknownSponsorship(grantID) }
        let r = try await engine.revokeMyStandingGrant(grantID: grantID)
        var a = aiState
        a.grants = (a.grants ?? []).filter { $0.grantID != grantID }
        aiState = a
        try await persist()
        return r
    }

    public func townGrants() async -> [AgentEngine.StandingGrantStatus] { await engine.activeStandingGrants() }

    // MARK: Launch replay

    /// Replays persisted signed state into the engine (each item re-verified there) and
    /// prunes expired items so the state stays bounded.
    func replayAIState() async {
        let now = clock.now()
        var a = aiState
        a.windows = (a.windows ?? []).filter { $0.announcement.activeUntil > now }
        a.invites = (a.invites ?? []).filter { $0.invite.activeUntil > now }
        a.grants = (a.grants ?? []).filter { $0.activeUntil > now }
        if let conv = a.myWindowConversation,
            !(a.windows ?? []).contains(where: { $0.conversationID == conv && $0.announcement.enabledBy.hexString == identityHex })
        { a.myWindowConversation = nil }
        aiState = a
        for w in a.windows ?? [] {
            try? await engine.receiveWindow(w.announcement, fromSenderIdentityHex: w.announcement.enabledBy.hexString)
        }
        for i in a.invites ?? [] {
            try? await engine.receiveInvite(i.invite, fromSenderIdentityHex: i.invite.enabledBy.hexString)
        }
        for g in a.grants ?? [] { try? await engine.receiveStandingGrant(g, fromSenderIdentityHex: identityHex) }
        a.contextGrants = (a.contextGrants ?? []).filter { $0.activeUntil > now }
        aiState = a
        for g in a.contextGrants ?? [] { try? await engine.receiveContextGrant(g, fromSenderIdentityHex: g.enabledBy.hexString) }
        await engine.setLoopGuardLimit(settings.loopGuardLimit ?? EldrClient.defaultLoopGuardLimit)
        for t in threads { if let l = t.loopGuardLimit { await engine.setThreadLoopGuardLimit(l, threadID: t.threadID) } }
    }
}


/// Audit-2 L1: at most `limit` autonomous AI turns per scope in any `window` seconds, counted
/// on MY side, so a peer cannot drive unbounded replies (cost / spam) by mislabelling its
/// agent's messages as human. Explicit user actions (@-mention, solo chat) are not counted.
public struct AutoTurnLimiter: Sendable {
    public var limit = 20
    public var window: Int64 = 600
    private var times: [String: [Int64]] = [:]
    public init() {}
    public mutating func allow(scope: String, now: Int64) -> Bool {
        var t = (times[scope] ?? []).filter { now - $0 < window }
        guard t.count < limit else { times[scope] = t; return false }
        t.append(now)
        times[scope] = t
        if times.count > 512 { times = times.filter { !$0.value.isEmpty && now - ($0.value.last ?? 0) < window } }
        return true
    }
}
