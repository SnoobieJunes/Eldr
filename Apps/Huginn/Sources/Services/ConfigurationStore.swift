import Combine
import Foundation
import PQRCACP

/// The single source of truth for eldr-acp configuration, bridging the GUI to the
/// on-disk files the CLI actually reads. It loads by parsing those files back through
/// the SAME `LLMConfig.fromEnvironment` / `AgentConfig.fromEnvironment` the binary
/// uses (no duplicated parsing), and saves (debounced) by writing them out again.
///
/// Layout written (matching AgentConfig's reader, confirmed from source):
///  - `<configDir>/env`            — `export KEY=value` lines; the launcher sources it
///  - `<configDir>/tools`          — newline tool allowlist (`parseToolList`)
///  - `<configDir>/skills`         — skills boolean / name list
///  - `<configDir>/prompt-preamble`
///  - `<configDir>/system-prompt`
@MainActor
final class ConfigurationStore: ObservableObject {

    // MARK: LLM (env file)
    @Published var llmURL: String
    @Published var llmToken: String
    @Published var llmModel: String
    /// Let a vision-capable model receive node-side images (`ELDR_LLM_VISION`). Off by
    /// default — most local models are text-only and would choke on image input.
    @Published var visionEnabled: Bool

    // MARK: Context budget (env file)
    @Published var maxToolResultBytes: Int
    /// Read-side cap: how much of a file `read_file` pulls off disk before truncating,
    /// so a huge file can't OOM the agent (`ELDR_ACP_MAX_READ_FILE_BYTES`). 0 = no cap.
    @Published var maxReadFileBytes: Int
    @Published var maxHistoryTurns: Int
    @Published var maxContextChars: Int
    /// A2: how many of the most-recent tool results stay verbatim in history; older
    /// ones are stubbed to one line (`ELDR_ACP_TOOL_RESULT_KEEP`). Default 4.
    @Published var toolResultKeepVerbatim: Int
    /// A2: spill an oversized tool result to a jail-inside file so the model can page
    /// the rest via read_file, instead of losing it to truncation
    /// (`ELDR_ACP_TOOL_RESULT_SPILL`). Default on.
    @Published var toolResultSpillEnabled: Bool

    // MARK: Agent limits (env file) — all 0 = unlimited (the engine's default).
    /// Cap on the agent's tool-call loop (`ELDR_ACP_MAX_ITERATIONS`).
    @Published var maxAgentSteps: Int
    /// Per-LLM-request wall-clock timeout in seconds (`ELDR_LLM_TIMEOUT_SECONDS`).
    @Published var llmTimeoutSeconds: Int
    /// Per-shell-command watchdog timeout in seconds (`ELDR_ACP_SHELL_TIMEOUT`).
    @Published var shellTimeoutSeconds: Int
    /// How long to wait for you to answer a tool-permission prompt before denying it,
    /// in seconds (`ELDR_ACP_PERMISSION_TIMEOUT`). Default 120.
    @Published var permissionTimeoutSeconds: Int

    // MARK: Security (env file)
    /// DANGEROUS: run mutating tools (write/edit/shell) WITHOUT asking permission
    /// (`ELDR_ACP_ALLOW_UNGATED_TOOLS`). Off by default (each change prompts). Only for
    /// a fully trusted, isolated machine.
    @Published var allowUngatedTools: Bool
    /// WS3e: the node-operator half of `delegate_to_cloud_agent`'s fail-closed gate
    /// (`ELDR_ACP_ALLOW_CLOUD_DELEGATION`) — a HARD off-switch, independent of
    /// `allowUngatedTools`, checked before the agent spawns any cloud CLI at all. Off
    /// by default. The tool call ITSELF still needs a phone permission card on top of
    /// this (the same allow-once/always/deny every mutating tool gets).
    @Published var cloudAgentDelegationEnabled: Bool

    // MARK: Tools / skills / prompts (individual files)
    /// Names of the built-in tools the agent may use. Empty in AgentConfig means
    /// "all"; the UI always shows the four checkboxes, so we persist the explicit set.
    @Published var enabledTools: Set<String>
    @Published var skillsEnabled: Bool
    /// Which built-in skills to advertise when skills are on (subset of `allSkillNames`;
    /// full set = "all"). Persisted via the `skills` file / `ELDR_ACP_SKILLS`.
    @Published var enabledSkills: Set<String>
    @Published var promptPreamble: String
    @Published var systemPromptOverride: String

    // MARK: Project memory (Phase 3) — events.jsonl drives ContextLearner.
    /// When false, the env file sets `ELDR_ACP_EVENTS_FILE=` (empty) so the agent
    /// emits no events and the learner goes idle.
    @Published var learningEnabled: Bool
    /// Explicit project context file (`eldr.md`) prepended to every session
    /// (`ELDR_ACP_CONTEXT_FILE`). Empty = auto-discover per project.
    @Published var contextFilePath: String

    // MARK: contextgraph (graph-based context manager) — env file.
    /// Route context assembly through the contextgraph service. Off → unchanged.
    @Published var contextGraphEnabled: Bool
    /// contextgraph REST endpoint the agent calls (and the wizard health-checks).
    @Published var contextGraphURL: String
    /// contextgraph channel/agent label so per-project graphs stay separate
    /// (`ELDR_ACP_CONTEXTGRAPH_AGENT`). Empty = derived from the session folder.
    @Published var contextGraphAgentName: String

    // MARK: WS3b — cloud-CLI harness vendor keys (Keychain only, never the env file or
    // a descriptor's static `env`). Huginn spawns `claude-agent-acp`/`gemini` itself via
    // `runHarness`, so it merges the key into a COPY of the descriptor's `env`
    // (`HarnessDescriptor.withVendorKey`) at launch — the key never sits in `ELDR_*`
    // where a `run_shell`/`open_terminal` child (or a prompt-injected local model)
    // could read it. Empty = no key on file (the harness still launches, without one).
    @Published var claudeCodeAPIKey: String
    @Published var geminiAPIKey: String
    private static let claudeCodeKeyAccount = "vendor-key-claude-code"
    private static let geminiKeyAccount = "vendor-key-gemini-cli"

    /// `.a2aRemote` bearer tokens — ONE per descriptor id (unlike the fixed claude/gemini
    /// scalars above, a node can select among several `.a2aRemote` descriptors), mirroring
    /// `withVendorKey`'s launch-scoped-secret pattern for `withBearerToken`. Read/written via
    /// `a2aBearerToken(for:)` / `setA2ABearerToken(_:for:)`, bound by the UI through a local
    /// `@State` (see `BridgeView`) — same Keychain storage flow as the vendor keys.
    private static func a2aBearerAccount(for descriptorID: String) -> String {
        "vendor-a2a-bearer-\(descriptorID)"
    }

    func a2aBearerToken(for descriptorID: String) -> String {
        keychain.load(account: Self.a2aBearerAccount(for: descriptorID))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func setA2ABearerToken(_ token: String, for descriptorID: String) {
        saveOrDelete(token, account: Self.a2aBearerAccount(for: descriptorID))
    }

    // MARK: AC94 — harness executable overrides (defaults + env-file mirror)

    /// Per-descriptor absolute-executable overrides, keyed by descriptor id. A path
    /// is not a secret, so UserDefaults (not Keychain); mirrored into the agent env
    /// file (`ELDR_HARNESS_CMD_<ID>`) so the CLI-side `delegate_to_cloud_agent`
    /// resolves the SAME binary as Huginn's own spawns.
    static let harnessCommandOverridesKey = "harnessCommandOverrides"

    /// The operator-pinned executable for a `.stdioSpawn` harness, or "" when the
    /// registry default stands.
    static func harnessCommandOverride(
        for id: String, defaults: UserDefaults = .standard
    ) -> String {
        (defaults.dictionary(forKey: harnessCommandOverridesKey) as? [String: String])?[id] ?? ""
    }

    func harnessCommandOverride(for id: String) -> String {
        Self.harnessCommandOverride(for: id, defaults: defaults)
    }

    /// Persist (empty = clear) the executable override for `id`, then rewrite the env
    /// file so launchd/CLI consumers see it without waiting for the next Save.
    func setHarnessCommandOverride(_ path: String, for id: String) {
        var overrides =
            (defaults.dictionary(forKey: Self.harnessCommandOverridesKey) as? [String: String])
            ?? [:]
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            overrides.removeValue(forKey: id)
        } else {
            overrides[id] = trimmed
        }
        if overrides.isEmpty {
            defaults.removeObject(forKey: Self.harnessCommandOverridesKey)
        } else {
            defaults.set(overrides, forKey: Self.harnessCommandOverridesKey)
        }
        writeEnvFile()
    }

    // MARK: sybilclaw gateway (Huginn-only pref — NOT an eldr-acp env var)
    /// The port sybilclaw's gateway daemon listens on (default 18789). Used by the
    /// Connections panel's status probe (and, later, the gateway bridge). `eldr-acp`
    /// itself has no port, so this is persisted to UserDefaults, never the env file.
    @Published var sybilclawGatewayPort: Int
    static let gatewayPortKey = "sybilclawGatewayPort"
    static let defaultGatewayPort = 18789

    /// WS-B5: which Gateway vendor is on the other end of `sybilclawGatewayPort` — the
    /// cofounder's **sybilclaw** fork (the default; what every other gateway string in
    /// this file assumed before this existed) or a **vanilla OpenClaw** install. The wire
    /// protocol is IDENTICAL either way (same handshake, same `chat.send`/event stream —
    /// see `SybilclawGatewayClient`), so this changes only labeling/captions and which
    /// on-disk config the setup wizard's harness-registration step defaults to
    /// (`ConfigPaths.defaultGatewayConfig(for:)`) — collapsing what used to be a
    /// wizard-local, unpersisted `HarnessKindUI` choice AND a hardcoded "sybilclaw"
    /// caption/registration-check elsewhere in this UI into ONE stored preference both
    /// surfaces read.
    enum GatewayFlavor: String, CaseIterable, Identifiable, Sendable {
        case sybilclaw
        case openClaw = "openclaw"
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .sybilclaw: return "sybilclaw"
            case .openClaw: return "OpenClaw"
            }
        }
    }
    @Published var gatewayFlavor: GatewayFlavor
    static let gatewayFlavorKey = "gatewayFlavor"

    /// WS-B6: bumped every time `HarnessRegistration.apply` runs to completion
    /// (`SetupWizardView.registerHarness()`), so any view that reads
    /// `HarnessRegistration.isRegistered` — the Configuration ▸ Status tab's
    /// "Registered in acpx"/"Registered in <gateway>" rows — knows to recompute
    /// instead of showing whatever it captured on its own first appearance. In-memory
    /// only (not persisted; a stale revision count on next launch is harmless, the
    /// rows re-derive from disk on mount regardless).
    @Published private(set) var harnessRegistrationRevision = 0
    func noteHarnessRegistrationChanged() { harnessRegistrationRevision += 1 }

    // MARK: WS-B1 — Test Chat workspace + tool policy (Huginn-only prefs; NOT
    // eldr-acp env vars — these only govern the in-app Test Chat harness).
    /// The folder Test Chat's tools (read_file/write_file/run_shell) operate in.
    /// Empty ⇒ Test Chat falls back to a throwaway scratch dir, same as before this
    /// setting existed. Persisted to UserDefaults (like `sybilclawGatewayPort`), not
    /// the CLI's env file. Seeded ONCE, the first time this store loads with no saved
    /// value yet, from the Bridge's own "Agent project folder"
    /// (`ACPBridgeService.agentWorkdir`, on disk at `<configDir>/workdir`) if that's
    /// already set — most people configuring the Bridge want the same project in
    /// Test Chat, and this saves them a second folder pick.
    @Published var testChatWorkspacePath: String
    /// When ON, Test Chat auto-grants every tool permission request (the old,
    /// silent-only behavior — now visibly annotated in the transcript instead). When
    /// OFF (the default), each mutating tool call waits for an explicit Approve/Deny
    /// in the chat UI and fails closed (denied) on timeout or session teardown.
    @Published var testChatAutoApprove: Bool
    static let testChatWorkspaceKey = "testChatWorkspacePath"
    static let testChatAutoApproveKey = "testChatAutoApprove"

    /// When ON, inbound A2A tasks skip the per-task approval UI and run immediately —
    /// the headless/CLI mode the served endpoint exists for. Are-you-sure-confirmed in
    /// the Bridge tab; persists until turned off. Tool use inside an auto-approved
    /// task still follows `allowUngatedTools` (AC108) — this toggle never grants
    /// tools by itself. Huginn-only pref (UserDefaults, like `testChatAutoApprove`).
    @Published var a2aAutoApprove: Bool
    static let a2aAutoApproveKey = "a2aAutoApprove"

    /// WS-D: the user-editable quick-command chips rendered above Test Chat's
    /// composer (shared `CustomCommand` type with the phone terminal's strip).
    /// Seeded ONCE — first load with no saved value — from the enabled skills
    /// (`/spec /snippet /html`), then fully user-owned (add/reorder/delete).
    /// Huginn-only pref (UserDefaults), never an eldr-acp env var.
    @Published var customCommands: [CustomCommand]
    static let customCommandsKey = "testChatCustomCommands"

    /// The four built-in tools, in advertise order (mirrors ToolExecutor.allToolNames).
    static let allToolNames = ["read_file", "write_file", "list_dir", "run_shell"]
    /// The built-in skill command names, in advertise order (mirrors PQRCACP's
    /// `AgentSkill.builtIns`: createSpec / generateSnippet / visualizeHTML).
    static let allSkillNames = ["spec", "snippet", "html"]

    let paths: ConfigPaths
    private var saveCancellable: AnyCancellable?
    private var loaded = false
    /// C-8: the LLM token is kept in the Keychain (WhenUnlockedThisDeviceOnly), never
    /// in the cleartext env file. Injectable so tests can isolate to their own service.
    private let keychain: KeychainBox
    private static let tokenAccount = "llm-token"

    /// AC94: injectable so tests keep harness-command overrides out of the real defaults.
    private let defaults: UserDefaults

    init(
        paths: ConfigPaths = .standard, keychain: KeychainBox = KeychainBox(),
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        self.paths = paths
        self.keychain = keychain

        // Load by re-reading the files through the binary's own parsers.
        let env = ConfigurationStore.parseEnvFile(at: paths.envFile)
        let llm = LLMConfig.fromEnvironment(env)
        let agent = AgentConfig.fromEnvironment(env, configDir: paths.configDir)

        llmURL = llm.url
        // C-8: prefer the Keychain token; fall back to a legacy env-file token (then
        // migrated to the Keychain and dropped from the file on the next save).
        llmToken =
            keychain.load(account: Self.tokenAccount).flatMap { String(data: $0, encoding: .utf8) }
            ?? llm.token
        llmModel = llm.model
        visionEnabled = agent.visionEnabled
        // AgentConfig clamps a non-positive byte cap to Int.max ("unbounded"); show 0
        // for that so the field round-trips cleanly.
        maxToolResultBytes = agent.maxToolResultBytes == Int.max ? 0 : agent.maxToolResultBytes
        maxReadFileBytes = agent.maxReadFileBytes == Int.max ? 0 : agent.maxReadFileBytes
        maxHistoryTurns = agent.maxHistoryTurns
        maxContextChars = agent.maxContextChars
        toolResultKeepVerbatim = agent.toolResultKeepVerbatim
        toolResultSpillEnabled = agent.toolResultSpillEnabled
        maxAgentSteps = agent.maxIterations
        shellTimeoutSeconds = Int(agent.shellTimeoutSeconds)
        llmTimeoutSeconds = Int(llm.requestTimeoutSeconds)
        permissionTimeoutSeconds = Int(agent.permissionTimeoutSeconds)
        allowUngatedTools = agent.allowUngatedTools
        cloudAgentDelegationEnabled = agent.cloudAgentDelegationEnabled
        enabledTools =
            agent.toolAllowlist.isEmpty
            ? Set(ConfigurationStore.allToolNames) : Set(agent.toolAllowlist)
        skillsEnabled = agent.skillsEnabled
        enabledSkills = agent.skillAllowlist.map(Set.init) ?? Set(ConfigurationStore.allSkillNames)
        promptPreamble = agent.promptPreamble ?? ""
        systemPromptOverride = agent.systemPromptOverride ?? ""
        learningEnabled = (agent.eventsFilePath?.isEmpty == false)
        contextFilePath = agent.contextFilePath ?? ""
        contextGraphEnabled = agent.contextGraphEnabled
        contextGraphURL = agent.contextGraphURL
        contextGraphAgentName = agent.contextGraphAgentName ?? ""
        sybilclawGatewayPort =
            (UserDefaults.standard.object(forKey: Self.gatewayPortKey) as? Int)
            ?? Self.defaultGatewayPort
        // WS-B5: no prior key ever existed for this, so there is nothing to migrate —
        // defaulting to `.sybilclaw` exactly matches every existing install's actual
        // (previously unstated) assumption.
        gatewayFlavor =
            GatewayFlavor(rawValue: UserDefaults.standard.string(forKey: Self.gatewayFlavorKey) ?? "")
            ?? .sybilclaw
        // First load with nothing saved yet: seed from the Bridge's own workdir file
        // rather than defaulting to empty (= scratch dir). Once a value is saved
        // (even back to "", via the "Use scratch dir" action), that choice sticks.
        testChatWorkspacePath =
            UserDefaults.standard.string(forKey: Self.testChatWorkspaceKey)
            ?? ConfigurationStore.loadTextFile(at: paths.workdirFile) ?? ""
        testChatAutoApprove =
            (UserDefaults.standard.object(forKey: Self.testChatAutoApproveKey) as? Bool) ?? false
        a2aAutoApprove =
            (UserDefaults.standard.object(forKey: Self.a2aAutoApproveKey) as? Bool) ?? false
        // WS-D: saved list wins; first-ever load seeds from the enabled skills in
        // advertise order (mirrors skillsFileContents' ordering).
        if let saved = CustomCommand.decodeList(
            UserDefaults.standard.data(forKey: Self.customCommandsKey))
        {
            customCommands = saved
        } else {
            let seedSkills =
                agent.skillsEnabled
                ? ConfigurationStore.allSkillNames.filter {
                    (agent.skillAllowlist.map(Set.init) ?? Set(ConfigurationStore.allSkillNames))
                        .contains($0)
                }
                : []
            customCommands = CustomCommand.seeded(fromSkills: seedSkills)
        }
        claudeCodeAPIKey =
            keychain.load(account: Self.claudeCodeKeyAccount)
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        geminiAPIKey =
            keychain.load(account: Self.geminiKeyAccount)
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""

        loaded = true
        // Debounced auto-save: any published change schedules one write 0.5s after the
        // last edit. The delay also dodges the @Published willSet timing — by the time
        // the sink fires, the stored properties already hold their new values.
        saveCancellable =
            objectWillChange
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] in self?.save() }
    }

    // MARK: - Save

    func save() {
        guard loaded else { return }
        // Huginn-only prefs (no eldr-acp env var): persisted separately from the CLI files.
        UserDefaults.standard.set(sybilclawGatewayPort, forKey: Self.gatewayPortKey)
        UserDefaults.standard.set(gatewayFlavor.rawValue, forKey: Self.gatewayFlavorKey)
        UserDefaults.standard.set(testChatWorkspacePath, forKey: Self.testChatWorkspaceKey)
        UserDefaults.standard.set(testChatAutoApprove, forKey: Self.testChatAutoApproveKey)
        UserDefaults.standard.set(a2aAutoApprove, forKey: Self.a2aAutoApproveKey)
        if let data = CustomCommand.encodeList(customCommands) {
            UserDefaults.standard.set(data, forKey: Self.customCommandsKey)
        }
        saveTokenToKeychain()
        saveVendorKeysToKeychain()
        writeEnvFile()
        writeFile(paths.toolsFile, contents: toolsFileContents())
        writeFile(paths.skillsFile, contents: skillsFileContents())
        writeFile(paths.preambleFile, contents: promptPreamble)
        writeFile(paths.systemPromptFile, contents: systemPromptOverride)
    }

    /// The `skills` file contents (parsed by `AgentConfig.parseSkills`): "0" when off,
    /// "1" when ALL built-ins are on, else the comma-separated subset.
    private func skillsFileContents() -> String {
        guard skillsEnabled else { return "0" }
        if enabledSkills.count >= Self.allSkillNames.count { return "1" }
        let ordered = Self.allSkillNames.filter { enabledSkills.contains($0) }
        return ordered.isEmpty ? "0" : ordered.joined(separator: ",")
    }

    /// The env file the launcher `source`s. Only simple scalar values live here;
    /// the long prompt strings are their own files (read directly by AgentConfig).
    private func writeEnvFile() {
        var lines: [String] = [
            "# Written by Huginn — do not edit by hand.",
            export("ELDR_LLM_URL", llmURL),
            // C-8: ELDR_LLM_TOKEN is intentionally NOT written here — it used to land in
            // cleartext at the umask (commonly world-readable). It's in the Keychain now;
            // the Configurator injects it when spawning the launcher, and the launcher
            // reads it from the Keychain for external clients (Xcode/OpenClaw).
            export("ELDR_LLM_MODEL", llmModel),
            export("ELDR_LLM_VISION", visionEnabled ? "1" : "0"),
            export("ELDR_ACP_MAX_TOOL_RESULT_BYTES", String(maxToolResultBytes)),
            export("ELDR_ACP_MAX_READ_FILE_BYTES", String(maxReadFileBytes)),
            export("ELDR_ACP_MAX_HISTORY_TURNS", String(maxHistoryTurns)),
            export("ELDR_ACP_MAX_CONTEXT_CHARS", String(maxContextChars)),
            // A2: tool-result aging (verbatim-keep count) + spill-to-file.
            export("ELDR_ACP_TOOL_RESULT_KEEP", String(toolResultKeepVerbatim)),
            export("ELDR_ACP_TOOL_RESULT_SPILL", toolResultSpillEnabled ? "1" : "0"),
            // Agent limits — 0 = unlimited (the engine's `fromEnvironment` default).
            export("ELDR_ACP_MAX_ITERATIONS", String(maxAgentSteps)),
            export("ELDR_ACP_SHELL_TIMEOUT", String(shellTimeoutSeconds)),
            export("ELDR_LLM_TIMEOUT_SECONDS", String(llmTimeoutSeconds)),
            export("ELDR_ACP_PERMISSION_TIMEOUT", String(permissionTimeoutSeconds)),
            // Security escape hatch — only honored when explicitly turned on.
            export("ELDR_ACP_ALLOW_UNGATED_TOOLS", allowUngatedTools ? "1" : "0"),
            // WS3e: cloud-CLI delegation's node-side hard off-switch — separate from
            // allowUngatedTools above.
            export(
                "ELDR_ACP_ALLOW_CLOUD_DELEGATION", cloudAgentDelegationEnabled ? "1" : "0"),
            // Empty value (learning off) → AgentConfig.stringEnv treats "" as nil.
            export("ELDR_ACP_EVENTS_FILE", learningEnabled ? paths.eventsFile : ""),
            // Empty = auto-discover the per-project eldr.md.
            export("ELDR_ACP_CONTEXT_FILE", contextFilePath),
            export("ELDR_ACP_CONTEXTGRAPH", contextGraphEnabled ? "1" : "0"),
            export("ELDR_ACP_CONTEXTGRAPH_URL", contextGraphURL),
            export("ELDR_ACP_CONTEXTGRAPH_AGENT", contextGraphAgentName),
        ]
        // AC94: mirror the operator's harness-executable overrides so the CLI-side
        // delegate_to_cloud_agent resolves the same binaries (HarnessRegistry reads
        // these back via `resolvedDescriptor`). Sorted for a stable file.
        let overrides =
            (defaults.dictionary(forKey: Self.harnessCommandOverridesKey) as? [String: String])
            ?? [:]
        for (id, path) in overrides.sorted(by: { $0.key < $1.key }) {
            lines.append(export(HarnessRegistry.commandOverrideEnvVar(for: id), path))
        }
        lines.append("")
        writeFile(paths.envFile, contents: lines.joined(separator: "\n"))
    }

    /// The legacy FILE-keychain mirror of the LLM token, read by the `eldr-acp` launcher
    /// via `/usr/bin/security` (which cannot see data-protection items). Prompts at most
    /// once for `security`, and the grant sticks because `/usr/bin/security` is
    /// Apple-signed and stable across Huginn rebuilds (unlike Huginn's own changing
    /// signature). C-8 still holds: the token lives in the Keychain, never the env file.
    private var launcherTokenKeychain: KeychainBox {
        KeychainBox(service: keychain.service, useDataProtection: false)
    }

    /// C-8: persist the LLM token to the Keychain (or delete it when blank). Replaces
    /// the cleartext `export ELDR_LLM_TOKEN=…` that used to land in the env file. Written
    /// to BOTH the data-protection keychain (Huginn's own prompt-free reads) and the file
    /// keychain (the launcher's `security` read for external Xcode/OpenClaw clients).
    private func saveTokenToKeychain() {
        if llmToken.isEmpty {
            keychain.delete(account: Self.tokenAccount)
            launcherTokenKeychain.delete(account: Self.tokenAccount)
        } else if let data = llmToken.data(using: .utf8) {
            try? keychain.save(data, account: Self.tokenAccount)
            try? launcherTokenKeychain.save(data, account: Self.tokenAccount)
        }
    }

    /// WS3b: persist the cloud-CLI vendor keys to the Keychain (or delete when blank).
    /// Data-protection only — unlike the LLM token, no launcher/file-keychain mirror:
    /// Huginn spawns these harnesses itself (`runHarness`), so it already holds the
    /// value in-process and merges it directly into the launch env; no external
    /// process needs to read it back via `/usr/bin/security`.
    private func saveVendorKeysToKeychain() {
        saveOrDelete(claudeCodeAPIKey, account: Self.claudeCodeKeyAccount)
        saveOrDelete(geminiAPIKey, account: Self.geminiKeyAccount)
    }

    private func saveOrDelete(_ value: String, account: String) {
        if value.isEmpty {
            keychain.delete(account: account)
        } else if let data = value.data(using: .utf8) {
            try? keychain.save(data, account: account)
        }
    }

    /// WS3c seam: resolve a selectable harness by id with its vendor key merged in
    /// (`HarnessDescriptor.withVendorKey`) — the single place a host asks "what do I
    /// actually launch for this id". Returns nil for an unknown id.
    func resolvedHarnessDescriptor(id: String) -> HarnessDescriptor? {
        Self.resolvedHarnessDescriptor(id: id, keychain: keychain, defaults: defaults)
    }

    /// Static counterpart, for a caller that doesn't hold a live `ConfigurationStore`
    /// instance (mirrors `ACPBridgeService.llmTokenEnvironment()`'s pattern of reading
    /// the Keychain directly via the default `KeychainBox()` — same service/account
    /// convention, so it sees whatever the instance last saved).
    static func resolvedHarnessDescriptor(
        id: String, keychain: KeychainBox = KeychainBox(), defaults: UserDefaults = .standard
    ) -> HarnessDescriptor? {
        guard var descriptor = HarnessRegistry.descriptor(id: id) else { return nil }
        // AC94: the operator-pinned executable path applies before any launch-scoped
        // secret merge (`withCommand` is `.stdioSpawn`-only, so a2a/builtIn pass through).
        descriptor = descriptor.withCommand(harnessCommandOverride(for: id, defaults: defaults))
        if descriptor.kind == .a2aRemote {
            let token = keychain.load(account: a2aBearerAccount(for: descriptor.id))
                .flatMap { String(data: $0, encoding: .utf8) }
            return descriptor.withBearerToken(token)
        }
        let account: String
        switch descriptor.id {
        case "claude-code": account = claudeCodeKeyAccount
        case "gemini-cli": account = geminiKeyAccount
        default: return descriptor
        }
        let key = keychain.load(account: account).flatMap { String(data: $0, encoding: .utf8) }
        return descriptor.withVendorKey(key)
    }

    /// WS3c: which harness answers the phone's REMOTE-drive session over the relay
    /// (`ACPRelayHost` — distinct from the watch-along `Responder`, which only picks
    /// what drafts a reply in the Mac's own read-only chat mirror). A Huginn-only pref
    /// (UserDefaults, like `sybilclawGatewayPort`) — not an eldr-acp env var.
    static let relayHarnessIDKey = "relayHarnessID"
    static func selectedRelayHarnessID() -> String {
        UserDefaults.standard.string(forKey: relayHarnessIDKey) ?? HarnessDescriptor.builtIn.id
    }

    // MARK: WS-B2 — relay URL override + validation
    //
    // Mirrors `relayHarnessID`'s shape exactly: the persisted VALUE lives on
    // `ACPBridgeService.relayURLOverride` (a Huginn-only pref, NOT an eldr-acp env
    // var — this only governs which Nostr relay the Configurator's OWN PQRC node
    // dials), not on this store instance, so there's exactly one in-memory copy and no
    // risk of `ConfigurationStore.save()` clobbering an edit the Relay tab just made
    // with a stale cached value. `ConfigurationStore` only owns the UserDefaults key
    // and the validation rule both surfaces share.

    /// UserDefaults key `ACPBridgeService.relayURLOverride` reads/writes directly.
    static let relayURLKey = "relayOverrideURL"

    /// The persisted override, read fresh from UserDefaults (mirrors
    /// `selectedRelayHarnessID()` / `sybilclawGatewayPort()` — a caller that doesn't
    /// hold a live `ConfigurationStore` instance reads Huginn-only prefs this way so it
    /// doesn't need to ride through SwiftUI's environment at `@StateObject`
    /// construction time). Empty ⇒ no override saved yet.
    static func selectedRelayURL() -> String {
        UserDefaults.standard.string(forKey: relayURLKey) ?? ""
    }

    /// Reasons a relay-URL override is refused. The override is never silently repaired —
    /// `validateRelayOverride` returns the failure so the UI can explain it, and callers
    /// that just need "is there a USABLE override" fall back to the default relay instead.
    enum RelayURLValidationError: Error, Equatable {
        case invalidURL
        case unsupportedScheme
        /// `ws://` (plaintext) was given for a host that isn't loopback — SPEC §0's
        /// cardinal rule (never downgrade transport to plaintext off-box) forbids this
        /// unconditionally, even for a user-typed override.
        case plaintextOffLoopback
    }

    /// Validate a relay-URL override. Empty (trimmed) input is valid and means "use the
    /// default" (`.success(nil)`). A non-empty valid override returns `.success(url)`.
    /// `ws://` is allowed ONLY when the host is loopback (127.0.0.0/8, `::1`, or
    /// `localhost` — where a local `pqrc-relay` dev/demo instance runs plaintext);
    /// every other host MUST be `wss://`.
    static func validateRelayOverride(_ raw: String) -> Result<String?, RelayURLValidationError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .success(nil) }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
            let host = url.host, !host.isEmpty
        else { return .failure(.invalidURL) }
        switch scheme {
        case "wss":
            return .success(trimmed)
        case "ws":
            return isLoopbackHost(host) ? .success(trimmed) : .failure(.plaintextOffLoopback)
        default:
            return .failure(.unsupportedScheme)
        }
    }

    /// The validated override, or nil to fall back to the default relay — for a
    /// caller that only cares "what do I actually dial", not why an invalid value was
    /// refused (mirrors `validateRelayOverride`'s success case, dropping the error).
    static func effectiveRelayURL(_ raw: String) -> String? {
        if case .success(let value) = validateRelayOverride(raw) { return value }
        return nil
    }

    /// Loopback = `localhost`, `::1`, or an IPv4 LITERAL in 127.0.0.0/8. Parsed as
    /// four numeric octets — a string-prefix check would also match DNS names like
    /// `127.evil.com`, which can resolve anywhere and must never get plaintext `ws://`.
    private static func isLoopbackHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h == "::1" { return true }
        let octets = h.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
            octets.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && UInt8($0) != nil })
        else { return false }
        return octets[0] == "127"
    }

    /// `export KEY='value'` with POSIX single-quote escaping so any URL/token/path is
    /// safe to `source` in zsh.
    private func export(_ key: String, _ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "export \(key)='\(escaped)'"
    }

    /// Tool allowlist file: written only when a strict subset is enabled. When all
    /// four are on we write an empty file (= "all", AgentConfig's default) so adding a
    /// future tool isn't silently excluded.
    private func toolsFileContents() -> String {
        if enabledTools.count >= ConfigurationStore.allToolNames.count { return "" }
        return ConfigurationStore.allToolNames.filter { enabledTools.contains($0) }
            .joined(separator: "\n")
    }

    private func writeFile(_ path: String, contents: String) {
        let fm = FileManager.default
        try? fm.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try? contents.data(using: .utf8)?.write(to: URL(fileURLWithPath: path), options: .atomic)
        // C-8: owner-only (0600) — the env file previously landed at the umask
        // (commonly 0644, world-readable). These are all user-private config files.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    // MARK: - Derived config (for the in-process test chat + health checks)

    var llmConfig: LLMConfig {
        LLMConfig(
            url: llmURL, token: llmToken, model: llmModel,
            requestTimeoutSeconds: Double(llmTimeoutSeconds))
    }

    var agentConfig: AgentConfig {
        AgentConfig(
            maxToolResultBytes: maxToolResultBytes,
            maxReadFileBytes: maxReadFileBytes,
            maxHistoryTurns: maxHistoryTurns,
            maxContextChars: maxContextChars,
            toolResultKeepVerbatim: toolResultKeepVerbatim,
            toolResultSpillEnabled: toolResultSpillEnabled,
            toolAllowlist: enabledTools.count >= ConfigurationStore.allToolNames.count
                ? [] : ConfigurationStore.allToolNames.filter { enabledTools.contains($0) },
            promptPreamble: promptPreamble.isEmpty ? nil : promptPreamble,
            systemPromptOverride: systemPromptOverride.isEmpty ? nil : systemPromptOverride,
            skillsEnabled: skillsEnabled,
            skillAllowlist: enabledSkills.count >= ConfigurationStore.allSkillNames.count
                ? nil : ConfigurationStore.allSkillNames.filter { enabledSkills.contains($0) },
            eventsFilePath: learningEnabled ? paths.eventsFile : nil,
            contextFilePath: contextFilePath.isEmpty ? nil : contextFilePath,
            contextGraphEnabled: contextGraphEnabled,
            contextGraphURL: contextGraphURL,
            contextGraphAgentName: contextGraphAgentName.isEmpty ? nil : contextGraphAgentName,
            permissionTimeoutSeconds: Double(permissionTimeoutSeconds),
            maxIterations: maxAgentSteps,
            shellTimeoutSeconds: Double(shellTimeoutSeconds),
            allowUngatedTools: allowUngatedTools,
            visionEnabled: visionEnabled)
    }

    // MARK: - A4: agent version (staleness seam)

    /// The version THIS app was built against — the baseline a later staleness check
    /// (WS-B3) compares the installed binary to. Reads the PQRCACP constant directly so
    /// the two can never drift.
    static var expectedAgentVersion: String { ACPAgent.agentVersionSummary }

    /// The version reported by the INSTALLED `~/.local/bin/eldr-acp` (its `--version`
    /// output). nil when the binary is missing or won't run. The spawn happens off the
    /// main thread inside `ProcessRunner`. WS-B3 will diff this against
    /// `expectedAgentVersion` to flag (and offer to reinstall) a stale CLI — out of
    /// scope here; this just makes the installed version readable.
    func installedAgentVersion() async -> String? {
        let binary = paths.installedBinary
        guard FileManager.default.isExecutableFile(atPath: binary) else { return nil }
        let (out, exit) = await ProcessRunner.run(binary, ["--version"])
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return (exit == 0 && !trimmed.isEmpty) ? trimmed : nil
    }

    // MARK: - Env-file parsing (the inverse of writeEnvFile)

    /// Parse `export KEY='value'` / `KEY=value` lines into an env dict. Comments
    /// (`#…`) and blanks are skipped; surrounding single/double quotes are stripped
    /// and `'\''` unescaped.
    static func parseEnvFile(at path: String) -> [String: String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var env: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line.removeFirst("export ".count) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            value = unquote(value)
            if !key.isEmpty { env[key] = value }
        }
        return env
    }

    /// Read a small on-disk value file (trimmed, empty ⇒ nil) — mirrors
    /// `ACPBridgeService`'s private `loadOwner(from:)`, used here just to seed
    /// `testChatWorkspacePath` from the Bridge's `workdir` file on first load.
    private static func loadTextFile(at path: String) -> String? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func unquote(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        if s.hasPrefix("'") && s.hasSuffix("'") {
            return String(s.dropFirst().dropLast()).replacingOccurrences(of: "'\\''", with: "'")
        }
        if s.hasPrefix("\"") && s.hasSuffix("\"") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}

/// All the on-disk locations the Configurator and the CLI share. Centralized so the
/// installer, log tailer, learner, and store can't drift apart.
struct ConfigPaths: Sendable {
    let configDir: String
    let binDir: String

    var envFile: String { join(configDir, "env") }
    var toolsFile: String { join(configDir, "tools") }
    var skillsFile: String { join(configDir, "skills") }
    var preambleFile: String { join(configDir, "prompt-preamble") }
    var systemPromptFile: String { join(configDir, "system-prompt") }
    var logFile: String { join(configDir, "eldr-acp.log") }
    var eventsFile: String { join(configDir, "events.jsonl") }
    var projectsDir: String { join(configDir, "projects") }
    /// Same on-disk file `ACPBridgeService.setAgentWorkdir` writes/reads (its
    /// `workdirFilePath`) — read-only from here, just to seed Test Chat's own
    /// workspace default the first time it loads with nothing saved yet.
    var workdirFile: String { join(configDir, "workdir") }
    /// WS-MLX: the managed MLX area (private Python venv, server log, fine-tune
    /// configs) — kept beside the agent config so it's one visible, debuggable place.
    var mlxDir: String { join(configDir, "mlx") }

    var installedBinary: String { join(binDir, "eldr-acp") }
    var launcher: String { join(binDir, "eldr-acp-xcode") }
    /// Dedicated launcher OpenClaw (and other ACP clients) are pointed at. Same
    /// script body as the Xcode launcher — client-agnostic.
    var openClawLauncher: String { join(binDir, "eldr-acp-openclaw") }

    /// WS-B5: the two gateway-vendor config paths below used to each hand-roll this
    /// same "home dir + subdir + filename" computation; collapsed to one helper so
    /// there's exactly one place that builds a path under the user's home dir.
    private func homeConfigPath(_ dir: String, _ file: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ((home as NSString).appendingPathComponent(dir) as NSString)
            .appendingPathComponent(file)
    }

    /// Default OpenClaw config file the agent is registered into (user-overridable
    /// in the wizard). OpenClaw loads ACP agents via its `acpx` plugin. Gateway-WATCHED.
    var defaultOpenClawConfig: String { homeConfigPath(".config/openclaw", "config.json") }

    /// Default sybilclaw gateway config (`~/.sybilclaw/sybilclaw.json`). Gateway-WATCHED:
    /// editing it can hot-reload/restart a running gateway, so registration treats it
    /// crash-safely (see `HarnessRegistration`).
    var defaultSybilclawConfig: String { homeConfigPath(".sybilclaw", "sybilclaw.json") }

    /// WS-B5: the ONE place that picks between the two paths above by
    /// `ConfigurationStore.GatewayFlavor` — the setup wizard's harness step and any
    /// other surface that needs "the gateway config for whatever flavor is configured"
    /// go through this instead of re-deriving the choice themselves.
    func defaultGatewayConfig(for flavor: ConfigurationStore.GatewayFlavor) -> String {
        switch flavor {
        case .sybilclaw: return defaultSybilclawConfig
        case .openClaw: return defaultOpenClawConfig
        }
    }

    /// acpx's OWN global config (`~/.acpx/config.json`). A running gateway does NOT watch
    /// this, so the agent COMMAND can be written here anytime without restarting anything.
    var acpxGlobalConfig: String { homeConfigPath(".acpx", "config.json") }

    /// Production paths: `$ELDR_ACP_CONFIG_DIR`/`$XDG_CONFIG_HOME`/`~/.config/eldr-acp`
    /// for config (so the GUI and CLI agree), and `~/.local/bin` for the binaries.
    static var standard: ConfigPaths {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configDir =
            AgentConfig.defaultConfigDir(env) ?? (home as NSString).appendingPathComponent(".config/eldr-acp")
        let binDir = (home as NSString).appendingPathComponent(".local/bin")
        return ConfigPaths(configDir: configDir, binDir: binDir)
    }

    private func join(_ a: String, _ b: String) -> String {
        (a as NSString).appendingPathComponent(b)
    }
}
