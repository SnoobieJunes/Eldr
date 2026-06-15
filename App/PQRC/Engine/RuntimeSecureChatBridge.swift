import Foundation
import PQRCMCP

/// The real `SecureChatBridge` (A35 Phase 2): serves the user's ACTUAL secure
/// chat to a local MCP client, in place of `DemoSecureChatBridge`. Read-only and
/// egress-firewall-redacted BY CONSTRUCTION — every value it returns has already
/// crossed the same firewall the remote-AI path uses:
///
/// - **Senders are LOCAL codenames, never identity hex.** "you" for me, a
///   contact's device-local `autoName` for a peer (PersonaRuntime.mcpCodename,
///   the same rule as `redactedForRemote`). The MCP server never sees a real
///   display name or a public key.
/// - **Text is byte-bounded to 64 KB** (invariant 4), so no multi-MB paste can
///   leave the device unbounded.
/// - **Role is honest** ("human"/"agent" straight from `participantType`), so an
///   AI message is always labeled an AI message (invariant 8).
/// - **There is no `post`/`send`** anywhere in the `SecureChatBridge` protocol,
///   so an MCP client cannot make EldrChat speak on the wire (SPEC §13 holds with
///   nothing new to enforce).
///
/// The bridge holds the `AppModel` weakly and reads it on the main actor: the
/// conversation list, titles and unread counts are main-actor UI state, while the
/// message bodies come from the actor-isolated `PersonaRuntime` (already redacted
/// there). If the model has gone away (silo locked), every method returns empty —
/// fail-closed, never stale.
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
