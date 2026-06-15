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

/// The read-only seam between the MCP server and EldrChat's runtime. The app
/// implements it over `PersonaRuntime` — and CRUCIALLY every method returns data
/// that has ALREADY crossed the egress firewall (codenames, byte-bounded), so the
/// MCP server never sees raw identities or unbounded content. The demo bridge in
/// the executable fakes it with fixture data.
///
/// Phase 1 is deliberately read-only: there is NO `post`/`send` here, so an MCP
/// client cannot make EldrChat speak on the wire — the "no autonomous send
/// outside a human-signed window" invariant (SPEC §13) is preserved by
/// construction. Action tools (window-gated) are a later phase.
public protocol SecureChatBridge: Sendable {
    func conversations() async -> [MCPConversation]
    func messages(conversationID: String, limit: Int) async -> [MCPMessage]
    func search(query: String, limit: Int) async -> [MCPMessage]
    /// Exactly what the user's AI sees as context for a conversation (the same
    /// redacted, bounded transcript the "what your AI sees" preview shows).
    func contextPreview(conversationID: String) async -> [MCPMessage]
}
