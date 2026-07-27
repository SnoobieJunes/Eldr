// SPDX-License-Identifier: Apache-2.0
import EldrNodeCore
import Foundation
import PQRCCore
import PQRCMCP
import PQRCNostr

// WS-G5 — the PRODUCTION wall host: the node-side owner of the cross-town wall.
//
// One actor owns the `TownWall` value and everything around it:
//
//   • the INBOUND wall service (`TownA2AService`) — decodes admitted `world/wall.post`
//     lines, buffers their chunk sets (bounded), reassembles complete posts via
//     `WallChunking`, and ingests them with the author's TOWN mapped from the VERIFIED
//     sender identity — never from the wire (sybil refusal, GOOSEWORLD §4.3);
//   • the OUTBOUND fan-out — a local post is appended to the local wall FIRST (the
//     wall's own bounds are the refusal point), then chunked to the transport budget
//     and sent pairwise to every peer the owner has granted `.wall` (WS-G5's "pairwise
//     fan-out is fine to ~8 towns"; `EldrNodeCore.maxTownPeers` is the same bound);
//   • the `GooseworldBridge` conformance the `eldr-gooseworld` MCP server drives —
//     towns/post/read/delegate over the real transport instead of the demo;
//   • cursor persistence (`WallCursorStore`) so a reader's position survives restarts.
//
// GRANTS gate BOTH directions with the same predicate transport admission uses
// (`StandingGrantAdmission`): inbound lines only reach `ingest` through
// `PlaneRoutedTownService`'s `.wall` re-check, and outbound fan-out sends only to peers
// covered by a live owner-signed `.wall` grant — an autonomous cross-town send with no
// live grant fails closed (invariant 9). Per-day byte/message BUDGETS remain the
// engine-side gate (`AgentEngine.authorizeTownSend`, phone/app layer), same split the
// delegate plane already documents in `StandingGrantTownAuthorizer`.
public actor TownWallHost {
    /// One paired peer town: the VERIFIED identity ↔ the local wall label for it.
    public struct TownPeer: Sendable, Codable, Equatable {
        /// 64-char lowercase-hex PQRC identity (the value grants name and the
        /// messenger verifies).
        public let identityHex: String
        /// Local pairing label used as the author TOWN for this peer's posts —
        /// `[A-Za-z0-9_-]`, validated at host init (an invalid label falls back to a
        /// hex-prefix id rather than admitting envelope-structural characters).
        public let townID: String
        /// Human-chosen display label. Untrusted at render time, like every label.
        public let label: String

        public init(identityHex: String, townID: String, label: String) {
            self.identityHex = Self.canonical(identityHex)
            self.townID = townID
            self.label = label
        }

        /// The identity normalization every construction path must share.
        static func canonical(_ hex: String) -> String {
            hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        /// Decoding MUST normalize too, and the synthesized `init(from:)` does not: it
        /// assigns the stored properties directly and never calls the memberwise init
        /// above. So a `town-peers.json` written by hand — which is exactly what
        /// `docs/guide/DEMO-GOOSEWORLD.md` step 3 instructs — with an UPPERCASE identity hex
        /// decoded un-normalized, and then failed silently in two places at once:
        /// `grantCovers` compares against `StandingGrant.peer`, which `validateStructure`
        /// pins to lowercase, with a deliberately case-sensitive `==`, so the peer was
        /// dropped from every fan-out; and the roster lookup that stamps the author TOWN
        /// missed, so the peer's posts rendered under a hex-prefix id instead of its town
        /// label. No error was logged for either — the wall just quietly did not reach
        /// that town. Normalizing here fixes every decode path at once.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.identityHex = Self.canonical(
                try container.decode(String.self, forKey: .identityHex))
            self.townID = try container.decode(String.self, forKey: .townID)
            self.label = try container.decode(String.self, forKey: .label)
        }
    }

    public struct Config: Sendable {
        /// This town's wall label (the `localTown` posts render as LOCAL).
        public var localTownID: String
        /// The agent id stamped on locally-authored posts (the flock/orchestrator id).
        public var localAgentID: String
        /// Canonical owner hex — the granter pin for every grant check.
        public var ownerHex: String
        public var peers: [TownPeer]
        public var wallLimits: TownWall.Limits
        /// Per-chunk text budget for OUTBOUND posts — derive from the relay's NIP-11
        /// budget (`PQRCMessenger.chunkTextBudget()`); the transport re-frames further
        /// as needed, so this only shapes chunk granularity, never correctness.
        public var chunkTextBudget: Int
        /// Bound on simultaneously-pending inbound chunk sets (a hostile peer streaming
        /// endless partial sets must displace ITS OWN oldest partials, never grow us).
        public var maxPendingChunkSets: Int

        public init(
            localTownID: String, localAgentID: String, ownerHex: String, peers: [TownPeer],
            wallLimits: TownWall.Limits = .init(), chunkTextBudget: Int = 16 * 1024,
            maxPendingChunkSets: Int = 64
        ) {
            self.localTownID = localTownID
            self.localAgentID = localAgentID
            self.ownerHex = ownerHex
            self.peers = peers
            self.wallLimits = wallLimits
            self.chunkTextBudget = max(4, chunkTextBudget)
            self.maxPendingChunkSets = max(1, maxPendingChunkSets)
        }
    }

    private let config: Config
    /// Canonical lowercase owner hex (normalized once, same contract as the authorizer).
    private let ownerHex: String
    private var wall: TownWall
    private let cursorStore: WallCursorStore?
    private let now: @Sendable () -> Int64
    private let liveGrants: @Sendable () async -> [StandingGrant]
    /// Publishes one already-A2A1-framed body to a peer (production:
    /// `NodeMessenger.sendFramed`). Injected so tests run over the relay simulator.
    private let sendFramed: @Sendable (String, String) async throws -> Void

    /// Per-peer OUTBOUND transports (framing + relay-budget chunking + ordered ids).
    private var outbound: [String: RelayA2ATransport] = [:]
    /// Pending inbound chunk sets, keyed `senderHex|chunkID`, insertion-ordered for
    /// bounded oldest-first eviction.
    private var pendingChunks: [String: [WallChunk]] = [:]
    private var pendingOrder: [String] = []
    /// Dropped inbound artifacts (undecodable line, refused set, refused ingest) —
    /// monitoring surface, mirrors `RelayA2ATransport.droppedFrameCount`.
    public private(set) var droppedInboundCount = 0
    private var lastSeen: [String: Int64] = [:]
    private var nextDelegationID = 1
    /// The persisted-cursor mirror: what the store holds, updated after every read.
    /// Kept host-side because `TownWall`'s cursors are deliberately private — readers
    /// loaded from disk stay in the mirror (and thus survive the next save) even if
    /// they never read again this run.
    private var cursorMirror: [String: UInt64] = [:]

    public init(
        config: Config,
        cursorStore: WallCursorStore?,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) },
        liveGrants: @escaping @Sendable () async -> [StandingGrant],
        sendFramed: @escaping @Sendable (String, String) async throws -> Void
    ) {
        self.config = config
        self.ownerHex = config.ownerHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.wall = TownWall(localTown: config.localTownID, limits: config.wallLimits)
        self.cursorStore = cursorStore
        self.now = now
        self.liveGrants = liveGrants
        self.sendFramed = sendFramed
        // Restore persisted cursors. `restoreCursor` refuses only an invalid reader id;
        // a cursor above the (fresh, empty) wall's highest sequence is the DOCUMENTED
        // restart case and loads fine — the reader simply sees nothing until new posts
        // arrive, with any pre-restart gap already surfaced as `missedPosts` semantics.
        if let stored = cursorStore?.load() {
            cursorMirror = stored
            for (reader, position) in stored {
                try? wall.restoreCursor(reader: reader, to: position)
            }
        }
    }

    // MARK: - Grants (one predicate, both directions)

    private func grantCovers(_ peerHex: String, _ plane: StandingGrant.Plane) async -> Bool {
        StandingGrantAdmission.admits(
            peer: peerHex, plane: plane, requiredGranterHex: ownerHex, cutoff: now(),
            grants: await liveGrants())
    }

    // MARK: - Inbound (the wall half of PlaneRoutedTownService)

    /// Handle one ADMITTED, PLANE-VERIFIED wall line from `peerIdentityHex`.
    /// `PlaneRoutedTownService` has already proven a live `.wall` grant for the sender;
    /// this ingests bytes, it authorizes nothing.
    public func ingest(line: String, from peerIdentityHex: String) {
        guard let params = WallWire.decodePost(line) else {
            droppedInboundCount += 1
            return
        }
        let sender = peerIdentityHex.lowercased()
        lastSeen[sender] = now()

        // Buffer the piece under sender|chunkID — a chunk id is only meaningful within
        // ONE sender, so two towns using the same id can never splice (and `reassemble`
        // would refuse a mixed set anyway; this is the cheaper first fence).
        let key = "\(sender)|\(params.chunk.id)"
        var set = pendingChunks[key] ?? []
        set.append(WallChunk(ref: params.chunk, body: params.body))
        if pendingChunks[key] == nil { pendingOrder.append(key) }
        pendingChunks[key] = set

        // Bounded pendings: evict the OLDEST set (counted) when over budget — a peer
        // streaming endless partials displaces its own oldest, never grows the node.
        while pendingOrder.count > config.maxPendingChunkSets, let oldest = pendingOrder.first {
            pendingOrder.removeFirst()
            pendingChunks.removeValue(forKey: oldest)
            droppedInboundCount += 1
        }

        guard set.count >= params.chunk.total else { return }  // still incomplete
        pendingChunks.removeValue(forKey: key)
        pendingOrder.removeAll { $0 == key }
        guard let text = WallChunking.reassemble(set) else {
            droppedInboundCount += 1  // mixed/duplicated/inconsistent set — refused whole
            return
        }

        // Author: TOWN from the VERIFIED sender (roster label, else a hex-prefix id —
        // hex is within the wall's identifier charset); AGENT is the peer node's own
        // namespace claim, sanitized to the identifier rules rather than trusted.
        let town = config.peers.first(where: { $0.identityHex == sender })
            .map(\.townID)
            .flatMap {
                TownWall.isValidIdentifier($0, max: config.wallLimits.maxIdentifierLength)
                    ? $0 : nil
            }
            ?? String(sender.prefix(12))
        let agent = TownWall.isValidIdentifier(
            params.agent, max: config.wallLimits.maxIdentifierLength) ? params.agent : "agent"

        do {
            try wall.append(
                text: text, author: WallAuthor(town: town, agent: agent),
                explicitTargets: params.targets, priorityForHuman: params.priorityForHuman,
                at: now())
        } catch {
            // Oversize/invalid remote post: refused whole, counted, never truncated.
            droppedInboundCount += 1
        }
    }

    // MARK: - Outbound fan-out

    /// Send one framed line to `peerHex` through that peer's outbound transport
    /// (created lazily; the transport owns relay-budget framing + ordered line ids).
    private func sendLine(_ line: String, to peerHex: String) {
        let transport: RelayA2ATransport
        if let existing = outbound[peerHex] {
            transport = existing
        } else {
            let send = self.sendFramed
            transport = RelayA2ATransport(maxFrameBytes: config.chunkTextBudget) { framed in
                try? await send(framed, peerHex)
            }
            outbound[peerHex] = transport
        }
        transport.send(line)
    }

    /// Peers currently covered by a live owner-signed grant for `plane`.
    private func grantedPeers(_ plane: StandingGrant.Plane) async -> [TownPeer] {
        var granted: [TownPeer] = []
        for peer in config.peers {
            if await grantCovers(peer.identityHex, plane) { granted.append(peer) }
        }
        return granted
    }

    // MARK: - Bridge operations (the GooseworldBridge surface)

    public func towns() async -> [WorldTown] {
        var out: [WorldTown] = []
        for peer in config.peers {
            out.append(
                WorldTown(
                    id: peer.townID, label: peer.label,
                    wallPlaneGranted: await grantCovers(peer.identityHex, .wall),
                    delegatePlaneGranted: await grantCovers(peer.identityHex, .delegate),
                    lastSeen: lastSeen[peer.identityHex] ?? 0))
        }
        return out
    }

    public func post(text: String, priorityForHuman: Bool, targets: [String]) async -> MCPWriteResult {
        // Local wall FIRST: its bounds (size, identifiers, target count) are the
        // refusal point, and the local stamp is what the reader sees.
        let post: WallPost
        do {
            post = try wall.append(
                text: text,
                author: WallAuthor(town: wall.localTown, agent: localAgentID()),
                explicitTargets: targets, priorityForHuman: priorityForHuman, at: now())
        } catch {
            return .failedClosed(reason: Self.describe(error))
        }

        // Fan out to every `.wall`-granted peer — pairwise, over each peer's own
        // ratcheted channel. No grant, no send (invariant 9); zero granted peers is an
        // honest local-only post, reported as such.
        let granted = await grantedPeers(.wall)
        let chunks = WallChunking.split(
            text, maxBytes: config.chunkTextBudget, id: "\(wall.localTown)-\(post.sequence)")
        for peer in granted {
            for chunk in chunks {
                guard
                    let line = WallWire.encodePost(
                        .init(
                            chunk: chunk.ref, body: chunk.body, agent: post.author.agent,
                            priorityForHuman: priorityForHuman, targets: targets))
                else { continue }
                sendLine(line, to: peer.identityHex)
            }
        }
        let detail =
            "posted to the wall as \(post.author.agent)@\(post.author.town)"
            + (granted.isEmpty
                ? " (no towns hold a live wall grant — local wall only)"
                : " → \(granted.count) town\(granted.count == 1 ? "" : "s")"
                    + (chunks.count > 1 ? " in \(chunks.count) chunks" : ""))
        return .ok(detail: detail)
    }

    public func read(reader: String, limit: Int?, fromStart: Bool) -> Result<WallReadResult, TownWallError> {
        do {
            let result = try wall.read(reader: reader, limit: limit, fromStart: fromStart)
            cursorMirror[reader] = result.cursorAfter
            persistCursors()
            return .success(result)
        } catch let error as TownWallError {
            return .failure(error)
        } catch {
            return .failure(.invalidIdentifier(reader))
        }
    }

    public func delegate(town: String, task: String) async -> MCPWriteResult {
        guard let peer = config.peers.first(where: { $0.townID == town }) else {
            return .failedClosed(reason: "unknown town \"\(town)\" — see world_towns")
        }
        guard await grantCovers(peer.identityHex, .delegate) else {
            return .failedClosed(
                reason:
                    "no live standing grant covers the delegate plane for \(town); ask the owner to grant it"
            )
        }
        // A2A v1.0 `message/send`, the same wire shape the WS-G1 delegate plane
        // services. Fire-and-forget v1: the peer's reply routes to this node's DELEGATE
        // service (not the wall); correlating it back into a synchronous tool result is
        // future work, stated honestly in the result text.
        let id = nextDelegationID
        nextDelegationID += 1
        let taskJSON = Self.jsonString(task)
        let line =
            #"{"jsonrpc":"2.0","id":\#(id),"method":"message/send","params":{"message":{"role":"user","parts":[{"kind":"text","text":\#(taskJSON)}]}}}"#
        sendLine(line, to: peer.identityHex)
        return .ok(
            detail:
                "task sent to \(town)'s flock over the delegate plane; its reply arrives on this node's delegation channel"
        )
    }

    // MARK: - Helpers

    private func localAgentID() -> String {
        TownWall.isValidIdentifier(
            config.localAgentID, max: config.wallLimits.maxIdentifierLength)
            ? config.localAgentID : "orchestrator"
    }

    private func persistCursors() {
        cursorStore?.save(cursorMirror.filter { $0.value > 0 })
    }

    /// Test hook: pending inbound chunk sets currently buffered.
    public var pendingChunkSetCount: Int { pendingChunks.count }

    static func describe(_ error: Error) -> String {
        switch error {
        case TownWallError.emptyText: return "post text is empty"
        case TownWallError.textTooLarge(let bytes, let limit):
            return "post is \(bytes) bytes; this wall's limit is \(limit)"
        case TownWallError.invalidIdentifier(let id): return "invalid identifier: \(id)"
        case TownWallError.tooManyTargets(let count, let limit):
            return "\(count) targets exceeds the limit of \(limit)"
        default: return "wall refused the post"
        }
    }

    /// JSON-encode a string literal (for the delegation line).
    static func jsonString(_ s: String) -> String {
        let data = (try? JSONEncoder().encode([s])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}

// MARK: - The two seams the host plugs into

/// The wall half handed to `PlaneRoutedTownService`: every line arriving here has
/// already passed transport admission AND the `.wall` plane re-check.
public struct TownWallService: TownA2AService {
    private let host: TownWallHost
    public init(host: TownWallHost) { self.host = host }
    public func handle(
        line: String, from peerIdentityHex: String,
        reply: @escaping @Sendable (String) -> Void
    ) async {
        // Wall posts are notifications; nothing is ever written back on this plane.
        await host.ingest(line: line, from: peerIdentityHex)
    }
}

/// The `GooseworldBridge` the MCP server drives — a thin forwarder onto the host actor.
public struct TownWallHostBridge: GooseworldBridge {
    private let host: TownWallHost
    public init(host: TownWallHost) { self.host = host }
    public func towns() async -> [WorldTown] { await host.towns() }
    public func post(text: String, priorityForHuman: Bool, targets: [String]) async -> MCPWriteResult {
        await host.post(text: text, priorityForHuman: priorityForHuman, targets: targets)
    }
    public func read(reader: String, limit: Int?, fromStart: Bool) async -> Result<WallReadResult, TownWallError> {
        await host.read(reader: reader, limit: limit, fromStart: fromStart)
    }
    public func delegate(town: String, task: String) async -> MCPWriteResult {
        await host.delegate(town: town, task: task)
    }
}
