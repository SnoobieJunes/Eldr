// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCCore

/// External-agent bridge (AC178): an orchestrator that is not an HTTP LLM speaks
/// through an AI account. Inbound context is annotated; outbound replies pass the
/// same gates as any agent turn: a live sponsorship from the pinned owner, the
/// owner present in the conversation, and the thread loop guard.
public struct BridgeContext: Sendable, Equatable {
    public var conversationID: String
    public var groupID: String?
    public var threadID: String?
    public var threadTitle: String?
    public var sponsoredUntil: Int64?
    public var ownerPresent: Bool
    public var loopGuarded: Bool
    /// nil when a reply would be accepted right now.
    public var refusal: String?
}

extension EldrClient {
    /// Where a reply to this conversation/thread would go, and whether it is allowed.
    public func bridgeContext(conversationID conv: String, threadID: String?) async -> BridgeContext {
        let thread = threadID.flatMap { id in threads.first { $0.threadID == id } }
        let home = thread?.conversationID ?? conv
        let gid = UIConversation.groupID(home)
        let owner = ownerIdentityHex
        let ownerPresent: Bool = {
            guard let owner else { return false }
            if let gid { return groups.first { $0.groupID == gid }?.members.contains(owner) ?? false }
            return home == owner
        }()
        var sponsoredUntil: Int64?
        var refusal: String?
        if !isAgent { refusal = EldrClientError.notAgentAccount.description }
        else {
            do { sponsoredUntil = try liveSponsorship(now: clock.now()).activeUntil }
            catch { refusal = "\(error)" }
        }
        var guarded = false
        if let t = thread { guarded = await engine.loopGuardActive(threadID: t.threadID) }
        if refusal == nil, !ownerPresent { refusal = "my owner is not in this conversation" }
        if refusal == nil, guarded { refusal = "loop guard: too many consecutive AI messages; waiting for a human" }
        if refusal == nil, threadID != nil, thread == nil { refusal = "unknown thread" }
        return BridgeContext(
            conversationID: home, groupID: gid, threadID: thread?.threadID, threadTitle: thread?.title,
            sponsoredUntil: sponsoredUntil, ownerPresent: ownerPresent, loopGuarded: guarded, refusal: refusal)
    }

    /// Send an orchestrator reply as this AI account. `to` is a contact, `group:<id>`
    /// or a group name; `thread` (id, prefix or title) wins over both.
    @discardableResult
    public func bridgeReply(_ text: String, to: String?, thread: String?) async throws -> (reached: Int, skipped: Int) {
        guard isAgent else { throw EldrClientError.notAgentAccount }
        let conv: String
        var tid: String?
        if let thread {
            let t = try self.thread(matching: thread)
            conv = t.conversationID; tid = t.threadID
        } else if let to {
            conv = try resolveConversation(to)
        } else { throw EldrClientError.bridgeGated("no destination") }
        let ctx = await bridgeContext(conversationID: conv, threadID: tid)
        if let why = ctx.refusal { throw EldrClientError.bridgeGated(why) }
        let r = try await post(text, conversationID: conv, threadID: tid, participant: .agent)
        if let tid { await engine.recordThreadMessage(threadID: tid, participantType: .agent) }
        return r
    }
}

extension EldrClient {
    /// Matches iOS `AppSession.defaultThreadLoopGuardLimit` (AC179). PQRCCore's
    /// `agentLoopGuardLimit` (6) stays the library default for other hosts.
    public static let defaultLoopGuardLimit = 50
}
