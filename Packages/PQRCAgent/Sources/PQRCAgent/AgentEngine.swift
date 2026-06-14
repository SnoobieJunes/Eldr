import Foundation
import PQRCCore
import PQRCNostr

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
    func postAgentMessage(_ body: MessageBody, threadID: String) async throws
    func postAgentReply(_ body: MessageBody) async throws  // conversation scope (ai_window)
}

/// Enforcement core for AI participation (SPEC §13, APP-SPEC §8–9).
/// Owns every gate between an `AgentProvider`'s output and the wire.
public actor AgentEngine {
    /// Allowed always-on durations (APP-SPEC §8: bounded only).
    public static let allowedWindowDurations: [Int64] = [15 * 60, 30 * 60, 60 * 60, 2 * 60 * 60]
    public static let maxWindowDuration: Int64 = 2 * 60 * 60

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

    public init(myIdentity: PQRCIdentity, clock: any Clock, sink: any AgentMessageSink) {
        self.myIdentity = myIdentity
        self.clock = clock
        self.sink = sink
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

    public func endMyWindowEarly() {
        conversationWindows[myIdentityHex] = nil
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
            if consecutiveAgentMessages[threadID, default: 0] >= PQRCConstants.agentLoopGuardLimit {
                throw AgentEngineError.loopGuardPaused
            }
        } else {
            guard let until = conversationWindows[myIdentityHex], now < until else {
                throw AgentEngineError.autonomousSendNotAuthorized
            }
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
        provider: any AgentProvider, context: AgentContext, threadID: String
    ) async -> Int {
        do {
            try authorizeAutonomousSend(threadID: threadID)
        } catch {
            return 0  // silent by default; loop-guard pause; expiry — all fail closed
        }
        guard let turn = try? await provider.threadTurn(context: context), !turn.messages.isEmpty
        else { return 0 }

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
                try await sink.postAgentMessage(body, threadID: threadID)
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
        provider: any AgentProvider, context: AgentContext
    ) async -> Bool {
        do {
            try authorizeAutonomousSend(threadID: nil)
        } catch {
            return false
        }
        guard let turn = try? await provider.threadTurn(context: context),
            let message = turn.messages.first
        else { return false }
        do {
            try authorizeAutonomousSend(threadID: nil)
            try await sink.postAgentReply(
                MessageBody(text: message.text, sentAt: clock.now()))
            return true
        } catch {
            return false
        }
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
        consecutiveAgentMessages[threadID, default: 0] >= PQRCConstants.agentLoopGuardLimit
    }
}
