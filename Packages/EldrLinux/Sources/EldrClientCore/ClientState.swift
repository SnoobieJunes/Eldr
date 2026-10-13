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

    public static let maxSeen = 5000
}
