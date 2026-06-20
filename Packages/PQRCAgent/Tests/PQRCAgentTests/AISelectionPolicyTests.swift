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
        #expect(policy.primary(from: ais) == ais[0])
        #expect(policy.primary(from: ais)?.id == "a")
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
        #expect(policy.primary(from: none) == nil)
        #expect(policy.participants(from: none, conversationID: "x", threadID: nil).isEmpty)
    }
}
