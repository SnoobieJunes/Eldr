// SPDX-License-Identifier: Apache-2.0
import Foundation
import PQRCCore
import PQRCNostr

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

    public static let maxSeen = 5000
}

/// How a received message's agent sponsorship checked out, evaluated PER MESSAGE at
/// receipt (never cached as a contact-level flag).
public enum SponsorshipStatus: Codable, Sendable, Equatable {
    /// Human-labeled message: sponsorship does not apply.
    case human
    /// Agent-labeled message with no sponsorship attached.
    case unsponsored
    /// Agent-labeled, carrying a valid, unexpired, unrevoked sponsorship.
    case sponsored(sponsorIdentityHex: String, label: String?, activeUntil: Int64)
    /// Agent-labeled, carrying a sponsorship that failed (bad signature, wrong agent,
    /// expired, revoked, over 30 days…). Shown as a warning, never as sponsored.
    case invalid(reason: String)

    public var isSponsored: Bool { if case .sponsored = self { return true } else { return false } }
}

/// One rendered line of a conversation (kept encrypted at rest with the state).
public struct HistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var peerIdentityHex: String
    public var outgoing: Bool
    public var text: String
    public var sentAt: Int64
    public var agent: Bool
    public var sponsorship: SponsorshipStatus
}

/// A sponsorship THIS identity issued to an agent (sponsor side).
public struct IssuedSponsorship: Codable, Sendable, Equatable {
    public var sponsorship: AgentSponsorship
    public var revokedAt: Int64?
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

    public static let maxHistory = 5000
    public static let maxRevoked = 2000
    public static let maxHistoryBytes = 32 * 1024 * 1024
}
