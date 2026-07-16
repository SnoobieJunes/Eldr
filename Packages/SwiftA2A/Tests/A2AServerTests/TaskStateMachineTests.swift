import Testing

@testable import A2ACore
@testable import A2AServer

// Exhaustive legality table for `TaskStateMachine.canTransition`, covering every
// ordered pair among the nine known `A2ATaskState` cases, plus a forward-compat
// check for the `.unknown` case.

@Suite struct TaskStateMachineTests {
    static let allStates: [A2ATaskState] = [
        .unspecified, .submitted, .working, .completed, .failed, .canceled,
        .inputRequired, .rejected, .authRequired,
    ]

    /// The legal `(from, to)` pairs per the documented rules in
    /// `TaskStateMachine.canTransition`'s doc comment. Anything not listed here is
    /// expected to be illegal.
    static let legalPairs: [(A2ATaskState, A2ATaskState)] = {
        var pairs: [(A2ATaskState, A2ATaskState)] = []
        for to in allStates {
            pairs.append((.unspecified, to))
        }
        let forwardFromActive: [A2ATaskState] = [
            .working, .inputRequired, .authRequired, .completed, .failed, .canceled,
            .rejected,
        ]
        for to in forwardFromActive {
            pairs.append((.submitted, to))
            pairs.append((.working, to))
        }
        let forwardFromInterrupted: [A2ATaskState] = [
            .working, .completed, .failed, .canceled, .rejected,
        ]
        for to in forwardFromInterrupted {
            pairs.append((.inputRequired, to))
            pairs.append((.authRequired, to))
        }
        return pairs
    }()

    private static func isDocumentedLegal(_ from: A2ATaskState, _ to: A2ATaskState) -> Bool {
        legalPairs.contains { $0.0 == from && $0.1 == to }
    }

    @Test func everyKnownPairMatchesTheDocumentedTable() {
        for from in Self.allStates {
            for to in Self.allStates {
                let expected = Self.isDocumentedLegal(from, to)
                let actual = TaskStateMachine.canTransition(from: from, to: to)
                #expect(actual == expected, "from \(from.wireName) to \(to.wireName)")
            }
        }
    }

    @Test func terminalStatesAcceptNoOutgoingTransition() {
        for from: A2ATaskState in [.completed, .failed, .canceled, .rejected] {
            for to in Self.allStates {
                #expect(!TaskStateMachine.canTransition(from: from, to: to))
            }
        }
    }

    @Test func repeatedWorkingIsExplicitlyLegal() {
        #expect(TaskStateMachine.canTransition(from: .working, to: .working))
    }

    @Test func submittedAndWorkingCannotGoBackToSubmitted() {
        #expect(!TaskStateMachine.canTransition(from: .submitted, to: .submitted))
        #expect(!TaskStateMachine.canTransition(from: .working, to: .submitted))
    }

    @Test func interruptedStatesCannotJumpToEachOther() {
        #expect(!TaskStateMachine.canTransition(from: .inputRequired, to: .authRequired))
        #expect(!TaskStateMachine.canTransition(from: .authRequired, to: .inputRequired))
        #expect(!TaskStateMachine.canTransition(from: .inputRequired, to: .inputRequired))
    }

    @Test func unspecifiedAllowsAnyOutgoingTransition() {
        for to in Self.allStates {
            #expect(TaskStateMachine.canTransition(from: .unspecified, to: to))
        }
    }

    @Test func unknownFromStateIsForwardCompatibleAndAllowsTransitions() {
        let unknown = A2ATaskState.unknown("TASK_STATE_FROM_THE_FUTURE")
        #expect(!unknown.isTerminal)
        for to in Self.allStates {
            #expect(TaskStateMachine.canTransition(from: unknown, to: to))
        }
    }
}
