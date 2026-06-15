import Foundation

/// A fixture bridge so the `pqrc-mcp` executable runs (and Goose/Xcode/Claude can
/// connect and exercise the protocol) BEFORE the real `PersonaRuntime`-backed
/// bridge is wired into the app. All names are already codenames, mirroring what
/// the real (firewall-redacted) bridge will return.
public struct DemoSecureChatBridge: SecureChatBridge {
    public init() {}

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
}
