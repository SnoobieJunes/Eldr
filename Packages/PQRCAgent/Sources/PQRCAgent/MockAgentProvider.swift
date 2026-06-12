import Foundation

/// Deterministic, scriptable provider for tests and the Local Universe demo.
///
/// `eager` mode always wants to speak — used to prove the engine's
/// silent-by-default gate suppresses provider enthusiasm, not relies on it.
public actor MockAgentProvider: AgentProvider {
    public struct Script: Sendable {
        public var draft: String
        public var threadTurns: [AgentTurn?]

        public init(draft: String = "Here's a draft reply.", threadTurns: [AgentTurn?] = []) {
            self.draft = draft
            self.threadTurns = threadTurns
        }
    }

    private var script: Script
    private let eager: Bool
    private var turnIndex = 0
    public private(set) var draftCalls = 0
    public private(set) var threadTurnCalls = 0

    public init(script: Script = Script(), eager: Bool = false) {
        self.script = script
        self.eager = eager
    }

    public func draftReply(context: AgentContext) async throws -> Draft {
        draftCalls += 1
        if let last = context.transcript.last {
            return Draft(text: "\(script.draft) (re: \(last.text.prefix(24)))")
        }
        return Draft(text: script.draft)
    }

    public func threadTurn(context: AgentContext) async throws -> AgentTurn? {
        threadTurnCalls += 1
        if turnIndex < script.threadTurns.count {
            let turn = script.threadTurns[turnIndex]
            turnIndex += 1
            return turn
        }
        if eager {
            return AgentTurn(messages: [
                AgentMessage(text: "eager turn #\(threadTurnCalls)")
            ])
        }
        return nil
    }
}
