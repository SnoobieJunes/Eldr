import Foundation

/// A stored message as the app layer sees it after decryption.
public struct StoredMessage: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let conversationID: String
    /// Sender PQRC identity pubkey hex ("me" included).
    public let senderIdentity: String
    public let participantType: ParticipantType
    public let text: String
    /// True send time from inside the encrypted payload.
    public let sentAt: Int64
    public let threadID: String?
    public let isContext: Bool
    /// Human-applied "Add to AI Context" marker. Local mirror of
    /// `MessageBody.aiContext`; gates what a peer AI may consume under a grant.
    public var aiContext: Bool
    /// Local-only delivery state: "queued" | "sent" (APP-SPEC D5 — no remote receipts).
    public var localStatus: String
    /// Friendly codename of the AI that authored this message, when it was one
    /// of the local human's own configured AIs (multi-AI tethering). PURELY
    /// LOCAL — never written to the wire (SPEC §0, names stay client-side); it
    /// only lets the UI label "clever-otter-glides-204" instead of a generic
    /// "your AI" when several AIs share a conversation. nil for human messages
    /// and for peers' agents (those resolve to a locally-derived name).
    public var agentName: String?
    /// True when this message was drafted by an AI and approved/sent by a human
    /// (the "Draft with AI ▸ Send as my AI" flow) — a co-authored "made with the
    /// person and their AI" message, as opposed to an autonomous agent send.
    /// Mirrors `MessageBody.coauthored`, which DOES ride inside the ciphertext, so
    /// every participant stores and renders the co-authorship (not local-only).
    public var coauthored: Bool

    public init(
        id: String, conversationID: String, senderIdentity: String,
        participantType: ParticipantType, text: String, sentAt: Int64,
        threadID: String? = nil, isContext: Bool = false,
        aiContext: Bool = false, localStatus: String = "queued",
        agentName: String? = nil, coauthored: Bool = false
    ) {
        self.id = id
        self.conversationID = conversationID
        self.senderIdentity = senderIdentity
        self.participantType = participantType
        self.text = text
        self.sentAt = sentAt
        self.threadID = threadID
        self.isContext = isContext
        self.aiContext = aiContext
        self.localStatus = localStatus
        self.agentName = agentName
        self.coauthored = coauthored
    }

    enum CodingKeys: String, CodingKey {
        case id, conversationID, senderIdentity, participantType, text, sentAt
        case threadID, isContext, aiContext, localStatus, agentName, coauthored
    }

    /// Tolerant decode: `aiContext` was added after first ship, so payloads
    /// written by earlier builds lack it — default to false instead of failing
    /// the whole record (which would silently drop the message).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        conversationID = try c.decode(String.self, forKey: .conversationID)
        senderIdentity = try c.decode(String.self, forKey: .senderIdentity)
        participantType = try c.decode(ParticipantType.self, forKey: .participantType)
        text = try c.decode(String.self, forKey: .text)
        sentAt = try c.decode(Int64.self, forKey: .sentAt)
        threadID = try c.decodeIfPresent(String.self, forKey: .threadID)
        isContext = try c.decodeIfPresent(Bool.self, forKey: .isContext) ?? false
        aiContext = try c.decodeIfPresent(Bool.self, forKey: .aiContext) ?? false
        localStatus = try c.decodeIfPresent(String.self, forKey: .localStatus) ?? "queued"
        agentName = try c.decodeIfPresent(String.self, forKey: .agentName)
        coauthored = try c.decodeIfPresent(Bool.self, forKey: .coauthored) ?? false
    }
}

/// Persistence seam (CLAUDE.md): SwiftData implementation in the app layer,
/// in-memory implementation for tests. Implementations are responsible for
/// envelope-encrypting sensitive fields via `EncryptedStore` before disk.
public protocol MessageStore: Sendable {
    func save(_ message: StoredMessage) async throws
    func messages(conversationID: String) async throws -> [StoredMessage]
    func messages(threadID: String) async throws -> [StoredMessage]
    func message(id: String) async throws -> StoredMessage?
    func updateStatus(messageID: String, status: String) async throws
    /// Flip the "Add to AI Context" marker on a stored message.
    func setAIContext(messageID: String, value: Bool) async throws
    /// Removes a single message (used by "Not sent" tap-to-retry: drop the
    /// failed copy, then send fresh).
    func deleteMessage(messageID: String) async throws
    func deleteConversation(_ conversationID: String) async throws
    func wipeAll() async throws
}

/// In-memory store for tests and the Local Universe.
public actor InMemoryMessageStore: MessageStore {
    private var storage: [String: StoredMessage] = [:]
    private var order: [String] = []

    public init() {}

    public func save(_ message: StoredMessage) async throws {
        if storage[message.id] == nil {
            order.append(message.id)
        }
        storage[message.id] = message
    }

    public func messages(conversationID: String) async throws -> [StoredMessage] {
        order.compactMap { storage[$0] }.filter { $0.conversationID == conversationID }
    }

    public func messages(threadID: String) async throws -> [StoredMessage] {
        order.compactMap { storage[$0] }.filter { $0.threadID == threadID }
    }

    public func message(id: String) async throws -> StoredMessage? {
        storage[id]
    }

    public func updateStatus(messageID: String, status: String) async throws {
        guard var message = storage[messageID] else { throw PQRCError.recordNotFound }
        message.localStatus = status
        storage[messageID] = message
    }

    public func setAIContext(messageID: String, value: Bool) async throws {
        guard var message = storage[messageID] else { throw PQRCError.recordNotFound }
        message.aiContext = value
        storage[messageID] = message
    }

    public func deleteMessage(messageID: String) async throws {
        storage[messageID] = nil
        order.removeAll { $0 == messageID }
    }

    public func deleteConversation(_ conversationID: String) async throws {
        for (id, message) in storage where message.conversationID == conversationID {
            storage[id] = nil
            order.removeAll { $0 == id }
        }
    }

    public func wipeAll() async throws {
        storage.removeAll()
        order.removeAll()
    }
}
