// SPDX-License-Identifier: Apache-2.0
import Foundation
import OSLog
import PQRCCore
import PQRCNostr

/// Engine-scoped diagnostics. Provider-call failures on the autonomous paths are
/// logged here at `.error` (with the provider's error description) so a thread/window
/// reply that fails — provider error, timeout, or a reply that stripped to empty — is
/// never silently swallowed (the "LMStudio responded but we didn't see it" class of
/// bug). Matches PQRCNostr's `Logger(subsystem: "chat.pqrc", …)` convention.
private let agentLog = Logger(subsystem: "chat.pqrc", category: "agent")

public enum AgentEngineError: Error, Equatable, Sendable {
    /// Autonomous send attempted outside an active window/invite — fail closed
    /// (SPEC §13.3, CLAUDE.md invariant 9).
    case autonomousSendNotAuthorized
    case windowSignatureInvalid
    case windowNotFromHumanIdentity
    case windowDurationUnbounded
    case loopGuardPaused

    // MARK: Standing town grants (GOOSEWORLD §5, DEVIATIONS AC126)
    //
    // Deliberately a SEPARATE set of cases rather than a reuse of
    // `autonomousSendNotAuthorized`. The town gate and the §13 gate are different
    // gates with different scopes; if one error meant both, a caller could catch
    // the wrong one and conclude it had permission it never had. Distinct cases
    // make that mistake a compile-time-visible one.

    /// Town send attempted with no live, unrevoked grant covering that exact
    /// (peer, plane) — fail closed.
    case townSendNotAuthorized
    /// A live grant covers it, but this send would cross the day's message or
    /// byte budget. Distinct from `townSendNotAuthorized` so a client can say
    /// "budget spent, back tomorrow" instead of "you were never allowed".
    case townBudgetExhausted
    /// A live `delegate` grant covers it, but `max_concurrent_tasks` are already
    /// in flight.
    case townTaskLimitReached
    /// The requested duration is not one of `allowedStandingGrantDurations`, or an
    /// incoming grant claims more life than `maxStandingGrantDuration`. Bounded is
    /// mandatory; there is no unbounded standing grant.
    case standingGrantDurationUnbounded
    case standingGrantSignatureInvalid
    case standingGrantNotFromHumanIdentity
    /// Structurally invalid (bad peer hex, empty/duplicate planes, out-of-range
    /// budget, oversized tool ceiling…). Carries the wire layer's reason.
    case standingGrantMalformed(StandingGrantError)
    /// A verified peer already holds `maxStandingGrantsPerGranter` distinct live
    /// grants and this is a NEW grant id — refused so a paired-but-hostile peer
    /// cannot grow the grant store without bound (a re-issue of an existing id is
    /// always accepted and never reaches this). Fail-closed: the new grant simply
    /// is not honored, which can only ever withhold authorization, never widen it.
    case standingGrantLimitReached
}

/// Where engine-approved agent messages go: the conversation send path
/// (PQRCMessenger in production, a spy in tests). The engine posts thread
/// turns ONLY through this sink with the thread id set — there is no other
/// output path in the API (the recording guarantee, APP-SPEC §8).
public protocol AgentMessageSink: Sendable {
    /// `agentName` is the local friendly codename of the producing AI (multi-AI
    /// tethering); it is stored locally for labeling and NEVER put on the wire.
    /// `agentAIID` is the producing AI's STABLE local id (feature-1 per-AI isolation):
    /// storage buckets the message by this id, not by `agentName` — a display name can
    /// collide across two of my AIs, an id cannot. nil ⇒ the sink falls back to resolving
    /// the id from the name (single-AI / legacy paths).
    func postAgentMessage(
        _ body: MessageBody, threadID: String, agentName: String?, agentAIID: String?
    ) async throws
    /// Conversation scope (ai_window). `conversationID` is the destination pinned at
    /// GATE-check time and threaded through the (possibly slow, cross-actor) provider
    /// call, so the reply lands in the conversation whose context it was built from — the
    /// sink must NOT re-resolve the destination from mutable "current window" state at post
    /// time (that was the F1 TOCTOU: the human switching the window to another chat mid-turn
    /// would redirect chat A's content into chat B). The sink re-verifies the window still
    /// belongs to `conversationID` and drops the reply otherwise.
    func postAgentReply(
        _ body: MessageBody, conversationID: String, agentName: String?, agentAIID: String?
    ) async throws

    /// Voice a watch-along DRAFT (SPEC §13.5 endpoint model): `body` carries the
    /// REDACTED text that goes on the wire to the group; `rawText` is the owner's
    /// local-only view (so the owner sees the real answer the agent produced). A sink
    /// that can't split the two falls back (default) to posting the redacted body.
    /// `threadID == nil` ⇒ conversation scope.
    func postAgentDraft(
        _ body: MessageBody, rawText: String, threadID: String?, agentName: String?,
        agentAIID: String?
    ) async throws

    /// A non-fatal diagnostic from an autonomous path: the provider CALL failed
    /// (it threw, e.g. a bad key/timeout/decode error) and so no message could be
    /// produced. The engine surfaces this so the failure is VISIBLE to the user /
    /// Agent Inspector instead of vanishing (the "the AI responded but we didn't
    /// see it" bug). This is NOT a wire/recording path — it carries no agent
    /// output, only the human-readable reason. `threadID == nil` ⇒ conversation
    /// scope. The default is a no-op, so a sink that doesn't surface diagnostics
    /// (e.g. test spies) is unaffected; the engine ALSO logs every such failure
    /// at `.error` independently of the sink (see `runThreadTurn`/`runWindowReply`).
    func reportAgentFailure(_ reason: String, threadID: String?, agentName: String?) async
}

extension AgentMessageSink {
    /// Default: no raw/redacted split available — post the SAFE (redacted) `body` so a
    /// secret never reaches the wire even if a sink doesn't implement the local view.
    public func postAgentDraft(
        _ body: MessageBody, rawText: String, threadID: String?, agentName: String?,
        agentAIID: String?
    ) async throws {
        if let threadID {
            try await postAgentMessage(
                body, threadID: threadID, agentName: agentName, agentAIID: agentAIID)
        } else {
            // Conversation-scope DRAFT with no explicit destination: the production sink
            // overrides `postAgentDraft` and resolves the draft target itself, so this
            // default (test-spy) fallback has no conversation to pin — the sink ignores it.
            try await postAgentReply(
                body, conversationID: "", agentName: agentName, agentAIID: agentAIID)
        }
    }

    /// Default: no-op. The engine still logs the failure at `.error`, so existing
    /// conformers (and test spies) keep compiling and behaving exactly as before;
    /// a UI-aware sink overrides this to drive an alert / Agent Inspector entry.
    public func reportAgentFailure(_ reason: String, threadID: String?, agentName: String?) async {}
}

/// Enforcement core for AI participation (SPEC §13, APP-SPEC §8–9).
/// Owns every gate between an `AgentProvider`'s output and the wire.
public actor AgentEngine {
    /// Allowed always-on durations (APP-SPEC §8: bounded only). Includes the longer
    /// 8h/24h options the "My AI responds" picker offers — without them, selecting 8h or
    /// 24h threw `invalidDuration` (swallowed by `try?` in the app), so only 1h appeared
    /// to work. Still strictly bounded (24h max) + visible-indicator per invariant 9.
    public static let allowedWindowDurations: [Int64] = [
        15 * 60, 30 * 60, 60 * 60, 2 * 60 * 60, 8 * 60 * 60, 24 * 60 * 60,
    ]
    public static let maxWindowDuration: Int64 = 24 * 60 * 60

    private let myIdentity: PQRCIdentity
    private let clock: any Clock
    private let sink: any AgentMessageSink

    /// Conversation-scope windows: human identity hex -> active_until.
    private var conversationWindows: [String: Int64] = [:]
    /// Thread-scope invites: threadID -> (human identity hex -> active_until).
    private var threadInvites: [String: [String: Int64]] = [:]
    /// Context-sharing grants: scope tag -> (granter identity hex -> active_until).
    /// Orthogonal to windows/invites: this is the *consume* axis, never *send*.
    private var contextGrants: [String: [String: Int64]] = [:]
    /// Standing town grants (AC126): `grantKey(granter:peer:plane:)` -> record.
    ///
    /// A THIRD, independent axis. Windows/invites gate `authorizeAutonomousSend`;
    /// context grants gate the consume axis; these gate `authorizeTownSend` and
    /// nothing else. No lookup here is ever consulted by the §13 gate, and no §13
    /// state is ever consulted here — that separation is the whole point of the
    /// workstream (GOOSEWORLD §5: "widening gates ad hoc per surface is how
    /// invariant 9 erodes").
    private var standingGrants: [String: StandingGrantRecord] = [:]
    /// Loop guard (D14): consecutive agent messages per thread.
    private var consecutiveAgentMessages: [String: Int] = [:]

    /// Test-only observability of the grant store's size — the quantity the
    /// per-granter cap + expiry-prune bound (visible only through `@testable`).
    /// Not part of the public API; production never reads it.
    var standingGrantRecordCountForTesting: Int { standingGrants.count }
    /// Loop-guard threshold: pause a thread's agents once this many consecutive
    /// agent messages accumulate with no human in between. Configurable per
    /// account (the app reads a per-silo setting and passes it in); defaults to
    /// `PQRCConstants.agentLoopGuardLimit`. A value `<= 0` means the guard is
    /// OFF (unbounded) — agents can ping-pong without an automatic pause.
    private var loopGuardLimit: Int

    /// Per-thread loop-guard overrides (user-set "max AI turns" for a thread, plan
    /// C1). A thread's own value wins over the account-wide `loopGuardLimit`;
    /// `0` = unlimited for that thread.
    private var threadLoopGuardLimits: [String: Int] = [:]

    public init(
        myIdentity: PQRCIdentity, clock: any Clock, sink: any AgentMessageSink,
        loopGuardLimit: Int = PQRCConstants.agentLoopGuardLimit
    ) {
        self.myIdentity = myIdentity
        self.clock = clock
        self.sink = sink
        self.loopGuardLimit = loopGuardLimit
    }

    /// Update the account-wide loop-guard threshold live. `<= 0` turns it off.
    public func setLoopGuardLimit(_ limit: Int) {
        loopGuardLimit = limit
    }

    /// Set a per-thread loop-guard threshold (the user's "max AI turns" for this
    /// thread). `0` = unlimited. Overrides `loopGuardLimit` for `threadID`.
    public func setThreadLoopGuardLimit(_ limit: Int, threadID: String) {
        threadLoopGuardLimits[threadID] = limit
    }

    /// The effective threshold for a thread: its own override if set, else the
    /// account-wide default. `<= 0` means the guard is off (unlimited) for it.
    private func effectiveLoopGuardLimit(for threadID: String) -> Int {
        threadLoopGuardLimits[threadID] ?? loopGuardLimit
    }

    private var myIdentityHex: String { myIdentity.publicKeyData.hexString }

    // MARK: - ai_window (conversation scope, SPEC §13.3)

    /// Human-only action: sign and activate my own always-on window.
    public func startMyWindow(durationSeconds: Int64) throws -> AIWindowAnnouncement {
        guard Self.allowedWindowDurations.contains(durationSeconds) else {
            throw AgentEngineError.windowDurationUnbounded
        }
        let announcement = try AIWindowAnnouncement.make(
            activeUntil: clock.now() + durationSeconds, identity: myIdentity)
        conversationWindows[myIdentityHex] = announcement.activeUntil
        return announcement
    }

    /// Close MY conversation window NOW, returning a SIGNED closing announcement
    /// (`activeUntil = now`) that the caller MUST publish — otherwise only this
    /// device closes, and every peer's "AI active" indicator AND any owner-gated
    /// bridge node (`isAuthorizedForOwner`) would keep the stale window live until
    /// its original expiry, continuing to post as the owner's signed agent.
    ///
    /// A present/past `activeUntil` only ever REVOKES: `receiveWindow` accepts it,
    /// and `activeWindow` / `authorizeAutonomousSend` / `isAuthorizedForOwner` all
    /// read it as already-expired. So this can never self-activate an agent
    /// (invariant 9 / SPEC §13) — it is purely a human-driven revocation. My local
    /// gate is cleared via `defer` even if signing throws, so it always closes here.
    public func endMyWindowEarly() throws -> AIWindowAnnouncement {
        defer { conversationWindows[myIdentityHex] = nil }
        return try AIWindowAnnouncement.make(activeUntil: clock.now(), identity: myIdentity)
    }

    /// Validates an incoming announcement: signed by the claimed sender's HUMAN
    /// identity key, time-bounded. Agents cannot self-activate — only an
    /// identity-key signature is accepted.
    public func receiveWindow(
        _ announcement: AIWindowAnnouncement, fromSenderIdentityHex sender: String
    ) throws {
        guard announcement.enabledBy.hexString == sender else {
            throw AgentEngineError.windowNotFromHumanIdentity
        }
        guard announcement.hasValidSignature() else {
            throw AgentEngineError.windowSignatureInvalid
        }
        guard announcement.activeUntil - clock.now() <= Self.maxWindowDuration else {
            throw AgentEngineError.windowDurationUnbounded
        }
        conversationWindows[sender] = announcement.activeUntil
    }

    /// Visible-indicator state (every client MUST display it for the duration).
    public func activeWindow(for identityHex: String) -> Int64? {
        guard let until = conversationWindows[identityHex], until > clock.now() else {
            return nil
        }
        return until
    }

    // MARK: - ai_invite (thread scope, D7)

    public func startMyInvite(threadID: String, durationSeconds: Int64) throws -> AIInvite {
        guard Self.allowedWindowDurations.contains(durationSeconds) else {
            throw AgentEngineError.windowDurationUnbounded
        }
        let invite = try AIInvite.make(
            threadID: threadID, activeUntil: clock.now() + durationSeconds, identity: myIdentity)
        threadInvites[threadID, default: [:]][myIdentityHex] = invite.activeUntil
        return invite
    }

    public func withdrawMyInvite(threadID: String) {
        threadInvites[threadID]?[myIdentityHex] = nil
    }

    public func receiveInvite(_ invite: AIInvite, fromSenderIdentityHex sender: String) throws {
        guard invite.enabledBy.hexString == sender else {
            throw AgentEngineError.windowNotFromHumanIdentity
        }
        guard invite.hasValidSignature() else {
            throw AgentEngineError.windowSignatureInvalid
        }
        guard invite.activeUntil - clock.now() <= Self.maxWindowDuration else {
            throw AgentEngineError.windowDurationUnbounded
        }
        threadInvites[invite.thread.id, default: [:]][sender] = invite.activeUntil
    }

    public func activeInvite(threadID: String, identityHex: String) -> Int64? {
        guard let until = threadInvites[threadID]?[identityHex], until > clock.now() else {
            return nil
        }
        return until
    }

    // MARK: - ai_context_grant (consume axis, DEVIATIONS N24)

    /// Human-only action: sign and activate my own context-sharing grant for a
    /// scope. Same bounded-duration rules as windows/invites.
    public func startMyContextGrant(
        scope: AIContextGrant.Scope, durationSeconds: Int64
    ) throws -> AIContextGrant {
        guard Self.allowedWindowDurations.contains(durationSeconds) else {
            throw AgentEngineError.windowDurationUnbounded
        }
        let grant = try AIContextGrant.make(
            scope: scope, activeUntil: clock.now() + durationSeconds, identity: myIdentity)
        contextGrants[scope.tag, default: [:]][myIdentityHex] = grant.activeUntil
        return grant
    }

    public func withdrawMyContextGrant(scope: AIContextGrant.Scope) {
        contextGrants[scope.tag]?[myIdentityHex] = nil
    }

    /// Validates an incoming grant: signed by the claimed sender's HUMAN
    /// identity key, time-bounded. Agents cannot self-activate (invariant 9).
    public func receiveContextGrant(
        _ grant: AIContextGrant, fromSenderIdentityHex sender: String
    ) throws {
        guard grant.enabledBy.hexString == sender else {
            throw AgentEngineError.windowNotFromHumanIdentity
        }
        guard grant.hasValidSignature() else {
            throw AgentEngineError.windowSignatureInvalid
        }
        guard grant.activeUntil - clock.now() <= Self.maxWindowDuration else {
            throw AgentEngineError.windowDurationUnbounded
        }
        contextGrants[grant.scope.tag, default: [:]][sender] = grant.activeUntil
    }

    public func activeContextGrant(scope: AIContextGrant.Scope, identityHex: String) -> Int64? {
        guard let until = contextGrants[scope.tag]?[identityHex], until > clock.now() else {
            return nil
        }
        return until
    }

    /// Whether shared context may flow in a scope. Default policy is
    /// BIDIRECTIONAL (ties resolve to privacy, SPEC §0): my own grant must be
    /// live AND at least one other human's grant must be live. So no one's
    /// marked context is consumed by a peer AI unless both humans opted in.
    public func contextSharingAuthorized(scope: AIContextGrant.Scope) -> Bool {
        let now = clock.now()
        let live = contextGrants[scope.tag]?.filter { $0.value > now } ?? [:]
        guard live[myIdentityHex] != nil else { return false }
        return live.keys.contains { $0 != myIdentityHex }
    }

    // MARK: - standing_grant (town scope, GOOSEWORLD §5 / DEVIATIONS AC126)

    /// One live grant, plus the day-accounting the gate spends against it.
    ///
    /// The budget counters live HERE, not on the wire object, because they are
    /// purely local bookkeeping: nothing about how much of today's allowance my
    /// agent has spent should ever be inferable by a peer or a relay (SPEC §0).
    struct StandingGrantRecord: Sendable {
        let grantID: String
        let granter: String
        let peer: String
        let plane: StandingGrant.Plane
        let activeUntil: Int64
        let budget: StandingGrant.Budget
        /// UTC day the counters below belong to. Compared, never scheduled on.
        var dayIndex: Int64
        var messagesUsed: Int
        var bytesUsed: Int
        /// In-flight delegated task ids (a Set, so a duplicate `begin` for the same
        /// task can't inflate the concurrency count and a lost `end` can't
        /// double-decrement).
        var tasksInFlight: Set<String>
    }

    /// A live grant as a client should render it: expiry AND what is left of the
    /// budget, so the indicator can say "3 days left, 41 of 200 messages" rather
    /// than a bare "active" badge.
    ///
    /// Visibility is not a nicety here — it is the property that makes a day-scale
    /// grant acceptable at all. `ai_window` is safe partly because it is short;
    /// a standing grant is safe partly because it is *conspicuous* for its whole
    /// life (GOOSEWORLD §5, invariant 9's visible-indicator clause).
    public struct StandingGrantStatus: Equatable, Sendable {
        public let grantID: String
        public let granterIdentityHex: String
        public let peerIdentityHex: String
        public let plane: StandingGrant.Plane
        public let activeUntil: Int64
        public let messagesRemaining: Int
        public let bytesRemaining: Int
        public let tasksInFlight: Int
        public let maxConcurrentTasks: Int
        public let toolCeiling: [String]?

        /// Public memberwise init. A synthesized one is `internal`, which made this
        /// public read-only DTO unconstructible outside the package — so app-layer code
        /// (the World screen's row derivation, WS-D1a) could not table-test against the
        /// REAL type and would have had to mirror it. Constructing a status object
        /// authorizes nothing on its own; the engine remains the only thing that can
        /// mint or honor a grant.
        public init(
            grantID: String, granterIdentityHex: String, peerIdentityHex: String,
            plane: StandingGrant.Plane, activeUntil: Int64, messagesRemaining: Int,
            bytesRemaining: Int, tasksInFlight: Int, maxConcurrentTasks: Int,
            toolCeiling: [String]?
        ) {
            self.grantID = grantID
            self.granterIdentityHex = granterIdentityHex
            self.peerIdentityHex = peerIdentityHex
            self.plane = plane
            self.activeUntil = activeUntil
            self.messagesRemaining = messagesRemaining
            self.bytesRemaining = bytesRemaining
            self.tasksInFlight = tasksInFlight
            self.maxConcurrentTasks = maxConcurrentTasks
            self.toolCeiling = toolCeiling
        }
    }

    /// The UTC day a timestamp falls in. Floor division (not truncation), so the
    /// pre-1970 case a hostile clock could produce still yields a monotone index
    /// rather than folding two days together.
    static func utcDayIndex(_ time: Int64) -> Int64 {
        let day = PQRCConstants.secondsPerDay
        let quotient = time / day
        return (time % day < 0) ? quotient - 1 : quotient
    }

    /// Storage key. All three components are fixed-vocabulary or hex-validated
    /// (`StandingGrant.validateStructure` pins `peer` to 64 lowercase hex, and the
    /// granter key is a hex-encoded pubkey), so `|` cannot appear inside a
    /// component and the key is unambiguous.
    static func grantKey(granter: String, peer: String, plane: StandingGrant.Plane) -> String {
        "\(granter)|\(peer)|\(plane.rawValue)"
    }

    /// Human-only action: sign and activate MY standing grant toward one peer town.
    ///
    /// `grantID` is supplied by the caller rather than minted here on purpose — the
    /// engine stays free of system randomness so every test is deterministic
    /// (TEST-PLAN §1). The id is not security material; the signature binds it.
    ///
    /// Returns the signed grant, which the caller MUST publish: like
    /// `startMyWindow`, activating it locally without telling the peer produces a
    /// grant only one side can see, which defeats the visibility property.
    public func startMyStandingGrant(
        grantID: String, peerIdentityHex: String, planes: [StandingGrant.Plane],
        budget: StandingGrant.Budget, durationSeconds: Int64
    ) throws -> StandingGrant {
        guard PQRCConstants.allowedStandingGrantDurations.contains(durationSeconds) else {
            throw AgentEngineError.standingGrantDurationUnbounded
        }
        let grant: StandingGrant
        do {
            grant = try StandingGrant.make(
                grantID: grantID, peer: peerIdentityHex, planes: planes, budget: budget,
                activeUntil: clock.now() + durationSeconds, identity: myIdentity)
        } catch let error as StandingGrantError {
            throw AgentEngineError.standingGrantMalformed(error)
        }
        store(grant, granter: myIdentityHex)
        return grant
    }

    /// Validates an incoming grant: signed by the CLAIMED SENDER's own human
    /// identity key, structurally sound, and bounded. Agents cannot self-grant —
    /// only an identity-key signature is accepted, exactly as `receiveWindow` does
    /// (SPEC §13.3, invariant 9). An agent-key signature over the same bytes fails
    /// the verify; a grant whose `enabled_by` disagrees with the sender is rejected
    /// before any crypto runs.
    public func receiveStandingGrant(
        _ grant: StandingGrant, fromSenderIdentityHex sender: String
    ) throws {
        guard grant.enabledBy.hexString == sender else {
            throw AgentEngineError.standingGrantNotFromHumanIdentity
        }
        do {
            try grant.validateStructure()
        } catch let error as StandingGrantError {
            throw AgentEngineError.standingGrantMalformed(error)
        }
        guard grant.hasValidSignature() else {
            throw AgentEngineError.standingGrantSignatureInvalid
        }
        guard grant.hasBoundedDuration(now: clock.now()) else {
            throw AgentEngineError.standingGrantDurationUnbounded
        }
        // Bound a single granter's footprint (see `maxStandingGrantsPerGranter`).
        // Prune first so an expired grant never counts against a peer's live quota,
        // then refuse only a NEW grant id past the cap — a re-issue (top-up) of an
        // id already on file is always honored. A caller cannot use this to probe
        // state: the decision is about the grant in hand, and the count is of the
        // SENDER's own grants, which the sender already knows it issued.
        let now = clock.now()
        pruneExpiredGrants(now: now)
        let liveGrantIDsFromSender = Set(
            standingGrants.values
                .filter { $0.granter == sender && now < $0.activeUntil }
                .map(\.grantID))
        if !liveGrantIDsFromSender.contains(grant.grantID),
            liveGrantIDsFromSender.count >= PQRCConstants.maxStandingGrantsPerGranter
        {
            throw AgentEngineError.standingGrantLimitReached
        }
        store(grant, granter: sender)
        agentLog.debug(
            "Standing grant accepted from \(sender, privacy: .private) for planes \(grant.planes.joined(separator: "+"), privacy: .private)"
        )
    }

    /// Materializes one record per KNOWN plane. Unknown plane strings stay bound in
    /// the signature (so the grant still verifies on a newer peer) but produce no
    /// record here, and therefore authorize nothing — forward-compatible and
    /// fail-closed at once (SPEC §12).
    ///
    /// Re-storing the SAME `grantID` preserves the day counters. That is a
    /// security property, not an optimization: if a replayed grant reset the
    /// budget, replaying it would BE the budget bypass. A genuinely new grant id
    /// (a deliberate human act) starts fresh.
    private func store(_ grant: StandingGrant, granter: String) {
        let now = clock.now()
        // Opportunistic prune: an expired grant authorizes nothing already (every
        // gate/query checks `now < activeUntil`), so dropping it here changes no
        // decision — it only keeps the store from accumulating dead records in a
        // long-lived daemon. Cheap: runs once per grant issued/received.
        pruneExpiredGrants(now: now)
        let today = Self.utcDayIndex(now)
        for plane in grant.knownPlanes {
            let key = Self.grantKey(granter: granter, peer: grant.peer, plane: plane)
            let previous = standingGrants[key]
            let carryOver = previous?.grantID == grant.grantID ? previous : nil
            standingGrants[key] = StandingGrantRecord(
                grantID: grant.grantID, granter: granter, peer: grant.peer, plane: plane,
                activeUntil: grant.activeUntil, budget: grant.budget,
                dayIndex: carryOver?.dayIndex ?? today,
                messagesUsed: carryOver?.messagesUsed ?? 0,
                bytesUsed: carryOver?.bytesUsed ?? 0,
                tasksInFlight: carryOver?.tasksInFlight ?? [])
        }
    }

    /// Human-only action: withdraw MY standing grant, returning a SIGNED
    /// revocation the caller MUST publish.
    ///
    /// Mirrors `endMyWindowEarly`: the local state is cleared in a `defer`, so
    /// even if signing throws, THIS device has already stopped honoring the grant.
    /// The failure mode we refuse to allow is "revocation failed, so we kept
    /// going" — on doubt, closed.
    public func revokeMyStandingGrant(grantID: String) throws -> StandingGrantRevocation {
        defer { forgetGrants(grantID: grantID, granter: myIdentityHex) }
        do {
            return try StandingGrantRevocation.make(
                grantID: grantID, revokedAt: clock.now(), identity: myIdentity)
        } catch let error as StandingGrantError {
            throw AgentEngineError.standingGrantMalformed(error)
        }
    }

    /// Applies an incoming revocation. Effective on receipt.
    ///
    /// Two fail-closed subtleties:
    ///
    /// 1. It only ever removes grants whose GRANTER is the revocation's signer.
    ///    A third party who signs a revocation naming someone else's grant id
    ///    revokes nothing — otherwise any peer could switch off any other peer's
    ///    grant, which is a denial-of-service dressed as a safety feature.
    /// 2. A revocation for a grant id this device has never seen is a SILENT
    ///    no-op, not an error. Reporting "unknown grant" would answer the question
    ///    "do you hold grant X?" for anyone willing to guess ids. Replaying a
    ///    revocation is likewise idempotent.
    ///
    /// A bad signature or a mismatched `enabled_by` DOES throw: that is a judgment
    /// about the message in hand, not a disclosure about stored state.
    public func receiveStandingGrantRevocation(
        _ revocation: StandingGrantRevocation, fromSenderIdentityHex sender: String
    ) throws {
        guard revocation.enabledBy.hexString == sender else {
            throw AgentEngineError.standingGrantNotFromHumanIdentity
        }
        guard revocation.hasValidSignature() else {
            throw AgentEngineError.standingGrantSignatureInvalid
        }
        forgetGrants(grantID: revocation.grantID, granter: sender)
    }

    /// Removes every plane-record belonging to one grant id AND one granter.
    /// Both halves of that predicate matter: the granter clause is what stops a
    /// third party from revoking someone else's grant by guessing its id.
    /// Keys are collected before removal so the dictionary is never mutated
    /// through a live iteration.
    private func forgetGrants(grantID: String, granter: String) {
        let doomed = standingGrants.filter {
            $0.value.grantID == grantID && $0.value.granter == granter
        }.keys
        for key in doomed { standingGrants[key] = nil }
    }

    /// Drops every record whose life has run out (`activeUntil <= now`). Purely a
    /// memory bound: an expired record is already invisible to every gate and query
    /// (all of them require `now < activeUntil`), so removing it is behavior-
    /// preserving. Called opportunistically on `store`, so the store's size tracks
    /// LIVE grants rather than every grant ever seen. Keys are collected before
    /// removal so the dictionary is not mutated through a live iteration.
    private func pruneExpiredGrants(now: Int64) {
        let doomed = standingGrants.filter { now >= $0.value.activeUntil }.keys
        for key in doomed { standingGrants[key] = nil }
    }

    // MARK: The town gate (separate from §13's, fail closed)

    /// Throws unless a live, unrevoked, in-budget grant of MINE covers this exact
    /// (peer, plane) and this many bytes.
    ///
    /// **This is not `authorizeAutonomousSend` and must never become it.** Holding
    /// a standing grant authorizes cross-town traffic on a named plane and nothing
    /// else: it does not let my agent speak in an ordinary conversation, and it
    /// does not let it post in a thread. Those still require a live `ai_window` or
    /// `ai_invite`, unchanged, byte for byte (SPEC §13.3).
    ///
    /// Pure check, no side effects — spending is an explicit `recordTownSend`, the
    /// same shape as `recordThreadMessage`. Two reasons: an authorization that
    /// silently consumed budget would double-charge every caller that re-checks
    /// mid-turn (`runThreadTurn` does exactly that), and a check with no side
    /// effects is one a UI can call freely to decide whether to grey out a button.
    public func authorizeTownSend(
        peerIdentityHex: String, plane: StandingGrant.Plane, bytes: Int
    ) throws {
        guard bytes >= 0 else {
            throw AgentEngineError.standingGrantMalformed(.malformedBudget)
        }
        let now = clock.now()
        let key = Self.grantKey(granter: myIdentityHex, peer: peerIdentityHex, plane: plane)
        guard let record = standingGrants[key], now < record.activeUntil else {
            throw AgentEngineError.townSendNotAuthorized
        }
        // Day rollover is evaluated HERE, on access, from the injected clock —
        // never by a scheduled reset (invariant 1).
        let (messagesUsed, bytesUsed) = Self.usage(of: record, at: now)
        // Written as `<` and as a SUBTRACTION rather than `used + bytes <= cap`
        // on purpose: `bytes` is caller-supplied and `used + bytes` traps on
        // overflow for a large enough `bytes`, which would turn a bad argument
        // into a crashed actor. Both operands of the subtraction are validated
        // into `0...maxBytesPerDay`, so it cannot overflow for any `bytes`.
        guard messagesUsed < record.budget.messagesPerDay,
            bytes <= record.budget.bytesPerDay - bytesUsed
        else {
            throw AgentEngineError.townBudgetExhausted
        }
    }

    /// Today's spend against a record, rolling the day forward but never back.
    ///
    /// The comparison is `today > record.dayIndex`, not `!=`: a clock moved
    /// BACKWARDS must not hand the budget back. Time is an untrusted input here
    /// (SPEC §5.2 keeps it out of the key schedule for the same reason), so the
    /// rollover is monotone — the only direction it can be wrong in is stingy.
    private static func usage(
        of record: StandingGrantRecord, at now: Int64
    ) -> (messages: Int, bytes: Int) {
        Self.utcDayIndex(now) > record.dayIndex ? (0, 0) : (record.messagesUsed, record.bytesUsed)
    }

    /// Spends one message and `bytes` against MY grant for (peer, plane). Call it
    /// once per send actually made, after `authorizeTownSend` allowed it.
    ///
    /// Deliberately non-throwing and forgiving of an unknown/expired grant: this is
    /// accounting, and an accounting call that can throw invites a caller to skip
    /// it. Counters saturate at the budget ceiling, so a caller that records
    /// without authorizing first can only ever make the gate *more* closed.
    public func recordTownSend(
        peerIdentityHex: String, plane: StandingGrant.Plane, bytes: Int
    ) {
        let key = Self.grantKey(granter: myIdentityHex, peer: peerIdentityHex, plane: plane)
        guard var record = standingGrants[key] else { return }
        let today = Self.utcDayIndex(clock.now())
        if today > record.dayIndex {
            record.dayIndex = today
            record.messagesUsed = 0
            record.bytesUsed = 0
        }
        // Clamp the addend to the daily cap BEFORE adding, so a caller passing a
        // wild byte count saturates instead of trapping (same overflow hazard as
        // `authorizeTownSend`; both operands stay inside `0...maxBytesPerDay`).
        let spend = min(max(0, bytes), record.budget.bytesPerDay)
        record.messagesUsed = min(record.messagesUsed + 1, record.budget.messagesPerDay)
        record.bytesUsed = min(record.bytesUsed + spend, record.budget.bytesPerDay)
        standingGrants[key] = record
    }

    /// Registers a delegated task against MY `delegate` grant for `peer`, subject
    /// to `max_concurrent_tasks`. Throws rather than queueing — a town that is at
    /// its ceiling should be told "no" now, not silently backlogged (GOOSEWORLD §4
    /// adversary class 4: runaway loops/cost).
    ///
    /// Concurrency is NOT budget: it does not roll over daily, because it counts
    /// things currently running rather than things spent.
    public func beginTownTask(peerIdentityHex: String, taskID: String) throws {
        let now = clock.now()
        let key = Self.grantKey(granter: myIdentityHex, peer: peerIdentityHex, plane: .delegate)
        guard var record = standingGrants[key], now < record.activeUntil else {
            throw AgentEngineError.townSendNotAuthorized
        }
        // Re-registering an id already in flight is idempotent, so a retried
        // begin can't consume two slots.
        if !record.tasksInFlight.contains(taskID) {
            guard record.tasksInFlight.count < record.budget.maxConcurrentTasks else {
                throw AgentEngineError.townTaskLimitReached
            }
            record.tasksInFlight.insert(taskID)
            standingGrants[key] = record
        }
    }

    /// Releases a delegated task slot. Unknown ids are a no-op (same
    /// no-state-probe rule as revocation).
    public func endTownTask(peerIdentityHex: String, taskID: String) {
        let key = Self.grantKey(granter: myIdentityHex, peer: peerIdentityHex, plane: .delegate)
        guard var record = standingGrants[key] else { return }
        record.tasksInFlight.remove(taskID)
        standingGrants[key] = record
    }

    /// Whether MY `delegate` grant for `peer` permits `tool`.
    ///
    /// `nil` ceiling ⇒ `true`: the grant adds no narrowing. That is NOT a
    /// widening — every tool call still passes the ACP permission gate and the
    /// path jail, which are unchanged and fail closed on their own. No live
    /// delegate grant at all ⇒ `false`.
    public func toolAuthorizedForTown(peerIdentityHex: String, tool: String) -> Bool {
        let key = Self.grantKey(granter: myIdentityHex, peer: peerIdentityHex, plane: .delegate)
        guard let record = standingGrants[key], clock.now() < record.activeUntil else {
            return false
        }
        guard let ceiling = record.budget.toolCeiling else { return true }
        return ceiling.contains(tool)
    }

    // MARK: Visibility (the indicator every client MUST render)

    /// Live status for one (peer, plane), or nil if there is no unexpired grant.
    /// `granterIdentityHex` defaults to ME; pass a peer's hex to inspect the grant
    /// THEY issued (what their town is allowed to do toward us).
    public func activeStandingGrant(
        peerIdentityHex: String, plane: StandingGrant.Plane,
        granterIdentityHex: String? = nil
    ) -> StandingGrantStatus? {
        let granter = granterIdentityHex ?? myIdentityHex
        let key = Self.grantKey(granter: granter, peer: peerIdentityHex, plane: plane)
        guard let record = standingGrants[key], clock.now() < record.activeUntil else {
            return nil
        }
        return status(for: record)
    }

    /// Every live grant, for the "what is standing right now" panel. Sorted by
    /// (peer, plane) so the UI order is stable across calls — a list that
    /// reshuffles is a list nobody reads, and an unread indicator is not an
    /// indicator.
    public func activeStandingGrants() -> [StandingGrantStatus] {
        let now = clock.now()
        return
            standingGrants.values
            .filter { now < $0.activeUntil }
            .map(status(for:))
            .sorted {
                ($0.peerIdentityHex, $0.plane.rawValue, $0.granterIdentityHex)
                    < ($1.peerIdentityHex, $1.plane.rawValue, $1.granterIdentityHex)
            }
    }

    private func status(for record: StandingGrantRecord) -> StandingGrantStatus {
        let (messagesUsed, bytesUsed) = Self.usage(of: record, at: clock.now())
        return StandingGrantStatus(
            grantID: record.grantID,
            granterIdentityHex: record.granter,
            peerIdentityHex: record.peer,
            plane: record.plane,
            activeUntil: record.activeUntil,
            messagesRemaining: max(0, record.budget.messagesPerDay - messagesUsed),
            bytesRemaining: max(0, record.budget.bytesPerDay - bytesUsed),
            tasksInFlight: record.tasksInFlight.count,
            maxConcurrentTasks: record.budget.maxConcurrentTasks,
            toolCeiling: record.budget.toolCeiling)
    }

    // MARK: - The autonomous-send gate (fail closed)

    /// Throws unless MY agent is currently authorized for the given scope.
    /// `threadID == nil` means conversation scope (requires my ai_window);
    /// a thread id requires MY active ai_invite for that thread.
    public func authorizeAutonomousSend(threadID: String?) throws {
        let now = clock.now()
        if let threadID {
            guard let until = threadInvites[threadID]?[myIdentityHex], now < until else {
                throw AgentEngineError.autonomousSendNotAuthorized
            }
            let limit = effectiveLoopGuardLimit(for: threadID)
            if limit > 0, consecutiveAgentMessages[threadID, default: 0] >= limit {
                throw AgentEngineError.loopGuardPaused
            }
        } else {
            guard let until = conversationWindows[myIdentityHex], now < until else {
                throw AgentEngineError.autonomousSendNotAuthorized
            }
        }
    }

    // MARK: - Owner-gated authorization (PQRC watch-along bridge, SPEC §13)

    /// Whether a PINNED OWNER currently authorizes autonomous agent sends. Mirrors
    /// `authorizeAutonomousSend`/`activeWindow`, but keyed on the owner's identity
    /// rather than mine: the Mac bridge participates as an openly-AI agent whose
    /// autonomy is governed by a *designated owner's* live, signed window/invite, not
    /// its own. `threadID == nil` ⇒ conversation scope (owner's `ai_window`); a thread
    /// id ⇒ the owner's `ai_invite` for that thread.
    ///
    /// Fail closed: no live owner window/invite ⇒ `false`. A link drop simply lets the
    /// window go stale, so the agent stops sending — the correct behavior (invariant 9).
    /// The owner's window/invite is populated by `receiveWindow(_,fromSenderIdentityHex:)`
    /// / `receiveInvite(_,fromSenderIdentityHex:)`, which already verify the signature
    /// is the owner's and the duration is bounded before storing it.
    public func isAuthorizedForOwner(_ ownerHex: String, threadID: String? = nil) -> Bool {
        let now = clock.now()
        if let threadID {
            guard let until = threadInvites[threadID]?[ownerHex], now < until else { return false }
            return true
        }
        guard let until = conversationWindows[ownerHex], now < until else { return false }
        return true
    }

    // MARK: - Watch-along draft voicing (§13.5 endpoint model, DEVIATIONS AC24)

    /// Voice a watch-along DRAFT — produced by the owner's Mac coding agent and
    /// delivered to this (the owner's) phone — to the group, as the owner's
    /// cryptographically-bound agent. The wire copy is REDACTED here (the scrub lives in
    /// the engine so it can't be bypassed); the raw text is handed to the sink only for
    /// the owner's local view. Gated by MY (the owner's) own active window/invite, fail
    /// closed (invariant 9). `threadID == nil` ⇒ conversation scope. Returns true iff
    /// posted.
    ///
    /// This is the §13.5 win: the agent's words are signed with MY agent key (the sink
    /// posts as `.agent`, which signs with this device's agent key) and the raw secret
    /// never leaves my device — only the redacted copy goes to the group.
    @discardableResult
    public func voiceAgentDraft(
        rawText: String, threadID: String? = nil, agentName: String? = nil,
        agentAIID: String? = nil
    ) async -> Bool {
        do {
            try authorizeAutonomousSend(threadID: threadID)
        } catch {
            return false  // no active owner window/invite (or loop-guard) ⇒ fail closed
        }
        let redacted = CredentialRedactor.scrub(rawText)
        let body = MessageBody(
            text: redacted, sentAt: clock.now(),
            thread: threadID.map { RumorContent.ThreadRef(id: $0) })
        do {
            try await sink.postAgentDraft(
                body, rawText: rawText, threadID: threadID, agentName: agentName,
                agentAIID: agentAIID)
            if let threadID { recordThreadMessage(threadID: threadID, participantType: .agent) }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Drafting (always allowed; private to my human; nothing sent)

    public func draft(provider: any AgentProvider, context: AgentContext) async throws -> Draft {
        try await provider.draftReply(context: context)
    }

    // MARK: - Thread turns (the recording guarantee)

    /// Runs one provider turn for a thread. Every message the provider returns
    /// is posted as a normal, signed, agent-labeled THREAD message through the
    /// sink — context contributions included. No other sink exists.
    /// Returns the number of messages posted (0 if the gate is closed or the
    /// provider stays silent).
    @discardableResult
    public func runThreadTurn(
        provider: any AgentProvider, context: AgentContext, threadID: String,
        agentName: String? = nil, agentAIID: String? = nil
    ) async -> Int {
        do {
            try authorizeAutonomousSend(threadID: threadID)
        } catch {
            // Silent by default: loop-guard pause / window-or-invite expiry are
            // BY DESIGN (invariant 9, fail closed), not failures to surface.
            return 0
        }

        // Run the provider call WITHOUT `try?` so a real failure (bad key, timeout,
        // decode error) can no longer vanish. A throw is surfaced (logged at .error
        // + reported to the sink); an empty/nil turn is a legit "nothing to say" and
        // stays quiet, but is still logged at a low level so it's diagnosable.
        let turn: AgentTurn?
        do {
            turn = try await provider.threadTurn(context: context)
        } catch {
            await surfaceProviderFailure(error, threadID: threadID, agentName: agentName)
            return 0
        }
        guard let turn, !turn.messages.isEmpty else {
            agentLog.debug(
                "Agent thread turn produced no message (provider returned empty/nil) for thread \(threadID, privacy: .public)"
            )
            return 0
        }

        var posted = 0
        for message in turn.messages {
            // Re-check the gate per message: expiry/withdrawal mid-turn stops the rest.
            do {
                try authorizeAutonomousSend(threadID: threadID)
            } catch {
                break
            }
            let body = MessageBody(
                text: message.isContext ? "Context: \(message.text)" : message.text,
                sentAt: clock.now(),
                thread: RumorContent.ThreadRef(id: threadID),
                isContext: message.isContext
            )
            do {
                try await sink.postAgentMessage(
                    body, threadID: threadID, agentName: agentName, agentAIID: agentAIID)
                recordThreadMessage(threadID: threadID, participantType: .agent)
                posted += 1
            } catch {
                break
            }
        }
        return posted
    }

    /// Conversation-scope autonomous reply during MY active ai_window.
    @discardableResult
    public func runWindowReply(
        provider: any AgentProvider, context: AgentContext, conversationID: String,
        agentName: String? = nil, agentAIID: String? = nil
    ) async -> Bool {
        do {
            try authorizeAutonomousSend(threadID: nil)
        } catch {
            // Silent by design: no active window / loop-guard pause — fail closed.
            return false
        }

        // Surface a provider throw instead of swallowing it with `try?` (same fix
        // as `runThreadTurn`); an empty/nil turn stays quiet but is logged low.
        let turn: AgentTurn?
        do {
            turn = try await provider.threadTurn(context: context)
        } catch {
            await surfaceProviderFailure(error, threadID: nil, agentName: agentName)
            return false
        }
        guard let message = turn?.messages.first else {
            agentLog.debug(
                "Agent window reply produced no message (provider returned empty/nil)")
            return false
        }
        do {
            try authorizeAutonomousSend(threadID: nil)
            try await sink.postAgentReply(
                MessageBody(text: message.text, sentAt: clock.now()),
                conversationID: conversationID, agentName: agentName, agentAIID: agentAIID)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Provider-failure surfacing (intermittent-failure hardening)

    /// A provider CALL on an autonomous path threw. Make it VISIBLE: log the
    /// provider's error description at `.error` (the diagnosable signal that was
    /// missing) and hand a human-readable reason to the sink so the UI / Agent
    /// Inspector can show it. Does NOT change any return contract — callers still
    /// return 0 / false; this only stops the silent swallow. Loop-guard pauses and
    /// window/invite expiry never reach here (they're caught at the gate above), so
    /// the by-design silent paths stay silent.
    private func surfaceProviderFailure(
        _ error: Error, threadID: String?, agentName: String?
    ) async {
        let reason = Self.describeProviderError(error)
        agentLog.error(
            "Agent autonomous reply failed (thread \(threadID ?? "—", privacy: .public)): \(reason, privacy: .public)"
        )
        await sink.reportAgentFailure(reason, threadID: threadID, agentName: agentName)
    }

    /// Human-readable reason for a provider throw, mirroring the app's
    /// `describeAgentError`/`runSelfAIReplies` mapping so thread/window failures
    /// read the same as the draft path the user already sees.
    private static func describeProviderError(_ error: Error) -> String {
        if case AgentProviderError.unavailable(let detail) = error { return detail }
        if case AgentProviderError.notConfigured = error {
            return "No AI provider configured. Pick one in Settings ▸ AI."
        }
        return (error as NSError).localizedDescription
    }

    // MARK: - Loop guard (D14)

    /// Feed EVERY thread message (local sends and remote receipts) through here.
    public func recordThreadMessage(threadID: String, participantType: ParticipantType) {
        switch participantType {
        case .agent:
            consecutiveAgentMessages[threadID, default: 0] += 1
        case .human:
            consecutiveAgentMessages[threadID] = 0  // a human resumes the agents
        }
    }

    public func loopGuardActive(threadID: String) -> Bool {
        let limit = effectiveLoopGuardLimit(for: threadID)
        guard limit > 0 else { return false }
        return consecutiveAgentMessages[threadID, default: 0] >= limit
    }
}
