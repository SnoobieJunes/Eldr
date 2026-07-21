// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import PQRCMCP

/// The real `SecureChatBridge` (A35 Phase 2 read; Phase 3 write): serves the user's
/// ACTUAL secure chat to a local MCP client, in place of `DemoSecureChatBridge`. Read
/// methods are egress-firewall-redacted BY CONSTRUCTION; write methods reuse
/// EldrChat's existing send/draft/mark paths (no new wire format, no crypto change)
/// and preserve the hard invariants:
///
/// - **Senders are LOCAL codenames, never identity hex.** "you" for me, a
///   contact's device-local `autoName` for a peer (PersonaRuntime.mcpCodename,
///   the same rule as `redactedForRemote`). The MCP server never sees a real
///   display name or a public key.
/// - **Text is byte-bounded to 64 KB** (invariant 4), so no multi-MB paste can
///   leave the device unbounded.
/// - **Role is honest** ("human"/"agent" straight from `participantType`), so an
///   AI message is always labeled an AI message (invariant 8). The only write that
///   posts on the wire, `sendAsMyAI`, goes through `PersonaRuntime.sendAsMyAI`
///   (`participant_type == .agent`), so it ALWAYS renders as AI-authored.
/// - **`sendAsMyAI` is WINDOW-GATED and fails closed.** It posts only while the
///   human has an ai_window open for that conversation; otherwise it sends nothing
///   and returns a refusal — an MCP client can never make EldrChat speak to others
///   outside a visible, human-opened window (invariant 9 / SPEC §13). `draftReply`
///   never sends; `markAIContext` only flips a local marker.
///
/// The bridge holds the `AppModel` weakly and reads it on the main actor: the
/// conversation list, titles and unread counts are main-actor UI state, while the
/// message bodies and write actions come from the actor-isolated `PersonaRuntime`
/// (already redacted/gated there). If the model has gone away (silo locked), every
/// read returns empty and every write fails closed — never stale, never autonomous.
struct RuntimeSecureChatBridge: SecureChatBridge {
    /// Weak so a locked/torn-down silo's model can deallocate; a dangling bridge
    /// then simply serves nothing rather than pinning the unlocked state alive.
    private weak var model: AppModel?

    init(model: AppModel) { self.model = model }

    func conversations() async -> [MCPConversation] {
        guard let runtime = await runtime() else { return [] }
        let rows = await MainActor.run { model?.conversations ?? [] }
        var result: [MCPConversation] = []
        for row in rows {
            // Route the title through the runtime's redaction — the UI's
            // `displayName` can degrade to "Contact <hex>", and the bridge must
            // never emit identity hex (security audit). `mcpConversationTitle`
            // yields a group name or the contact codename, never a key.
            result.append(
                MCPConversation(
                    id: row.id,
                    title: await runtime.mcpConversationTitle(row.id),
                    lastActivity: row.lastActivity,
                    unread: row.unread))
        }
        return result
    }

    func messages(conversationID: String, limit: Int) async -> [MCPMessage] {
        guard let runtime = await runtime() else { return [] }
        let lines = await runtime.mcpMessages(conversationID: conversationID, limit: limit)
        return lines.map(Self.message)
    }

    func search(query: String, limit: Int) async -> [MCPMessage] {
        guard let runtime = await runtime() else { return [] }
        return await runtime.mcpSearch(query: query, limit: limit).map(Self.message)
    }

    func contextPreview(conversationID: String) async -> [MCPMessage] {
        guard let runtime = await runtime() else { return [] }
        return await runtime.mcpContextPreview(conversationID: conversationID).map(Self.message)
    }

    // MARK: Write (reuse existing paths; fail closed when the silo is gone)

    func draftReply(conversationID: String, text: String) async -> MCPWriteResult {
        guard let runtime = await runtime() else {
            return .failedClosed(reason: "EldrChat is locked — unlock it to draft a reply.")
        }
        switch await runtime.mcpDraftReply(conversationID: conversationID, text: text) {
        case .drafted(let body):
            return .ok(
                detail:
                    "Draft ready for the user to review and send (NOT sent). Suggested reply:\n\(body)"
            )
        case .staged(let body):
            return .ok(detail: "Draft staged for the user (NOT sent):\n\(body)")
        case .failed(let reason):
            return .failedClosed(reason: reason)
        }
    }

    func markAIContext(conversationID: String, messageIDs: [String], value: Bool) async
        -> MCPWriteResult
    {
        guard let runtime = await runtime() else {
            return .failedClosed(reason: "EldrChat is locked — unlock it to change AI context.")
        }
        let count = await runtime.mcpMarkAIContext(
            conversationID: conversationID, messageIDs: messageIDs, value: value)
        return .ok(
            detail: "\(value ? "Marked" : "Unmarked") \(count) message(s) as AI context.")
    }

    func sendAsMyAI(conversationID: String, text: String) async -> MCPWriteResult {
        guard let runtime = await runtime() else {
            // Locked silo: cannot send, and must not pretend to. Fail closed.
            return .failedClosed(
                reason: "EldrChat is locked — it will not send. Unlock it and open an AI window first.")
        }
        switch await runtime.mcpSendAsMyAI(conversationID: conversationID, text: text) {
        case .sent:
            return .ok(detail: "Sent as your AI (an AI window is open for this conversation).")
        case .failedClosed(let reason):
            return .failedClosed(reason: reason)
        }
    }

    /// The model's actor-isolated runtime, or nil once the silo is gone.
    private func runtime() async -> PersonaRuntime? {
        await MainActor.run { model?.runtime }
    }

    private static func message(_ line: PersonaRuntime.MCPRedactedLine) -> MCPMessage {
        MCPMessage(
            conversationID: line.conversationID,
            sender: line.sender,
            role: line.role,
            text: line.text,
            sentAt: line.sentAt)
    }
}
