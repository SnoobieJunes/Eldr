// SPDX-License-Identifier: Apache-2.0
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
    case aiContextGrant = "ai_context_grant"
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

/// Human-signed grant authorizing the *consume* axis of AI context sharing
/// (APP-SPEC §8 extension, DEVIATIONS N24): within the named scope and until
/// `active_until`, the other party's agent may ingest this human's
/// `ai_context`-marked messages, and reciprocally this human's agent may ingest
/// theirs. It does NOT authorize sending — that remains `ai_window`/`ai_invite`.
/// Like those, valid ONLY when signed by the human identity key; agents cannot
/// self-activate (SPEC §13.3, CLAUDE.md invariant 9). A distinct domain string
/// keeps grant signatures from ever being replayed as a window/invite.
public struct AIContextGrant: Codable, Equatable, Sendable {
    /// Conversation- or thread-scoped, with the id bound into the signature so a
    /// conversation grant can't be reflected into a thread (or vice versa).
    public struct Scope: Codable, Equatable, Sendable {
        /// The two independent content streams a grant can authorize (D2 — the
        /// 2-step split). "human" = the peer's OWN messages; "ai" = the peer's AI
        /// messages. Each axis is a SEPARATE grant, issued and withdrawn on its own.
        public static let humanAxis = "human"
        public static let aiAxis = "ai"

        public let kind: String  // "conversation" | "thread"
        public let id: String
        /// Which content stream this grant authorizes (`humanAxis` | `aiAxis`).
        /// Defaults to "human" so a grant from an older client (no axis field) keeps
        /// its original meaning, and a human-axis grant serializes AND signs
        /// byte-identically to before (the field is omitted on encode when "human").
        public let axis: String

        public init(kind: String, id: String, axis: String = humanAxis) {
            self.kind = kind
            self.id = id
            self.axis = axis
        }

        public static func conversation(_ id: String, axis: String = humanAxis) -> Scope {
            Scope(kind: "conversation", id: id, axis: axis)
        }
        public static func thread(_ id: String, axis: String = humanAxis) -> Scope {
            Scope(kind: "thread", id: id, axis: axis)
        }

        /// Stable key for engine state + signing. The human axis is byte-identical
        /// to before ("kind:id"); a non-human axis appends ":<axis>" so the two are
        /// DISTINCT engine entries and DISTINCT signatures (SPEC §12: an old client
        /// computes only the human tag, so an ai-axis grant won't verify there and
        /// simply isn't honored — fails safe, no sharing).
        public var tag: String {
            axis == Self.humanAxis ? "\(kind):\(id)" : "\(kind):\(id):\(axis)"
        }

        enum CodingKeys: String, CodingKey { case kind, id, axis }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(String.self, forKey: .kind)
            id = try c.decode(String.self, forKey: .id)
            axis = try c.decodeIfPresent(String.self, forKey: .axis) ?? Self.humanAxis
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(kind, forKey: .kind)
            try c.encode(id, forKey: .id)
            // Omit the default so a human-axis grant serializes exactly as older
            // builds did (frozen vectors stay stable; old clients ignore the field).
            if axis != Self.humanAxis { try c.encode(axis, forKey: .axis) }
        }
    }

    public let type: String
    public let scope: Scope
    public let activeUntil: Int64
    public let enabledBy: Data
    public let sig: Data

    enum CodingKeys: String, CodingKey {
        case type
        case scope
        case activeUntil = "active_until"
        case enabledBy = "enabled_by"
        case sig
    }

    public init(scope: Scope, activeUntil: Int64, enabledBy: Data, sig: Data) {
        self.type = "ai_context_grant"
        self.scope = scope
        self.activeUntil = activeUntil
        self.enabledBy = enabledBy
        self.sig = sig
    }

    /// Domain-separated message the human identity key signs. The domain string
    /// is deliberately different from `pqrc-ai-window-v1` (no cross-replay), and
    /// the scope tag is bound in.
    public static func signatureMessage(scope: Scope, activeUntil: Int64, enabledBy: Data) -> Data {
        var msg = Data("pqrc-ai-context-grant-v1".utf8)
        msg.append(Data(int64BE: activeUntil))
        msg.append(enabledBy)
        msg.append(Data(scope.tag.utf8))
        return msg
    }

    public static func make(scope: Scope, activeUntil: Int64, identity: PQRCIdentity) throws -> AIContextGrant {
        let pub = identity.publicKeyData
        let sig = try identity.sign(signatureMessage(scope: scope, activeUntil: activeUntil, enabledBy: pub))
        return AIContextGrant(scope: scope, activeUntil: activeUntil, enabledBy: pub, sig: sig)
    }

    /// Signature check only — time bounds are enforced by the AgentEngine gate.
    public func hasValidSignature() -> Bool {
        PQRCIdentity.verify(
            signature: sig,
            message: Self.signatureMessage(scope: scope, activeUntil: activeUntil, enabledBy: enabledBy),
            publicKey: enabledBy
        )
    }
}

/// Content-free control to (re)flag a *previously sent* message as AI-shareable
/// context (DEVIATIONS N25). Carries only the target message id + the new value,
/// inside the encrypted body; renders no bubble. The receiver MUST reject a mark
/// for any message it did not receive from this same sender (no flagging someone
/// else's words as shareable).
public struct AIContextMark: Codable, Equatable, Sendable {
    public let messageID: String
    public let value: Bool

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case value
    }

    public init(messageID: String, value: Bool) {
        self.messageID = messageID
        self.value = value
    }
}

/// Reassembly metadata for a logical message split across several ratcheted
/// envelopes (SPEC §7/§11: chunking is the relay-only alternative to a Blossom
/// pointer for >64 KB content). Lives INSIDE the ciphertext, so relays and
/// servers never see that a message was chunked, how many parts it has, or how
/// big it is — only the bucket-padded per-envelope size like any other message.
/// Optional and ignored by older clients (SPEC §12 forward compatibility).
public struct MessageChunk: Codable, Equatable, Sendable {
    /// Groups the parts of one logical message. Random per logical message.
    public let id: String
    /// 0-based position of this part.
    public let index: Int
    /// Total number of parts in the logical message.
    public let total: Int

    enum CodingKeys: String, CodingKey {
        case id
        case index
        case total
    }

    public init(id: String, index: Int, total: Int) {
        self.id = id
        self.index = index
        self.total = total
    }
}

/// Splits and rejoins large text for relay chunking. Splitting is on grapheme
/// (Character) boundaries so a chunk never bisects a multi-byte scalar or an
/// emoji cluster, and each chunk's budget is measured as JSON-ESCAPED bytes —
/// the size the text actually occupies inside the encoded `MessageBody` — so
/// escape-heavy content can't push a chunk into the next (much larger) padding
/// bucket and blow past the relay's event-size limit.
public enum MessageChunker {
    /// Bytes a character costs once JSON-string-escaped (matches Swift's
    /// JSONEncoder with `withoutEscapingSlashes`): `" \ \b \t \n \f \r` → 2,
    /// other control chars → `\u00XX` (6), everything else → its UTF-8 length
    /// (non-ASCII is emitted as raw UTF-8, not `\u`-escaped).
    static func escapedCost(_ character: Character) -> Int {
        var cost = 0
        for scalar in character.unicodeScalars {
            switch scalar.value {
            case 0x22, 0x5C, 0x08, 0x09, 0x0A, 0x0C, 0x0D:
                cost += 2
            case 0x00...0x1F:
                cost += 6
            default:
                cost += String(scalar).utf8.count
            }
        }
        return cost
    }

    /// Returns the parts of `text`, each ≤ `budgetBytes` of JSON-escaped size,
    /// preserving order. A single returned element means no chunking is needed.
    /// Never returns an empty array (an empty string yields `[""]`).
    public static func split(
        _ text: String, budgetBytes: Int = PQRCConstants.maxChunkTextBytes
    ) -> [String] {
        precondition(budgetBytes > 0, "chunk budget must be positive")
        var totalCost = 0
        for character in text { totalCost += escapedCost(character) }
        if totalCost <= budgetBytes { return [text] }

        var parts: [String] = []
        var current = ""
        var currentBytes = 0
        for character in text {
            let size = escapedCost(character)
            // A single grapheme larger than the budget can't be split further
            // without corrupting it; it gets its own (slightly over-budget) part.
            if currentBytes + size > budgetBytes, !current.isEmpty {
                parts.append(current)
                current = ""
                currentBytes = 0
            }
            current.append(character)
            currentBytes += size
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// Reassembles parts in the given order. Caller is responsible for ordering
    /// by chunk index before calling.
    public static func join(_ parts: [String]) -> String {
        parts.joined()
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
    /// Sender-assigned stable id for THIS message, so both parties store the same
    /// id for the same message (the sender's local id travels inside the
    /// ciphertext). Without it each side minted its own UUID and cross-device
    /// controls that reference a message by id — the `ai_context_mark` retro-flag
    /// (DEVIATIONS N25) — could never resolve the peer's copy. Optional and
    /// ignored by older clients (SPEC §12); the receiver falls back to a fresh id.
    public var messageID: String?
    public var group: RumorContent.GroupRef?
    public var thread: RumorContent.ThreadRef?
    public var groupCreate: GroupCreate?
    public var threadCreate: ThreadCreate?
    public var aiInvite: AIInvite?
    /// "Context:"-prefixed agent contributions render with a folder glyph (APP-SPEC §8).
    public var isContext: Bool?
    /// Human-applied "this message is AI-shareable context" marker (DEVIATIONS
    /// N23). Distinct from `isContext` (the agent-authored render hint): this is
    /// set by a human via "Add to AI Context" and is only *consumed* by the peer
    /// AI under an active `AIContextGrant`. Inside the ciphertext only.
    public var aiContext: Bool?
    /// Retro-flag control for an already-sent message (DEVIATIONS N25).
    public var aiContextMark: AIContextMark?
    /// Human-signed context-sharing grant (DEVIATIONS N24).
    public var aiContextGrant: AIContextGrant?
    /// Sender-chosen display alias, shared only inside the encrypted channel —
    /// so only already-established contacts ever see it (no public profile,
    /// D11 preserved). Optional and ignored by older clients (SPEC §12).
    /// Recorded in DEVIATIONS as an upstream-NIP candidate.
    public var alias: String?
    /// Set when this body is one part of a chunked large message (DEVIATIONS:
    /// relay-only chunking, the §11 alternative to a Blossom pointer). Inside
    /// the ciphertext only; nil for ordinary single-envelope messages.
    public var chunk: MessageChunk?
    /// Set when this body is a watch-along DRAFT from the owner's Mac coding agent for
    /// the owner's phone to voice to the group (SPEC §13.5 endpoint model). Inside the
    /// ciphertext only, owner↔agent; nil for ordinary messages.
    public var agentDraft: AgentDraft?
    /// True when this message was drafted by the sender's AI and approved/sent by
    /// the human — a co-authored "made with you and your AI" message (the in-app
    /// "Draft with AI ▸ Send as my AI" flow), as opposed to an autonomous agent
    /// send. Travels INSIDE the ciphertext so every participant's client can show
    /// the co-authorship, and ONLY participants (relays/observers never see it —
    /// SPEC §0). Honest under invariant 8: the message stays `participant_type ==
    /// agent`, agent-signed, and renders with the AI badge; this only adds the
    /// human's directing credit. Optional + ignored by older clients (SPEC §12).
    public var coauthored: Bool?

    /// @-mentions parsed from `text` (people and tethered AIs), inside the ciphertext
    /// only (never wire metadata — SPEC §0). An AI mention routes the reply to the
    /// tethered AI of that name on each recipient's device; a person mention is a UI
    /// highlight/notify hint. Optional + ignored by older clients (SPEC §12).
    public var mentions: [Mention]?

    /// One @-mention. `id` is the target's stable identity (a person's PQRC identity
    /// hex, or — for an AI — the local ConfiguredAI id); AI routing matches by
    /// `displayName` so it resolves to each device's own tethered AI of that name.
    public struct Mention: Codable, Equatable, Sendable {
        public let id: String
        public let displayName: String
        public let kind: String  // "person" | "ai"
        public init(id: String, displayName: String, kind: String) {
            self.id = id
            self.displayName = displayName
            self.kind = kind
        }
    }

    enum CodingKeys: String, CodingKey {
        case text
        case sentAt = "sent_at"
        case messageID = "message_id"
        case group
        case thread
        case groupCreate = "group_create"
        case threadCreate = "thread_create"
        case aiInvite = "ai_invite"
        case isContext = "is_context"
        case aiContext = "ai_context"
        case aiContextMark = "ai_context_mark"
        case aiContextGrant = "ai_context_grant"
        case alias
        case chunk
        case agentDraft = "agent_draft"
        case coauthored
        case mentions
    }

    public init(
        text: String, sentAt: Int64, messageID: String? = nil,
        group: RumorContent.GroupRef? = nil, thread: RumorContent.ThreadRef? = nil,
        groupCreate: GroupCreate? = nil, threadCreate: ThreadCreate? = nil,
        aiInvite: AIInvite? = nil, isContext: Bool? = nil,
        aiContext: Bool? = nil, aiContextMark: AIContextMark? = nil,
        aiContextGrant: AIContextGrant? = nil, alias: String? = nil,
        chunk: MessageChunk? = nil, agentDraft: AgentDraft? = nil,
        coauthored: Bool? = nil, mentions: [Mention]? = nil
    ) {
        self.text = text
        self.sentAt = sentAt
        self.messageID = messageID
        self.group = group
        self.thread = thread
        self.groupCreate = groupCreate
        self.threadCreate = threadCreate
        self.aiInvite = aiInvite
        self.isContext = isContext
        self.aiContext = aiContext
        self.aiContextMark = aiContextMark
        self.aiContextGrant = aiContextGrant
        self.alias = alias
        self.chunk = chunk
        self.agentDraft = agentDraft
        self.coauthored = coauthored
        self.mentions = mentions
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

/// A watch-along DRAFT the owner's Mac coding agent produced, delivered to the owner's
/// phone so the PHONE voices it to the group as the owner's cryptographically-bound
/// agent (SPEC §13.5 endpoint model, DEVIATIONS AC24). It rides inside the ciphertext on
/// the owner↔agent pairwise link — only the owner can read it — and tells the phone where
/// to speak it. The phone redacts before voicing; the raw draft never reaches the group.
/// Optional + tolerated by older clients (SPEC §12).
public struct AgentDraft: Codable, Equatable, Sendable {
    /// Local codename of the producing AI (labeling only; never required).
    public let agentName: String?
    /// The conversation the phone should VOICE this draft into (group id / peer hex).
    public let voiceInto: String?
    /// Optional thread scope within that conversation.
    public let threadID: String?

    enum CodingKeys: String, CodingKey {
        case agentName = "agent_name"
        case voiceInto = "voice_into"
        case threadID = "thread_id"
    }

    public init(agentName: String? = nil, voiceInto: String? = nil, threadID: String? = nil) {
        self.agentName = agentName
        self.voiceInto = voiceInto
        self.threadID = threadID
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
