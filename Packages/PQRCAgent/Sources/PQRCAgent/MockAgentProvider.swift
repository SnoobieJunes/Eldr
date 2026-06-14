import Foundation

/// Deterministic, scriptable provider for tests and the Local Universe demo.
///
/// `eager` mode always wants to speak — used to prove the engine's
/// silent-by-default gate suppresses provider enthusiasm, not relies on it.
///
/// For beta testing, the default reply is the pangram "The quick brown fox
/// jumped over the lazy dog", and every context entry the provider was handed
/// (agent contributions and grant-authorized shared context) is echoed back —
/// so the whole context pipeline is visible end-to-end without a real model.
public actor MockAgentProvider: AgentProvider {
    public static let defaultReply = "The quick brown fox jumped over the lazy dog"

    public struct Script: Sendable {
        public var draft: String
        public var threadTurns: [AgentTurn?]

        public init(draft: String = MockAgentProvider.defaultReply, threadTurns: [AgentTurn?] = []) {
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
        return Draft(text: script.draft + Self.contextEcho(context))
    }

    public func threadTurn(context: AgentContext) async throws -> AgentTurn? {
        threadTurnCalls += 1
        if turnIndex < script.threadTurns.count {
            let turn = script.threadTurns[turnIndex]
            turnIndex += 1
            return turn
        }
        // Silent by default (the engine gate is what enforces silence — see the
        // integrity suite); `eager` makes the mock always want to speak.
        if eager {
            return AgentTurn(messages: [
                AgentMessage(text: Self.defaultReply + Self.contextEcho(context))
            ])
        }
        return nil
    }

    /// Echoes every context entry the provider consumed, one per line, so tests
    /// and the beta demo can see exactly what context reached the model.
    static func contextEcho(_ context: AgentContext) -> String {
        let consumed = context.transcript.filter { $0.isContext || $0.isSharedContext }
        guard !consumed.isEmpty else { return "" }
        return "\n" + consumed.map { "• ctx: \($0.text)" }.joined(separator: "\n")
    }
}
