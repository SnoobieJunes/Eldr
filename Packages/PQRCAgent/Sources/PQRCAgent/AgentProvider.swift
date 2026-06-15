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
    /// field); nil → the backend's built-in default. Augments, not replaces, the
    /// protocol conventions (draft-only / PASS-to-stay-silent) below.
    public let instructions: String?
    /// When true, the AI should contribute a brief summary, not verbatim quotes
    /// (the "summarize" output mode — less content leaves the device).
    public let summarize: Bool

    public init(
        myIdentityHex: String, myDisplayName: String, transcript: [TranscriptEntry],
        threadID: String? = nil, threadTitle: String? = nil,
        instructions: String? = nil, summarize: Bool = false
    ) {
        self.myIdentityHex = myIdentityHex
        self.myDisplayName = myDisplayName
        self.transcript = transcript
        self.threadID = threadID
        self.threadTitle = threadTitle
        self.instructions = instructions
        self.summarize = summarize
    }

    /// System prompt for a private draft, honoring the user's instructions +
    /// summarize mode. Custom instructions AUGMENT the conventions so providers
    /// keep behaving correctly (e.g. "reply with the draft only").
    public func draftSystemPrompt() -> String {
        var p =
            "You draft brief, natural message replies for \(myDisplayName). Reply with the draft text only."
        if summarize { p += " Prefer a concise summary over verbatim quoting." }
        if let instructions, !instructions.isEmpty {
            p += "\n\nYour user's instructions: \(instructions)"
        }
        return p
    }

    /// System prompt for a shared-thread / window turn, same augmentation rules.
    public func turnSystemPrompt() -> String {
        var p =
            "You are \(myDisplayName)'s AI in a shared thread with another person's AI. Contribute one short useful message, or reply exactly PASS to stay silent."
        if summarize {
            p += " Share a brief summary of the relevant context rather than quoting it verbatim."
        }
        if let instructions, !instructions.isEmpty {
            p += "\n\nYour user's instructions: \(instructions)"
        }
        return p
    }
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
