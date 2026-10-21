// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCAgent
import PQRCCore

/// AI context-sharing grants (SPEC N24, iOS `grantAIContext`/`withdrawAIContext`).
/// Bilateral: content flows only while my grant AND another human's grant are live.
/// Axis "human" = peers' words when my AI is not active; "ai" = peers' AI messages.
extension EldrClient {
    /// The scope as the SENDER of a grant names it. A 1:1 conversation is named by
    /// the peer's identity on each side, so the two sides' tags differ (AC180).
    func contextScope(conversationID conv: String, threadID: String?, axis: String) -> AIContextGrant.Scope {
        threadID.map { .thread($0, axis: axis) } ?? .conversation(conv, axis: axis)
    }

    func storeContextGrant(_ g: AIContextGrant) {
        var a = aiState
        a.contextGrants = (a.contextGrants ?? []).filter {
            !($0.enabledBy == g.enabledBy && $0.scope == g.scope)
        } + [g]
        aiState = a
    }

    /// Grant (or with `seconds == nil`, withdraw) context sharing here. Human only.
    @discardableResult
    public func setContextSharing(
        in conversationQuery: String, thread: String? = nil, axis: String = AIContextGrant.Scope.humanAxis,
        seconds: Int64?
    ) async throws -> Int64? {
        guard !isAgent else { throw EldrClientError.agentCannotSponsor }
        guard [AIContextGrant.Scope.humanAxis, AIContextGrant.Scope.aiAxis].contains(axis) else {
            throw EldrClientError.badSetting("axis is human or ai")
        }
        let (conv, tid): (String, String?)
        if let thread { let t = try self.thread(matching: thread); (conv, tid) = (t.conversationID, t.threadID) }
        else { (conv, tid) = (try resolveConversation(conversationQuery), nil) }
        let scope = contextScope(conversationID: conv, threadID: tid, axis: axis)
        guard let seconds else {
            await engine.withdrawMyContextGrant(scope: scope)
            var a = aiState
            a.contextGrants = (a.contextGrants ?? []).filter { !($0.enabledBy.hexString == identityHex && $0.scope == scope) }
            aiState = a
            // iOS withdraws locally only; the peer's view expires with the grant.
            try await persist()
            emit(.aiContextGrant(identityHex: identityHex, conversationID: conv, threadID: tid, axis: axis, until: nil))
            return nil
        }
        let g: AIContextGrant
        do { g = try await engine.startMyContextGrant(scope: scope, durationSeconds: seconds) }
        catch { throw EldrClientError.badDuration }
        storeContextGrant(g)
        try await post("enabled AI context sharing", conversationID: conv, threadID: tid, aiContextGrant: g)
        emit(.aiContextGrant(identityHex: identityHex, conversationID: conv, threadID: tid, axis: axis, until: g.activeUntil))
        return g.activeUntil
    }

    /// Live grants in a conversation/thread: identity → until, for one axis.
    public func contextGrants(conversationID conv: String, threadID: String?, axis: String) async -> [String: Int64] {
        let now = clock.now()
        var out: [String: Int64] = [:]
        for g in aiState.contextGrants ?? [] where g.activeUntil > now && g.scope.axis == axis {
            let who = g.enabledBy.hexString
            if let tid = threadID {
                guard g.scope == .thread(tid, axis: axis) else { continue }
            } else if UIConversation.groupID(conv) != nil {
                guard g.scope == .conversation(conv, axis: axis) else { continue }
            } else {
                // 1:1: mine names the peer; the peer's names me.
                let mineOK = who == identityHex && g.scope == .conversation(conv, axis: axis)
                let theirsOK = who == conv && g.scope == .conversation(identityHex, axis: axis)
                guard mineOK || theirsOK else { continue }
            }
            out[who] = g.activeUntil
        }
        return out
    }

    /// Bilateral: my grant and at least one other human's grant are live.
    func contextSharedNow(conversationID conv: String, threadID: String?, axis: String) -> Bool {
        let now = clock.now()
        var mine = false, other = false
        for g in aiState.contextGrants ?? [] where g.activeUntil > now && g.scope.axis == axis {
            let who = g.enabledBy.hexString
            let match: Bool
            if let tid = threadID { match = g.scope == .thread(tid, axis: axis) }
            else if UIConversation.groupID(conv) != nil { match = g.scope == .conversation(conv, axis: axis) }
            else {
                match = (who == identityHex && g.scope == .conversation(conv, axis: axis))
                    || (who == conv && g.scope == .conversation(identityHex, axis: axis))
            }
            guard match else { continue }
            if who == identityHex { mine = true } else { other = true }
        }
        return mine && other
    }
}

extension EldrClient {
    /// "What your AI sees" (iOS AIContextInspectorView): the exact, read-only
    /// transcript my AI would be handed here right now. Empty when my AI is off here.
    public func aiContextPreview(in conversationQuery: String, thread: String? = nil) async throws -> [TranscriptEntry] {
        let (conv, tid): (String, String?)
        if let thread { let t = try self.thread(matching: thread); (conv, tid) = (t.conversationID, t.threadID) }
        else { (conv, tid) = (try resolveConversation(conversationQuery), nil) }
        let active: Bool
        if let tid { active = await engine.activeInvite(threadID: tid, identityHex: identityHex) != nil }
        else { active = myWindowConversation == conv }
        guard active else { return [] }
        return agentContext(conversationID: conv, threadID: tid).transcript
    }
}

extension EldrClient {
    /// A sender may only flag their OWN prior message (iOS author guard, N25).
    func applyContextMark(_ mark: AIContextMark, from sender: String) {
        var a = agentState
        guard var h = a.history,
            let i = h.firstIndex(where: { $0.id == mark.messageID && !$0.outgoing && $0.peerIdentityHex == sender })
        else {
            // The relay may deliver the mark before its message: hold it (bounded,
            // in memory) and apply when that message arrives (DEVIATIONS AC199).
            if pendingMarks.count < 256 { pendingMarks[mark.messageID] = (sender, mark.value) }
            return
        }
        h[i].aiContext = mark.value ? true : nil
        a.history = h
        agentState = a
    }

    /// Applies a held mark to a just-received row (same author only).
    func applyPendingMark(to e: inout HistoryEntry) {
        guard let p = pendingMarks.removeValue(forKey: e.id), p.sender == e.peerIdentityHex, !e.outgoing else { return }
        e.aiContext = p.value ? true : nil
    }

    /// "Add to AI Context" on one of MY messages (by id, or "last" = my latest here).
    /// Mirrored to the peer as a content-free control so their side can show it.
    @discardableResult
    public func markAIContext(in conversationQuery: String, thread: String? = nil, message: String, _ value: Bool) async throws -> String {
        let (conv, tid): (String, String?)
        if let thread { let t = try self.thread(matching: thread); (conv, tid) = (t.conversationID, t.threadID) }
        else { (conv, tid) = (try resolveConversation(conversationQuery), nil) }
        let gid = UIConversation.groupID(conv)
        var a = agentState
        var h = a.history ?? []
        let mineHere = h.indices.filter {
            h[$0].outgoing && h[$0].threadID == tid
                && (gid != nil ? h[$0].groupID == gid : (h[$0].peerIdentityHex == conv && h[$0].groupID == nil))
        }
        guard let i = message == "last" ? mineHere.last : mineHere.first(where: { h[$0].id.hasPrefix(message) }) else {
            throw EldrClientError.badSetting("no message of yours matches '\(message)' here")
        }
        h[i].aiContext = value ? true : nil
        a.history = h
        agentState = a
        let id = h[i].id
        try await post("", conversationID: conv, threadID: tid, aiContextMark: AIContextMark(messageID: id, value: value))
        return id
    }

    /// iOS "Draft with AI ▸ Send as my AI": human-directed, so co-authored (AC44).
    @discardableResult
    public func sendAsMyAI(_ text: String, in conversationQuery: String, thread: String? = nil) async throws -> (reached: Int, skipped: Int) {
        guard !isAgent else { throw EldrClientError.agentCannotSponsor }
        if let thread {
            let t = try self.thread(matching: thread)
            return try await post(text, conversationID: t.conversationID, threadID: t.threadID, participant: .agent, mine: true, coauthored: true)
        }
        return try await post(text, conversationID: try resolveConversation(conversationQuery), participant: .agent, mine: true, coauthored: true)
    }

    /// Per-thread loop-guard override (iOS setThreadLoopGuardLimit). nil = the global limit.
    public func setThreadLoopGuard(_ thread: String, limit: Int?) async throws {
        let t = try self.thread(matching: thread)
        if let limit, !(0...1000).contains(limit) { throw EldrClientError.badSetting("loop guard is 0–1000 (0 = off)") }
        guard let i = state.threads?.firstIndex(where: { $0.threadID == t.threadID }) else { return }
        state.threads?[i].loopGuardLimit = limit
        await engine.setThreadLoopGuardLimit(limit ?? (settings.loopGuardLimit ?? EldrClient.defaultLoopGuardLimit), threadID: t.threadID)
        try await persist()
    }
}
