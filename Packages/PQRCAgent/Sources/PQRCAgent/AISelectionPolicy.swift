import Foundation

/// The one property the default routing policy needs from a tethered AI to decide
/// the PARTICIPATION set: whether this AI may post on its own (window/thread/solo
/// turns). `TetheredAI` (App layer) already exposes `participatesAutonomously`, so
/// it conforms with no new code — this protocol only lets `AISelectionPolicy` live
/// in PQRCAgent (next to `AgentProvider`) without depending on the App-layer
/// `TetheredAI` type itself.
public protocol AISelectionCandidate: Sendable {
    /// True when this AI is allowed to post autonomously (not "draft"-only / "off").
    var participatesAutonomously: Bool { get }

    /// Coarse capability tags describing what this AI is suited for — e.g.
    /// `["code"]` for a paired coding node, empty for a general chat model. A
    /// task-routing policy (`CapabilityRoutingPolicy`) matches these against a
    /// scope's REQUIRED capabilities to pick the engine; `DefaultAISelectionPolicy`
    /// ignores them. Optional: a default of `[]` lets every existing candidate (and
    /// the package tests) conform with no change.
    var routingCapabilities: Set<String> { get }
}

public extension AISelectionCandidate {
    var routingCapabilities: Set<String> { [] }
}

/// Router policy indirection (Phase 2): "which AI handles this request" is a
/// pluggable, injectable policy instead of hardcoded `ais[0]` / a fixed
/// `participatesAutonomously` filter in the runtime.
///
/// Two decisions are routed:
///  - `primary`: the single AI used for PRIVATE drafts (the "draft my reply"
///    feature) and the Settings "Test AI now" probe.
///  - `participants`: the SET of AIs that take an autonomous turn in a solo chat,
///    an active ai_window, or an invited thread.
///
/// The protocol is generic over the AI element (`associatedtype AI`) so it can
/// live here in PQRCAgent while the concrete element (`TetheredAI`) lives in the
/// App layer. `DefaultAISelectionPolicy` reproduces today's behavior EXACTLY.
///
/// A future policy can route by task: e.g. send a code/dev request to the paired
/// Mac ("acp") backend while keeping casual chat on the on-device model, or pick a
/// different participation set per conversation/thread. `participants` is handed
/// the `conversationID` and optional `threadID` precisely so such a policy can
/// route on scope — the default policy ignores them (today's behavior).
public protocol AISelectionPolicy<AI>: Sendable {
    associatedtype AI: AISelectionCandidate

    /// The primary AI for a private draft (or the Settings probe). `conversationID`
    /// + `threadID` (nil for the probe or a conversation-scope draft) let a policy
    /// route the draft ENGINE by scope — e.g. a coding conversation drafts with the
    /// paired `acp` node while ordinary chat stays on-device. The default policy
    /// ignores them. nil only when there are no AIs at all (the runtime keeps at
    /// least one, so the draft path never sees nil — but the contract is honest).
    func primary(from ais: [AI], conversationID: String, threadID: String?) -> AI?

    /// The AIs that take an autonomous turn for this scope. `conversationID` and
    /// `threadID` (nil for a conversation-scope/window turn) let a future policy
    /// route by scope; the default policy ignores them.
    func participants(from ais: [AI], conversationID: String, threadID: String?) -> [AI]
}

/// The default routing policy: EXACTLY today's behavior.
///  - `primary` = the first AI (`ais.first` — was `ais[0]`).
///  - `participants` = the `participatesAutonomously`-filtered set, ignoring
///    `conversationID`/`threadID` (the runtime used the same flat filter at every
///    window/thread/solo turn).
public struct DefaultAISelectionPolicy<AI: AISelectionCandidate>: AISelectionPolicy {
    public init() {}

    public func primary(from ais: [AI], conversationID: String, threadID: String?) -> AI? {
        ais.first
    }

    public func participants(
        from ais: [AI], conversationID: String, threadID: String?
    ) -> [AI] {
        ais.filter { $0.participatesAutonomously }
    }
}

/// Intelligent task routing (ACPRouterplan Phase 3 — "task-type → engine is a
/// policy swap"): route a draft or an autonomous turn to an AI whose declared
/// `routingCapabilities` cover what a scope REQUIRES — e.g. a coding request in a
/// paired-dev conversation goes to the `acp` Mac node, while ordinary chat stays on
/// the on-device model.
///
/// **Privacy (SPEC §0): routing is decided ONLY from explicit signals** — each AI's
/// declared capabilities, and a scope→requirement classifier the host supplies
/// (e.g. backed by "is this conversation a `coding_agent` node?"). It NEVER inspects
/// message CONTENT to infer a task type (that would mean reading plaintext to make a
/// routing call). It is deterministic and degrades safely: when no tethered AI
/// matches a scope's requirement it falls back to the default choice (first /
/// all-autonomous), so a request is never stranded for want of a perfect engine.
///
/// Drop-in `AISelectionPolicy`: swap it in via
/// `PersonaRuntime.setAISelectionPolicy(_:)`. The runtime default stays
/// `DefaultAISelectionPolicy`, so behavior is unchanged until a host opts in.
public struct CapabilityRoutingPolicy<AI: AISelectionCandidate>: AISelectionPolicy {
    /// Maps a scope (conversation + optional thread) to the capabilities a routed
    /// AI should have. An empty result means "no preference for this scope" ⇒
    /// default behavior. Supplied by the host so the policy stays pure and
    /// content-blind — it is given the requirement, it never derives one.
    private let requirement:
        @Sendable (_ conversationID: String, _ threadID: String?) -> Set<String>

    public init(
        requirement: @escaping @Sendable (_ conversationID: String, _ threadID: String?) -> Set<String>
    ) {
        self.requirement = requirement
    }

    /// Convenience: route by a static map of `conversationID → required
    /// capabilities` (e.g. the host's snapshot of which conversations are coding
    /// nodes). Thread scope inherits its conversation's requirement.
    public init(byConversation map: [String: Set<String>]) {
        self.requirement = { conversationID, _ in map[conversationID] ?? [] }
    }

    public func primary(from ais: [AI], conversationID: String, threadID: String?) -> AI? {
        let required = requirement(conversationID, threadID)
        if !required.isEmpty,
            let match = ais.first(where: { $0.routingCapabilities.isSuperset(of: required) })
        {
            return match
        }
        // No requirement for this scope, or nothing tethered satisfies it → the
        // default primary (first), so a draft always has an engine.
        return ais.first
    }

    public func participants(from ais: [AI], conversationID: String, threadID: String?) -> [AI] {
        let autonomous = ais.filter { $0.participatesAutonomously }
        let required = requirement(conversationID, threadID)
        guard !required.isEmpty else { return autonomous }
        let matching = autonomous.filter { $0.routingCapabilities.isSuperset(of: required) }
        // Prefer the capable subset, but never strand a scope with zero
        // participants when none match — fall back to the full autonomous set.
        return matching.isEmpty ? autonomous : matching
    }
}
