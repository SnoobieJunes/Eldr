// SPDX-License-Identifier: Apache-2.0
import Foundation

/// One conversation, as exposed to an MCP client. Already egress-safe: the app's
/// bridge derives `title` from local names only, never identity keys.
public struct MCPConversation: Sendable, Codable, Equatable {
    public let id: String
    public let title: String
    /// Unix seconds of the most recent activity.
    public let lastActivity: Int64
    public let unread: Int
    public init(id: String, title: String, lastActivity: Int64, unread: Int) {
        self.id = id
        self.title = title
        self.lastActivity = lastActivity
        self.unread = unread
    }
}

/// One message, as exposed to an MCP client. `sender` is ALREADY a local codename
/// ("you" / a contact's local autoName), never a real display name or identity
/// hex — the app's bridge runs the same egress firewall (`redactedForRemote`) the
/// remote-AI path uses, and byte-bounds the result.
public struct MCPMessage: Sendable, Codable, Equatable {
    public let conversationID: String
    public let sender: String
    /// "human" | "agent" — honest participant type (an AI message is labeled agent).
    public let role: String
    public let text: String
    public let sentAt: Int64
    public init(conversationID: String, sender: String, role: String, text: String, sentAt: Int64) {
        self.conversationID = conversationID
        self.sender = sender
        self.role = role
        self.text = text
        self.sentAt = sentAt
    }
}

/// The outcome of a write action exposed to an MCP client. Carries a human-readable
/// `detail` the server renders back to the model. `failedClosed` is the load-bearing
/// flag for the window gate: when an MCP client tries to `send_as_my_ai` and NO
/// ai_window is active for that conversation, the bridge returns
/// `.closed(reason:)`, the server reports an error (`isError: true`), and EldrChat
/// stays silent on the wire — the agent cannot make the app speak to others outside
/// a visible, human-opened window (CLAUDE.md invariant 9, SPEC §13).
public enum MCPWriteResult: Sendable, Equatable {
    /// The action succeeded; `detail` describes what happened (e.g. a draft body,
    /// or "sent as your AI in an active AI window").
    case ok(detail: String)
    /// The action was refused. `reason` explains why (e.g. no active AI window, or
    /// the silo locked); the server surfaces it as a tool error, never a silent drop.
    case failedClosed(reason: String)

    /// Convenience: the text the server shows the model for this outcome.
    public var detail: String {
        switch self {
        case .ok(let detail): return detail
        case .failedClosed(let reason): return reason
        }
    }
    /// Whether the server should mark the `tools/call` result `isError`.
    public var isError: Bool {
        if case .failedClosed = self { return true }
        return false
    }
}

/// The read/write seam between the MCP server and EldrChat's runtime. The app
/// implements it over `PersonaRuntime` — and CRUCIALLY every READ method returns
/// data that has ALREADY crossed the egress firewall (codenames, byte-bounded), so
/// the MCP server never sees raw identities or unbounded content. The demo bridge in
/// the executable fakes it with fixture data.
///
/// **Write posture (A35 Phase 3 — invariant-preserving).** Three action tools exist,
/// but they reuse EldrChat's existing send/draft/mark paths verbatim — no new wire
/// format, no crypto change — and they respect the hard invariants by construction:
/// - `draftReply` only produces a DRAFT for the human; it never sends. Always safe.
/// - `markAIContext` toggles the local "Add to AI Context" marker (the existing
///   markAsAIContext path). Safe.
/// - `sendAsMyAI` posts an **agent-labeled** message (`participant_type == agent`,
///   so it renders as AI-authored — invariant 8) **only while an ai_window is active**
///   for that conversation. With NO active window it MUST fail closed
///   (`.failedClosed`), so an MCP client can never make EldrChat speak autonomously
///   to others outside a human-opened, visible window (invariant 9, SPEC §13).
public protocol SecureChatBridge: Sendable {
    // MARK: Read (firewall-redacted, byte-bounded by construction)
    func conversations() async -> [MCPConversation]
    func messages(conversationID: String, limit: Int) async -> [MCPMessage]
    func search(query: String, limit: Int) async -> [MCPMessage]
    /// Exactly what the user's AI sees as context for a conversation (the same
    /// redacted, bounded transcript the "what your AI sees" preview shows).
    func contextPreview(conversationID: String) async -> [MCPMessage]

    // MARK: Write (reuse existing paths; invariants 8 + 9 preserved)
    /// Produce a DRAFT reply for the human to review — never sends. Always safe.
    func draftReply(conversationID: String, text: String) async -> MCPWriteResult
    /// Mark/unmark the given messages as "AI context" (existing markAsAIContext path).
    func markAIContext(conversationID: String, messageIDs: [String], value: Bool) async
        -> MCPWriteResult
    /// Post an AGENT-LABELED message — ONLY when an ai_window is active for this
    /// conversation; otherwise fail closed (invariant 9 / SPEC §13).
    func sendAsMyAI(conversationID: String, text: String) async -> MCPWriteResult
}
