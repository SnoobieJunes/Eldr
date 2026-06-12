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
    /// Local-only delivery state: "queued" | "sent" (APP-SPEC D5 — no remote receipts).
    public var localStatus: String

    public init(
        id: String, conversationID: String, senderIdentity: String,
        participantType: ParticipantType, text: String, sentAt: Int64,
        threadID: String? = nil, isContext: Bool = false, localStatus: String = "queued"
    ) {
        self.id = id
        self.conversationID = conversationID
        self.senderIdentity = senderIdentity
        self.participantType = participantType
        self.text = text
        self.sentAt = sentAt
        self.threadID = threadID
        self.isContext = isContext
        self.localStatus = localStatus
    }
}

/// Persistence seam (CLAUDE.md): SwiftData implementation in the app layer,
/// in-memory implementation for tests. Implementations are responsible for
/// envelope-encrypting sensitive fields via `EncryptedStore` before disk.
public protocol MessageStore: Sendable {
    func save(_ message: StoredMessage) async throws
    func messages(conversationID: String) async throws -> [StoredMessage]
    func messages(threadID: String) async throws -> [StoredMessage]
    func updateStatus(messageID: String, status: String) async throws
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

    public func updateStatus(messageID: String, status: String) async throws {
        guard var message = storage[messageID] else { throw PQRCError.recordNotFound }
        message.localStatus = status
        storage[messageID] = message
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
