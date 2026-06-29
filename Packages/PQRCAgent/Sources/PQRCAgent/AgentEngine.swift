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
    func postAgentReply(
        _ body: MessageBody, agentName: String?, agentAIID: String?
    ) async throws  // conversation scope (ai_window)

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
            try await postAgentReply(body, agentName: agentName, agentAIID: agentAIID)
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
    /// Loop guard (D14): consecutive agent messages per thread.
    private var consecutiveAgentMessages: [String: Int] = [:]
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
        provider: any AgentProvider, context: AgentContext, agentName: String? = nil,
        agentAIID: String? = nil
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
                MessageBody(text: message.text, sentAt: clock.now()), agentName: agentName,
                agentAIID: agentAIID)
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
