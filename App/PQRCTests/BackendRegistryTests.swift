import Foundation
import PQRCAgent
import Testing

@testable import EldrChat

/// Phase-2 data-driven backend registry. The previously-scattered per-`kind`
/// logic (selectable list, off-device/firewall/consent classification, legacy
/// Keychain account, and the provider factory) now derives from
/// `BackendRegistry`. These tests pin the EXACT current behavior per kind so the
/// consolidation is provably byte-identical and a future edit can't drift.
@Suite("Backend registry — data-driven backends")
struct BackendRegistryTests {

    /// Every kind the product ships, with its documented classification. This IS
    /// the contract: if any value here changes, the registry changed behavior.
    private struct Expected {
        let isRemote: Bool
        let firewall: Bool
        let consent: Bool
        let keyAccount: String?
    }
    private static let expected: [(tag: String, e: Expected)] = [
        ("ondevice", Expected(isRemote: false, firewall: false, consent: false, keyAccount: nil)),
        ("pcc", Expected(isRemote: true, firewall: false, consent: true, keyAccount: nil)),
        ("claude", Expected(isRemote: true, firewall: true, consent: true, keyAccount: "anthropic-api-key")),
        ("openai", Expected(isRemote: true, firewall: true, consent: true, keyAccount: "openai-api-key")),
        ("gemini", Expected(isRemote: true, firewall: true, consent: true, keyAccount: "gemini-api-key")),
        ("openrouter", Expected(isRemote: true, firewall: true, consent: true, keyAccount: "openrouter-api-key")),
        ("groq", Expected(isRemote: true, firewall: true, consent: true, keyAccount: "groq-api-key")),
        ("custom", Expected(isRemote: true, firewall: true, consent: true, keyAccount: "custom-api-key")),
        ("hub", Expected(isRemote: true, firewall: true, consent: true, keyAccount: nil)),
        ("acp", Expected(isRemote: true, firewall: true, consent: true, keyAccount: nil)),
        ("demo", Expected(isRemote: false, firewall: false, consent: false, keyAccount: nil)),
    ]

    /// The registry contains EVERY existing kind, in the existing picker order,
    /// and nothing extra. `ConfiguredAI.kinds` is derived from it, so they match.
    @Test func registryContainsEveryKind_inOrder() {
        let registryTags = BackendRegistry.all.map(\.tag)
        #expect(registryTags == Self.expected.map(\.tag), "registry order/content == documented kinds")
        // The selectable list now derives from the registry — same order, same tags.
        #expect(ConfiguredAI.kinds.map(\.tag) == registryTags)
        // Every kind resolves to a descriptor.
        for (tag, _) in Self.expected {
            #expect(BackendRegistry.descriptor(for: tag) != nil, "\(tag) has a descriptor")
        }
    }

    /// For EACH kind, the four classifier predicates equal the documented values
    /// — asserted through `ConfiguredAI`'s public API (what every caller uses).
    /// ACP IS firewalled; PCC is NOT — the two off-device exceptions, pinned.
    @Test func classification_matchesDocumentedValuesPerKind() {
        for (tag, e) in Self.expected {
            #expect(ConfiguredAI.isRemote(tag) == e.isRemote, "isRemote(\(tag))")
            #expect(
                ConfiguredAI.appliesEgressFirewall(tag) == e.firewall, "appliesEgressFirewall(\(tag))")
            #expect(ConfiguredAI.requiresConsent(tag) == e.consent, "requiresConsent(\(tag))")
            #expect(ConfiguredAI.keyAccount(for: tag) == e.keyAccount, "keyAccount(\(tag))")
        }
    }

    /// The two off-device exceptions called out in the spec, asserted directly so
    /// the intent is legible: ACP is firewalled, PCC is exempt.
    @Test func acpIsFirewalled_pccIsExempt() {
        #expect(ConfiguredAI.appliesEgressFirewall("acp"), "ACP IS firewalled")
        #expect(ConfiguredAI.appliesEgressFirewall("pcc") == false, "PCC is exempt from the firewall")
        // Both are still off-device + consent-gated.
        #expect(ConfiguredAI.isRemote("acp") && ConfiguredAI.requiresConsent("acp"))
        #expect(ConfiguredAI.isRemote("pcc") && ConfiguredAI.requiresConsent("pcc"))
    }

    /// The per-AI Keychain account (`apikey.<id>`) is granted exactly where the
    /// old rule did: remote backends EXCEPT hub/pcc (which run the model
    /// host-side / Apple-side). ACP qualifies — it gets one today even though its
    /// provider is a Demo stub.
    @Test func perAIKeyAccount_matchesLegacyRule() {
        func account(_ kind: String) -> String? {
            ConfiguredAI(id: "fixed-id", name: "n", kind: kind).apiKeyAccount
        }
        for kind in ["claude", "openai", "gemini", "openrouter", "groq", "custom", "acp"] {
            #expect(account(kind) == "apikey.fixed-id", "\(kind) gets a per-AI key account")
        }
        for kind in ["ondevice", "pcc", "hub", "demo"] {
            #expect(account(kind) == nil, "\(kind) gets no per-AI key account")
        }
    }

    /// Labels derive from the registry; an unknown kind echoes its own tag
    /// (the old `?? kind` fallback).
    @Test func labels_deriveFromRegistry_unknownEchoesTag() {
        #expect(ConfiguredAI.label(for: "claude") == "Claude (Anthropic)")
        #expect(ConfiguredAI.label(for: "ondevice") == "On-device Core AI")
        #expect(ConfiguredAI.label(for: "totally-unknown") == "totally-unknown")
    }

    // MARK: - Provider construction (the factory derives from the registry)

    /// The concrete provider type NAME the factory produced for a kind, built
    /// exactly as the runtime would in a FRESH per-test silo so no API key is ever
    /// present (the "no key → Demo stub" path).
    ///
    /// We compare by name rather than `as?`/`is`: the app target links `PQRCAgent`
    /// as a dynamic framework and the test target `@testable import`s `EldrChat`,
    /// so the `any AgentProvider` existential the factory returns can carry a
    /// SECOND copy of the `PQRCAgent` types — a cross-module identity mismatch
    /// where `type(of: p)` prints `DemoAgentProvider` yet `p is DemoAgentProvider`
    /// is false (observed on this toolchain). The bare type name is stable across
    /// those copies and still pins the exact concrete provider the runtime builds.
    /// `@MainActor`: `AppSession.makeProvider`/`siloService` are main-actor isolated.
    @MainActor
    private func providerTypeName(kind: String) -> String {
        let siloID = "test-backendregistry-\(UUID().uuidString)"
        let config = ConfiguredAI(id: UUID().uuidString, name: "n", kind: kind)
        defer { KeychainStore(service: AppSession.siloService(siloID)).deleteAll() }
        let provider = AppSession.makeProvider(config: config, siloID: siloID, hubClient: nil)
        return String(describing: type(of: provider))
    }

    /// `demo` → the Demo provider.
    @Test @MainActor func makeProvider_demo_isDemo() {
        #expect(providerTypeName(kind: "demo") == "DemoAgentProvider")
    }

    /// `claude` with NO key stored falls back to the Demo provider (so the AI
    /// still visibly responds instead of going silent).
    @Test @MainActor func makeProvider_claudeWithoutKey_isDemo() {
        #expect(providerTypeName(kind: "claude") == "DemoAgentProvider")
    }

    /// `ondevice` → FoundationModels when the platform supports it, Demo
    /// otherwise. Assert it's exactly one of the two, and that it tracks
    /// availability precisely (Demo iff FoundationModels is unavailable).
    @Test @MainActor func makeProvider_ondevice_isFoundationModelsOrDemo() {
        let name = providerTypeName(kind: "ondevice")
        let expected =
            FoundationModelsAgentProvider.isAvailable
            ? "FoundationModelsAgentProvider" : "DemoAgentProvider"
        #expect(name == expected, "ondevice resolves to \(expected) here, got \(name)")
    }

    /// `custom` with no base URL → Demo stub (the documented "no URL yet" path),
    /// regardless of key.
    @Test @MainActor func makeProvider_customWithoutBaseURL_isDemo() {
        #expect(providerTypeName(kind: "custom") == "DemoAgentProvider")
    }

    /// `hub` with no nearby relay client → Demo stub.
    @Test @MainActor func makeProvider_hubWithoutClient_isDemo() {
        #expect(providerTypeName(kind: "hub") == "DemoAgentProvider")
    }

    /// `acp` is always the Demo stub today (the live node link is unwired) — its
    /// provider construction is pinned so the consolidation didn't change it.
    @Test @MainActor func makeProvider_acp_isDemoStub() {
        #expect(providerTypeName(kind: "acp") == "DemoAgentProvider")
    }

    /// `pcc` without PCC support available → Demo stub (the documented fallback).
    @Test @MainActor func makeProvider_pccWhenUnavailable_isDemoStub() {
        // The test environment has no PCC; assert the fallback only when that holds
        // (keeps the test honest on a future PCC-capable runtime).
        if !PCCFoundationModelsProvider.isAvailable {
            #expect(providerTypeName(kind: "pcc") == "DemoAgentProvider")
        }
    }

    /// An unknown kind routes through the on-device default arm (the old
    /// `switch`'s `default:`), so it behaves IDENTICALLY to `ondevice`.
    @Test @MainActor func makeProvider_unknownKind_fallsBackToOnDeviceDefault() {
        #expect(providerTypeName(kind: "totally-unknown") == providerTypeName(kind: "ondevice"))
    }
}
