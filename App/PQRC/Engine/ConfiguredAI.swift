import Foundation
import PQRCAgent

/// One AI a person has tethered to themselves. A user can configure several at
/// once (e.g. on-device Core AI + Claude) so they can share context with each
/// other in a chat or thread (multi-AI tethering). Stored in UserDefaults; API
/// keys stay in the Keychain, keyed by `kind`.
///
/// Beyond the backend, each AI carries its own *context profile* — what it's
/// allowed to gather and what it does with it (custom instructions, a gather
/// policy, a context depth, and an output mode). All profile fields are optional
/// so configs saved by older builds still decode (missing → the default).
struct ConfiguredAI: Identifiable, Codable, Equatable, Sendable {
    var id: String
    /// Friendly, user-editable display name (a friendly codename by default).
    var name: String
    /// Inference backend: "ondevice" | "claude" | "openai" | "gemini" |
    /// "openrouter" | "groq" | "custom" | "demo".
    var kind: String

    // MARK: Context profile (all optional → default when absent)

    /// Custom system prompt / persona. nil → the backend's built-in default.
    var instructions: String?
    /// What the AI may gather: "active" (live convo once it's on — default),
    /// "strict" (ONLY messages I tap "Add to AI Context"), or "off" (disabled).
    var contextPolicy: String?
    /// Max recent messages handed to the model. nil → `defaultDepth`.
    var contextDepth: Int?
    /// What it does with the context: "participate" (posts in windows/threads —
    /// default), "draft" (only suggests to me, never auto-posts), or "summarize"
    /// (participates, but contributes brief summaries, not verbatim quotes).
    var outputMode: String?
    /// For the "custom" backend: the OpenAI-compatible base URL (e.g. a Mac
    /// running Ollama/LM Studio: "http://192.168.1.20:11434/v1").
    var baseURL: String?
    /// Optional model id/slug override (groq / custom / openrouter).
    var model: String?

    init(
        id: String, name: String, kind: String, instructions: String? = nil,
        contextPolicy: String? = nil, contextDepth: Int? = nil, outputMode: String? = nil,
        baseURL: String? = nil, model: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.instructions = instructions
        self.contextPolicy = contextPolicy
        self.contextDepth = contextDepth
        self.outputMode = outputMode
        self.baseURL = baseURL
        self.model = model
    }

    static let defaultDepth = 20

    var effectivePolicy: String { contextPolicy ?? "active" }
    var effectiveOutputMode: String { outputMode ?? "participate" }
    var effectiveDepth: Int { max(1, contextDepth ?? Self.defaultDepth) }

    /// The selectable backends and their labels.
    static let kinds: [(tag: String, label: String)] = [
        ("ondevice", "On-device Core AI"),
        ("claude", "Claude (Anthropic)"),
        ("openai", "OpenAI"),
        ("gemini", "Gemini"),
        ("openrouter", "OpenRouter (many models)"),
        ("groq", "Groq (fast)"),
        ("custom", "Custom / self-hosted (OpenAI-compatible)"),
        ("demo", "Demo (simulated)"),
    ]

    /// Context-gather policies and output modes, for the Settings pickers.
    static let policies: [(tag: String, label: String)] = [
        ("active", "Live conversation while active"),
        ("strict", "Only messages I add to context"),
        ("off", "Off — this AI gathers nothing"),
    ]
    static let outputModes: [(tag: String, label: String)] = [
        ("participate", "Participate — can post in windows/threads"),
        ("draft", "Draft only — suggests to me, never posts"),
        ("summarize", "Summarize — shares summaries, not verbatim"),
    ]

    static func label(for kind: String) -> String {
        kinds.first { $0.tag == kind }?.label ?? kind
    }

    /// Backends that send conversation content off the on-device model — require
    /// explicit consent and (usually) a Keychain API key. "custom" is included
    /// even when self-hosted: content still leaves the app to a server, so the
    /// firewall/consent default applies (the user can turn the firewall off for
    /// a server they fully control).
    static func isRemote(_ kind: String) -> Bool {
        ["claude", "openai", "gemini", "openrouter", "groq", "custom"].contains(kind)
    }

    /// Keychain account holding the API key for a remote backend, if any.
    static func keyAccount(for kind: String) -> String? {
        switch kind {
        case "claude": return "anthropic-api-key"
        case "openai": return "openai-api-key"
        case "gemini": return "gemini-api-key"
        case "openrouter": return "openrouter-api-key"
        case "groq": return "groq-api-key"
        case "custom": return "custom-api-key"
        default: return nil
        }
    }

    /// "custom" needs a base URL; a self-hosted server may need no key at all.
    static func needsBaseURL(_ kind: String) -> Bool { kind == "custom" }
    static func keyOptional(_ kind: String) -> Bool { kind == "custom" }
    /// Backends where a free-text model id/slug is meaningful to expose.
    static func supportsModelField(_ kind: String) -> Bool {
        ["openrouter", "groq", "custom"].contains(kind)
    }
}

/// A configured AI bound to a live provider instance — the runtime's view of a
/// tethered AI. `provider` is `Sendable` (the protocol requires it). Carries the
/// context profile so the runtime can honor each AI's gather policy / depth /
/// instructions / output mode independently.
struct TetheredAI: Sendable {
    let id: String
    let name: String
    let provider: any AgentProvider
    /// True for backends that send context off the on-device model. The egress
    /// firewall (name redaction + byte bound) applies only to these; on-device
    /// AIs bypass it entirely.
    var isRemote: Bool = false
    /// Custom system prompt, or nil for the backend default.
    var instructions: String? = nil
    /// "active" | "strict" | "off".
    var contextPolicy: String = "active"
    /// Max recent messages in the context window.
    var contextDepth: Int = ConfiguredAI.defaultDepth
    /// "participate" | "draft" | "summarize".
    var outputMode: String = "participate"

    /// Whether this AI may post on its own (solo replies, window/thread turns).
    /// "draft"-only AIs and "off" AIs never auto-post.
    var participatesAutonomously: Bool {
        outputMode != "draft" && contextPolicy != "off"
    }
    /// Whether the model should contribute summaries rather than verbatim text.
    var summarizes: Bool { outputMode == "summarize" }
}

/// One line of the read-only "what your AI sees" context preview (Settings).
struct ContextPreviewLine: Identifiable, Sendable {
    let id = UUID()
    let role: String
    let text: String
    /// True when this entry is peer content a context-sharing grant authorized.
    let shared: Bool
}
