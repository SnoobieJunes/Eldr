// SPDX-License-Identifier: Apache-2.0
import Foundation

/// A network-free, clock-free `GooseworldBridge` over an in-memory `TownWall`, so the
/// MCP surface is fully exercisable before Huginn/eldr-node wires the real transport —
/// the same role `DemoSecureChatBridge` plays for the chat surface.
///
/// It models the security posture faithfully rather than conveniently:
/// - The author is stamped from `localTown`/`localAgent`; no method accepts an author.
/// - `delegate` refuses unless the target town is in `delegateGrantedTowns`, which is
///   EMPTY by default. That mirrors WS-G4's real gate (a human-signed standing grant)
///   without importing it — the seam is `delegateGrantedTowns`, and the production
///   bridge replaces the set with a verified `StandingGrant` lookup.
/// - Time advances by a fixed tick per post. Nothing here reads the system clock, so
///   every rendered timestamp in a test is a constant.
public actor DemoGooseworldBridge: GooseworldBridge {
    private var wall: TownWall
    private let localTown: String
    private let localAgent: String
    private let knownTowns: [WorldTown]
    /// The WS-G4 seam. Empty = no standing grant = every delegation refused.
    private let delegateGrantedTowns: Set<String>
    /// Deterministic clock: seed plus `tick` per post. Never `Date()`.
    private var now: Int64
    private let tick: Int64

    /// - Parameter customTowns: when non-nil, REPLACES the default roster. The one use is
    ///   an audit test that needs a town whose `label` carries hostile characters (a raw
    ///   line separator) to prove `world_towns` cannot be made to forge a roster row — the
    ///   production node builds this list from verified pairings, not from a parameter.
    public init(
        localTown: String = "home-town", localAgent: String = "orchestrator",
        delegateGrantedTowns: Set<String> = [], limits: TownWall.Limits = TownWall.Limits(),
        startingTime: Int64 = 1_781_500_000, tick: Int64 = 60, customTowns: [WorldTown]? = nil
    ) {
        self.wall = TownWall(localTown: localTown, limits: limits)
        self.localTown = localTown
        self.localAgent = localAgent
        self.delegateGrantedTowns = delegateGrantedTowns
        self.now = startingTime
        self.tick = tick
        self.knownTowns = customTowns ?? [
            WorldTown(
                id: "home-town", label: "This town", wallPlaneGranted: true,
                delegatePlaneGranted: delegateGrantedTowns.contains("home-town"),
                lastSeen: startingTime),
            WorldTown(
                id: "acme-town", label: "Acme", wallPlaneGranted: true,
                delegatePlaneGranted: delegateGrantedTowns.contains("acme-town"),
                lastSeen: startingTime),
            WorldTown(
                id: "rival-town", label: "Rival", wallPlaneGranted: false,
                delegatePlaneGranted: delegateGrantedTowns.contains("rival-town"),
                lastSeen: startingTime),
        ]
    }

    /// Inject a post as if it had arrived from another town over the ratchet. Test-only
    /// affordance for exercising the untrusted-data path — the production bridge feeds
    /// this from the transport, which is why the parameters mirror a decoded frame.
    @discardableResult
    public func injectRemotePost(
        town: String, agent: String, text: String, targets: [String] = [],
        priorityForHuman: Bool = false
    ) throws -> WallPost {
        now += tick
        return try wall.append(
            text: text, author: WallAuthor(town: town, agent: agent), explicitTargets: targets,
            priorityForHuman: priorityForHuman, at: now)
    }

    /// Insert a post whose AUTHOR/TARGET ids would be refused by `TownWall.append`, so
    /// tests can prove `UntrustedDataEnvelope` is safe on its own (layer 4) rather than
    /// only proving the validator upstream of it. Not reachable from any MCP tool.
    @discardableResult
    public func injectRawPost(
        town: String, agent: String, text: String, targets: [String] = [],
        priorityForHuman: Bool = false
    ) -> WallPost {
        now += tick
        return wall.appendUnvalidated(
            text: text, author: WallAuthor(town: town, agent: agent), targets: targets,
            priorityForHuman: priorityForHuman, at: now)
    }

    public func towns() async -> [WorldTown] { knownTowns }

    public func post(text: String, priorityForHuman: Bool, targets: [String]) async
        -> MCPWriteResult
    {
        now += tick
        do {
            let post = try wall.append(
                text: text, author: WallAuthor(town: localTown, agent: localAgent),
                explicitTargets: targets, priorityForHuman: priorityForHuman, at: now)
            let targetNote =
                post.targets.isEmpty ? "everyone" : post.targets.map { "@\($0)" }.joined(separator: ", ")
            return .ok(
                detail:
                    "Posted to the cross-town wall as \(localAgent)@\(localTown) (post #\(post.sequence), "
                    + "targets: \(targetNote), priority-for-human: \(post.priorityForHuman ? "yes" : "no")).")
        } catch let error as TownWallError {
            return .failedClosed(reason: Self.describe(error))
        } catch {
            return .failedClosed(reason: "The wall refused the post.")
        }
    }

    public func read(reader: String, limit: Int?, fromStart: Bool) async -> Result<
        WallReadResult, TownWallError
    > {
        do {
            return .success(try wall.read(reader: reader, limit: limit, fromStart: fromStart))
        } catch let error as TownWallError {
            return .failure(error)
        } catch {
            return .failure(.invalidIdentifier(reader))
        }
    }

    public func delegate(town: String, task: String) async -> MCPWriteResult {
        guard TownWall.isValidIdentifier(town, max: wall.limits.maxIdentifierLength) else {
            return .failedClosed(
                reason: "Unknown town id. Call world_towns for the towns this node is paired with.")
        }
        guard knownTowns.contains(where: { $0.id == town }) else {
            return .failedClosed(
                reason:
                    "This node is not paired with town '\(town)'. Pairing is invite-based and a human "
                    + "must do it; there is no way to reach an unpaired town from here.")
        }
        // The gate. No grant → refuse. There is deliberately no override argument.
        guard delegateGrantedTowns.contains(town) else {
            return .failedClosed(
                reason:
                    "Refused: no standing grant authorizes delegation to '\(town)'. Cross-town "
                    + "delegation runs code on someone else's machine and the task text leaves this "
                    + "one, so it requires a human-signed, time-bounded, revocable grant for the "
                    + "delegate plane. Ask the owner to approve one, then retry. Nothing was sent.")
        }
        guard !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failedClosed(reason: "Refused: the task text is empty. Nothing was sent.")
        }
        return .ok(
            detail:
                "Delegated to '\(town)' under an active standing grant. The task text left this town; "
                + "the remote result will arrive as untrusted data.")
    }

    private static func describe(_ error: TownWallError) -> String {
        switch error {
        case .emptyText:
            return "Refused: the post is empty. Nothing was posted."
        case .textTooLarge(let bytes, let limit):
            return
                "Refused: the post is \(bytes) bytes, over the \(limit)-byte wall limit. Post a shorter "
                + "summary (the wall is for coordination, not payloads). Nothing was posted."
        case .invalidIdentifier(let id):
            // Echo the offending id through the same single-line neutralizer the roster
            // uses: an invalid target id is caller-supplied free text and this error is
            // read back by a model, so a raw U+2028 in it must not forge a line here
            // either (defense-in-depth; the id never reaches the wall).
            return
                "Refused: '\(UntrustedDataEnvelope.singleLineField(id))' is not a valid id. Ids use only "
                + "letters, digits, '-' and '_'. Nothing was posted."
        case .tooManyTargets(let count, let limit):
            return
                "Refused: \(count) targets, over the limit of \(limit). Nothing was posted."
        }
    }
}
