// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCCore
import PQRCNostr
import PQRCAgent

/// Long-term secrets. Stored as its own encrypted account ("keys").
public struct ClientKeys: Codable, Sendable {
    public var nostrPrivateKey: Data
    public var identitySeed: Data
    public var identityDH: Data
}

/// One verified contact. The kind-10420 binding EVENT is stored so the contact is
/// re-verified offline at every launch (`VerifiedContact(storedBindingEvent:)`) —
/// trust never comes from a cached "verified" flag.
public struct ContactRecord: Codable, Sendable, Equatable {
    public var name: String?
    public var nostrPubkeyHex: String
    public var identityHex: String
    public var bindingEvent: NostrEvent
    public var session: RatchetSnapshot?
    public var addedAt: Date
    /// WS-N7 contact management (schema 3). Optional so older state decodes.
    public var verified: Bool?
    public var blocked: Bool?
    public var pinned: Bool?
}

/// A pending message request from a non-contact (D12). Only the sender is recorded;
/// the held envelopes stay on the relay and are replayed once the sender is accepted.
public struct RequestRecord: Codable, Sendable, Equatable {
    public var nostrPubkeyHex: String
    public var firstSeen: Date
    public var lastSeen: Date
    public var count: Int
}

/// Everything mutable, saved (encrypted) after every send / receive / accept.
public struct ClientState: Codable, Sendable {
    public var contacts: [ContactRecord] = []
    public var requests: [RequestRecord] = []
    public var prekeys: PrekeyState?
    /// Wrap IDs of envelopes already DELIVERED as messages (bounded). Held requests are
    /// deliberately not recorded, so the relay re-delivers them after a restart.
    public var seenWrapIDs: [String] = []
    public var relays: [String] = []
    /// Milestone 2 (sponsorship + history). Optional so older state still decodes.
    public var agent: AgentState?
    /// Contacts the user pre-approved for ONE reconnect (AC166). Optional for old state.
    public var approvedReconnects: [String]?
    /// True when the prekey bundle on the relay lists one-time prekeys we no longer
    /// hold (consumed, or new ones not yet published). Cleared by a successful announce.
    public var publishedBundleStale: Bool?
    /// Group rosters (APP-SPEC §7 D1, WS-N1). Optional so older state still decodes.
    public var groups: [GroupRecord]?
    /// Group invites waiting for my approval (AC220), and groups I declined.
    public var pendingGroupInvites: [GroupRecord]?
    public var declinedGroups: [String]?
    /// Threads (D7, WS-N2) and AI-participation state (SPEC §13). Optional for old state.
    public var threads: [ThreadRecord]?
    public var ai: AIState?
    public var settings: ClientSettings?
    /// State schema (AC177). nil = written before versioning (treated as 1). A build
    /// refuses to open state with a schema newer than `currentSchema`, so an old binary
    /// can never re-save (and silently strip) newer fields.
    public var schema: Int?
    /// Joined Buzz workspaces (WS-N7, iOS `BuzzWorkspaceRecord`). Schema 3.
    public var buzz: [BuzzWorkspaceRecord]?
    /// conversation id → newest `sentAt` I have read (iOS `lastReadAt`). Schema 4.
    public var lastRead: [String: Int64]?

    public static let maxSeen = 5000
    /// Bump whenever a field is added that an older build would drop on save.
    /// 2 = groups/threads/AI/settings/HistoryEntry.threadID (WS-N1…N5); 3 = WS-N7 contact fields;
    /// 4 = WS-N7a unread, retry, mentions, multi-AI roster, context modes.
    public static let currentSchema = 5  // 5 = group admins + invites (AC220)
}

// `SponsorshipStatus` and `IssuedSponsorship` live in PQRCCore (SponsorshipLedger.swift),
// shared with iOS.

/// One rendered line of a conversation (kept encrypted at rest with the state).
public struct HistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var peerIdentityHex: String
    public var outgoing: Bool
    public var text: String
    public var sentAt: Int64
    public var agent: Bool
    public var sponsorship: SponsorshipStatus
    /// Set for group messages (the group id); nil for 1:1. Optional for old state.
    public var groupID: String? = nil
    /// Set for thread messages. Optional for old state.
    public var threadID: String? = nil
    /// For agent-labeled messages authorized by a human's own window/invite (not an AI
    /// account sponsorship): until when that authorization ran, as checked on receipt.
    public var aiAuthorizedUntil: Int64? = nil
    /// Local-only: posted by MY AI (window reply / thread turn).
    public var mine: Bool? = nil
    /// Local, monotonic order of arrival. The AI-context cutoff uses it instead of
    /// the sender-chosen `sentAt`, which a peer could set to anything.
    public var seq: Int? = nil
    /// "Add to AI Context" (iOS feature 7 / N25): marked by its author. Schema 3.
    public var aiContext: Bool? = nil
    /// "Made with <person> & their AI": a human-directed AI message (AC44). Schema 3.
    public var coauthored: Bool? = nil
    /// Outgoing message that reached no recipient ("Not sent", tap to retry). Schema 4.
    public var failed: Bool? = nil
    /// Which of my AIs (or the peer's) wrote an agent row (`agent_name`). Schema 4.
    public var agentName: String? = nil
    /// Received message whose @-mentions name me. Schema 4.
    public var mentionsMe: Bool? = nil
}

public struct ThreadRecord: Codable, Sendable, Equatable {
    public var threadID: String
    /// A contact's identity hex, or `group:<groupID>`.
    public var conversationID: String
    public var title: String
    public var createdBy: String
    /// Per-thread loop-guard override (iOS setThreadLoopGuardLimit). Schema 3.
    public var loopGuardLimit: Int? = nil
}

/// A signed window/invite we hold (ours or a peer's), replayed into the AgentEngine at
/// launch so a separate CLI invocation still sees it. Signatures are re-verified then.
public struct StoredWindow: Codable, Sendable, Equatable {
    public var conversationID: String
    public var announcement: AIWindowAnnouncement
}
public struct StoredInvite: Codable, Sendable, Equatable {
    public var invite: AIInvite
}

/// OpenAI-compatible endpoint (LM Studio, Ollama, vLLM, llama.cpp, OpenAI, OpenRouter…).
/// The API key is NOT here: it lives in its own keystore account ("ai-key").
public struct AIProviderConfig: Codable, Sendable, Equatable {
    public var baseURL: String
    public var model: String
    public var instructions: String?
    public var timeoutSeconds: Double?
    /// Backend kind, iOS `BackendRegistry` tags: nil/"custom" (OpenAI-compatible at
    /// `baseURL`), "claude", "openai", "gemini", "openrouter", "groq". Schema 3.
    public var kind: String?
    public init(baseURL: String, model: String, instructions: String? = nil, timeoutSeconds: Double? = nil, kind: String? = nil) {
        self.baseURL = baseURL; self.model = model; self.instructions = instructions; self.timeoutSeconds = timeoutSeconds
        self.kind = kind
    }
    public static let kinds = ["custom", "claude", "openai", "gemini", "openrouter", "groq"]
    public var effectiveKind: String { kind ?? "custom" }
}

public struct AIState: Codable, Sendable {
    public var windows: [StoredWindow]?
    public var invites: [StoredInvite]?
    /// The single conversation my (global) window is for (iOS `myWindowConversationID`).
    public var myWindowConversation: String?
    public var provider: AIProviderConfig?
    public var grants: [StandingGrant]?
    /// conversation/thread id → the history `seq` at which my AI was turned on there.
    /// The AI only sees messages after it, never earlier history.
    public var activeSince: [String: Int64]?
    /// Signed AI context-sharing grants (mine and received), replayed at start. Schema 3.
    public var contextGrants: [AIContextGrant]?
    /// Additional tethered AIs after the primary (`provider`). Schema 4.
    public var extraAIs: [TetheredAIConfig]?
    /// scope (thread id or conversation id) → ordered AI ids; [] = silence. Schema 4.
    public var rosters: [String: [String]]?
    /// Conversations where my AIs reply in order (primary → reviewer/critic → synthesizer).
    public var orderedCritique: [String]?
    /// conversation id → "off" | "marked" | "full" (iOS conversationContextMode).
    public var contextModes: [String: String]?
    /// Display name of the primary AI (default "<me>'s AI").
    public var primaryName: String?
}

/// One extra tethered AI (iOS `TetheredAI`, minus Apple-only backends). Its key lives in
/// keystore account `ai-key.<id>`.
public struct TetheredAIConfig: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var config: AIProviderConfig
    /// false = draft-only: never takes an autonomous turn.
    public var autonomous: Bool
    public init(id: String, name: String, config: AIProviderConfig, autonomous: Bool = true) {
        self.id = id; self.name = name; self.config = config; self.autonomous = autonomous
    }
}

/// User settings (WS-N5). Every field optional; nil = default.
public struct ClientSettings: Codable, Sendable, Equatable {
    public var displayName: String?
    /// Consecutive agent messages per thread before agents pause. 0 = off.
    public var loopGuardLimit: Int?
    public init(displayName: String? = nil, loopGuardLimit: Int? = nil) {
        self.displayName = displayName; self.loopGuardLimit = loopGuardLimit
    }
}

/// Persisted form of `GroupRoster` (which isn't Codable). Every roster is shown as
/// "asserted by X", never as ground truth (APP-SPEC §7: no membership agreement).
public struct GroupRecord: Codable, Sendable, Equatable {
    public var groupID: String
    public var name: String
    public var members: [String]
    public var assertedBy: String
    public var revision: Int
    /// Who may change the roster (AC220). nil = state from before admins (legacy: the
    /// last asserter is treated as the admin).
    public var admins: [String]?
    /// Who invited me (pending invites only).
    public var invitedBy: String?

    public init(_ r: GroupRoster) {
        groupID = r.groupID; name = r.name; members = r.members
        assertedBy = r.assertedBy; revision = r.revision; admins = r.admins
    }
    var roster: GroupRoster {
        GroupRoster(
            create: GroupCreate(groupID: groupID, name: name, members: members, revision: revision,
                                admins: admins ?? [assertedBy]),
            assertedBy: assertedBy)
    }
}

/// Sponsorship / history state. Every field is optional on the wire so a state file
/// written by Milestone 1 still decodes (fail-closed decode would otherwise refuse it).
public struct AgentState: Codable, Sendable {
    /// This persona is an AI account: sends are labeled `agent` and REQUIRE a live
    /// sponsorship from `ownerIdentityHex`.
    public var agentMode: Bool?
    /// The only identity whose sponsorship this agent accepts.
    public var ownerIdentityHex: String?
    public var mySponsorship: AgentSponsorship?
    public var issued: [IssuedSponsorship]?
    /// "<sponsorHex>:<sponsorshipID>" of every revocation seen.
    public var revoked: [String]?
    public var history: [HistoryEntry]?
    public var nextSeq: Int?

    public static let maxHistory = 5000
    public static let maxRevoked = 2000
    public static let maxHistoryBytes = 32 * 1024 * 1024
}

/// A joined Buzz workspace. Its per-workspace secret key lives in the keystore under
/// `buzzws.<id>` (never in this record), like iOS's Keychain account.
public struct BuzzWorkspaceRecord: Codable, Sendable, Equatable {
    public var id: String
    public var relayURL: String
    public var name: String
    public var communityID: String
    public var role: String
    public var pubkeyHex: String
    public var joinedAt: Int64
    public var host: String { URL(string: relayURL)?.host ?? relayURL }
}
