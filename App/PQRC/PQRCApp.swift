import CryptoKit
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

    static var configuredRelayURLs: [String] {
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
        "openrouter": "openrouter-api-key",
    ]

    /// Provider per the Settings picker. Token-based providers (Claude/OpenAI/
    /// Gemini) read their key from the Keychain; with no key they fall back to
    /// the Demo provider so the AI still visibly responds instead of going
    /// silent. The on-device default uses Core AI (FoundationModels) when
    /// available, Demo otherwise.
    /// Builds a live provider for one backend kind, reading API keys from THIS
    /// silo's Keychain service so accounts never share AI credentials.
    static func makeProvider(kind: String, siloID: String) -> any AgentProvider {
        let keychain = KeychainStore(service: siloService(siloID))
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
        case "openrouter":
            return key(for: "openrouter").map { OpenRouterAPIProvider(apiKey: $0) } ?? DemoAgentProvider()
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

    /// The configured AIs bound to live providers — the runtime's tethered AIs.
    static func makeRuntimeAIs(siloID: String) -> [TetheredAI] {
        loadConfiguredAIs(siloID: siloID).map {
            TetheredAI(
                id: $0.id, name: $0.name,
                provider: makeProvider(kind: $0.kind, siloID: siloID),
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

    // MARK: - Silos (deniable multi-account)

    static func siloService(_ siloID: String) -> String { "chat.pqrc.silo.\(siloID)" }
    static func siloStoreURL(_ siloID: String) -> URL {
        URL.applicationSupportDirectory.appendingPathComponent("silo-\(siloID).store")
    }
    /// A silo exists iff its wrapped master key is present under its service.
    static func siloExists(_ siloID: String) -> Bool {
        KeychainStore(service: siloService(siloID)).loadIfPresent(account: "wrapped-master-key") != nil
    }
    private static func displayNameKey(_ siloID: String) -> String { "displayName.\(siloID)" }

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
        let name = UserDefaults.standard.string(forKey: Self.displayNameKey(derived.siloID)) ?? "Me"
        let transports = await makeRelayTransports()
        let runtime = PersonaRuntime(
            displayName: name,
            transports: transports,
            blobStore: LocalBlossomSimulator(),
            ais: Self.makeRuntimeAIs(siloID: derived.siloID),
            keychainService: Self.siloService(derived.siloID),
            siloKEK: derived.kek,
            enableLocalLink: Self.localLinkEnabled)
        await runtime.setFirewallEnabled(Self.firewallEnabled)
        let model = AppModel(runtime: runtime, personaName: name)
        do {
            try await model.start(
                inMemoryStore: false, storeURL: Self.siloStoreURL(derived.siloID),
                relayURLs: Self.configuredRelayURLs)
            mode = .single(model)
        } catch {
            bootError = String(describing: error)
        }
    }

    /// Lock the current silo and return to the lock screen ("swap accounts").
    func lockSilo() async {
        if case .single(let model) = mode {
            await model.runtime.shutdown()
        }
        activeSilo = nil
        mode = .locked
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
        await model.runtime.setAIs(Self.makeRuntimeAIs(siloID: siloID))
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
        case .locked, .onboarding: return nil
        case .single(let model): return model
        case .universe(let universe, let selected): return universe.models[selected]
        }
    }
}

struct RootView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
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
