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

    /// OPTIONAL ordered, role-tagged turn-taking for a bounded multi-AI critique
    /// loop in a thread (plan C3). Returns the autonomous participants in a stable
    /// order, each tagged with a role (e.g. "primary" → "reviewer"/"critic" → … →
    /// "synthesizer") so the host can run them in sequence — each AI rebuilding
    /// context so it sees the prior AIs' messages — and re-run the set for a
    /// bounded number of rounds (terminated by the C1 loop guard).
    ///
    /// `nil` (the default in the protocol extension below) means "this policy does
    /// NOT do ordered critique — use `participants(from:)` exactly as today", so
    /// `DefaultAISelectionPolicy` and `CapabilityRoutingPolicy` are unaffected. A
    /// non-nil result — even an empty array — means the policy is driving the turn
    /// order explicitly. Like `participants`, the result is content-blind: it is
    /// derived only from the candidate set and the scope, never from message text
    /// (SPEC §0).
    func critiqueTurn(
        from ais: [AI], conversationID: String, threadID: String?
    ) -> [(ai: AI, role: String)]?
}

public extension AISelectionPolicy {
    /// Default: no ordered critique. Existing policies inherit this and keep
    /// today's behavior; the host falls back to `participants(from:)`.
    func critiqueTurn(
        from ais: [AI], conversationID: String, threadID: String?
    ) -> [(ai: AI, role: String)]? { nil }
}

/// The role tags `OrderedCritiquePolicy` emits for a multi-AI critique turn, and
/// the values `AgentSkills.threadSystemPrompt(aiRole:)` recognizes for
/// role-specific prompt guidance. One source of truth so the selection policy and
/// the prompt builder agree on the exact spelling.
public enum AICritiqueRole {
    /// The first AI: produces the initial answer. Also the default role — no extra
    /// prompt guidance is injected for it (today's behavior).
    public static let primary = "primary"
    /// A middle AI: critiques the prior answer rather than re-solving.
    public static let reviewer = "reviewer"
    /// A middle AI: stress-tests the prior answers (objections, edge cases).
    public static let critic = "critic"
    /// The last AI: merges the prior answers into one converged result.
    public static let synthesizer = "synthesizer"
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

/// Ordered, role-tagged multi-AI turn-taking for a bounded critique loop in a
/// thread (plan C3): the autonomous participants run in a stable sequence —
/// primary → reviewer/critic(s) → synthesizer — each one rebuilding context so it
/// sees the prior AIs' messages, so a primary answer can be reviewed and then
/// merged. The host re-runs the ordered set for a bounded number of rounds; the
/// C1 loop guard terminates it.
///
/// **Privacy (SPEC §0): content-blind.** Order and roles are derived ONLY from the
/// candidate set (its stable input order) and its size — never from message text.
/// The policy reads no plaintext to make a routing/ordering call. Deterministic and
/// `Sendable`.
///
/// Drop-in `AISelectionPolicy`: swap it in via
/// `PersonaRuntime.setAISelectionPolicy(_:)`. `participants`/`primary` keep the same
/// MEMBERSHIP as `DefaultAISelectionPolicy` (the autonomous set), so a host that
/// ignores the `critiqueTurn` API still behaves; the ordering/roles live in
/// `critiqueTurn`.
public struct OrderedCritiquePolicy<AI: AISelectionCandidate>: AISelectionPolicy {
    public init() {}

    /// The primary AI for a private draft: the first autonomous AI (the one tagged
    /// "primary" in the critique order), or — if none participate autonomously —
    /// the first AI, so a draft always has an engine. Mirrors today's contract
    /// (never nil for a non-empty set).
    public func primary(from ais: [AI], conversationID: String, threadID: String?) -> AI? {
        autonomous(from: ais).first ?? ais.first
    }

    /// The autonomous set, in stable input order — identical MEMBERSHIP to the
    /// default policy. (Ordering and roles are carried by `critiqueTurn`.)
    public func participants(from ais: [AI], conversationID: String, threadID: String?) -> [AI] {
        autonomous(from: ais)
    }

    /// The ordered, role-tagged critique turn: the autonomous participants in their
    /// stable input order — first = "primary", last = "synthesizer", middle =
    /// alternating "reviewer"/"critic". Always non-nil for this policy (an empty
    /// array when no AI participates autonomously). Content-blind.
    public func critiqueTurn(
        from ais: [AI], conversationID: String, threadID: String?
    ) -> [(ai: AI, role: String)]? {
        let ordered = autonomous(from: ais)
        let count = ordered.count
        return ordered.enumerated().map { index, ai in
            (ai: ai, role: Self.role(at: index, of: count))
        }
    }

    /// Deterministic, content-blind role assignment for `count` participants:
    ///  - 0 or 1 → "primary"
    ///  - first → "primary", last → "synthesizer"
    ///  - middle slots → "reviewer" / "critic", alternating from the second slot
    ///    (slot 1 = reviewer, slot 2 = critic, slot 3 = reviewer, …)
    static func role(at index: Int, of count: Int) -> String {
        guard count > 1 else { return AICritiqueRole.primary }
        if index == 0 { return AICritiqueRole.primary }
        if index == count - 1 { return AICritiqueRole.synthesizer }
        return index % 2 == 1 ? AICritiqueRole.reviewer : AICritiqueRole.critic
    }

    private func autonomous(from ais: [AI]) -> [AI] {
        ais.filter { $0.participatesAutonomously }
    }
}

/// Composes capability routing (WHO answers) with optional ordered critique (the
/// ORDER + roles), per plan C4. `primary`/`participants` defer to the wrapped
/// `CapabilityRoutingPolicy` (so coding scopes still route to the Mac node); when the
/// host flags a scope as "ordered critique", `critiqueTurn` returns the
/// capability-selected participants in the `OrderedCritiquePolicy` order/roles,
/// otherwise nil (the runtime then runs them flat — unchanged behavior). This lets the
/// app's auto coding-node map AND the user's per-conversation "AIs reply in order"
/// toggle coexist in the single `aiSelection` slot. Content-blind, `Sendable`.
public struct CompositeAISelectionPolicy<AI: AISelectionCandidate>: AISelectionPolicy {
    private let base: CapabilityRoutingPolicy<AI>
    private let orderedScope: @Sendable (_ conversationID: String, _ threadID: String?) -> Bool

    public init(
        base: CapabilityRoutingPolicy<AI>,
        orderedScope: @escaping @Sendable (_ conversationID: String, _ threadID: String?) -> Bool
    ) {
        self.base = base
        self.orderedScope = orderedScope
    }

    public func primary(from ais: [AI], conversationID: String, threadID: String?) -> AI? {
        base.primary(from: ais, conversationID: conversationID, threadID: threadID)
    }

    public func participants(from ais: [AI], conversationID: String, threadID: String?) -> [AI] {
        base.participants(from: ais, conversationID: conversationID, threadID: threadID)
    }

    public func critiqueTurn(
        from ais: [AI], conversationID: String, threadID: String?
    ) -> [(ai: AI, role: String)]? {
        guard orderedScope(conversationID, threadID) else { return nil }
        // Order/role the capability-selected participants for this scope.
        let parts = base.participants(from: ais, conversationID: conversationID, threadID: threadID)
        return OrderedCritiquePolicy<AI>().critiqueTurn(
            from: parts, conversationID: conversationID, threadID: threadID)
    }
}

/// Per-conversation roster MEMBERSHIP and ORDER (features 4 & 5). The user picks
/// which of their tethered AIs participate in a given chat — and in what order —
/// in the per-AI hub; that choice is the SOLE source of both the participation set
/// and the reply order. This policy restricts + reorders the candidate set to the
/// scope's roster, then delegates `primary`/`participants`/`critiqueTurn` to a
/// wrapped `base` policy so capability routing and ordered-critique roles still
/// apply to the rostered subset.
///
/// Roster semantics (host supplies the closure, typically reading
/// `AppSession.conversationAIRoster`):
///  - `nil`   ⇒ no roster set for this scope: pass the full candidate set through
///              UNCHANGED — today's behavior and the D1 "all my AIs in config
///              order" default. A host that never sets a roster behaves exactly as
///              before.
///  - `[]`    ⇒ silence: NO AI participates in this scope.
///  - `[ids]` ⇒ exactly these AIs, in THIS order; ids not present in the candidate
///              set (an AI the user removed) are skipped.
///
/// Content-blind (derives only from the scope + the stored roster, never message
/// text — SPEC §0) and `Sendable`. Drop-in via `PersonaRuntime.setAISelectionPolicy`.
public struct ConversationRosterPolicy<AI: AISelectionCandidate>: AISelectionPolicy {
    private let aiID: @Sendable (AI) -> String
    private let roster: @Sendable (_ conversationID: String, _ threadID: String?) -> [String]?
    private let base: any AISelectionPolicy<AI>

    public init(
        aiID: @escaping @Sendable (AI) -> String,
        roster: @escaping @Sendable (_ conversationID: String, _ threadID: String?) -> [String]?,
        base: any AISelectionPolicy<AI>
    ) {
        self.aiID = aiID
        self.roster = roster
        self.base = base
    }

    /// The candidate set restricted to — and reordered by — this scope's roster.
    /// A `nil` roster returns the input unchanged.
    private func rostered(_ ais: [AI], _ conversationID: String, _ threadID: String?) -> [AI] {
        guard let ids = roster(conversationID, threadID) else { return ais }
        let byID = Dictionary(ais.map { (aiID($0), $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    public func primary(from ais: [AI], conversationID: String, threadID: String?) -> AI? {
        base.primary(
            from: rostered(ais, conversationID, threadID),
            conversationID: conversationID, threadID: threadID)
    }

    public func participants(from ais: [AI], conversationID: String, threadID: String?) -> [AI] {
        base.participants(
            from: rostered(ais, conversationID, threadID),
            conversationID: conversationID, threadID: threadID)
    }

    public func critiqueTurn(
        from ais: [AI], conversationID: String, threadID: String?
    ) -> [(ai: AI, role: String)]? {
        base.critiqueTurn(
            from: rostered(ais, conversationID, threadID),
            conversationID: conversationID, threadID: threadID)
    }
}
