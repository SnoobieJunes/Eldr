import Foundation
import Testing

@testable import PQRCAgent

/// Stand-in for the App-layer `TetheredAI`: the minimal `AISelectionCandidate` the
/// default policy operates on. The App's `TetheredAI` conforms identically (it
/// already has `participatesAutonomously`); this lets the package test the policy
/// without depending on the App target.
private struct FakeAI: AISelectionCandidate, Equatable {
    let id: String
    let participatesAutonomously: Bool
    var routingCapabilities: Set<String> = []
}

@Suite("Default AI selection policy")
struct AISelectionPolicyTests {
    private let policy = DefaultAISelectionPolicy<FakeAI>()

    /// `primary` is the FIRST AI — exactly the old `ais[0]`.
    @Test func primary_isFirst() {
        let ais = [
            FakeAI(id: "a", participatesAutonomously: true),
            FakeAI(id: "b", participatesAutonomously: true),
            FakeAI(id: "c", participatesAutonomously: false),
        ]
        #expect(policy.primary(from: ais, conversationID: "c", threadID: nil) == ais[0])
        #expect(policy.primary(from: ais, conversationID: "c", threadID: nil)?.id == "a")
    }

    /// `participants` is the `participatesAutonomously`-filtered set, in order,
    /// independent of the conversation/thread scope (the default ignores it).
    @Test func participants_areTheAutonomousFilteredSet() {
        let ais = [
            FakeAI(id: "a", participatesAutonomously: true),
            FakeAI(id: "b", participatesAutonomously: false),  // draft-only / off
            FakeAI(id: "c", participatesAutonomously: true),
        ]
        let convScope = policy.participants(from: ais, conversationID: "conv-1", threadID: nil)
        #expect(convScope.map(\.id) == ["a", "c"])
        // Scope is ignored by the default policy: a thread scope yields the same set.
        let threadScope = policy.participants(from: ais, conversationID: "conv-1", threadID: "t-9")
        #expect(threadScope == convScope)
    }

    /// Empty input → nil primary and an empty participation set (no crash on `[0]`).
    @Test func emptyInput_nilPrimary_emptyParticipants() {
        let none: [FakeAI] = []
        #expect(policy.primary(from: none, conversationID: "x", threadID: nil) == nil)
        #expect(policy.participants(from: none, conversationID: "x", threadID: nil).isEmpty)
    }
}

@Suite("Capability routing policy (task-type → engine)")
struct CapabilityRoutingPolicyTests {
    private let chat = FakeAI(id: "chat", participatesAutonomously: true)  // no caps
    private let mac = FakeAI(
        id: "mac", participatesAutonomously: true, routingCapabilities: ["code"])

    /// A coding-scope requirement routes the PRIMARY (the draft engine) to the
    /// code-capable AI even though it isn't first; a non-coding scope has no
    /// requirement and gets the default (first).
    @Test func primary_routesToCapableEngine_forCodingScope() {
        let policy = CapabilityRoutingPolicy<FakeAI>(byConversation: ["mac-node": ["code"]])
        let ais = [chat, mac]
        #expect(policy.primary(from: ais, conversationID: "mac-node", threadID: nil)?.id == "mac")
        #expect(policy.primary(from: ais, conversationID: "buddy", threadID: nil)?.id == "chat")
    }

    /// When nothing tethered satisfies the requirement, primary falls back to the
    /// first AI — a draft always has an engine (never nil for a non-empty set).
    @Test func primary_fallsBackToFirst_whenNoEngineMatches() {
        let policy = CapabilityRoutingPolicy<FakeAI>(byConversation: ["mac-node": ["code"]])
        let onlyChat = [chat, FakeAI(id: "chat2", participatesAutonomously: true)]
        #expect(
            policy.primary(from: onlyChat, conversationID: "mac-node", threadID: nil)?.id == "chat")
    }

    /// In a coding scope the autonomous PARTICIPANT set narrows to the code-capable
    /// AIs (the routing); elsewhere it is the usual autonomous set.
    @Test func participants_narrowToCapable_inCodingScope() {
        let policy = CapabilityRoutingPolicy<FakeAI>(byConversation: ["mac-node": ["code"]])
        let ais = [chat, mac]
        #expect(
            policy.participants(from: ais, conversationID: "mac-node", threadID: nil).map(\.id)
                == ["mac"])
        #expect(
            policy.participants(from: ais, conversationID: "buddy", threadID: nil).map(\.id)
                == ["chat", "mac"])
    }

    /// A code-capable but "draft-only" AI is not an autonomous participant, so a
    /// coding scope with no capable AUTONOMOUS AI falls back to the full autonomous
    /// set rather than stranding the turn with zero participants.
    @Test func participants_fallBack_whenCapableIsNotAutonomous() {
        let policy = CapabilityRoutingPolicy<FakeAI>(byConversation: ["mac-node": ["code"]])
        let draftOnlyMac = FakeAI(
            id: "mac", participatesAutonomously: false, routingCapabilities: ["code"])
        let result = policy.participants(
            from: [chat, draftOnlyMac], conversationID: "mac-node", threadID: nil)
        #expect(result.map(\.id) == ["chat"])
    }

    /// The closure initializer can route on THREAD scope too.
    @Test func requirementClosure_canRouteByThread() {
        let policy = CapabilityRoutingPolicy<FakeAI>(requirement: { _, threadID in
            threadID == "code-thread" ? ["code"] : []
        })
        let ais = [chat, mac]
        #expect(policy.primary(from: ais, conversationID: "x", threadID: "code-thread")?.id == "mac")
        #expect(policy.primary(from: ais, conversationID: "x", threadID: nil)?.id == "chat")
    }

    /// The optional ordered-critique API is OFF for the existing policies — they
    /// inherit the protocol default (`nil`), so today's behavior is unchanged.
    @Test func existingPolicies_critiqueTurn_isNil() {
        let ais = [
            FakeAI(id: "a", participatesAutonomously: true),
            FakeAI(id: "b", participatesAutonomously: true),
        ]
        #expect(
            DefaultAISelectionPolicy<FakeAI>().critiqueTurn(
                from: ais, conversationID: "c", threadID: nil) == nil)
        #expect(
            CapabilityRoutingPolicy<FakeAI>(byConversation: [:]).critiqueTurn(
                from: ais, conversationID: "c", threadID: nil) == nil)
    }
}

@Suite("Ordered critique policy (multi-AI turn-taking)")
struct OrderedCritiquePolicyTests {
    private let policy = OrderedCritiquePolicy<FakeAI>()

    /// N=2: first is the "primary", the last is the "synthesizer".
    @Test func critiqueTurn_two_primaryThenSynthesizer() {
        let ais = [
            FakeAI(id: "a", participatesAutonomously: true),
            FakeAI(id: "b", participatesAutonomously: true),
        ]
        let turn = policy.critiqueTurn(from: ais, conversationID: "c", threadID: "t")
        #expect(turn?.map { $0.ai.id } == ["a", "b"])
        #expect(turn?.map { $0.role } == ["primary", "synthesizer"])
    }

    /// N=3: primary → reviewer → synthesizer, in stable input order.
    @Test func critiqueTurn_three_primaryReviewerSynthesizer() {
        let ais = [
            FakeAI(id: "a", participatesAutonomously: true),
            FakeAI(id: "b", participatesAutonomously: true),
            FakeAI(id: "c", participatesAutonomously: true),
        ]
        let turn = policy.critiqueTurn(from: ais, conversationID: "c", threadID: "t")
        #expect(turn?.map { $0.ai.id } == ["a", "b", "c"])
        #expect(turn?.map { $0.role } == ["primary", "reviewer", "synthesizer"])
    }

    /// N=4: the middle slots alternate "reviewer" then "critic".
    @Test func critiqueTurn_four_middleAlternatesReviewerCritic() {
        let ais = (0..<4).map { FakeAI(id: "ai\($0)", participatesAutonomously: true) }
        let turn = policy.critiqueTurn(from: ais, conversationID: "c", threadID: "t")
        #expect(turn?.map { $0.role } == ["primary", "reviewer", "critic", "synthesizer"])
    }

    /// A single autonomous AI is just the "primary" (no critique partners).
    @Test func critiqueTurn_one_isPrimary() {
        let solo = [FakeAI(id: "only", participatesAutonomously: true)]
        let turn = policy.critiqueTurn(from: solo, conversationID: "c", threadID: "t")
        #expect(turn?.map { $0.role } == ["primary"])
    }

    /// Non-autonomous (draft-only / off) AIs are excluded; the remaining order and
    /// the role assignment are unaffected by the gaps.
    @Test func critiqueTurn_excludesNonAutonomous_keepsOrder() {
        let ais = [
            FakeAI(id: "a", participatesAutonomously: true),
            FakeAI(id: "draft", participatesAutonomously: false),
            FakeAI(id: "b", participatesAutonomously: true),
            FakeAI(id: "c", participatesAutonomously: true),
        ]
        let turn = policy.critiqueTurn(from: ais, conversationID: "c", threadID: "t")
        #expect(turn?.map { $0.ai.id } == ["a", "b", "c"])
        #expect(turn?.map { $0.role } == ["primary", "reviewer", "synthesizer"])
    }

    /// No autonomous AI ⇒ a non-nil but empty ordered set (the policy is still
    /// "driving"; there is simply no one to run).
    @Test func critiqueTurn_noAutonomous_isEmptyNotNil() {
        let ais = [FakeAI(id: "off", participatesAutonomously: false)]
        let turn = policy.critiqueTurn(from: ais, conversationID: "c", threadID: "t")
        #expect(turn != nil)
        #expect(turn?.isEmpty == true)
    }

    /// `participants` / `primary` keep the same MEMBERSHIP as the default policy
    /// (the autonomous set, in order), so a host that ignores `critiqueTurn` still
    /// gets the right AIs.
    @Test func participantsAndPrimary_matchAutonomousSet() {
        let ais = [
            FakeAI(id: "a", participatesAutonomously: true),
            FakeAI(id: "off", participatesAutonomously: false),
            FakeAI(id: "b", participatesAutonomously: true),
        ]
        #expect(
            policy.participants(from: ais, conversationID: "c", threadID: nil).map(\.id) == ["a", "b"])
        #expect(policy.primary(from: ais, conversationID: "c", threadID: nil)?.id == "a")
    }
}

@Suite("Conversation roster policy (per-chat membership + order)")
struct ConversationRosterPolicyTests {
    private func ai(_ id: String, _ auto: Bool = true) -> FakeAI {
        FakeAI(id: id, participatesAutonomously: auto)
    }
    private func policy(
        base: any AISelectionPolicy<FakeAI> = DefaultAISelectionPolicy<FakeAI>(),
        _ roster: @escaping @Sendable (String, String?) -> [String]?
    ) -> ConversationRosterPolicy<FakeAI> {
        ConversationRosterPolicy(aiID: { $0.id }, roster: roster, base: base)
    }

    /// nil roster ⇒ pass-through (today's behavior; the "all my AIs" default).
    @Test func nilRoster_passesThrough() {
        let p = policy { _, _ in nil }
        let ais = [ai("a"), ai("b"), ai("c")]
        #expect(
            p.participants(from: ais, conversationID: "c", threadID: nil).map(\.id) == ["a", "b", "c"])
        #expect(p.primary(from: ais, conversationID: "c", threadID: nil)?.id == "a")
    }

    /// [] ⇒ no participants (silence every AI in this chat).
    @Test func emptyRoster_silencesAll() {
        let p = policy { _, _ in [] }
        #expect(p.participants(from: [ai("a"), ai("b")], conversationID: "c", threadID: nil).isEmpty)
    }

    /// A roster filters to membership AND imposes order (reordering the input).
    @Test func roster_filtersAndReorders() {
        let p = policy { _, _ in ["c", "a"] }
        let ais = [ai("a"), ai("b"), ai("c")]
        #expect(p.participants(from: ais, conversationID: "x", threadID: nil).map(\.id) == ["c", "a"])
        #expect(p.primary(from: ais, conversationID: "x", threadID: nil)?.id == "c")
    }

    /// Unknown/removed ids in the roster are skipped (an AI the user deleted).
    @Test func roster_skipsUnknownIDs() {
        let p = policy { _, _ in ["ghost", "b"] }
        #expect(
            p.participants(from: [ai("a"), ai("b")], conversationID: "x", threadID: nil).map(\.id)
                == ["b"])
    }

    /// Roster order drives the ordered-critique sequence through the wrapped base.
    @Test func roster_drivesCritiqueOrder() {
        let p = policy(base: OrderedCritiquePolicy<FakeAI>()) { _, _ in ["c", "a", "b"] }
        let ais = [ai("a"), ai("b"), ai("c")]
        let turn = p.critiqueTurn(from: ais, conversationID: "x", threadID: "t")
        #expect(turn?.map { $0.ai.id } == ["c", "a", "b"])
        #expect(turn?.map { $0.role } == ["primary", "reviewer", "synthesizer"])
    }

    /// Thread scope is routed independently of conversation scope.
    @Test func roster_perScope() {
        let p = policy { _, threadID in threadID == "t1" ? ["b"] : ["a"] }
        let ais = [ai("a"), ai("b")]
        #expect(p.participants(from: ais, conversationID: "c", threadID: nil).map(\.id) == ["a"])
        #expect(p.participants(from: ais, conversationID: "c", threadID: "t1").map(\.id) == ["b"])
    }
}
