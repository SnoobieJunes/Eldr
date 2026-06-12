import Foundation

/// Who authored a message. `participant_type` is cryptographically meaningful
/// (SPEC §8.2, §13.4): an agent-signed message MUST carry `.agent` and MUST
/// render as AI-authored; a human label under an agent signature is a protocol
/// violation.
public enum ParticipantType: String, Codable, Sendable {
    case human
    case agent
}

public enum SenderRole: String, Codable, Sendable {
    case identity
    case agent
}

/// Rumor types carried in PQRC payloads (SPEC §8.2 + APP-SPEC §7/§8 extensions).
public enum RumorType: String, Codable, Sendable {
    case message
    case handshake
    case groupCreate = "group_create"
    case threadCreate = "thread_create"
    case aiInvite = "ai_invite"
}

/// Blossom content pointer for >64 KB payloads (SPEC §11). Wire name: `ptr`.
public struct ContentPointer: Codable, Equatable, Sendable {
    public let blossomURL: String
    /// Symmetric key for the blob — itself inside the ratchet-encrypted payload,
    /// so it is never visible to relays or the Blossom server.
    public let decryptionKey: Data
    public let sha256: String
    public let sizeBytes: Int
    public let mirrorURLs: [String]

    enum CodingKeys: String, CodingKey {
        case blossomURL = "blossom_url"
        case decryptionKey = "decryption_key"
        case sha256
        case sizeBytes = "size_bytes"
        case mirrorURLs = "mirror_urls"
    }

    public init(blossomURL: String, decryptionKey: Data, sha256: String, sizeBytes: Int, mirrorURLs: [String]) {
        self.blossomURL = blossomURL
        self.decryptionKey = decryptionKey
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.mirrorURLs = mirrorURLs
    }
}

/// Signed always-on AI announcement (SPEC §13.3). Valid ONLY when signed by the
/// human identity key; agents cannot self-activate.
public struct AIWindowAnnouncement: Codable, Equatable, Sendable {
    public let type: String
    public let activeUntil: Int64
    public let enabledBy: Data
    public let sig: Data

    enum CodingKeys: String, CodingKey {
        case type
        case activeUntil = "active_until"
        case enabledBy = "enabled_by"
        case sig
    }

    public init(activeUntil: Int64, enabledBy: Data, sig: Data) {
        self.type = "ai_active"
        self.activeUntil = activeUntil
        self.enabledBy = enabledBy
        self.sig = sig
    }

    /// Domain-separated message the human identity key signs.
    public static func signatureMessage(activeUntil: Int64, enabledBy: Data, threadID: String?) -> Data {
        var msg = Data("pqrc-ai-window-v1".utf8)
        msg.append(Data(int64BE: activeUntil))
        msg.append(enabledBy)
        if let threadID {
            msg.append(Data(threadID.utf8))
        }
        return msg
    }

    public static func make(activeUntil: Int64, identity: PQRCIdentity) throws -> AIWindowAnnouncement {
        let pub = identity.publicKeyData
        let sig = try identity.sign(signatureMessage(activeUntil: activeUntil, enabledBy: pub, threadID: nil))
        return AIWindowAnnouncement(activeUntil: activeUntil, enabledBy: pub, sig: sig)
    }

    /// Signature check only — time bounds are enforced by the AgentEngine gate.
    public func hasValidSignature(threadID: String? = nil) -> Bool {
        PQRCIdentity.verify(
            signature: sig,
            message: Self.signatureMessage(activeUntil: activeUntil, enabledBy: enabledBy, threadID: threadID),
            publicKey: enabledBy
        )
    }
}

/// Thread-scoped analogue of ai_window (APP-SPEC §8, D7). Inherits all
/// ai_window rules: human-identity signature, bounded duration, fail-closed.
public struct AIInvite: Codable, Equatable, Sendable {
    public struct ThreadRef: Codable, Equatable, Sendable {
        public let id: String
        public init(id: String) { self.id = id }
    }

    public let type: String
    public let thread: ThreadRef
    public let activeUntil: Int64
    public let enabledBy: Data
    public let sig: Data

    enum CodingKeys: String, CodingKey {
        case type
        case thread
        case activeUntil = "active_until"
        case enabledBy = "enabled_by"
        case sig
    }

    public init(threadID: String, activeUntil: Int64, enabledBy: Data, sig: Data) {
        self.type = "ai_invite"
        self.thread = ThreadRef(id: threadID)
        self.activeUntil = activeUntil
        self.enabledBy = enabledBy
        self.sig = sig
    }

    public static func make(threadID: String, activeUntil: Int64, identity: PQRCIdentity) throws -> AIInvite {
        let pub = identity.publicKeyData
        let sig = try identity.sign(
            AIWindowAnnouncement.signatureMessage(activeUntil: activeUntil, enabledBy: pub, threadID: threadID)
        )
        return AIInvite(threadID: threadID, activeUntil: activeUntil, enabledBy: pub, sig: sig)
    }

    public func hasValidSignature() -> Bool {
        PQRCIdentity.verify(
            signature: sig,
            message: AIWindowAnnouncement.signatureMessage(
                activeUntil: activeUntil, enabledBy: enabledBy, threadID: thread.id
            ),
            publicKey: enabledBy
        )
    }
}

/// The rumor content schema (SPEC §8.2, NIP-XX §7) — the actual PQRC message
/// payload, carried unsigned inside the seal. Unknown JSON fields are
/// preserved-or-ignored, never fatal (SPEC §12); decoding uses only the keys
/// below and tolerates extras by construction.
public struct RumorContent: Codable, Equatable, Sendable {
    public struct GroupRef: Codable, Equatable, Sendable {
        public let id: String
        public init(id: String) { self.id = id }
    }
    public struct ThreadRef: Codable, Equatable, Sendable {
        public let id: String
        public init(id: String) { self.id = id }
    }

    public var version: String
    public var type: RumorType
    public var participantType: ParticipantType
    public var senderRole: SenderRole
    public var header: RatchetHeader?
    public var ciphertext: Data?
    public var contentPointer: ContentPointer?
    public var aiWindow: AIWindowAnnouncement?
    public var handshake: HandshakeMessage?
    /// Agent authenticity (SPEC §13.4, NIP-XX §8): REQUIRED iff
    /// `participant_type == "agent"` — an Ed25519 signature by the sender's
    /// bound agent key over "pqrc-agent-msg-v1" || ciphertext. A human-labeled
    /// rumor carrying one (or an agent-labeled rumor lacking a valid one) is a
    /// protocol violation.
    public var agentSig: Data?

    enum CodingKeys: String, CodingKey {
        case version = "pqrc_version"
        case type
        case participantType = "participant_type"
        case senderRole = "sender_role"
        case header = "ratchet_header"
        case ciphertext
        case contentPointer = "ptr"
        case aiWindow = "ai_window"
        case handshake
        case agentSig = "agent_sig"
    }

    /// The message the agent key signs.
    public static func agentSignatureMessage(ciphertext: Data) -> Data {
        Data("pqrc-agent-msg-v1".utf8) + ciphertext
    }

    public init(
        type: RumorType,
        participantType: ParticipantType,
        senderRole: SenderRole,
        header: RatchetHeader?,
        ciphertext: Data?,
        contentPointer: ContentPointer? = nil,
        aiWindow: AIWindowAnnouncement? = nil,
        handshake: HandshakeMessage? = nil
    ) {
        self.version = PQRCConstants.version
        self.type = type
        self.participantType = participantType
        self.senderRole = senderRole
        self.header = header
        self.ciphertext = ciphertext
        self.contentPointer = contentPointer
        self.aiWindow = aiWindow
        self.handshake = handshake
    }
}

/// The decrypted inner message body (what the ratchet ciphertext protects).
/// This is where thread/group routing and the true send time live — inside the
/// encryption, never on the public event (SPEC §8.4).
public struct MessageBody: Codable, Equatable, Sendable {
    public var text: String
    public var sentAt: Int64
    public var group: RumorContent.GroupRef?
    public var thread: RumorContent.ThreadRef?
    public var groupCreate: GroupCreate?
    public var threadCreate: ThreadCreate?
    public var aiInvite: AIInvite?
    /// "Context:"-prefixed agent contributions render with a folder glyph (APP-SPEC §8).
    public var isContext: Bool?

    enum CodingKeys: String, CodingKey {
        case text
        case sentAt = "sent_at"
        case group
        case thread
        case groupCreate = "group_create"
        case threadCreate = "thread_create"
        case aiInvite = "ai_invite"
        case isContext = "is_context"
    }

    public init(
        text: String, sentAt: Int64,
        group: RumorContent.GroupRef? = nil, thread: RumorContent.ThreadRef? = nil,
        groupCreate: GroupCreate? = nil, threadCreate: ThreadCreate? = nil,
        aiInvite: AIInvite? = nil, isContext: Bool? = nil
    ) {
        self.text = text
        self.sentAt = sentAt
        self.group = group
        self.thread = thread
        self.groupCreate = groupCreate
        self.threadCreate = threadCreate
        self.aiInvite = aiInvite
        self.isContext = isContext
    }
}

/// Group creation / roster revision, sent pairwise to each member (APP-SPEC §7, D1).
public struct GroupCreate: Codable, Equatable, Sendable {
    public let groupID: String
    public let name: String
    /// Members as PQRC identity pubkeys (hex).
    public let members: [String]
    public let conversationType: String
    /// Monotonic revision so roster changes order deterministically.
    public let revision: Int

    enum CodingKeys: String, CodingKey {
        case groupID = "group_id"
        case name
        case members
        case conversationType = "conversation_type"
        case revision
    }

    public init(groupID: String, name: String, members: [String], revision: Int) {
        self.groupID = groupID
        self.name = name
        self.members = members
        self.conversationType = "group"
        self.revision = revision
    }
}

/// Embedded AI thread creation (APP-SPEC §8, D7).
public struct ThreadCreate: Codable, Equatable, Sendable {
    public let threadID: String
    public let title: String
    public let anchorMessageID: String?
    public let createdBy: String

    enum CodingKeys: String, CodingKey {
        case threadID = "thread_id"
        case title
        case anchorMessageID = "anchor_message_id"
        case createdBy = "created_by"
    }

    public init(threadID: String, title: String, anchorMessageID: String?, createdBy: String) {
        self.threadID = threadID
        self.title = title
        self.anchorMessageID = anchorMessageID
        self.createdBy = createdBy
    }
}

/// Stable JSON coding for wire structs: sorted keys so frozen vectors and
/// golden files are byte-stable across runs.
public enum WireJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        JSONDecoder()
    }
}
