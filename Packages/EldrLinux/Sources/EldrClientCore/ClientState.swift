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
    /// True when the prekey bundle on the relay lists one-time prekeys we no longer
    /// hold (consumed, or new ones not yet published). Cleared by a successful announce.
    public var publishedBundleStale: Bool?
    /// Group rosters (APP-SPEC §7 D1, WS-N1). Optional so older state still decodes.
    public var groups: [GroupRecord]?

    public static let maxSeen = 5000
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
}

/// Persisted form of `GroupRoster` (which isn't Codable). Every roster is shown as
/// "asserted by X", never as ground truth (APP-SPEC §7: no membership agreement).
public struct GroupRecord: Codable, Sendable, Equatable {
    public var groupID: String
    public var name: String
    public var members: [String]
    public var assertedBy: String
    public var revision: Int

    public init(_ r: GroupRoster) {
        groupID = r.groupID; name = r.name; members = r.members
        assertedBy = r.assertedBy; revision = r.revision
    }
    var roster: GroupRoster {
        GroupRoster(
            create: GroupCreate(groupID: groupID, name: name, members: members, revision: revision),
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

    public static let maxHistory = 5000
    public static let maxRevoked = 2000
    public static let maxHistoryBytes = 32 * 1024 * 1024
}
