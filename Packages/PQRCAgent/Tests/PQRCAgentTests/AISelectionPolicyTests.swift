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
}
