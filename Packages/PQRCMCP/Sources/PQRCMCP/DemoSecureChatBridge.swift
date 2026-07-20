// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A fixture bridge so the `pqrc-mcp` executable runs (and Goose/Xcode/Claude can
/// connect and exercise the protocol) BEFORE the real `PersonaRuntime`-backed
/// bridge is wired into the app. All names are already codenames, mirroring what
/// the real (firewall-redacted) bridge will return.
///
/// The write tools are modeled faithfully: `draft_reply`/`mark_ai_context` always
/// succeed (they never send), and `send_as_my_ai` succeeds ONLY for a conversation
/// passed as `activeWindowConversationID` — every other conversation fails closed,
/// mirroring the real "no AI window open → no autonomous send" gate (invariant 9).
public struct DemoSecureChatBridge: SecureChatBridge {
    /// The conversation (if any) for which a human-opened AI window is currently
    /// active, so `send_as_my_ai` is allowed there. nil → no window anywhere.
    private let activeWindowConversationID: String?

    public init(activeWindowConversationID: String? = nil) {
        self.activeWindowConversationID = activeWindowConversationID
    }

    private static let corpus: [MCPMessage] = [
        MCPMessage(
            conversationID: "alice", sender: "you", role: "human",
            text: "Did the PQXDH handshake land?", sentAt: 1_781_499_000),
        MCPMessage(
            conversationID: "alice", sender: "a contact", role: "human",
            text: "Yes — merged this morning. Rekey test is next.", sentAt: 1_781_499_500),
        MCPMessage(
            conversationID: "alice", sender: "your AI", role: "agent",
            text: "Summary: handshake merged; remaining work is the PQ rekey interval test.",
            sentAt: 1_781_500_000),
        MCPMessage(
            conversationID: "bob", sender: "you", role: "human",
            text: "Lunch at noon?", sentAt: 1_781_400_000),
        MCPMessage(
            conversationID: "design-thread", sender: "a contact", role: "human",
            text: "Let's pin the tech-spec skill to this thread.", sentAt: 1_781_490_000),
    ]

    public func conversations() async -> [MCPConversation] {
        [
            MCPConversation(id: "alice", title: "Alice", lastActivity: 1_781_500_000, unread: 2),
            MCPConversation(id: "bob", title: "Bob", lastActivity: 1_781_400_000, unread: 0),
            MCPConversation(
                id: "design-thread", title: "Design", lastActivity: 1_781_490_000, unread: 1),
        ]
    }

    public func messages(conversationID: String, limit: Int) async -> [MCPMessage] {
        Array(Self.corpus.filter { $0.conversationID == conversationID }.suffix(limit))
    }

    public func search(query: String, limit: Int) async -> [MCPMessage] {
        Array(Self.corpus.filter { $0.text.localizedCaseInsensitiveContains(query) }.prefix(limit))
    }

    public func contextPreview(conversationID: String) async -> [MCPMessage] {
        await messages(conversationID: conversationID, limit: 20)
    }

    // MARK: Write (mirrors the real bridge's invariant posture)

    public func draftReply(conversationID: String, text: String) async -> MCPWriteResult {
        // Never sends — just stages a draft for the human.
        .ok(detail: "Draft saved for \(conversationID) (the user can review and send it):\n\(text)")
    }

    public func markAIContext(conversationID: String, messageIDs: [String], value: Bool) async
        -> MCPWriteResult
    {
        .ok(
            detail:
                "\(value ? "Marked" : "Unmarked") \(messageIDs.count) message(s) as AI context in \(conversationID)."
        )
    }

    public func sendAsMyAI(conversationID: String, text: String) async -> MCPWriteResult {
        // Window gate: speak only when the human has an AI window open here.
        guard conversationID == activeWindowConversationID else {
            return .failedClosed(
                reason:
                    "No active AI window for \(conversationID). EldrChat will not send autonomously — ask the user to open an AI window for this conversation first, then retry."
            )
        }
        return .ok(detail: "Sent as your AI (in the active AI window) to \(conversationID): \(text)")
    }
}
