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
    /// Encrypted `ContactRecord` JSON (binding, nicknames, flags). The whole
    /// record is one sealed blob: nothing about a contact except the opaque
    /// row key is visible at rest (D11 — no published profiles).
    var encryptedPayload: Data = Data()

    init(identityHex: String, encryptedPayload: Data) {
        self.identityHex = identityHex
        self.encryptedPayload = encryptedPayload
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

/// Everything the app knows about a verified contact, sealed as one blob.
/// The binding is re-verified through `BindingVerifier.verify` on every
/// restore — invariant 7's only-path-to-trusted-keys survives persistence.
struct ContactRecord: Codable, Sendable {
    var binding: IdentityBinding
    /// User-set local rename; takes precedence over everything (D11).
    var localNickname: String?
    /// Alias the peer chose for themselves, received over the encrypted
    /// channel (only established contacts ever see it).
    var peerAlias: String?
    var verified: Bool
    var blocked: Bool
    /// Session-restore fidelity: the lrp unlinkability caveat sticks.
    var usedLastResortPrekey: Bool
    /// Locally-generated friendly codename (adjective-noun-verb-###). PURELY
    /// LOCAL — invented on this device and NEVER broadcast (SPEC §0). Replaces
    /// the ugly truncated-key fallback so every contact reads as a real name.
    /// Optional → tolerant decode of records written before this field existed.
    var autoName: String? = nil
    /// Locally-generated friendly codename for this contact's AI (so a peer's
    /// assistant reads as a name, not "Contact …'s AI"). Also never broadcast.
    var autoAIName: String? = nil
    /// Local type tag — `"coding_agent"` for a paired Eldr ACP Configurator. PURELY
    /// LOCAL (never broadcast, SPEC §0); only drives a distinct icon. Optional →
    /// tolerant decode of records written before this field existed.
    var contactType: String? = nil

    var identityHex: String { binding.identityPubkey.hexString }

    /// Display-name resolution, one rule everywhere:
    /// local rename > peer's self-chosen alias > local friendly name > key.
    var displayName: String {
        localNickname ?? peerAlias ?? autoName ?? "Contact \(String(identityHex.prefix(8)))"
    }
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

    func message(id: String) async throws -> StoredMessage? {
        let crypter = try requireCrypter()
        let descriptor = FetchDescriptor<MessageModel>(predicate: #Predicate { $0.id == id })
        guard let model = try modelContext.fetch(descriptor).first,
            let plain = try? crypter.open(model.encryptedPayload, recordID: "msg-\(id)")
        else { return nil }
        return try? JSONDecoder().decode(StoredMessage.self, from: plain)
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

    func setAIContext(messageID: String, value: Bool) async throws {
        let crypter = try requireCrypter()
        let descriptor = FetchDescriptor<MessageModel>(
            predicate: #Predicate { $0.id == messageID })
        guard let model = try modelContext.fetch(descriptor).first,
            let plain = try? crypter.open(model.encryptedPayload, recordID: "msg-\(messageID)"),
            var message = try? JSONDecoder().decode(StoredMessage.self, from: plain)
        else { throw PQRCError.recordNotFound }
        message.aiContext = value
        model.encryptedPayload = try crypter.seal(
            try JSONEncoder().encode(message), recordID: "msg-\(messageID)")
        try modelContext.save()
    }

    func deleteMessage(messageID: String) async throws {
        try modelContext.delete(
            model: MessageModel.self, where: #Predicate { $0.id == messageID })
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
        // Local mutable copy so we can wipe the transient plaintext secrets after
        // sealing (AC40). `snapshot` is already a fresh copy produced by
        // `makeSnapshot()` (every secret field deep-copied), so this never
        // touches the live ratchet the running session needs.
        var snapshot = snapshot
        defer { snapshot.zeroize() }
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

    func sessions() throws -> [(peerIdentityHex: String, snapshot: RatchetSnapshot)] {
        let crypter = try requireCrypter()
        return try modelContext.fetch(FetchDescriptor<SessionRecordModel>()).compactMap { model in
            guard
                let plain = try? crypter.open(
                    model.encryptedSnapshot, recordID: "session-\(model.peerIdentityHex)"),
                let snapshot = try? JSONDecoder().decode(RatchetSnapshot.self, from: plain)
            else { return nil }
            return (model.peerIdentityHex, snapshot)
        }
    }

    // MARK: Contact persistence

    func saveContact(_ record: ContactRecord) throws {
        let crypter = try requireCrypter()
        let identityHex = record.identityHex
        let blob = try crypter.seal(
            try JSONEncoder().encode(record), recordID: "contact-\(identityHex)")
        let descriptor = FetchDescriptor<ContactModel>(
            predicate: #Predicate { $0.identityHex == identityHex })
        if let existing = try modelContext.fetch(descriptor).first {
            existing.encryptedPayload = blob
        } else {
            modelContext.insert(ContactModel(identityHex: identityHex, encryptedPayload: blob))
        }
        try modelContext.save()
    }

    func contacts() throws -> [ContactRecord] {
        let crypter = try requireCrypter()
        return try modelContext.fetch(FetchDescriptor<ContactModel>()).compactMap { model in
            guard
                let plain = try? crypter.open(
                    model.encryptedPayload, recordID: "contact-\(model.identityHex)")
            else { return nil }
            return try? JSONDecoder().decode(ContactRecord.self, from: plain)
        }
    }

    // MARK: Conversation / thread metadata persistence

    func saveConversationMeta(id: String, type: String, meta: ConversationMeta) throws {
        let crypter = try requireCrypter()
        let blob = try crypter.seal(try JSONEncoder().encode(meta), recordID: "conv-\(id)")
        let descriptor = FetchDescriptor<ConversationModel>(
            predicate: #Predicate { $0.id == id })
        if let existing = try modelContext.fetch(descriptor).first {
            existing.encryptedMeta = blob
            existing.type = type
        } else {
            modelContext.insert(ConversationModel(id: id, type: type, encryptedMeta: blob))
        }
        try modelContext.save()
    }

    func conversationMetas() throws -> [(id: String, type: String, meta: ConversationMeta, pinned: Bool)] {
        let crypter = try requireCrypter()
        return try modelContext.fetch(FetchDescriptor<ConversationModel>()).compactMap { model in
            guard
                let plain = try? crypter.open(model.encryptedMeta, recordID: "conv-\(model.id)"),
                let meta = try? JSONDecoder().decode(ConversationMeta.self, from: plain)
            else { return nil }
            return (model.id, model.type, meta, model.pinned)
        }
    }

    func setPinned(conversationID: String, pinned: Bool) throws {
        let descriptor = FetchDescriptor<ConversationModel>(
            predicate: #Predicate { $0.id == conversationID })
        guard let model = try modelContext.fetch(descriptor).first else { return }
        model.pinned = pinned
        try modelContext.save()
    }

    func saveThreadMeta(threadID: String, conversationID: String, meta: ThreadMeta) throws {
        let crypter = try requireCrypter()
        let blob = try crypter.seal(try JSONEncoder().encode(meta), recordID: "thread-\(threadID)")
        let descriptor = FetchDescriptor<ThreadRecordModel>(
            predicate: #Predicate { $0.id == threadID })
        if let existing = try modelContext.fetch(descriptor).first {
            existing.encryptedMeta = blob
        } else {
            modelContext.insert(
                ThreadRecordModel(id: threadID, conversationID: conversationID, encryptedMeta: blob))
        }
        try modelContext.save()
    }

    func threadMetas() throws -> [(threadID: String, conversationID: String, meta: ThreadMeta)] {
        let crypter = try requireCrypter()
        return try modelContext.fetch(FetchDescriptor<ThreadRecordModel>()).compactMap { model in
            guard
                let plain = try? crypter.open(model.encryptedMeta, recordID: "thread-\(model.id)"),
                let meta = try? JSONDecoder().decode(ThreadMeta.self, from: plain)
            else { return nil }
            return (model.id, model.conversationID, meta)
        }
    }

    /// Distinct conversation ids that have at least one stored message.
    func conversationIDsWithMessages() throws -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        let descriptor = FetchDescriptor<MessageModel>(sortBy: [SortDescriptor(\.localSeq)])
        for model in try modelContext.fetch(descriptor) where !seen.contains(model.conversationID) {
            seen.insert(model.conversationID)
            ordered.append(model.conversationID)
        }
        return ordered
    }

    // MARK: Processed-envelope dedupe (replay survival across relaunch)

    /// Without this, a relaunch would re-receive every stored relay envelope:
    /// the ratchet rejects them (keys deleted — FS working as designed), but
    /// they'd churn the retry queue and surface as quarantine noise.
    func markProcessed(eventID: String) throws {
        modelContext.insert(ProcessedEventModel(eventID: eventID))
        try modelContext.save()
    }

    func processedEventIDs() throws -> Set<String> {
        Set(try modelContext.fetch(FetchDescriptor<ProcessedEventModel>()).map(\.eventID))
    }

    static func makeContainer(inMemory: Bool, url: URL? = nil) throws -> ModelContainer {
        let schema = Schema([
            ContactModel.self, ConversationModel.self, MessageModel.self,
            SessionRecordModel.self, ThreadRecordModel.self, ProcessedEventModel.self,
        ])
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            // Pin the store location and ensure its parent exists FIRST — on a
            // fresh install Library/Application Support may not exist yet, and
            // letting Core Data discover that prints a wall of self-recovering
            // "errno 2 / no such file" errors at launch.
            let storeURL =
                url ?? URL.applicationSupportDirectory.appendingPathComponent("default.store")
            try? FileManager.default.createDirectory(
                at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            configuration = ModelConfiguration(schema: schema, url: storeURL)
        }
        let container = try ModelContainer(for: schema, configurations: [configuration])
        if !inMemory {
            // Defense-in-depth on top of the per-record envelope encryption
            // (every sensitive field is AES-GCM-sealed under the SE-wrapped
            // master key). completeUntilFirstUserAuthentication, NOT .complete:
            // a messenger DB must stay readable while the device is locked
            // (background work, relaunch); .complete makes it inaccessible then
            // and causes real open/write failures on device. Still encrypted at
            // rest and unreadable until the first post-boot unlock.
            for fileURL in container.configurations.map(\.url) {
                try? FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: fileURL.path)
            }
        }
        return container
    }
}
