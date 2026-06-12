import Foundation
import PQRCCore
import SwiftData

// MARK: - Models (APP-SPEC §3)
//
// Sensitive fields are envelope-encrypted blobs under per-record HKDF keys
// (EncryptedStore, SPEC §3.4). Only opaque ids and ordering counters are
// stored in the clear; message content, names, timestamps and ratchet state
// never touch SQLite unencrypted. The at-rest canary test scans the raw
// store files to enforce this.

@Model
final class ContactModel {
    @Attribute(.unique) var identityHex: String
    var nostrPubkeyHex: String
    var agentPubkeyHex: String
    var crossSignatureB64: String
    /// Encrypted local-only nickname (D11 — no published profiles).
    var encryptedNickname: Data
    var verified: Bool
    var blocked: Bool

    init(
        identityHex: String, nostrPubkeyHex: String, agentPubkeyHex: String,
        crossSignatureB64: String, encryptedNickname: Data, verified: Bool = false,
        blocked: Bool = false
    ) {
        self.identityHex = identityHex
        self.nostrPubkeyHex = nostrPubkeyHex
        self.agentPubkeyHex = agentPubkeyHex
        self.crossSignatureB64 = crossSignatureB64
        self.encryptedNickname = encryptedNickname
        self.verified = verified
        self.blocked = blocked
    }
}

@Model
final class ConversationModel {
    @Attribute(.unique) var id: String
    var type: String  // "1to1" | "group"
    /// Encrypted ConversationMeta JSON (name, member list, roster asserter).
    var encryptedMeta: Data
    var pinned: Bool
    var isRequest: Bool
    var localSeq: Int

    init(
        id: String, type: String, encryptedMeta: Data, pinned: Bool = false,
        isRequest: Bool = false, localSeq: Int = 0
    ) {
        self.id = id
        self.type = type
        self.encryptedMeta = encryptedMeta
        self.pinned = pinned
        self.isRequest = isRequest
        self.localSeq = localSeq
    }
}

@Model
final class MessageModel {
    @Attribute(.unique) var id: String
    var conversationID: String
    var threadID: String?
    /// Encrypted StoredMessage JSON.
    var encryptedPayload: Data
    /// Local monotonic ordering key — leaks order only, never wall-clock time.
    var localSeq: Int

    init(id: String, conversationID: String, threadID: String?, encryptedPayload: Data, localSeq: Int) {
        self.id = id
        self.conversationID = conversationID
        self.threadID = threadID
        self.encryptedPayload = encryptedPayload
        self.localSeq = localSeq
    }
}

@Model
final class SessionRecordModel {
    @Attribute(.unique) var peerIdentityHex: String
    var encryptedSnapshot: Data

    init(peerIdentityHex: String, encryptedSnapshot: Data) {
        self.peerIdentityHex = peerIdentityHex
        self.encryptedSnapshot = encryptedSnapshot
    }
}

@Model
final class ThreadRecordModel {
    @Attribute(.unique) var id: String
    var conversationID: String
    var encryptedMeta: Data
    var closed: Bool

    init(id: String, conversationID: String, encryptedMeta: Data, closed: Bool = false) {
        self.id = id
        self.conversationID = conversationID
        self.encryptedMeta = encryptedMeta
        self.closed = closed
    }
}

@Model
final class ProcessedEventModel {
    @Attribute(.unique) var eventID: String
    init(eventID: String) { self.eventID = eventID }
}

// MARK: - Decrypted metadata shapes

struct ConversationMeta: Codable, Sendable {
    var name: String
    var memberIdentityHexes: [String]
    var rosterAssertedBy: String?
    var rosterRevision: Int
    var groupID: String?
}

struct ThreadMeta: Codable, Sendable {
    var title: String
    var createdBy: String
    var anchorMessageID: String?
}

// MARK: - SwiftData-backed MessageStore

/// The production `MessageStore` (CLAUDE.md seam). All payloads pass through
/// `EncryptedStore` before SwiftData sees them; the container additionally
/// uses complete file protection.
@ModelActor
actor SwiftDataMessageStore: MessageStore {
    private var crypter: EncryptedStore?
    private var seqCounter = 0

    func configure(crypter: EncryptedStore) {
        self.crypter = crypter
        let fetch = FetchDescriptor<MessageModel>(sortBy: [SortDescriptor(\.localSeq, order: .reverse)])
        seqCounter = ((try? modelContext.fetch(fetch))?.first?.localSeq ?? 0) + 1
    }

    private func requireCrypter() throws -> EncryptedStore {
        guard let crypter else { throw PQRCError.storeUnavailable }
        return crypter
    }

    func save(_ message: StoredMessage) async throws {
        let crypter = try requireCrypter()
        let payload = try crypter.seal(
            try JSONEncoder().encode(message), recordID: "msg-\(message.id)")
        seqCounter += 1
        modelContext.insert(
            MessageModel(
                id: message.id, conversationID: message.conversationID,
                threadID: message.threadID, encryptedPayload: payload, localSeq: seqCounter))
        try modelContext.save()
    }

    func messages(conversationID: String) async throws -> [StoredMessage] {
        let crypter = try requireCrypter()
        let descriptor = FetchDescriptor<MessageModel>(
            predicate: #Predicate { $0.conversationID == conversationID },
            sortBy: [SortDescriptor(\.localSeq)])
        return try modelContext.fetch(descriptor).compactMap { model in
            guard let plain = try? crypter.open(model.encryptedPayload, recordID: "msg-\(model.id)")
            else { return nil }
            return try? JSONDecoder().decode(StoredMessage.self, from: plain)
        }
    }

    func messages(threadID: String) async throws -> [StoredMessage] {
        let crypter = try requireCrypter()
        let descriptor = FetchDescriptor<MessageModel>(
            predicate: #Predicate { $0.threadID == threadID },
            sortBy: [SortDescriptor(\.localSeq)])
        return try modelContext.fetch(descriptor).compactMap { model in
            guard let plain = try? crypter.open(model.encryptedPayload, recordID: "msg-\(model.id)")
            else { return nil }
            return try? JSONDecoder().decode(StoredMessage.self, from: plain)
        }
    }

    func updateStatus(messageID: String, status: String) async throws {
        let crypter = try requireCrypter()
        let descriptor = FetchDescriptor<MessageModel>(
            predicate: #Predicate { $0.id == messageID })
        guard let model = try modelContext.fetch(descriptor).first,
            let plain = try? crypter.open(model.encryptedPayload, recordID: "msg-\(messageID)"),
            var message = try? JSONDecoder().decode(StoredMessage.self, from: plain)
        else { throw PQRCError.recordNotFound }
        message.localStatus = status
        model.encryptedPayload = try crypter.seal(
            try JSONEncoder().encode(message), recordID: "msg-\(messageID)")
        try modelContext.save()
    }

    func deleteConversation(_ conversationID: String) async throws {
        try modelContext.delete(
            model: MessageModel.self,
            where: #Predicate { $0.conversationID == conversationID })
        try modelContext.delete(
            model: ConversationModel.self, where: #Predicate { $0.id == conversationID })
        try modelContext.save()
    }

    func wipeAll() async throws {
        try modelContext.delete(model: MessageModel.self)
        try modelContext.delete(model: ConversationModel.self)
        try modelContext.delete(model: ContactModel.self)
        try modelContext.delete(model: SessionRecordModel.self)
        try modelContext.delete(model: ThreadRecordModel.self)
        try modelContext.delete(model: ProcessedEventModel.self)
        try modelContext.save()
    }

    // MARK: Session persistence

    func saveSession(peerIdentityHex: String, snapshot: RatchetSnapshot) throws {
        let crypter = try requireCrypter()
        let blob = try crypter.seal(
            try JSONEncoder().encode(snapshot), recordID: "session-\(peerIdentityHex)")
        let descriptor = FetchDescriptor<SessionRecordModel>(
            predicate: #Predicate { $0.peerIdentityHex == peerIdentityHex })
        if let existing = try modelContext.fetch(descriptor).first {
            existing.encryptedSnapshot = blob
        } else {
            modelContext.insert(
                SessionRecordModel(peerIdentityHex: peerIdentityHex, encryptedSnapshot: blob))
        }
        try modelContext.save()
    }

    static func makeContainer(inMemory: Bool, url: URL? = nil) throws -> ModelContainer {
        let schema = Schema([
            ContactModel.self, ConversationModel.self, MessageModel.self,
            SessionRecordModel.self, ThreadRecordModel.self, ProcessedEventModel.self,
        ])
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else if let url {
            configuration = ModelConfiguration(schema: schema, url: url)
        } else {
            configuration = ModelConfiguration(schema: schema)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
