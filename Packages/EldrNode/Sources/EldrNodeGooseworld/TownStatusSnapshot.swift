// SPDX-License-Identifier: Apache-2.0
import Foundation

// WS-D1n — the node's DASHBOARD read model.
//
// This is the answer to "who is this node actually connected to?", for a human looking at
// Huginn — not for an agent. It is deliberately a separate type from `WorldTown` (the
// agent-facing MCP shape) so the two can never drift into each other: `WorldTown` is
// rendered through `UntrustedDataEnvelope` into prose for a model to read, while this is
// decoded by a native view that draws rows and lamps.
//
// **Three properties this type must keep, because the dashboard's whole claim rests on
// them:**
//
// 1. **Metadata only — never message content.** Not a wall post, not a task body, not a
//    fragment of either. `worldStatusSnapshotCarriesNoMessageContent` pins the encoded
//    field set against an allowlist so a future field cannot quietly widen this.
// 2. **No identity keys.** `townID` and `label` are the LOCAL pairing labels the owner
//    chose (`TownWallHost.TownPeer`), never the 64-char peer hex. Huginn already holds
//    `town-peers.json` and can join on `townID` itself, so shipping hex here would buy
//    nothing and cost the property that this snapshot is safe to render anywhere.
// 3. **Read-only.** There is no mutating counterpart and no write path on this socket
//    method; the kill switch stays out-of-band (the grants file / phone), and the
//    dashboard only ever *shows* it land.
//
// `generatedAt` exists because the honest-status rule requires every row to carry a
// "confirmed at" — a view must be able to say "last confirmed 4m ago" rather than imply
// the state is current.
public struct TownStatusSnapshot: Sendable, Codable, Equatable {
    /// One paired town, as a human sees it.
    public struct Town: Sendable, Codable, Equatable {
        /// Local pairing label (`[A-Za-z0-9_-]`), NOT an identity key.
        public let townID: String
        /// Human-chosen display label. Untrusted at render time, like every label.
        public let label: String
        /// A live owner-signed grant covers this peer on the wall plane.
        public let wallGranted: Bool
        /// …and on the delegate plane.
        public let delegateGranted: Bool
        /// Unix seconds of last inbound contact; 0 = never seen this run.
        public let lastSeen: Int64
        /// LATEST expiry among the live grants covering this peer — the moment its
        /// authorization fully lapses ("authorized until"). nil = no live grant. Drives
        /// the "expiring soon" affordance without the view re-deriving grant math.
        public let grantExpiry: Int64?

        public init(
            townID: String, label: String, wallGranted: Bool, delegateGranted: Bool,
            lastSeen: Int64, grantExpiry: Int64?
        ) {
            self.townID = townID
            self.label = label
            self.wallGranted = wallGranted
            self.delegateGranted = delegateGranted
            self.lastSeen = lastSeen
            self.grantExpiry = grantExpiry
        }
    }

    /// This node's own town label.
    public let nodeTownID: String
    /// The local author agent id posts are stamped with.
    public let localAgentID: String
    /// Paired towns. Empty is a legitimate state (nothing paired), distinct from the
    /// socket being unreachable — which the CLIENT reports, never this type.
    public let towns: [Town]
    /// Inbound artifacts dropped since node start (undecodable line, refused chunk set,
    /// refused ingest). A real monitoring signal `TownWallHost` already tracks.
    public let droppedInboundCount: Int
    /// When this snapshot was taken, node clock. The "confirmed at" every row needs.
    public let generatedAt: Int64

    public init(
        nodeTownID: String, localAgentID: String, towns: [Town], droppedInboundCount: Int,
        generatedAt: Int64
    ) {
        self.nodeTownID = nodeTownID
        self.localAgentID = localAgentID
        self.towns = towns
        self.droppedInboundCount = droppedInboundCount
        self.generatedAt = generatedAt
    }

    /// Every field name this type may ever encode, at any depth. The canary test asserts
    /// the encoded JSON's key set is a subset of this — so adding a field that could
    /// carry content fails the test until it is consciously added here.
    public static let allowedFieldNames: Set<String> = [
        "nodeTownID", "localAgentID", "towns", "droppedInboundCount", "generatedAt",
        "townID", "label", "wallGranted", "delegateGranted", "lastSeen", "grantExpiry",
    ]
}
