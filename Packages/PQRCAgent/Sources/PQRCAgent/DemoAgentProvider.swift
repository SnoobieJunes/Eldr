import Foundation

/// A no-network "simulated AI" for demos and for any time a real brain isn't
/// configured (APP-SPEC §9). It performs no inference: it concatenates the
/// conversation context it was handed and emits that back as a single,
/// clearly-labelled simulated reply — so the end-to-end AI pipeline (window
/// gating, agent bubbles, thread turns) is visible without FoundationModels or
/// a paid API key.
///
/// Unlike `MockAgentProvider` (deterministic fixtures for the test suite), this
/// is eager by construction: when the engine authorizes a turn, it always
/// speaks, summarising everything it can see.
public struct DemoAgentProvider: AgentProvider {
    public init() {}

    public func draftReply(context: AgentContext) async throws -> Draft {
        Draft(text: Self.simulatedReply(context))
    }

    public func threadTurn(context: AgentContext) async throws -> AgentTurn? {
        // Eager: the engine's window/invite gate is what enforces silence, so a
        // demo turn that reaches here is already authorized to speak.
        AgentTurn(messages: [AgentMessage(text: Self.simulatedReply(context))])
    }

    /// Builds the simulated response by stitching the visible transcript
    /// together. Shared-context entries (peer messages a grant authorized) are
    /// folded in too, so the context-sharing path is observable end-to-end.
    static func simulatedReply(_ context: AgentContext) -> String {
        let lines = context.transcript.map { entry -> String in
            let role = entry.participantType == .agent
                ? "\(entry.senderDisplayName)'s AI"
                : entry.senderDisplayName
            let marker = entry.isSharedContext ? " (shared context)" : (entry.isContext ? " (context)" : "")
            return "• \(role)\(marker): \(entry.text)"
        }
        let scope = context.threadTitle.map { "thread “\($0)”" } ?? "this conversation"
        guard !lines.isEmpty else {
            return "🤖 Demo AI (simulated): nothing in \(scope) yet to summarise."
        }
        return """
            🤖 Demo AI (simulated) — recap of \(scope):
            \(lines.joined(separator: "\n"))
            """
    }
}
