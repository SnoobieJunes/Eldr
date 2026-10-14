// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCAgent
import PQRCCore

// WS-N7a (DEVIATIONS AC191+): several tethered AIs, a per-chat roster and reply order,
// ordered critique, per-conversation context mode, solo AI chats and @-mentions, on the
// SAME PQRCAgent selection policies iOS uses. Every autonomous post still goes through
// the engine's window / invite / loop-guard gate; only solo chats (no other human) skip
// it, exactly as iOS does (SPEC §13: the gate protects other people).

/// A runnable tethered AI.
struct LinuxAI: AISelectionCandidate {
    let id: String
    let name: String
    let autonomous: Bool
    let instructions: String?
    let provider: any AgentProvider
    var participatesAutonomously: Bool { autonomous }
}

extension EldrClient {
    public static let primaryAIID = "primary"
    public static let contextModes = ["off", "marked", "full"]

    public var primaryAIName: String { aiState.primaryName ?? "\(myName)'s AI" }
    public var extraAIs: [TetheredAIConfig] { aiState.extraAIs ?? [] }

    /// Names (and ids) of my AIs, primary first, for the CLI and GTK.
    public func myAIs() -> [(id: String, name: String, kind: String, autonomous: Bool)] {
        var out: [(String, String, String, Bool)] = []
        if let p = providerConfig { out.append((Self.primaryAIID, primaryAIName, p.effectiveKind, true)) }
        for a in extraAIs { out.append((a.id, a.name, a.config.effectiveKind, a.autonomous)) }
        return out
    }

    func tetheredAIs() -> [LinuxAI] {
        var out: [LinuxAI] = []
        if let p = currentProvider() {
            out.append(LinuxAI(id: Self.primaryAIID, name: primaryAIName, autonomous: true,
                               instructions: providerConfig?.instructions, provider: p))
        }
        for a in extraAIs {
            let provider = aiOverrides[a.id] ?? Self.makeProvider(
                a.config, key: store.load(account: Self.aiKeyAccount(a.id)).map { String(decoding: $0, as: UTF8.self) } ?? "")
            out.append(LinuxAI(id: a.id, name: a.name, autonomous: a.autonomous, instructions: a.config.instructions, provider: provider))
        }
        return out
    }

    static func aiKeyAccount(_ id: String) -> String { "\(aiKeyAccount).\(id)" }

    /// A mentionable AI name: 1–32 of letters, digits, '-' or '_' (the @-token grammar).
    static func validAIName(_ n: String) -> Bool {
        (1...32).contains(n.count) && n.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    public func renamePrimaryAI(_ name: String) async throws {
        guard Self.validAIName(name) else { throw EldrClientError.badSetting("AI names are 1–32 letters, digits, - or _") }
        guard !extraAIs.contains(where: { $0.name.lowercased() == name.lowercased() }) else { throw EldrClientError.badSetting("an AI named '\(name)' already exists") }
        var a = aiState; a.primaryName = name; aiState = a
        try await persist()
    }

    /// Adds another tethered AI. Its key goes into its own keystore account.
    @discardableResult
    public func addAI(name: String, config: AIProviderConfig, apiKey: String?, autonomous: Bool = true) async throws -> TetheredAIConfig {
        guard Self.validAIName(name) else { throw EldrClientError.badSetting("AI names are 1–32 letters, digits, - or _") }
        let taken = myAIs().map { $0.name.lowercased() }
        guard !taken.contains(name.lowercased()) else { throw EldrClientError.badSetting("an AI named '\(name)' already exists") }
        guard AIProviderConfig.kinds.contains(config.effectiveKind) else { throw EldrClientError.badSetting("unknown AI kind '\(config.effectiveKind)'") }
        if config.effectiveKind == "custom" {
            guard let u = URL(string: config.baseURL), let sc = u.scheme, ["http", "https"].contains(sc), u.host != nil
            else { throw EldrClientError.badProviderURL(config.baseURL) }
        }
        guard extraAIs.count < 8 else { throw EldrClientError.badSetting("at most 9 AIs") }
        let rec = TetheredAIConfig(id: "ai-" + UUID().uuidString.prefix(8).lowercased(), name: name, config: config, autonomous: autonomous)
        if let apiKey { try store.save(Data(apiKey.utf8), account: Self.aiKeyAccount(rec.id)) }
        var a = aiState
        a.extraAIs = extraAIs + [rec]
        aiState = a
        do { try await persist() } catch {
            store.delete(account: Self.aiKeyAccount(rec.id))
            throw error
        }
        return rec
    }

    public func removeAI(_ q: String) async throws {
        guard let rec = extraAIs.first(where: { $0.id == q || $0.name.lowercased() == q.lowercased() })
        else { throw EldrClientError.badSetting("no extra AI named '\(q)' (the primary is cleared with ai-config --clear)") }
        var a = aiState
        a.extraAIs = extraAIs.filter { $0.id != rec.id }
        a.rosters = a.rosters?.mapValues { $0.filter { $0 != rec.id } }
        aiState = a
        try await persist()
        store.delete(account: Self.aiKeyAccount(rec.id))
    }

    // MARK: Roster, order, critique, context mode

    /// Sets which of my AIs take turns in a conversation (or thread), and in what order.
    /// nil = all autonomous AIs in config order; [] = none (silence).
    public func setAIRoster(_ names: [String]?, in conversationQuery: String, thread: String? = nil) async throws {
        let scope = try thread.map { try self.thread(matching: $0).threadID } ?? resolveConversation(conversationQuery)
        let ais = myAIs()
        let ids = try names.map { ns in
            try ns.map { n in
                guard let a = ais.first(where: { $0.name.lowercased() == n.lowercased() || $0.id == n }) else {
                    throw EldrClientError.badSetting("no AI named '\(n)'")
                }
                return a.id
            }
        }
        var a = aiState
        var r = a.rosters ?? [:]
        r[scope] = ids
        a.rosters = r
        aiState = a
        try await persist()
    }

    public func aiRoster(conversationID: String, threadID: String?) -> [String]? {
        let r = aiState.rosters ?? [:]
        if let threadID, let t = r[threadID] { return t }
        return r[conversationID]
    }

    public func setOrderedCritique(_ on: Bool, in conversationQuery: String) async throws {
        let conv = try resolveConversation(conversationQuery)
        var a = aiState
        var set = Set(a.orderedCritique ?? [])
        if on { set.insert(conv) } else { set.remove(conv) }
        a.orderedCritique = set.sorted()
        aiState = a
        try await persist()
    }
    public func orderedCritique(_ conv: String) -> Bool { (aiState.orderedCritique ?? []).contains(conv) }

    /// "off" (AI sees nothing and never posts here), "marked" (only rows added to AI
    /// context), "full" (everything since the AI was turned on). nil = default (full).
    public func setContextMode(_ mode: String?, in conversationQuery: String) async throws {
        if let mode { guard Self.contextModes.contains(mode) else { throw EldrClientError.badSetting("context mode is off, marked or full") } }
        let conv = try resolveConversation(conversationQuery)
        var a = aiState
        var m = a.contextModes ?? [:]
        m[conv] = mode
        a.contextModes = m
        aiState = a
        try await persist()
    }
    public func contextMode(_ conv: String) -> String? { aiState.contextModes?[conv] }
    public var allContextModes: [String: String] { aiState.contextModes ?? [:] }
    public var critiqueConversations: Set<String> { Set(aiState.orderedCritique ?? []) }

    /// The ordered (AI, role) list for one autonomous turn in this scope.
    func aiTurnOrder(conversationID conv: String, threadID: String?) -> [(ai: LinuxAI, role: String)] {
        let ais = tetheredAIs()
        let roster = aiRoster(conversationID: conv, threadID: threadID)
        let base: any AISelectionPolicy<LinuxAI> = orderedCritique(conv) ? OrderedCritiquePolicy<LinuxAI>() : DefaultAISelectionPolicy<LinuxAI>()
        let policy = ConversationRosterPolicy<LinuxAI>(aiID: { $0.id }, roster: { _, _ in roster }, base: base)
        if let ordered = policy.critiqueTurn(from: ais, conversationID: conv, threadID: threadID) { return ordered }
        return policy.participants(from: ais, conversationID: conv, threadID: threadID).map { ($0, AICritiqueRole.primary) }
    }

    /// Role guidance (reviewer / critic / synthesizer) only in an ordered critique; a
    /// primary keeps the plain instructions (unchanged single-AI behavior).
    func rolePrompt(_ role: String, aiName: String?, threadID: String?, conv: String, instructions: String?) -> String? {
        guard role != AICritiqueRole.primary else { return nil }
        let peer = UIConversation.groupID(conv).flatMap { g in groups.first { $0.groupID == g }?.name }
            ?? state.contacts.first { $0.identityHex == conv }?.name ?? ""
        return AgentSkills.threadSystemPrompt(
            displayName: myName, contextDomain: "", peerName: peer,
            threadID: threadID ?? conv, activeSkillIDs: [], instructions: instructions, aiRole: role)
    }

    // MARK: Solo AI chat

    /// A group with no other human: my AIs answer me directly (no window needed).
    public func isSolo(_ conv: String) -> Bool {
        guard let g = UIConversation.groupID(conv), let rec = groups.first(where: { $0.groupID == g }) else { return false }
        return rec.members == [identityHex]
    }

    @discardableResult
    public func createSoloAIChat(name: String) async throws -> GroupRecord {
        let (g, _) = try await createGroup(name: name, members: [])
        var a = aiState
        a.activeSince = (a.activeSince ?? [:]).merging([UIConversation.group(g.groupID): 0]) { _, n in n }
        aiState = a
        try await persist()
        return g
    }

    func runSoloTurn(_ ai: LinuxAI, context: AgentContext, conversationID conv: String) async {
        do {
            guard let text = try await ai.provider.threadTurn(context: context)?.messages.first?.text,
                !text.isEmpty, isSolo(conv)
            else { return }
            try await post(text, conversationID: conv, participant: .agent, mine: true, agentName: ai.name)
            emit(.myAI(conversationID: conv, threadID: nil, error: nil))
        } catch {
            emit(.myAI(conversationID: conv, threadID: nil, error: "\(ai.name): \(error)"))
        }
    }

    // MARK: @-mentions

    /// iOS `resolveMentions`: single @tokens against contact names and my AI names (my
    /// AI wins a tie). Multi-word names match their first token only.
    func resolveMentions(in text: String) -> [MessageBody.Mention] {
        guard text.contains("@") else { return [] }
        var byName: [String: (id: String, kind: String)] = [:]
        for c in state.contacts {
            if let n = c.name?.split(separator: " ").first.map(String.init)?.lowercased(), !n.isEmpty { byName[n] = (c.identityHex, "person") }
        }
        for a in myAIs() { byName[a.name.lowercased()] = (a.id, "ai") }
        var out: [MessageBody.Mention] = []
        var seen = Set<String>()
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            guard chars[i] == "@" else { i += 1; continue }
            var j = i + 1
            var token = ""
            while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "-" || chars[j] == "_" {
                token.append(chars[j]); j += 1
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

    /// Composer autocomplete: my AIs first, then the people in this conversation.
    public func mentionCandidates(conversationID conv: String) -> [(name: String, kind: String)] {
        var out = myAIs().map { (name: $0.name, kind: "ai") }
        let peers: [String] = UIConversation.groupID(conv).flatMap { g in groups.first { $0.groupID == g }?.members.filter { $0 != identityHex } }
            ?? [conv]
        for h in peers {
            if let n = state.contacts.first(where: { $0.identityHex == h })?.name, !out.contains(where: { $0.name.lowercased() == n.lowercased() }) {
                out.append((n, "person"))
            }
        }
        return out
    }

    /// After my own human send: solo replies, and @-mentions of my AIs.
    func afterMySend(_ text: String, conversationID conv: String, threadID: String?) async {
        lastMentionChoices = []
        let myAINames = Set(myAIs().map { $0.name.lowercased() })
        let named = Set(resolveMentions(in: text).filter { $0.kind == "ai" && myAINames.contains($0.displayName.lowercased()) }
            .map { $0.displayName.lowercased() })
        if threadID == nil, isSolo(conv) {
            spawnAI(conversationID: conv, threadID: nil, only: named.isEmpty ? nil : named, solo: true)
            return
        }
        guard !named.isEmpty else { return }
        if let threadID {
            spawnAI(conversationID: conv, threadID: threadID, only: named)  // still invite-gated
        } else if myWindowConversation == conv, await engine.activeWindow(for: identityHex) != nil {
            spawnAI(conversationID: conv, threadID: nil, only: named)
        } else {
            for n in named.sorted() {
                lastMentionChoices.append(myAIs().first { $0.name.lowercased() == n }?.name ?? n)
                let display = myAIs().first { $0.name.lowercased() == n }?.name ?? n
                emit(.aiMentionChoice(conversationID: conv, aiName: display))
            }
        }
    }
}
