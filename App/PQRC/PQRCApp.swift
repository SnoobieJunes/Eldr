import CryptoKit
import PQRCAgent
import PQRCCore
import PQRCMCP
import PQRCNostr
import Security
import SwiftUI

/// Connection details for a running local MCP server, shown in Settings so the
/// user can configure their MCP client (the exact shim command + token + env).
struct LocalMCPConnection: Equatable {
    let socketPath: String
    let token: String

    /// The environment a user pastes into their MCP client's server config so the
    /// `pqrc-mcp-bridge` shim can reach this in-app server.
    var env: [String: String] {
        ["PQRC_MCP_SOCKET": socketPath, "PQRC_MCP_TOKEN": token]
    }
}

/// Cross-cutting UI intents raised by the macOS menu-bar `.commands` (which live
/// at Scene level) and consumed by `MainView` (which owns the sheets/selection).
/// SwiftUI's command closures can't reach a View's `@State` directly, so this
/// small observable is the seam: a command bumps a counter or flips a flag here,
/// `MainView` observes it. Harmless on iPhone/iPad (no menu bar fires them).
@MainActor
@Observable
final class AppCommands {
    /// Bumped by ⌘N — MainView opens New Conversation.
    var newConversationTick = 0
    /// Bumped by ⇧⌘N — MainView opens New Group.
    var newGroupTick = 0
    /// Bumped by ⌥⌘N — MainView starts a new AI (self) chat.
    var newAIChatTick = 0
    /// Bumped by ⌘, — MainView opens Settings.
    var openSettingsTick = 0
    /// Bumped by ⌘F — MainView focuses the conversation search field.
    var findTick = 0
    /// Bumped by ⌃⌘S — MainView toggles the sidebar.
    var toggleSidebarTick = 0

    func newConversation() { newConversationTick += 1 }
    func newGroup() { newGroupTick += 1 }
    func newAIChat() { newAIChatTick += 1 }
    func openSettings() { openSettingsTick += 1 }
    func find() { findTick += 1 }
    func toggleSidebar() { toggleSidebarTick += 1 }
}

@main
struct PQRCApp: App {
    @State private var session = AppSession()
    @State private var commands = AppCommands()

    var body: some Scene {
        WindowGroup {
            // Mac ONLY: a sane window minimum so it can't be squeezed to a phone
            // sliver. A `.frame(minWidth:)` is NOT inert on iOS — it would force a
            // real iPhone to render 760pt wide and CLIP everything (the "UI cut off"
            // bug). So gate it to "iOS app running on Mac" and pass nil (no
            // constraint) on a real iPhone/iPad.
            // "iOS app on Mac" (Designed for iPad) AND Mac Catalyst both want the
            // desktop min/ideal frame so the window resizes freely instead of the
            // fixed small-or-fullscreen iPad sizing. `isMacCatalystApp` covers the
            // Catalyst runtime; `isiOSAppOnMac` the Designed-for-iPad one.
            let onMac =
                ProcessInfo.processInfo.isiOSAppOnMac
                || ProcessInfo.processInfo.isMacCatalystApp
            RootView()
                .environment(session)
                .environment(commands)
                .frame(
                    minWidth: onMac ? 760 : nil, idealWidth: onMac ? 1100 : nil,
                    minHeight: onMac ? 520 : nil, idealHeight: onMac ? 760 : nil)
                .onOpenURL { url in
                    session.handleDeepLink(url)
                }
        }
        // Window starts at a comfortable desktop size and is freely resizable to
        // fit its content's min/ideal frame (above). iOS ignores both.
        .defaultSize(width: 1100, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            // Menu-bar commands — the single biggest "feels native on Mac" win.
            // Each maps to a standard shortcut and routes through `AppCommands`.
            // `replacing: .newItem` puts our New items in the File menu where Mac
            // users expect ⌘N; CommandGroup is a no-op on iOS.
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") { commands.newConversation() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Group") { commands.newGroup() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New AI Chat") { commands.newAIChat() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
            }
            // ⌘F Find lives in a standard place under the (empty) text-editing menu.
            CommandGroup(after: .textEditing) {
                Button("Find Conversation") { commands.find() }
                    .keyboardShortcut("f", modifiers: .command)
            }
            // NOTE: no custom "Toggle Sidebar" command. SwiftUI already installs a
            // system "Show Sidebar" item bound to ⌃⌘S for the `NavigationSplitView`
            // in `MainView`, and registering our own ⌃⌘S in `.sidebar` duplicated
            // that exact shortcut — UIKit rejects duplicate key commands with an
            // uncaught `NSInvalidArgumentException` ("Replacement elements contain
            // duplicates") the moment the main menu is built, which on Mac is at
            // launch. So the app crashed on launch on Mac. The built-in ⌃⌘S already
            // toggles the split view's sidebar, so we just rely on it.
            // ⌘, Settings in the app menu, replacing the disabled default.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { commands.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
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
        /// Passphrase lock screen — the always-first state. Unlock an existing
        /// silo, create a new one, or migrate a pre-silo account. No account list
        /// is ever shown (deniable multi-account).
        case locked
        case onboarding
        case single(AppModel)
        case universe(LocalUniverse, selected: Int)
    }

    var mode: Mode = .locked
    var bootError: String?
    /// Surfaced on the lock screen when a passphrase doesn't unlock anything.
    var unlockError: String?
    /// The currently-unlocked silo (so reboots reuse the same key/store).
    private var activeSilo: SiloKey.Derived?
    /// Set when the user opens the demo from Settings or launch args.
    var demoRunning = false
    /// npub arriving via a `pqrc:add?npub=…` deep link (QR scan from the
    /// Camera app lands here instead of in a web browser).
    var pendingNpub: String?
    /// Optional `&type=…` from the deep link — `coding_agent` when the Eldr ACP
    /// Configurator generated it, so the new contact is tagged as the owner's coding
    /// agent (enables the §13.5 watch-along draft path). nil for an ordinary add.
    var pendingContactType: String?

    /// A pre-silo account from an older build is present and must be migrated
    /// (wrapped under a passphrase) before it can be unlocked.
    var hasLegacyAccount: Bool {
        KeychainStore(service: "chat.pqrc.keys").loadIfPresent(account: "identity-seed") != nil
    }

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--reset") {
            KeychainStore(service: "chat.pqrc.keys").deleteAll()
            UserDefaults.standard.removeObject(forKey: "displayName")
            Self.deleteAllStoreFiles()
        }
        if arguments.contains("--local-universe") || arguments.contains("--uitest") {
            Task { await bootUniverse(runScript: arguments.contains("--demo-script")) }
        }
        #if DEBUG
            if arguments.contains("--uitest-biometric") {
                // Deterministic Face ID harness: wipe the test silo, create it
                // fresh (which auto-enables Face ID when the device/Simulator has
                // it enrolled), then lock — landing on the lock screen, which
                // auto-prompts Face ID at launch. Lets a UI driver verify the
                // glance-unlock path end to end.
                let derived = SiloKey.derive(passphrase: "faceid-test-pass")
                KeychainStore(service: Self.siloService(derived.siloID)).deleteAll()
                disableBiometricUnlock()
                Self.deleteAllStoreFiles()
                Task {
                    await createAccount(
                        passphrase: "faceid-test-pass", displayName: "FaceID Test")
                    // Present the lock screen directly (a full lockSilo/shutdown
                    // races the still-in-flight startup in this harness); the
                    // running runtime just leaks for the duration of the test.
                    mode = .locked
                }
            }
        #endif
        // Otherwise stay `.locked`: the user must enter a passphrase. We NEVER
        // auto-boot an account — that would reveal one exists.
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

    /// Per-silo UserDefaults key: the bare base for legacy/test (empty silo), or
    /// suffixed by siloID so accounts never share — or accumulate each other's —
    /// settings at rest. A deniability requirement (DEVIATIONS A33): a flat,
    /// device-global key would let one silo (or anyone with file access) read
    /// another silo's content/activity, and a hidden account must leave no such
    /// trace.
    nonisolated static func siloDefaultsKey(_ base: String, _ siloID: String) -> String {
        siloID.isEmpty ? base : "\(base).\(siloID)"
    }

    static func configuredRelayURLs(siloID: String) -> [String] {
        if let env = ProcessInfo.processInfo.environment["PQRC_RELAY_URL"] {
            return [env]
        }
        // Test launches stay hermetic: launch args only exist in dev/test
        // contexts, and a UI test must never depend on a live relay.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--uitest") || arguments.contains("--reset")
            || arguments.contains("--uitest-biometric")
        {
            return ["local"]
        }
        let saved =
            UserDefaults.standard.stringArray(forKey: siloDefaultsKey("relayURLs", siloID)) ?? []
        return saved.isEmpty ? [Self.defaultRelayURL] : saved
    }

    static func setRelayURLs(_ urls: [String], siloID: String) {
        UserDefaults.standard.set(urls, forKey: siloDefaultsKey("relayURLs", siloID))
    }

    /// Retained while this device hosts a Multipeer relay (`host` in the relay
    /// list). Stopped before re-resolving and on lock.
    private var relayHost: NearbyRelayHost?
    /// Retained while this device is JOINED to a nearby relay (`nearby`), so the
    /// "Nearby host's AI" backend can route inference through the same link.
    private var relayClient: MultipeerRelayClient?

    private func makeRelayTransports(siloID: String) async -> [any RelayTransport] {
        await relayHost?.stop()
        relayHost = nil
        await relayClient?.stop()
        relayClient = nil
        var transports: [any RelayTransport] = []
        for configured in Self.configuredRelayURLs(siloID: siloID) {
            switch configured {
            case "local":
                transports.append(await LocalRelaySimulator(url: "local://relay").connect())
            case "host":
                // Host a relay for nearby companions over Multipeer — no router,
                // no public relay (crowded places like a train or airport). The
                // host also shares its on-device AI. MC needs real radios, so this
                // path is verified on hardware, not the simulator.
                let relay = LocalRelaySimulator(url: "nearby://host")
                #if canImport(MultipeerConnectivity)
                    let host = NearbyRelayHost(
                        link: MultipeerNearbyLink(serviceType: "pqrc-relay"),
                        relay: relay, aiAnswer: Self.onDeviceHubAI())
                    try? await host.start()
                    relayHost = host
                #endif
                transports.append(await relay.connect())
            case "nearby":
                // Join a nearby device that's hosting a relay.
                #if canImport(MultipeerConnectivity)
                    let client = MultipeerRelayClient(
                        link: MultipeerNearbyLink(serviceType: "pqrc-relay"))
                    try? await client.start()
                    relayClient = client
                    transports.append(client)
                #else
                    transports.append(await LocalRelaySimulator().connect())
                #endif
            default:
                if let url = URL(string: configured), url.scheme == "ws" || url.scheme == "wss" {
                    transports.append(await NostrWebSocketTransport(url: url).connect())
                }
            }
        }
        if transports.isEmpty {
            transports.append(await LocalRelaySimulator(url: "local://relay").connect())
        }
        return transports
    }

    /// A `HubAIAnswer` backed by this device's on-device model, so a relay host
    /// can share its Apple Intelligence with companions over the link. Returns nil
    /// when on-device AI isn't available.
    private static func onDeviceHubAI() -> HubAIAnswer {
        { system, prompt in
            guard FoundationModelsAgentProvider.isAvailable else { return nil }
            return try? await FoundationModelsAgentProvider.oneShot(
                instructions: system, prompt: prompt)
        }
    }

    /// Token-based API providers and the Keychain account each key is stored
    /// under. Keys live in the Keychain (service `chat.pqrc.keys`), never
    /// UserDefaults.
    static let apiKeyAccounts: [String: String] = [
        "claude": "anthropic-api-key",
        "openai": "openai-api-key",
        "gemini": "gemini-api-key",
        "openrouter": "openrouter-api-key",
        "groq": "groq-api-key",
        "custom": "custom-api-key",
    ]

    /// Provider per the Settings picker. Token-based providers (Claude/OpenAI/
    /// Gemini) read their key from the Keychain; with no key they fall back to
    /// the Demo provider so the AI still visibly responds instead of going
    /// silent. The on-device default uses Core AI (FoundationModels) when
    /// available, Demo otherwise.
    /// Builds a live provider for one backend kind, reading API keys from THIS
    /// silo's Keychain service so accounts never share AI credentials.
    static func makeProvider(
        config: ConfiguredAI, siloID: String, hubClient: MultipeerRelayClient?
    ) -> any AgentProvider {
        let keychain = KeychainStore(service: siloService(siloID))
        func read(_ account: String?) -> String? {
            guard let account, let data = keychain.loadIfPresent(account: account) else { return nil }
            let value = String(decoding: data, as: UTF8.self)
            return value.isEmpty ? nil : value
        }
        func key(for provider: String) -> String? {
            // Per-AI key first (so two AIs of the SAME provider can hold DIFFERENT
            // keys), then the legacy shared account for back-compat.
            read(config.apiKeyAccount) ?? read(apiKeyAccounts[provider])
        }
        let model = config.model ?? ""
        switch config.kind {
        case "claude":
            return key(for: "claude").map { AnthropicAPIProvider(apiKey: $0) } ?? DemoAgentProvider()
        case "openai":
            return key(for: "openai").map { OpenAIAPIProvider(apiKey: $0) } ?? DemoAgentProvider()
        case "gemini":
            return key(for: "gemini").map { GeminiAPIProvider(apiKey: $0) } ?? DemoAgentProvider()
        case "openrouter":
            return key(for: "openrouter").map {
                model.isEmpty
                    ? OpenRouterAPIProvider(apiKey: $0) : OpenRouterAPIProvider(apiKey: $0, model: model)
            } ?? DemoAgentProvider()
        case "groq":
            return key(for: "groq").map {
                model.isEmpty ? GroqAPIProvider(apiKey: $0) : GroqAPIProvider(apiKey: $0, model: model)
            } ?? DemoAgentProvider()
        case "custom":
            // Self-hosted / any OpenAI-compatible server: needs a base URL; the
            // key is OPTIONAL (a local Ollama/LM Studio usually has none). No URL
            // yet → Demo stub so the AI still visibly responds.
            let base = (config.baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.isEmpty else { return DemoAgentProvider() }
            return CustomOpenAIProvider(baseURL: base, apiKey: key(for: "custom") ?? "", model: model)
        case "hub":
            // Borrow a nearby host's AI over the Multipeer link. Needs an active
            // `nearby` relay client; otherwise fall back to the Demo stub.
            return hubClient.map { NearbyHubAIProvider(client: $0) } ?? DemoAgentProvider()
        case "pcc":
            // Apple Private Cloud Compute server model. No API key (on-Apple).
            // Reasoning depth + sampling are baked into the provider instance.
            return PCCFoundationModelsProvider.isAvailable
                ? PCCFoundationModelsProvider(
                    reasoningLevel: config.effectiveReasoning,
                    temperature: config.temperature,
                    maxResponseTokens: config.maxResponseTokens)
                : DemoAgentProvider()
        case "demo":
            return DemoAgentProvider()
        default:  // "ondevice"
            return FoundationModelsAgentProvider.isAvailable
                ? FoundationModelsAgentProvider() : DemoAgentProvider()
        }
    }

    private static func configuredAIsKey(_ siloID: String) -> String { "configuredAIs.\(siloID)" }

    /// This silo's configured AIs (multi-AI tethering), stored per-silo so
    /// accounts don't share AI setup. Defaults to a single on-device AI.
    static func loadConfiguredAIs(siloID: String) -> [ConfiguredAI] {
        if let data = UserDefaults.standard.data(forKey: configuredAIsKey(siloID)),
            let list = try? JSONDecoder().decode([ConfiguredAI].self, from: data),
            !list.isEmpty
        {
            return list
        }
        let def = [
            ConfiguredAI(
                id: UUID().uuidString,
                name: FriendlyName.local(seed: "ai:ondevice:\(siloID)"), kind: "ondevice")
        ]
        saveConfiguredAIs(def, siloID: siloID)
        return def
    }

    static func saveConfiguredAIs(_ list: [ConfiguredAI], siloID: String) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: configuredAIsKey(siloID))
        }
    }

    /// Per-conversation AI context override (Settings → conversation details):
    /// "off" | "marked" | "full", or nil = use each AI's own gather policy.
    /// `nonisolated` so the (actor) PersonaRuntime can read it without an await.
    nonisolated static func conversationContextMode(_ conversationID: String, siloID: String = "")
        -> String?
    {
        UserDefaults.standard.string(forKey: siloDefaultsKey("aiContextMode.\(conversationID)", siloID))
    }
    nonisolated static func setConversationContextMode(
        _ mode: String?, conversationID: String, siloID: String = ""
    ) {
        let key = siloDefaultsKey("aiContextMode.\(conversationID)", siloID)
        if let mode { UserDefaults.standard.set(mode, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// Agent-skills asymmetry knob: a short label of THIS workstation's context
    /// domain (e.g. "iOS / Xcode"), injected into shared-thread prompts so each
    /// tether advertises what it has without dumping its full context.
    nonisolated static func aiContextDomain(siloID: String = "") -> String {
        UserDefaults.standard.string(forKey: siloDefaultsKey("aiContextDomain", siloID)) ?? ""
    }
    nonisolated static func setAIContextDomain(_ value: String, siloID: String = "") {
        let key = siloDefaultsKey("aiContextDomain", siloID)
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { UserDefaults.standard.removeObject(forKey: key) }
        else { UserDefaults.standard.set(t, forKey: key) }
    }

    /// Agent skills pinned to a thread (ids from `AgentSkills.catalog`), appended
    /// to each AI's thread-turn prompt.
    nonisolated static func threadSkills(_ threadID: String, siloID: String = "") -> [String] {
        UserDefaults.standard.stringArray(forKey: siloDefaultsKey("threadSkills.\(threadID)", siloID))
            ?? []
    }
    nonisolated static func setThreadSkills(_ ids: [String], threadID: String, siloID: String = "") {
        let key = siloDefaultsKey("threadSkills.\(threadID)", siloID)
        if ids.isEmpty { UserDefaults.standard.removeObject(forKey: key) }
        else { UserDefaults.standard.set(ids, forKey: key) }
    }

    // MARK: - Custom agent skills (app-layer overlay, per-silo)

    /// User-authored skills overlaid on the built-in `AgentSkills.catalog`. Stored
    /// per-silo (deniability — A33) so accounts never share or accumulate each
    /// other's custom skills at rest, exactly like every other silo-scoped
    /// setting. The package catalog stays the source of truth for built-ins; these
    /// are merged in only for DISPLAY (the Thread Skills picker) and for THREAD
    /// INJECTION (their `fragment` is appended to the thread-turn prompt the same
    /// way a built-in's is). Nothing here ever touches the wire — a skill is just
    /// prompt text, recorded in the thread like any agent message.
    nonisolated static func loadCustomSkills(siloID: String = "") -> [CustomSkill] {
        guard let data = UserDefaults.standard.data(forKey: siloDefaultsKey("customSkills", siloID)),
            let list = try? JSONDecoder().decode([CustomSkill].self, from: data)
        else { return [] }
        return list
    }
    nonisolated static func saveCustomSkills(_ list: [CustomSkill], siloID: String = "") {
        let key = siloDefaultsKey("customSkills", siloID)
        if list.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    /// One custom skill, looked up by its (overlay) id — for thread injection.
    nonisolated static func customSkill(_ id: String, siloID: String = "") -> CustomSkill? {
        loadCustomSkills(siloID: siloID).first { $0.id == id }
    }

    /// Bounds the Settings stepper for the loop-guard threshold (DEVIATIONS D14):
    /// a sensible floor so a human is reliably kept in the loop, up to a high cap.
    /// `nonisolated` so the (actor) PersonaRuntime and the nonisolated setter can
    /// read them without hopping to the main actor.
    nonisolated static let agentLoopGuardMin = 2
    nonisolated static let agentLoopGuardMax = 20

    /// Per-silo loop-guard threshold (DEVIATIONS D14): pause a thread's agents
    /// after this many consecutive agent messages with no human in between.
    /// Returns the spec default (`PQRCConstants.agentLoopGuardLimit`) when unset,
    /// or the user's per-account value — including `0`, which means the guard is
    /// OFF (unbounded). Per-silo so a hidden account never shares/leaks the knob
    /// (A33). `nonisolated` so the (actor) PersonaRuntime can read it without an
    /// await before constructing its engine.
    nonisolated static func agentLoopGuardLimit(siloID: String = "") -> Int {
        let key = siloDefaultsKey("agentLoopGuardLimit", siloID)
        // `object(forKey:)` distinguishes "never set" (use the default) from an
        // explicit `0` (the user turned the guard OFF) — `integer(forKey:)` can't.
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return PQRCConstants.agentLoopGuardLimit
        }
        return UserDefaults.standard.integer(forKey: key)
    }

    /// Persist the per-silo loop-guard threshold. `0` turns the guard OFF; any
    /// positive value is clamped to `[agentLoopGuardMin, agentLoopGuardMax]`.
    nonisolated static func setAgentLoopGuardLimit(_ limit: Int, siloID: String = "") {
        let key = siloDefaultsKey("agentLoopGuardLimit", siloID)
        let clamped = limit <= 0 ? 0 : min(max(limit, agentLoopGuardMin), agentLoopGuardMax)
        UserDefaults.standard.set(clamped, forKey: key)
    }

    /// The configured AIs bound to live providers — the runtime's tethered AIs.
    static func makeRuntimeAIs(siloID: String, hubClient: MultipeerRelayClient?) -> [TetheredAI] {
        loadConfiguredAIs(siloID: siloID).filter(\.isEnabled).map { config in
            TetheredAI(
                id: config.id, name: config.name,
                provider: makeProvider(config: config, siloID: siloID, hubClient: hubClient),
                isRemote: ConfiguredAI.isRemote(config.kind),
                appliesEgressFirewall: ConfiguredAI.appliesEgressFirewall(config.kind),
                instructions: config.instructions,
                contextPolicy: config.effectivePolicy,
                contextDepth: config.effectiveDepth,
                outputMode: config.effectiveOutputMode)
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

    // MARK: - Silos (deniable multi-account)

    static func siloService(_ siloID: String) -> String { "chat.pqrc.silo.\(siloID)" }
    static func siloStoreURL(_ siloID: String) -> URL {
        URL.applicationSupportDirectory.appendingPathComponent("silo-\(siloID).store")
    }
    /// A silo exists iff its wrapped master key is present under its service.
    static func siloExists(_ siloID: String) -> Bool {
        KeychainStore(service: siloService(siloID)).loadIfPresent(account: "wrapped-master-key") != nil
    }
    static func displayNameKey(_ siloID: String) -> String { "displayName.\(siloID)" }

    /// One-time migration of pre-silo (flat) UserDefaults into a silo namespace,
    /// then deletion of the flat originals. The first silo to boot claims any
    /// legacy device-global value; afterwards the flat keys are gone, so nothing
    /// bleeds across accounts or sits readable at rest (deniability — A33). Only
    /// the device-global keys are migrated (`relayURLs`, `aiContextDomain`, and
    /// the `lastReadAt` contact-activity map); per-conversation override keys are
    /// namespaced going forward but not back-migrated (they're keyed by a
    /// silo-specific conversation/thread id, so they never collided across silos).
    private static func migrateFlatDefaults(into siloID: String) {
        let defaults = UserDefaults.standard
        // `displayName` is included because an older build's buggy Settings alias
        // editor wrote it flat; the normal `unlock()` path never cleaned it, so a
        // stale alias could sit readable at rest (security audit, 2026-06-15).
        // `siloDefaultsKey("displayName", siloID)` == `displayNameKey(siloID)`.
        for base in ["relayURLs", "aiContextDomain", "lastReadAt", "displayName"] {
            let flatKey = base
            let scopedKey = siloDefaultsKey(base, siloID)
            if defaults.object(forKey: scopedKey) == nil,
                let flat = defaults.object(forKey: flatKey)
            {
                defaults.set(flat, forKey: scopedKey)
            }
            defaults.removeObject(forKey: flatKey)
        }
    }

    /// Unlock an existing silo by passphrase. Wrong passphrase / no such silo is
    /// reported generically — a typo and a non-existent account are
    /// indistinguishable (deniable).
    func unlock(passphrase: String) async {
        unlockError = nil
        let derived = SiloKey.derive(passphrase: passphrase)
        guard Self.siloExists(derived.siloID) else {
            unlockError = "Couldn't unlock. Check your passphrase, or create a new account."
            return
        }
        await bootSilo(derived)
    }

    /// Create a brand-new silo for a passphrase that has none yet.
    func createAccount(passphrase: String, displayName: String) async {
        unlockError = nil
        let derived = SiloKey.derive(passphrase: passphrase)
        guard !Self.siloExists(derived.siloID) else {
            unlockError = "An account already exists for that passphrase. Unlock it instead."
            return
        }
        UserDefaults.standard.set(
            displayName.isEmpty ? "Me" : displayName, forKey: Self.displayNameKey(derived.siloID))
        await bootSilo(derived)
        // Face ID is the default for the primary account: save its key behind
        // Face ID / Touch ID so the next launch unlocks with a glance. Best-effort
        // and silent — if the device has no biometric/passcode enrolled we just
        // stay passphrase-only (turn it on later in Settings). Only the FIRST
        // account is stored biometrically; hidden accounts stay passphrase-only
        // and deniable.
        enableBiometricByDefault()
    }

    /// Migrate a pre-silo (legacy, Secure-Enclave-wrapped) account into a
    /// passphrase silo, then unlock it. Re-wraps the SAME store master key under
    /// the passphrase (so the store isn't re-encrypted) and moves the store file
    /// to the silo's deterministic name.
    func migrateLegacyAccount(passphrase: String) async {
        unlockError = nil
        let derived = SiloKey.derive(passphrase: passphrase)
        let legacy = KeychainStore(service: "chat.pqrc.keys")
        let silo = KeychainStore(service: Self.siloService(derived.siloID))
        let kekData = derived.kek.withUnsafeBytes { Data($0) }
        let nonce = SystemNonceSource()
        // Identity + small secrets: raw → sealed under the silo key.
        for account in [
            "identity-seed", "nostr-key", "identity-dh", "prekey-state", "my-alias",
            "open-inbox-until",
        ] {
            if let raw = legacy.loadIfPresent(account: account),
                let sealed = try? SiloKey.seal(raw, kek: derived.kek)
            {
                try? silo.save(sealed, account: account)
            }
        }
        // Store master key: unwrap from Secure Enclave, re-wrap under the kek.
        let se = SecureEnclaveKeyWrapper(keychain: legacy)
        if let wrapped = legacy.loadIfPresent(account: "wrapped-master-key"),
            let master = try? se.unwrap(wrapped: wrapped),
            let rewrapped = try? SoftwareKeyWrapper(keyEncryptionKey: kekData, nonceSource: nonce)
                .wrap(masterKey: master)
        {
            try? silo.save(rewrapped, account: "wrapped-master-key")
        }
        // Carry AI API keys (raw, under the silo's service) and the configured-AI
        // list across so the migrated account keeps its AI setup.
        for account in Self.apiKeyAccounts.values {
            if let raw = legacy.loadIfPresent(account: account) {
                try? silo.save(raw, account: account)
            }
        }
        if let aiData = UserDefaults.standard.data(forKey: "configuredAIs") {
            UserDefaults.standard.set(aiData, forKey: Self.configuredAIsKey(derived.siloID))
            UserDefaults.standard.removeObject(forKey: "configuredAIs")
        }
        // Move the store file (and SQLite sidecars) to the silo's name.
        Self.moveStore(
            from: URL.applicationSupportDirectory.appendingPathComponent("default.store"),
            to: Self.siloStoreURL(derived.siloID))
        // Carry the display name across, then erase the legacy footprint.
        let name = UserDefaults.standard.string(forKey: "displayName") ?? "Me"
        UserDefaults.standard.set(name, forKey: Self.displayNameKey(derived.siloID))
        UserDefaults.standard.removeObject(forKey: "displayName")
        legacy.deleteAll()
        await bootSilo(derived)
        enableBiometricByDefault()
    }

    /// Onboarding default: turn on Face ID unlock for the first account, silently.
    /// A failure here (no device passcode/biometric) is NOT surfaced — the
    /// passphrase always works and the user can enable it later from Settings.
    /// Only the first account is stored; hidden accounts stay passphrase-only.
    private func enableBiometricByDefault() {
        guard !hasBiometricUnlock else { return }
        _ = enableBiometricUnlock()
        biometricError = nil
    }

    private func bootSilo(_ derived: SiloKey.Derived) async {
        activeSilo = derived
        // Pull any pre-silo (flat, device-global) UserDefaults into THIS silo's
        // namespace and delete the flat originals, so an older build's settings
        // don't linger readable at rest or bleed across accounts (A33).
        Self.migrateFlatDefaults(into: derived.siloID)
        let name = UserDefaults.standard.string(forKey: Self.displayNameKey(derived.siloID)) ?? "Me"
        let transports = await makeRelayTransports(siloID: derived.siloID)
        let runtime = PersonaRuntime(
            displayName: name,
            transports: transports,
            blobStore: LocalBlossomSimulator(),
            ais: Self.makeRuntimeAIs(siloID: derived.siloID, hubClient: relayClient),
            keychainService: Self.siloService(derived.siloID),
            siloKEK: derived.kek,
            siloID: derived.siloID,
            enableLocalLink: Self.localLinkEnabled)
        await runtime.setFirewallEnabled(Self.firewallEnabled)
        let model = AppModel(runtime: runtime, personaName: name, siloID: derived.siloID)
        do {
            try await model.start(
                inMemoryStore: false, storeURL: Self.siloStoreURL(derived.siloID),
                relayURLs: Self.configuredRelayURLs(siloID: derived.siloID))
            mode = .single(model)
        } catch {
            bootError = String(describing: error)
        }
    }

    /// Lock the current silo and return to the lock screen ("swap accounts").
    func lockSilo() async {
        // Tear the MCP server down FIRST: the redacted store it serves is about to
        // become unreadable, and nothing local-agent-facing may outlive the unlock.
        await stopLocalMCP()
        if case .single(let model) = mode {
            await model.runtime.shutdown()
        }
        await relayHost?.stop()
        relayHost = nil
        await relayClient?.stop()
        relayClient = nil
        activeSilo = nil
        mode = .locked
    }

    // MARK: - Local agent access (in-process MCP server, A35 Phase 2)

    /// The in-process MCP server, alive only while a silo is unlocked AND the
    /// Settings toggle is on. Loopback-only, token-gated, read-only, redacted.
    private var mcpServer: LocalMCPServer?
    /// Last-published connection details, surfaced in Settings so the user can
    /// paste the shim command/token/env into their MCP client. nil when stopped.
    var localMCPConnection: LocalMCPConnection?
    /// Surfaced in Settings if the loopback socket couldn't be bound.
    var localMCPError: String?

    /// Local agent access is a live, in-session state only — there is NO persisted
    /// "expose me" flag and the server is NEVER auto-started on launch (the
    /// cardinal rule: a fresh launch must not silently re-expose chat to local
    /// agents). It is OFF until the user explicitly toggles it on, and stops on
    /// lock. The UI reads this live state, so it stays accurate.
    var isLocalMCPRunning: Bool { mcpServer != nil }

    /// Turn local agent access ON: generate/persist a pairing token, bind a
    /// loopback Unix socket under the app container, host the MCP server over it,
    /// and publish the connection details for Settings to display. Requires an
    /// unlocked silo. Idempotent — a second call republishes the same details.
    func startLocalMCP() async {
        guard case .single(let model) = mode, let siloID = activeSilo?.siloID else {
            localMCPError = "Unlock an account first."
            return
        }
        guard mcpServer == nil else { return }
        localMCPError = nil

        let token = Self.pairingToken(siloID: siloID)
        // A short, unguessable socket path UNDER the app's temp dir (inside the
        // container) — a UDS path has a ~104-byte limit, so keep it short.
        let socketPath = NSTemporaryDirectory() + "eldr-mcp-\(UUID().uuidString.prefix(8)).sock"
        let bridge = RuntimeSecureChatBridge(model: model)
        let server = LocalMCPServer(bridge: bridge, token: token, socketPath: socketPath)
        do {
            try await server.start()
            mcpServer = server
            localMCPConnection = LocalMCPConnection(socketPath: socketPath, token: token)
        } catch {
            localMCPError = "Couldn't start the local MCP server: \(error)."
            localMCPConnection = nil
        }
    }

    /// Turn local agent access OFF: stop the server and clear the published
    /// details. Called on the toggle and on lock.
    func stopLocalMCP() async {
        await mcpServer?.stop()
        mcpServer = nil
        localMCPConnection = nil
        localMCPError = nil
    }

    /// Keychain account (within the per-silo service) holding the MCP pairing
    /// token. Per-silo so a hidden account never shares/leaks it (deniability).
    private static let mcpPairingTokenAccount = "mcp-pairing-token"

    /// A random pairing token for this silo, persisted in its Keychain so it's
    /// stable across launches (and protected at rest), generated on first use.
    private static func pairingToken(siloID: String) -> String {
        let keychain = KeychainStore(service: siloService(siloID))
        if let existing = keychain.loadIfPresent(account: mcpPairingTokenAccount),
            let value = String(data: existing, encoding: .utf8), !value.isEmpty
        {
            return value
        }
        return mintPairingToken(siloID: siloID)
    }

    /// Mint a fresh random pairing token and persist it, REPLACING any existing
    /// one. Used both for first-use generation and explicit regeneration.
    @discardableResult
    private static func mintPairingToken(siloID: String) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = Data(bytes).base64EncodedString()
        try? KeychainStore(service: siloService(siloID)).save(
            Data(token.utf8), account: mcpPairingTokenAccount)
        return token
    }

    /// Regenerate the per-silo MCP pairing token: mint a fresh one (invalidating
    /// the old one — any connected shim must re-pair with the new token), and if
    /// the local MCP server is currently running, restart it so it serves the new
    /// token and `localMCPConnection` republishes it for Settings to display.
    /// No-op without an unlocked silo.
    func regenerateMCPPairingToken() async {
        guard let siloID = activeSilo?.siloID else {
            localMCPError = "Unlock an account first."
            return
        }
        Self.mintPairingToken(siloID: siloID)
        // If the server is live, cycle it onto the new token. The published
        // connection (and the socket path) updates so the displayed token matches
        // what the server now enforces; the user must re-paste it into their MCP
        // client. If it's not running, the fresh token simply waits in Keychain.
        if isLocalMCPRunning {
            await stopLocalMCP()
            await startLocalMCP()
        }
    }

    // MARK: - Biometric convenience unlock (one primary silo)

    /// Holds {siloID, kek} for the one silo unlockable by Face ID / Touch ID.
    /// Its presence reveals only that A primary account exists — hidden silos are
    /// never stored here, so they stay passphrase-only and deniable.
    private struct BiometricSilo: Codable {
        let siloID: String
        let kek: Data
    }
    private static let biometricService = "chat.pqrc.biometric"
    private static let biometricAccount = "primary"

    /// Surfaced in Settings when enabling Face ID unlock fails (e.g. no device
    /// passcode set, so a `.userPresence` Keychain item can't be created).
    var biometricError: String?

    var hasBiometricUnlock: Bool {
        KeychainStore(service: Self.biometricService).contains(account: Self.biometricAccount)
    }

    /// Opt-in convenience: save the unlocked silo's key to the Keychain behind
    /// Face ID / Touch ID, so the next launch can unlock with a glance instead of
    /// the passphrase. Off by default; turned on from Settings ▸ Account. Returns
    /// false (and sets `biometricError`) if the system refuses to store it.
    @discardableResult
    func enableBiometricUnlock() -> Bool {
        guard let derived = activeSilo else { return false }
        let record = BiometricSilo(
            siloID: derived.siloID, kek: derived.kek.withUnsafeBytes { Data($0) })
        guard let blob = try? JSONEncoder().encode(record) else { return false }
        do {
            try KeychainStore(service: Self.biometricService)
                .saveBiometric(blob, account: Self.biometricAccount)
            biometricError = nil
            return true
        } catch {
            // Almost always: no device passcode / no enrolled biometric, which
            // a `.userPresence` item requires. Say so instead of failing silently.
            biometricError =
                "Couldn't turn on Face ID unlock. Set a device passcode (and enroll Face ID / Touch ID) in iOS Settings first, then try again."
            return false
        }
    }

    func disableBiometricUnlock() {
        biometricError = nil
        KeychainStore(service: Self.biometricService).delete(account: Self.biometricAccount)
    }

    /// Try to unlock via the Keychain-saved key behind Face ID / Touch ID.
    /// `autoTriggered` is the silent launch attempt: a cancel/failure there must
    /// not show a scary error (the user may simply want to type a hidden
    /// account's passphrase). An explicit tap reports a real failure.
    func biometricUnlock(autoTriggered: Bool = false) async {
        unlockError = nil
        let service = Self.biometricService
        let account = Self.biometricAccount
        let outcome = await Task.detached {
            KeychainStore(service: service).loadBiometric(account: account, prompt: "Unlock EldrChat")
        }.value
        switch outcome {
        case .success(let blob):
            guard let record = try? JSONDecoder().decode(BiometricSilo.self, from: blob),
                Self.siloExists(record.siloID)
            else {
                if !autoTriggered {
                    unlockError = "That account is no longer on this device. Enter your passphrase."
                }
                return
            }
            await bootSilo(
                SiloKey.Derived(siloID: record.siloID, kek: SymmetricKey(data: record.kek)))
        case .cancelled, .missing:
            // Quiet: the user cancelled, or nothing is enrolled — fall back to
            // the passphrase field that's always on screen.
            return
        case .failed:
            if !autoTriggered {
                unlockError = "Face ID didn't work. Enter your passphrase, or try Face ID again."
            }
        }
    }

    /// Move a SwiftData store plus its SQLite -wal/-shm sidecars.
    private static func moveStore(from: URL, to: URL) {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: from.path + suffix)
            let dst = URL(fileURLWithPath: to.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            try? fm.removeItem(at: dst)
            try? fm.moveItem(at: src, to: dst)
        }
    }

    /// `--reset` only: nuke every on-disk store so a dev/test wipe is total.
    private static func deleteAllStoreFiles() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: URL.applicationSupportDirectory, includingPropertiesForKeys: nil)
        else { return }
        for url in files where url.lastPathComponent.contains(".store") {
            try? fm.removeItem(at: url)
        }
    }

    /// Tears the current silo down and boots it again — the apply path for
    /// relay-list and Nearby changes from Settings (reuses the unlocked key).
    func rebootSingle() async {
        guard let derived = activeSilo else { return }
        // Stop the MCP server: its bridge points at the model we're about to
        // replace, so it must not outlive the reboot (the user re-enables it).
        await stopLocalMCP()
        if case .single(let model) = mode {
            await model.runtime.shutdown()
        }
        mode = .locked
        await bootSilo(derived)
    }

    /// The unlocked silo's id, for per-account AI settings (nil while locked).
    var activeSiloID: String? { activeSilo?.siloID }

    /// Re-resolves the tethered AIs + egress-firewall state after a Settings
    /// change (no reboot needed).
    func applyAIProvider() async {
        guard case .single(let model) = mode, let siloID = activeSilo?.siloID else { return }
        await model.runtime.setAIs(Self.makeRuntimeAIs(siloID: siloID, hubClient: relayClient))
        await model.runtime.setFirewallEnabled(Self.firewallEnabled)
    }

    /// Test ONE configured AI on demand (Settings ▸ AI per-row "Test"). Builds the
    /// provider exactly as the runtime would — this silo's Keychain key, base URL,
    /// model, PCC reasoning, etc. — runs a one-line sample, and returns the reply
    /// or a readable failure reason. Works for ANY row (enabled or not) and
    /// reflects the row's CURRENT settings, so it doesn't depend on the runtime
    /// having refreshed. Drafts only (never posts), so no window/consent is needed.
    func testProvider(for config: ConfiguredAI) async -> String {
        let siloID = activeSilo?.siloID ?? ""
        let provider = Self.makeProvider(config: config, siloID: siloID, hubClient: relayClient)
        let name = UserDefaults.standard.string(forKey: Self.displayNameKey(siloID)) ?? "Me"
        let sample = AgentContext(
            myIdentityHex: "test", myDisplayName: name,
            transcript: [
                TranscriptEntry(
                    senderIdentityHex: "sample", senderDisplayName: "Test",
                    participantType: .human,
                    text: "Hi! Are you working? Reply in one short sentence.")
            ],
            instructions: config.instructions)
        do {
            let text = try await provider.draftReply(context: sample).text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "⚠️ Connected, but the model returned an empty reply." : text
        } catch {
            return "⚠️ " + AppModel.describeAgentError(error)
        }
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
            // The Configurator marks its pairing link `&type=coding_agent` so the phone
            // tags the agent contact (lets the watch-along draft path recognize it).
            pendingContactType = components?.queryItems?.first(where: { $0.name == "type" })?.value
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
        case .locked, .onboarding: return nil
        case .single(let model): return model
        case .universe(let universe, let selected): return universe.models[selected]
        }
    }
}

struct RootView: View {
    @Environment(AppSession.self) private var session
    /// The "venturing on unknown seas" first-run tour. Lives here (RootView) so it
    /// overlays the whole app without touching MainView/ConversationView, and is
    /// shared into the environment so Settings ▸ About can relaunch it.
    @State private var tour = TourCoordinator()

    var body: some View {
        content
            .environment(tour)
            .onboardingTour(tour, activeSiloID: session.activeSiloID)
            // First entry into a real account → present the welcome tour once.
            // (`.onChange` covers unlock/create; `.task` covers a same-launch boot.)
            .onChange(of: isSingleMode) { _, single in
                if single { tour.presentIfFirstRun(siloID: session.activeSiloID) }
            }
            .task {
                if isSingleMode { tour.presentIfFirstRun(siloID: session.activeSiloID) }
            }
    }

    /// True only for a real unlocked account (not the lock screen or demo).
    private var isSingleMode: Bool {
        if case .single = session.mode { return true }
        return false
    }

    @ViewBuilder private var content: some View {
        switch session.mode {
        case .locked, .onboarding:
            AccountGateView()
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
