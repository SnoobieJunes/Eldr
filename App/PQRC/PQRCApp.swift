import PQRCAgent
import PQRCCore
import PQRCNostr
import SwiftUI

@main
struct PQRCApp: App {
    @State private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .onOpenURL { url in
                    session.handleDeepLink(url)
                }
        }
    }
}

/// Top-level app mode: a real single-persona session, or the Local Universe
/// (Debug + reviewer demo) with multiple personas over an in-process relay.
@MainActor
@Observable
final class AppSession {
    enum Mode {
        case onboarding
        case single(AppModel)
        case universe(LocalUniverse, selected: Int)
    }

    var mode: Mode = .onboarding
    var bootError: String?
    /// Set when the user opens the demo from Settings or launch args.
    var demoRunning = false
    /// npub arriving via a `pqrc:add?npub=…` deep link (QR scan from the
    /// Camera app lands here instead of in a web browser).
    var pendingNpub: String?

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--reset") {
            KeychainStore().deleteAll()
            UserDefaults.standard.removeObject(forKey: "displayName")
        }
        if arguments.contains("--local-universe") || arguments.contains("--uitest") {
            Task { await bootUniverse(runScript: arguments.contains("--demo-script")) }
        } else if KeychainStore().loadIfPresent(account: "identity-seed") != nil,
            !arguments.contains("--reset")
        {
            Task { await bootSingle() }
        }
    }

    /// UI-test hooks, applied after the universe boots.
    func applyUITestHooks() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let model = activeModel else { return }
        if arguments.contains("--uitest-safetychange") {
            // Synthetic safety-code-change: exercises the persistent warning
            // banner path the same way a re-published 10420 would.
            let target = model.conversations.first { $0.title == "Bob" }
                ?? model.conversations.first
            model.safetyCodeChangedFor.insert(target?.id ?? "")
        }
        if arguments.contains("--uitest-10k") {
            // Seed a 10k-message conversation for the scroll perf test.
            guard
                let conversationID = (model.conversations.first { $0.title == "Bob" }
                    ?? model.conversations.first)?.id
            else { return }
            var list = model.messagesByConversation[conversationID] ?? []
            for i in 0..<10_000 {
                list.append(
                    StoredMessage(
                        id: "perf-\(i)", conversationID: conversationID,
                        senderIdentity: i % 2 == 0 ? model.myIdentityHex : conversationID,
                        participantType: .human, text: "Scroll perf message #\(i)",
                        sentAt: Int64(i), localStatus: "sent"))
            }
            model.messagesByConversation[conversationID] = list
        }
    }

    /// Relay resolution, in priority order:
    /// 1. `PQRC_RELAY_URL` env var (Xcode scheme) — single URL override.
    /// 2. `relayURLs` UserDefaults — the user's server list from Settings.
    /// 3. Default: the deployed anchor relay.
    /// The literal value `local` (anywhere in the list) is the in-process
    /// simulator. UI tests are unaffected — they boot the Local Universe.
    static let defaultRelayURL = "wss://relay.lerants.com"

    static var configuredRelayURLs: [String] {
        if let env = ProcessInfo.processInfo.environment["PQRC_RELAY_URL"] {
            return [env]
        }
        // Test launches stay hermetic: launch args only exist in dev/test
        // contexts, and a UI test must never depend on a live relay.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--uitest") || arguments.contains("--reset") {
            return ["local"]
        }
        let saved = UserDefaults.standard.stringArray(forKey: "relayURLs") ?? []
        return saved.isEmpty ? [Self.defaultRelayURL] : saved
    }

    private func makeRelayTransports() async -> [any RelayTransport] {
        var transports: [any RelayTransport] = []
        for configured in Self.configuredRelayURLs {
            if configured == "local" {
                transports.append(await LocalRelaySimulator(url: "local://relay").connect())
            } else if let url = URL(string: configured),
                url.scheme == "ws" || url.scheme == "wss"
            {
                transports.append(await NostrWebSocketTransport(url: url).connect())
            }
        }
        if transports.isEmpty {
            transports.append(await LocalRelaySimulator(url: "local://relay").connect())
        }
        return transports
    }

    /// Token-based API providers and the Keychain account each key is stored
    /// under. Keys live in the Keychain (service `chat.pqrc.keys`), never
    /// UserDefaults.
    static let apiKeyAccounts: [String: String] = [
        "claude": "anthropic-api-key",
        "openai": "openai-api-key",
        "gemini": "gemini-api-key",
    ]

    /// Provider per the Settings picker. Token-based providers (Claude/OpenAI/
    /// Gemini) read their key from the Keychain; with no key they fall back to
    /// the Demo provider so the AI still visibly responds instead of going
    /// silent. The on-device default uses Core AI (FoundationModels) when
    /// available, Demo otherwise.
    /// Builds a live provider for one backend kind. Token-based backends with no
    /// key fall back to the Demo provider so the AI still visibly responds.
    static func makeProvider(kind: String) -> any AgentProvider {
        let keychain = KeychainStore(service: "chat.pqrc.keys")
        func key(for provider: String) -> String? {
            guard let account = apiKeyAccounts[provider],
                let data = keychain.loadIfPresent(account: account)
            else { return nil }
            let value = String(decoding: data, as: UTF8.self)
            return value.isEmpty ? nil : value
        }
        switch kind {
        case "claude":
            return key(for: "claude").map { AnthropicAPIProvider(apiKey: $0) } ?? DemoAgentProvider()
        case "openai":
            return key(for: "openai").map { OpenAIAPIProvider(apiKey: $0) } ?? DemoAgentProvider()
        case "gemini":
            return key(for: "gemini").map { GeminiAPIProvider(apiKey: $0) } ?? DemoAgentProvider()
        case "demo":
            return DemoAgentProvider()
        default:  // "ondevice"
            return FoundationModelsAgentProvider.isAvailable
                ? FoundationModelsAgentProvider() : DemoAgentProvider()
        }
    }

    /// The user's configured AIs (multi-AI tethering), migrating the legacy
    /// single-provider setting on first read so existing installs keep working.
    static func loadConfiguredAIs() -> [ConfiguredAI] {
        if let data = UserDefaults.standard.data(forKey: "configuredAIs"),
            let list = try? JSONDecoder().decode([ConfiguredAI].self, from: data),
            !list.isEmpty
        {
            return list
        }
        // Migrate the pre-multi-provider tag: "remote" was Anthropic, "mock" the
        // deterministic stub now superseded by Demo.
        let kind: String
        switch UserDefaults.standard.string(forKey: "aiProvider") ?? "ondevice" {
        case "remote": kind = "claude"
        case "mock": kind = "demo"
        case let other: kind = other
        }
        let migrated = [
            ConfiguredAI(id: UUID().uuidString, name: FriendlyName.local(seed: "ai:" + kind), kind: kind)
        ]
        saveConfiguredAIs(migrated)
        return migrated
    }

    static func saveConfiguredAIs(_ list: [ConfiguredAI]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: "configuredAIs")
        }
    }

    /// The configured AIs bound to live providers — the runtime's tethered AIs.
    static func makeRuntimeAIs() -> [TetheredAI] {
        loadConfiguredAIs().map {
            TetheredAI(
                id: $0.id, name: $0.name, provider: makeProvider(kind: $0.kind),
                isRemote: ConfiguredAI.isRemote($0.kind))
        }
    }

    /// The egress firewall (redact names + byte-bound context sent to remote AIs)
    /// is ON by default; the user can disable it in Settings ▸ AI after the
    /// implications warning.
    static var firewallEnabled: Bool {
        UserDefaults.standard.object(forKey: "egressFirewallEnabled") as? Bool ?? true
    }

    /// Multipeer local link: user-toggleable (Settings → Nearby), OFF by
    /// default in every build. It advertises a Bonjour service and opens
    /// AWDL/Bluetooth — a privacy surface (and the iOS Simulator has no real
    /// radios, so it just spams `DTLS … No route to host`). The user opts in
    /// from Settings; only then do the radios start (and the Local Network
    /// permission prompt appears on device).
    static var localLinkEnabled: Bool {
        UserDefaults.standard.bool(forKey: "localLinkEnabled")
    }

    func bootSingle() async {
        let transports = await makeRelayTransports()
        let blossom = LocalBlossomSimulator()
        let runtime = PersonaRuntime(
            displayName: UserDefaults.standard.string(forKey: "displayName") ?? "Me",
            transports: transports,
            blobStore: blossom,
            ais: Self.makeRuntimeAIs(),
            keychainService: "chat.pqrc.keys",
            enableLocalLink: Self.localLinkEnabled)
        await runtime.setFirewallEnabled(Self.firewallEnabled)
        let model = AppModel(
            runtime: runtime,
            personaName: UserDefaults.standard.string(forKey: "displayName") ?? "Me")
        do {
            try await model.start(inMemoryStore: false, relayURLs: Self.configuredRelayURLs)
            mode = .single(model)
        } catch {
            bootError = String(describing: error)
        }
    }

    /// Tears the single-persona session down and boots it again — the apply
    /// path for relay-list and Nearby changes from Settings.
    func rebootSingle() async {
        if case .single(let model) = mode {
            await model.runtime.shutdown()
        }
        mode = .onboarding
        await bootSingle()
    }

    /// Re-resolves the tethered AIs + egress-firewall state after a Settings
    /// change (no reboot needed).
    func applyAIProvider() async {
        guard case .single(let model) = mode else { return }
        await model.runtime.setAIs(Self.makeRuntimeAIs())
        await model.runtime.setFirewallEnabled(Self.firewallEnabled)
    }

    /// `pqrc:add?npub=npub1…` — from a scanned QR. Opens New Conversation
    /// with the npub prefilled (handled by MainView).
    func handleDeepLink(_ url: URL) {
        guard url.scheme == "pqrc" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let npub = components?.queryItems?.first(where: { $0.name == "npub" })?.value,
            npub.hasPrefix("npub1")
        {
            pendingNpub = npub
        }
    }

    func bootUniverse(runScript: Bool) async {
        let universe = LocalUniverse()
        do {
            try await universe.boot()
            mode = .universe(universe, selected: 0)
            if runScript {
                demoRunning = true
                try await universe.runDemoScript()
                demoRunning = false
            }
            await applyUITestHooks()
        } catch {
            bootError = String(describing: error)
        }
    }

    func selectPersona(_ index: Int) {
        if case .universe(let universe, _) = mode {
            mode = .universe(universe, selected: index)
        }
    }

    var activeModel: AppModel? {
        switch mode {
        case .onboarding: return nil
        case .single(let model): return model
        case .universe(let universe, let selected): return universe.models[selected]
        }
    }
}

struct RootView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        switch session.mode {
        case .onboarding:
            OnboardingView()
        case .single(let model):
            MainView(model: model)
        case .universe(let universe, let selected):
            // The switcher renders inside the conversation-list screen only:
            // global overlays fight the navigation bar / composer for taps.
            MainView(
                model: universe.models[selected],
                personaSwitcher: PersonaSwitcher(universe: universe, selected: selected))
        }
    }
}

/// Debug/demo persona switcher for the Local Universe.
struct PersonaSwitcher: View {
    @Environment(AppSession.self) private var session
    let universe: LocalUniverse
    let selected: Int

    var body: some View {
        Picker("Persona", selection: Binding(
            get: { selected },
            set: { session.selectPersona($0) }
        )) {
            ForEach(Array(universe.models.enumerated()), id: \.offset) { index, model in
                Text(model.personaName).tag(index)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(.bar)
        .accessibilityIdentifier("persona-switcher")
    }
}
