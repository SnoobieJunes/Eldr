import Foundation
import PQRCCore

/// Client-side group state (APP-SPEC §7, D1 — pairwise fan-out, no
/// cryptographic membership agreement). Honest limitation: a malicious member
/// can present inconsistent rosters, so every roster is tracked and displayed
/// as "asserted by X", never as ground truth.
public struct GroupRoster: Sendable, Equatable {
    public let groupID: String
    public private(set) var name: String
    public private(set) var members: [String]
    /// Identity hex of the member whose `group_create` revision we last applied.
    public private(set) var assertedBy: String
    public private(set) var revision: Int

    public init(create: GroupCreate, assertedBy: String) {
        self.groupID = create.groupID
        self.name = create.name
        self.members = create.members
        self.assertedBy = assertedBy
        self.revision = create.revision
    }

    /// Applies a roster revision. Returns true if the state changed; stale or
    /// foreign-group revisions are ignored. Equal-revision conflicts from a
    /// different asserter are surfaced (returns true) so the UI can show the
    /// disagreement — never silently reconciled.
    public mutating func apply(_ create: GroupCreate, assertedBy newAsserter: String) -> Bool {
        guard create.groupID == groupID else { return false }
        guard create.revision >= revision else { return false }
        if create.revision == revision && create.members == members && newAsserter == assertedBy {
            return false
        }
        name = create.name
        members = create.members
        assertedBy = newAsserter
        revision = create.revision
        return true
    }

    public func contains(_ identityHex: String) -> Bool {
        members.contains(identityHex)
    }
}
