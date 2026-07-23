// SPDX-License-Identifier: Apache-2.0
import Foundation

// GooseworldBridge — the seam between the `eldr-gooseworld` MCP surface and the node
// that actually owns keys, transport and consent (GOOSEWORLD §6 WS-G3).
//
// Exactly the shape `SecureChatBridge` has, for exactly the same reason: the MCP server
// must be provable without a network, a clock, or a key. Huginn / eldr-node will
// implement this over the shipped A2A-over-ratchet transport; `DemoGooseworldBridge`
// implements it over an in-memory `TownWall`.
//
// **Where the trust boundary actually sits.** The binary a goosetown spawns
// (`eldr-gooseworld`) is a dumb pipe to a loopback socket; the node behind it holds the
// agent key and never hands it out (SPEC §13.5). Consequently:
//
// - **The caller cannot choose who it is.** `post` takes no author. The node stamps
//   `WallAuthor` from its own paired identity, so an agent cannot post as another town
//   or another delegate (GOOSEWORLD §4.3, sybil/impersonation).
// - **`reader` on `read` is a cursor name, not a credential.** gtwall keys positions by
//   delegate id and so do we; the id carries no authority, authenticates nothing, and
//   gates nothing. Naming this plainly in the tool description matters — otherwise a
//   model reasonably assumes passing someone else's reader id does something.
// - **`delegate` fails closed.** With no standing grant configured it refuses, and the
//   refusal is a tool ERROR. There is no bypass parameter and no default-allow path.

/// A paired town, as shown to an MCP client. Nothing here is an identity key: `id` is a
/// local pairing label of the same `[A-Za-z0-9_-]` shape as every other identifier, so
/// it is safe to render inside a header line.
public struct WorldTown: Sendable, Codable, Equatable {
    public let id: String
    /// Human-chosen label. Free-form, therefore treated as untrusted at render time.
    public let label: String
    /// Whether this town's posts reach our wall / ours reach theirs.
    public let wallPlaneGranted: Bool
    /// Whether `world_delegate` may target this town. False unless a human-signed
    /// standing grant says otherwise (WS-G4).
    public let delegatePlaneGranted: Bool
    /// Unix seconds of last contact, from the node's clock. Metadata only.
    public let lastSeen: Int64

    public init(
        id: String, label: String, wallPlaneGranted: Bool, delegatePlaneGranted: Bool,
        lastSeen: Int64
    ) {
        self.id = id
        self.label = label
        self.wallPlaneGranted = wallPlaneGranted
        self.delegatePlaneGranted = delegatePlaneGranted
        self.lastSeen = lastSeen
    }
}

/// The gooseworld side of the node.
///
/// Write outcomes reuse `MCPWriteResult` from the chat surface on purpose. That enum is
/// exactly the fail-closed shape this plane needs (`ok` / `failedClosed`), and reusing it
/// means the `isError` mapping here is *literally the same code path* as the one the
/// window gate already proves in `MCPServerTests` — a refusal cannot become a silent
/// success in one surface and not the other. Read `failedClosed` here as "refused by a
/// grant/consent gate", the direct analogue of "no ai_window is open".
public protocol GooseworldBridge: Sendable {
    /// Towns this node is paired with. Read-only; pairing is a human act.
    func towns() async -> [WorldTown]

    /// Post to the cross-town wall. The AUTHOR IS NOT A PARAMETER — the node stamps it.
    /// Refusals (oversized body, invalid target, wall plane not granted) come back as
    /// `.failedClosed` and surface as tool errors.
    func post(text: String, priorityForHuman: Bool, targets: [String]) async -> MCPWriteResult

    /// Read what `reader` has not seen, advancing that reader's cursor. Returns the
    /// structured result; FRAMING IS THE SERVER'S JOB — a bridge must never hand back
    /// pre-rendered remote text, or it could bypass `UntrustedDataEnvelope`.
    func read(reader: String, limit: Int?, fromStart: Bool) async -> Result<
        WallReadResult, TownWallError
    >

    /// Delegate a task to another town's flock. This is the code-execution-adjacent
    /// plane (GOOSEWORLD §1: a goosetown is a shell) and the task text itself is the
    /// exfiltration channel (§4.2). MUST fail closed with no standing grant.
    func delegate(town: String, task: String) async -> MCPWriteResult
}
