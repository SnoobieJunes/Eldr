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
    /// Inference backend: "ondevice" | "pcc" | "claude" | "openai" | "gemini" |
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
    /// Independent on/off switch — a disabled AI is fully inactive (no drafts, no
    /// context, no posting) but stays configured so you can flip it back on.
    /// Optional → older configs default to enabled.
    var enabled: Bool?

    // MARK: Private Cloud Compute tuning (kind == "pcc"; all optional → default)

    /// PCC reasoning depth: "light" | "moderate" | "deep". nil → "moderate".
    /// Reasoning is PCC-only and consumes tokens against the 32K window.
    var reasoningLevel: String?
    /// Optional sampling temperature (0.0–2.0) for PCC. nil → framework default.
    var temperature: Double?
    /// Optional response-length cap for PCC. nil → framework default.
    var maxResponseTokens: Int?

    init(
        id: String, name: String, kind: String, instructions: String? = nil,
        contextPolicy: String? = nil, contextDepth: Int? = nil, outputMode: String? = nil,
        baseURL: String? = nil, model: String? = nil, enabled: Bool? = nil,
        reasoningLevel: String? = nil, temperature: Double? = nil, maxResponseTokens: Int? = nil
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
        self.enabled = enabled
        self.reasoningLevel = reasoningLevel
        self.temperature = temperature
        self.maxResponseTokens = maxResponseTokens
    }

    static let defaultDepth = 20

    var effectivePolicy: String { contextPolicy ?? "active" }
    var effectiveOutputMode: String { outputMode ?? "participate" }
    var effectiveDepth: Int { max(1, contextDepth ?? Self.defaultDepth) }
    var isEnabled: Bool { enabled ?? true }
    /// PCC reasoning depth, defaulting to the balanced middle when unset.
    var effectiveReasoning: String { reasoningLevel ?? "moderate" }

    /// Per-AI Keychain account for the API key, so two AIs of the SAME provider
    /// can hold DIFFERENT keys (e.g. two Claude accounts) just by adding a second
    /// one. nil for backends that need no key (on-device / demo). The legacy
    /// shared account (`keyAccount(for:)`) is still read as a fallback so keys
    /// saved by older builds keep working.
    var apiKeyAccount: String? {
        // "hub" and "pcc" are off-device but need no key (the host / Apple PCC
        // runs the model), so they get no API-key account. The registry's
        // `usesPerAIKey` encodes exactly the old rule
        // (`isRemote && kind != "hub" && kind != "pcc"`); an unknown kind has no
        // descriptor → no per-AI account (matches the old `isRemote(unknown)==false`).
        (BackendRegistry.descriptor(for: kind)?.usesPerAIKey ?? false) ? "apikey.\(id)" : nil
    }

    /// The selectable backends and their labels — derived from the registry (its
    /// order IS the picker order). Adding a backend is one registry entry.
    static let kinds: [(tag: String, label: String)] =
        BackendRegistry.all.map { (tag: $0.tag, label: $0.label) }

    /// Context-gather policies and output modes, for the Settings pickers.
    /// Labels use the app-wide context vocabulary — Live / Marked only / Off —
    /// shared with the per-conversation override (ConversationDetailsView, the
    /// in-chat "AI here" chip). The TAGS ("active"/"strict"/"off") are the engine
    /// vocabulary and are UNCHANGED; only the human labels are unified.
    static let policies: [(tag: String, label: String)] = [
        ("active", "Live — full conversation while active"),
        ("strict", "Marked only — messages I add to context"),
        ("off", "Off — this AI gathers nothing"),
    ]
    static let outputModes: [(tag: String, label: String)] = [
        ("participate", "Participate — can post in windows/threads"),
        ("draft", "Draft only — suggests to me, never posts"),
        ("summarize", "Summarize — shares summaries, not verbatim"),
    ]
    /// PCC reasoning depths, for the Settings picker (kind == "pcc"). Deeper
    /// reasoning is more thorough but spends more of the per-user daily PCC quota.
    static let reasoningLevels: [(tag: String, label: String)] = [
        ("light", "Light — fastest"),
        ("moderate", "Moderate — balanced"),
        ("deep", "Deep — most thorough"),
    ]

    static func label(for kind: String) -> String {
        BackendRegistry.descriptor(for: kind)?.label ?? kind
    }

    /// Backends that send conversation content off the on-device model — require
    /// explicit consent and (usually) a Keychain API key. "custom" is included
    /// even when self-hosted: content still leaves the app to a server, so the
    /// firewall/consent default applies (the user can turn the firewall off for
    /// a server they fully control). "hub" sends content off-device too (to a
    /// nearby host); "pcc" sends it to Apple's Private Cloud Compute; "acp" to a
    /// paired Mac. Whether the egress firewall ALSO applies is a separate
    /// question — see `appliesEgressFirewall`. An unknown kind → false.
    static func isRemote(_ kind: String) -> Bool {
        BackendRegistry.descriptor(for: kind)?.isRemote ?? false
    }

    /// Off-device backends that ALSO get the name-redaction + byte-bound egress
    /// firewall. This is `isRemote` MINUS the Apple Private Cloud Compute tier:
    /// PCC is attested and retains no prompts (DEVIATIONS — Apple PCC tier), so we
    /// send full names/context for best quality while still requiring consent and
    /// showing the off-device indicator. Third-party vendors (Claude/OpenAI/…/hub)
    /// and ACP stay firewalled. An unknown kind → false.
    static func appliesEgressFirewall(_ kind: String) -> Bool {
        BackendRegistry.descriptor(for: kind)?.appliesEgressFirewall ?? false
    }

    /// Backends whose enablement shows the off-device consent alert. ALL remote
    /// backends, INCLUDING "hub" and "pcc": the content still leaves this device,
    /// so the user is asked first. An unknown kind → false.
    static func requiresConsent(_ kind: String) -> Bool {
        BackendRegistry.descriptor(for: kind)?.requiresConsent ?? false
    }

    /// Legacy SHARED Keychain account holding the API key for a remote backend,
    /// if any (read as a back-compat fallback for keys saved by older builds).
    static func keyAccount(for kind: String) -> String? {
        BackendRegistry.descriptor(for: kind)?.keyAccount
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
    /// True for backends that send context off the on-device model (drives the
    /// "leaves device" indicator + consent). Includes Apple Private Cloud Compute.
    var isRemote: Bool = false
    /// True for off-device backends that ALSO get the name-redaction + byte-bound
    /// egress firewall. This is `isRemote` for third-party vendors, but FALSE for
    /// Apple Private Cloud Compute (attested, no retention → send full context for
    /// quality). On-device AIs are false for both. See `ConfiguredAI.appliesEgressFirewall`.
    var appliesEgressFirewall: Bool = false
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

/// `TetheredAI` already exposes `participatesAutonomously`, so it satisfies the
/// `AISelectionCandidate` requirement with no new members — this conformance just
/// lets the routing policy (`AISelectionPolicy`, in PQRCAgent) operate on it.
extension TetheredAI: AISelectionCandidate {}

/// One line of the read-only "what your AI sees" context preview (Settings).
struct ContextPreviewLine: Identifiable, Sendable {
    let id = UUID()
    let role: String
    let text: String
    /// True when this entry is peer content a context-sharing grant authorized.
    let shared: Bool
}
