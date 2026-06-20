import Foundation
import PQRCAgent
import PQRCNostr  // MultipeerRelayClient (the "hub" backend's link)

/// One AI inference backend, described declaratively. This is the single source
/// of truth that the previously-scattered per-`kind` logic now derives from:
/// the selectable list (`ConfiguredAI.kinds`), the off-device/firewall/consent
/// classification (`isRemote` / `appliesEgressFirewall` / `requiresConsent`),
/// the legacy shared Keychain account (`keyAccount(for:)`), and the live
/// provider factory (`AppSession.makeProvider`). Adding a backend is now ONE
/// entry in `BackendRegistry.all` — that's the whole point.
///
/// Behavior must stay byte-identical to the old hand-written switch/predicates;
/// `BackendRegistryTests` pins every field per kind so a future edit can't drift.
///
/// `Sendable` (so the `static let all` table is concurrency-safe): every field is
/// a value/`String`, and `makeProvider` is a `@Sendable` closure returning a
/// `Sendable` `AgentProvider` — it captures nothing mutable.
struct BackendDescriptor: Sendable {
    /// The persisted wire/UserDefaults tag (e.g. "claude"). UNCHANGED — this is
    /// a compatibility key, never reformatted.
    let tag: String
    /// Human label for the Settings picker.
    let label: String

    /// Sends conversation content off the on-device model → consent + the
    /// "leaves device" indicator apply. Includes Apple Private Cloud Compute.
    let isRemote: Bool
    /// Off-device backends that ALSO get the name-redaction + byte-bound egress
    /// firewall. This is `isRemote` MINUS the Apple PCC tier (attested, no
    /// retention → full context for quality); ACP and every third-party vendor
    /// stay firewalled.
    let appliesEgressFirewall: Bool
    /// Whether enabling this backend shows the off-device consent alert.
    let requiresConsent: Bool

    /// The LEGACY shared Keychain account holding this provider's API key (read
    /// as a back-compat fallback for keys saved by older builds), or nil for
    /// backends that need no key. Maps to `ConfiguredAI.keyAccount(for:)` and
    /// `AppSession.apiKeyAccounts`.
    let keyAccount: String?
    /// Whether this backend gets a PER-AI Keychain account (`apikey.<id>`) so two
    /// AIs of the same provider can hold different keys. Exactly the old rule:
    /// `isRemote && tag != "hub" && tag != "pcc"` (those two are off-device but
    /// run the model host-side / Apple-side, so no key). Note ACP qualifies —
    /// it gets a per-AI account today even though its provider is a Demo stub.
    let usesPerAIKey: Bool

    /// Builds the live provider for this backend, reproducing the old switch arm
    /// EXACTLY. Inputs mirror what that switch read:
    /// - `config`: the configured AI (base URL, model, PCC tuning, …).
    /// - `key`: resolves this provider's API key — the per-AI account first, then
    ///   the legacy shared account — identical to the old local `key(for:)`.
    ///   Returns nil/empty-as-nil when no key is stored.
    /// - `hubClient`: the active nearby-relay client for the "hub" backend.
    let makeProvider:
        @Sendable (
            _ config: ConfiguredAI, _ key: (String) -> String?,
            _ hubClient: MultipeerRelayClient?
        ) -> any AgentProvider
}

/// The ordered registry of every backend, one entry per `ConfiguredAI.kind`.
/// Order is the Settings-picker order (was `ConfiguredAI.kinds`). Each entry
/// reproduces that kind's exact classification and provider construction.
enum BackendRegistry {
    static let all: [BackendDescriptor] = [
        BackendDescriptor(
            tag: "ondevice", label: "On-device Core AI",
            isRemote: false, appliesEgressFirewall: false, requiresConsent: false,
            keyAccount: nil, usesPerAIKey: false,
            makeProvider: { _, _, _ -> any AgentProvider in
                // On-device default: Core AI (FoundationModels) when available,
                // Demo otherwise so the AI still visibly responds.
                FoundationModelsAgentProvider.isAvailable
                    ? FoundationModelsAgentProvider() : DemoAgentProvider()
            }),
        BackendDescriptor(
            tag: "pcc", label: "Apple Private Cloud Compute",
            isRemote: true, appliesEgressFirewall: false, requiresConsent: true,
            keyAccount: nil, usesPerAIKey: false,
            makeProvider: { config, _, _ -> any AgentProvider in
                // Apple Private Cloud Compute server model. No API key (on-Apple).
                // Reasoning depth + sampling are baked into the provider instance.
                PCCFoundationModelsProvider.isAvailable
                    ? PCCFoundationModelsProvider(
                        reasoningLevel: config.effectiveReasoning,
                        temperature: config.temperature,
                        maxResponseTokens: config.maxResponseTokens)
                    : DemoAgentProvider()
            }),
        BackendDescriptor(
            tag: "claude", label: "Claude (Anthropic)",
            isRemote: true, appliesEgressFirewall: true, requiresConsent: true,
            keyAccount: "anthropic-api-key", usesPerAIKey: true,
            makeProvider: { _, key, _ -> any AgentProvider in
                key("claude").map { AnthropicAPIProvider(apiKey: $0) } ?? DemoAgentProvider()
            }),
        BackendDescriptor(
            tag: "openai", label: "OpenAI",
            isRemote: true, appliesEgressFirewall: true, requiresConsent: true,
            keyAccount: "openai-api-key", usesPerAIKey: true,
            makeProvider: { _, key, _ -> any AgentProvider in
                key("openai").map { OpenAIAPIProvider(apiKey: $0) } ?? DemoAgentProvider()
            }),
        BackendDescriptor(
            tag: "gemini", label: "Gemini",
            isRemote: true, appliesEgressFirewall: true, requiresConsent: true,
            keyAccount: "gemini-api-key", usesPerAIKey: true,
            makeProvider: { _, key, _ -> any AgentProvider in
                key("gemini").map { GeminiAPIProvider(apiKey: $0) } ?? DemoAgentProvider()
            }),
        BackendDescriptor(
            tag: "openrouter", label: "OpenRouter (many models)",
            isRemote: true, appliesEgressFirewall: true, requiresConsent: true,
            keyAccount: "openrouter-api-key", usesPerAIKey: true,
            makeProvider: { config, key, _ -> any AgentProvider in
                let model = config.model ?? ""
                return key("openrouter").map {
                    model.isEmpty
                        ? OpenRouterAPIProvider(apiKey: $0)
                        : OpenRouterAPIProvider(apiKey: $0, model: model)
                } ?? DemoAgentProvider()
            }),
        BackendDescriptor(
            tag: "groq", label: "Groq (fast)",
            isRemote: true, appliesEgressFirewall: true, requiresConsent: true,
            keyAccount: "groq-api-key", usesPerAIKey: true,
            makeProvider: { config, key, _ -> any AgentProvider in
                let model = config.model ?? ""
                return key("groq").map {
                    model.isEmpty
                        ? GroqAPIProvider(apiKey: $0) : GroqAPIProvider(apiKey: $0, model: model)
                } ?? DemoAgentProvider()
            }),
        BackendDescriptor(
            tag: "custom", label: "Custom / self-hosted (OpenAI-compatible)",
            isRemote: true, appliesEgressFirewall: true, requiresConsent: true,
            keyAccount: "custom-api-key", usesPerAIKey: true,
            makeProvider: { config, key, _ -> any AgentProvider in
                // Self-hosted / any OpenAI-compatible server: needs a base URL; the
                // key is OPTIONAL (a local Ollama/LM Studio usually has none). No URL
                // yet → Demo stub so the AI still visibly responds.
                let base = (config.baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !base.isEmpty else { return DemoAgentProvider() }
                return CustomOpenAIProvider(
                    baseURL: base, apiKey: key("custom") ?? "", model: config.model ?? "")
            }),
        BackendDescriptor(
            tag: "hub", label: "Nearby host's AI (Multipeer)",
            isRemote: true, appliesEgressFirewall: true, requiresConsent: true,
            keyAccount: nil, usesPerAIKey: false,
            makeProvider: { _, _, hubClient -> any AgentProvider in
                // Borrow a nearby host's AI over the Multipeer link. Needs an active
                // `nearby` relay client; otherwise fall back to the Demo stub.
                hubClient.map { NearbyHubAIProvider(client: $0) } ?? DemoAgentProvider()
            }),
        BackendDescriptor(
            tag: "acp", label: "Mac coding harness (ACP)",
            isRemote: true, appliesEgressFirewall: true, requiresConsent: true,
            keyAccount: nil, usesPerAIKey: true,
            makeProvider: { _, _, _ in
                // Drive a paired Mac node's coding harness over the sealed
                // NearbyACPTransport via ACPAgentProvider (PQRCAgent). The provider +
                // transport are built and unit-proven; wiring the LIVE node link (the
                // node-side ACP host + device-to-device pairing) is the remaining
                // Phase-1 e2e. Until a node is connected, the Demo stub keeps the
                // backend selectable and visibly responding.
                DemoAgentProvider()
            }),
        BackendDescriptor(
            tag: "demo", label: "Demo (simulated)",
            isRemote: false, appliesEgressFirewall: false, requiresConsent: false,
            keyAccount: nil, usesPerAIKey: false,
            makeProvider: { _, _, _ in DemoAgentProvider() }),
    ]

    /// Descriptor for a kind, or nil for an unknown tag (forward-compat: an older
    /// build's config naming a kind this build dropped resolves to nil and the
    /// callers fall back to their documented defaults).
    static func descriptor(for tag: String) -> BackendDescriptor? {
        all.first { $0.tag == tag }
    }
}
