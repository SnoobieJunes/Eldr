import Foundation

/// A no-network "simulated AI" for demos and for any time a real brain isn't
/// configured (APP-SPEC §9). It performs no inference, but it now responds
/// *conversationally* — acknowledging the latest message and naming the context
/// it can see — so the end-to-end AI pipeline (window gating, agent bubbles,
/// thread turns, context sharing) reads like a real assistant chat instead of a
/// raw transcript dump. This is what a tester sees before/without Apple
/// Intelligence, so it should showcase the product, not expose plumbing.
///
/// Unlike `MockAgentProvider` (deterministic fixtures for the test suite), this
/// is eager by construction: when the engine authorizes a turn, it always
/// speaks. Output is BOUNDED (one short reply, never the whole transcript) so
/// rapid AI-to-AI exchanges can't balloon a message turn-over-turn.
public struct DemoAgentProvider: AgentProvider {
    public init() {}

    public func draftReply(context: AgentContext) async throws -> Draft {
        Draft(text: Self.reply(to: context, inThread: false))
    }

    public func threadTurn(context: AgentContext) async throws -> AgentTurn? {
        // Eager: the engine's window/invite gate is what enforces silence, so a
        // demo turn that reaches here is already authorized to speak.
        AgentTurn(messages: [AgentMessage(text: Self.reply(to: context, inThread: true))])
    }

    /// A short, conversational simulated reply. Reacts to the most recent
    /// HUMAN message, and — when a grant has shared a peer's marked context —
    /// shows that it's using it, so the context-sharing path is observable
    /// without dumping the transcript. Always one or two sentences.
    static func reply(to context: AgentContext, inThread: Bool) -> String {
        let last = context.transcript.last
        let lastHuman = context.transcript.last { $0.participantType == .human }
        let shared = context.transcript.filter(\.isSharedContext)
        let marked = context.transcript.filter { $0.isContext && !$0.isSharedContext }

        var note = ""
        if let s = shared.first {
            note = " Using \(s.senderDisplayName)'s shared context"
                + (shared.count > 1 ? " (+\(shared.count - 1) more)" : "") + "."
        } else if let m = marked.first {
            note = " Noting your saved context: “\(snippet(m.text))”."
        }

        let preface = inThread ? "🤖 (demo AI)" : "🤖 Demo AI"
        // If the most recent message came from ANOTHER AI, build on it. This is
        // how two tethered AIs visibly talk to each other: each one runs after
        // the previous posted, sees it as the latest entry, and responds to it
        // (instead of every AI answering only the human).
        if let last, last.participantType == .agent {
            return "\(preface): Building on the other AI's take — “\(snippet(last.text))”. Here's a second angle to add.\(note)"
        }
        guard let human = lastHuman else {
            return "\(preface): I'm your simulated assistant — set up Apple Intelligence or an API key in Settings ▸ AI for real replies. What can I help with?"
        }
        if inThread {
            return "\(preface): On “\(snippet(human.text))” — happy to coordinate with the other AIs here.\(note)"
        }
        return "\(preface): Re “\(snippet(human.text))” — here's a simulated take; add a real provider in Settings ▸ AI for genuine answers.\(note)"
    }

    /// First ~80 chars on one line, so the reply stays short and never echoes a
    /// giant paste back (bounding turn-over-turn growth).
    private static func snippet(_ text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return oneLine.count > 80 ? String(oneLine.prefix(80)) + "…" : oneLine
    }
}
