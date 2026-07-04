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
    /// Stable `ConfiguredAI.id` of the local AI that authored this message, when it
    /// was one of THIS human's own configured AIs. PURELY LOCAL — never on the wire.
    /// Unlike `agentName` (a display codename), this is the stable id the per-AI
    /// context gate keys on (which of my AIs may see another AI's reply — feature 1).
    /// nil for human messages and for peers' agents (a peer agent buckets by its
    /// sender identity, `peerAI:<senderHex>`).
    public var agentAIID: String?
    /// Per-AI inclusion marks (`ConfiguredAI.id`s) — "include THIS message in THESE
    /// specific AIs' context" (feature 7, the per-AI long-press). PURELY LOCAL.
    /// nil + legacy `aiContext == true` ⇒ "all my participating AIs" (lazy
    /// migration); a non-nil (possibly empty) array is the explicit per-AI set.
    public var aiMarks: [String]?
    /// For an agent-authored message: the text re-sealed under the AUTHOR AI's
    /// per-record key (`EncryptedStore.seal(text, recordID: "ai:<agentAIID>:<id>")`
    /// for my AIs, `"peerAI:<senderHex>:<id>"` for a peer's). PURELY LOCAL, itself
    /// nested inside the outer master-sealed record. The context assembler surfaces
    /// another AI's words only by OPENING this seal with that author's key —
    /// enforcement-by-construction for the per-AI isolation gate (feature 1). nil for
    /// human messages and legacy records.
    public var sealedAgentContent: Data?

    public init(
        id: String, conversationID: String, senderIdentity: String,
        participantType: ParticipantType, text: String, sentAt: Int64,
        threadID: String? = nil, isContext: Bool = false,
        aiContext: Bool = false, localStatus: String = "queued",
        agentName: String? = nil, coauthored: Bool = false,
        agentAIID: String? = nil, aiMarks: [String]? = nil,
        sealedAgentContent: Data? = nil
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
        self.agentAIID = agentAIID
        self.aiMarks = aiMarks
        self.sealedAgentContent = sealedAgentContent
    }

    enum CodingKeys: String, CodingKey {
        case id, conversationID, senderIdentity, participantType, text, sentAt
        case threadID, isContext, aiContext, localStatus, agentName, coauthored
        case agentAIID, aiMarks, sealedAgentContent
    }

    /// Tolerant decode: `aiContext` was added after first ship, so payloads
    /// written by earlier builds lack it — default to false instead of failing
    /// the whole record (which would silently drop the message). The per-AI gate
    /// fields (`agentAIID`/`aiMarks`/`sealedAgentContent`) are added later still and
    /// decode to nil on legacy records (treated as "visible to all my AIs" — today's
    /// behavior; the per-AI isolation applies going-forward only).
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
        agentAIID = try c.decodeIfPresent(String.self, forKey: .agentAIID)
        aiMarks = try c.decodeIfPresent([String].self, forKey: .aiMarks)
        sealedAgentContent = try c.decodeIfPresent(Data.self, forKey: .sealedAgentContent)
    }

    /// Record id used to seal/open THIS agent message's content under its AUTHOR
    /// AI's key (per-AI isolation, feature 1) — one source of truth shared by the
    /// store (which seals on save) and the context assembler (which opens it as the
    /// act of including the message in another AI's view). nil for human messages.
    /// One of the owner's own AIs → keyed by its stable `agentAIID`; a peer's AI →
    /// keyed by the peer's sender identity (`peerAI:<hex>`).
    public var authorSealRecordID: String? {
        guard participantType == .agent else { return nil }
        if let agentAIID { return "ai:\(agentAIID):\(id)" }
        return "peerAI:\(senderIdentity):\(id)"
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
    /// Set the per-AI inclusion marks on a stored message (feature 7): the exact
    /// set of my AIs that may see this message regardless of the normal gate. An
    /// empty array clears the per-AI marks.
    func setAIMarks(messageID: String, aiIDs: [String]) async throws
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

    public func setAIMarks(messageID: String, aiIDs: [String]) async throws {
        guard var message = storage[messageID] else { throw PQRCError.recordNotFound }
        message.aiMarks = aiIDs
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
