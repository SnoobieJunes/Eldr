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

    /// The primary AI for private drafts / the Settings probe. nil only when there
    /// are no AIs at all (the runtime always keeps at least one, so in practice the
    /// runtime's draft path never sees nil — but the contract is honest).
    func primary(from ais: [AI]) -> AI?

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

    public func primary(from ais: [AI]) -> AI? {
        ais.first
    }

    public func participants(
        from ais: [AI], conversationID: String, threadID: String?
    ) -> [AI] {
        ais.filter { $0.participatesAutonomously }
    }
}
