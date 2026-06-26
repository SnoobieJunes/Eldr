import Foundation
import PQRCCore

/// One entry of decrypted conversation context handed to a provider.
/// Agents read plaintext on-device only (SPEC §13.1).
public struct TranscriptEntry: Sendable, Equatable {
    public let senderIdentityHex: String
    public let senderDisplayName: String
    public let participantType: ParticipantType
    public let text: String
    public let isContext: Bool
    /// True when this entry is another human's `ai_context`-marked message that
    /// the active grant authorizes my agent to consume as shared context. My own
    /// messages and agent contributions never set this.
    public let isSharedContext: Bool

    public init(
        senderIdentityHex: String, senderDisplayName: String,
        participantType: ParticipantType, text: String, isContext: Bool = false,
        isSharedContext: Bool = false
    ) {
        self.senderIdentityHex = senderIdentityHex
        self.senderDisplayName = senderDisplayName
        self.participantType = participantType
        self.text = text
        self.isContext = isContext
        self.isSharedContext = isSharedContext
    }
}

/// Everything a provider may see. Built on-device from decrypted state.
public struct AgentContext: Sendable {
    public let myIdentityHex: String
    public let myDisplayName: String
    public let transcript: [TranscriptEntry]
    /// Set when the turn is for an embedded thread.
    public let threadID: String?
    public let threadTitle: String?
    /// The user's custom system prompt for this AI (the "instructions" profile
    /// field) — and, by default, the ENTIRE system prompt. EldrChat is a conduit:
    /// nothing is prepended on the user's behalf. nil/empty → no system prompt at
    /// all (raw transcript only). The old hard-coded conventions (draft-only /
    /// PASS-to-stay-silent) are no longer auto-injected; they live as restorable
    /// constants (`defaultDraftInstructions` / `defaultThreadInstructions`) the
    /// user can drop into this field with one tap in Settings.
    public let instructions: String?
    /// When true, the AI should contribute a brief summary, not verbatim quotes
    /// (the "summarize" output mode — less content leaves the device).
    public let summarize: Bool
    /// A fully-composed system prompt that REPLACES the built-in one — used for
    /// shared-thread turns, where the runtime injects the PQRC guardrails + any
    /// pinned agent-skills (`AgentSkills.threadSystemPrompt`). nil → built-in.
    public let systemPromptOverride: String?

    public init(
        myIdentityHex: String, myDisplayName: String, transcript: [TranscriptEntry],
        threadID: String? = nil, threadTitle: String? = nil,
        instructions: String? = nil, summarize: Bool = false, systemPromptOverride: String? = nil
    ) {
        self.myIdentityHex = myIdentityHex
        self.myDisplayName = myDisplayName
        self.transcript = transcript
        self.threadID = threadID
        self.threadTitle = threadTitle
        self.instructions = instructions
        self.summarize = summarize
        self.systemPromptOverride = systemPromptOverride
    }

    /// The built-in EldrChat draft instructions — NOT injected by default. Offered
    /// as a one-tap "restore default" in Settings so the old behavior is reachable.
    public static let defaultDraftInstructions =
        "Draft brief, natural message replies for me. Reply with the draft text only."
    /// The built-in EldrChat shared-thread instructions — NOT injected by default.
    public static let defaultThreadInstructions =
        "You are my AI in a shared thread with another person's AI. Contribute one short "
        + "useful message, or reply exactly PASS to stay silent."

    /// System prompt for a private draft. EldrChat is a conduit: the user's
    /// `instructions` ARE the system prompt — nothing is prepended on their behalf.
    /// Empty instructions → empty system prompt (raw transcript only). The only
    /// non-user text is the summarize note, which the user opted into via the
    /// "summarize" output mode (a selected behavior, not chaff).
    public func draftSystemPrompt() -> String {
        var parts: [String] = []
        if let instructions, !instructions.isEmpty { parts.append(instructions) }
        if summarize { parts.append("Prefer a concise summary over verbatim quoting.") }
        return parts.joined(separator: "\n\n")
    }

    /// System prompt for a shared-thread / window turn. A `systemPromptOverride`
    /// (the runtime's composed guardrails + skills, kept for ordinary multi-AI
    /// threads) wins. Otherwise, same conduit rule as `draftSystemPrompt()`:
    /// user instructions only, empty by default.
    public func turnSystemPrompt() -> String {
        if let systemPromptOverride { return systemPromptOverride }
        var parts: [String] = []
        if let instructions, !instructions.isEmpty { parts.append(instructions) }
        if summarize {
            parts.append(
                "Share a brief summary of the relevant context rather than quoting it verbatim.")
        }
        return parts.joined(separator: "\n\n")
    }
}

/// OpenAI-style chat `messages` for a single turn, OMITTING the system role
/// entirely when the system prompt is empty/whitespace. EldrChat's conduit
/// default sends no system prompt, and a stray empty `{"role":"system"}` is
/// chaff some strict local servers (LM Studio / vLLM) reject — so drop it.
func openAIChatMessages(system: String, user: String) -> [[String: String]] {
    var messages: [[String: String]] = []
    if !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        messages.append(["role": "system", "content": system])
    }
    messages.append(["role": "user", "content": user])
    return messages
}

/// A private draft for the provider's own human. Never sent autonomously.
public struct Draft: Sendable, Equatable {
    public let text: String
    public init(text: String) { self.text = text }
}

/// One message an agent wants to post. "Context:"-prefixed contributions are
/// marked so they render with the folder glyph (APP-SPEC §8).
public struct AgentMessage: Sendable, Equatable {
    public let text: String
    public let isContext: Bool

    public init(text: String, isContext: Bool = false) {
        self.text = text
        self.isContext = isContext
    }
}

/// Zero or more messages — the ONLY way agent output enters the world
/// (the recording guarantee, APP-SPEC §8 rule 3).
public struct AgentTurn: Sendable, Equatable {
    public let messages: [AgentMessage]
    public init(messages: [AgentMessage]) { self.messages = messages }
}

public enum AgentProviderError: Error, Equatable, Sendable {
    case unavailable(String)
    case notConfigured
}

/// The inference seam (APP-SPEC §9): Mock for tests/Local Universe,
/// FoundationModels on-device by default, Anthropic API opt-in (D3).
/// Providers produce values; they cannot send anything — `AgentEngine` owns
/// the only path from provider output to the wire.
public protocol AgentProvider: Sendable {
    func draftReply(context: AgentContext) async throws -> Draft
    func threadTurn(context: AgentContext) async throws -> AgentTurn?
}
