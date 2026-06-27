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

    // MARK: Context budget (env file)
    @Published var maxToolResultBytes: Int
    @Published var maxHistoryTurns: Int
    @Published var maxContextChars: Int

    // MARK: Agent limits (env file) — all 0 = unlimited (the engine's default).
    /// Cap on the agent's tool-call loop (`ELDR_ACP_MAX_ITERATIONS`).
    @Published var maxAgentSteps: Int
    /// Per-LLM-request wall-clock timeout in seconds (`ELDR_LLM_TIMEOUT_SECONDS`).
    @Published var llmTimeoutSeconds: Int
    /// Per-shell-command watchdog timeout in seconds (`ELDR_ACP_SHELL_TIMEOUT`).
    @Published var shellTimeoutSeconds: Int

    // MARK: Tools / skills / prompts (individual files)
    /// Names of the built-in tools the agent may use. Empty in AgentConfig means
    /// "all"; the UI always shows the four checkboxes, so we persist the explicit set.
    @Published var enabledTools: Set<String>
    @Published var skillsEnabled: Bool
    @Published var promptPreamble: String
    @Published var systemPromptOverride: String

    // MARK: Project memory (Phase 3) — events.jsonl drives ContextLearner.
    /// When false, the env file sets `ELDR_ACP_EVENTS_FILE=` (empty) so the agent
    /// emits no events and the learner goes idle.
    @Published var learningEnabled: Bool

    // MARK: contextgraph (graph-based context manager) — env file.
    /// Route context assembly through the contextgraph service. Off → unchanged.
    @Published var contextGraphEnabled: Bool
    /// contextgraph REST endpoint the agent calls (and the wizard health-checks).
    @Published var contextGraphURL: String

    // MARK: sybilclaw gateway (Huginn-only pref — NOT an eldr-acp env var)
    /// The port sybilclaw's gateway daemon listens on (default 18789). Used by the
    /// Connections panel's status probe (and, later, the gateway bridge). `eldr-acp`
    /// itself has no port, so this is persisted to UserDefaults, never the env file.
    @Published var sybilclawGatewayPort: Int
    static let gatewayPortKey = "sybilclawGatewayPort"
    static let defaultGatewayPort = 18789

    /// The four built-in tools, in advertise order (mirrors ToolExecutor.allToolNames).
    static let allToolNames = ["read_file", "write_file", "list_dir", "run_shell"]

    let paths: ConfigPaths
    private var saveCancellable: AnyCancellable?
    private var loaded = false
    /// C-8: the LLM token is kept in the Keychain (WhenUnlockedThisDeviceOnly), never
    /// in the cleartext env file. Injectable so tests can isolate to their own service.
    private let keychain: KeychainBox
    private static let tokenAccount = "llm-token"

    init(paths: ConfigPaths = .standard, keychain: KeychainBox = KeychainBox()) {
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
        // AgentConfig clamps a non-positive byte cap to Int.max ("unbounded"); show 0
        // for that so the field round-trips cleanly.
        maxToolResultBytes = agent.maxToolResultBytes == Int.max ? 0 : agent.maxToolResultBytes
        maxHistoryTurns = agent.maxHistoryTurns
        maxContextChars = agent.maxContextChars
        maxAgentSteps = agent.maxIterations
        shellTimeoutSeconds = Int(agent.shellTimeoutSeconds)
        llmTimeoutSeconds = Int(llm.requestTimeoutSeconds)
        enabledTools =
            agent.toolAllowlist.isEmpty
            ? Set(ConfigurationStore.allToolNames) : Set(agent.toolAllowlist)
        skillsEnabled = agent.skillsEnabled
        promptPreamble = agent.promptPreamble ?? ""
        systemPromptOverride = agent.systemPromptOverride ?? ""
        learningEnabled = (agent.eventsFilePath?.isEmpty == false)
        contextGraphEnabled = agent.contextGraphEnabled
        contextGraphURL = agent.contextGraphURL
        sybilclawGatewayPort =
            (UserDefaults.standard.object(forKey: Self.gatewayPortKey) as? Int)
            ?? Self.defaultGatewayPort

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
        // Huginn-only pref (no eldr-acp env var): persisted separately from the CLI files.
        UserDefaults.standard.set(sybilclawGatewayPort, forKey: Self.gatewayPortKey)
        saveTokenToKeychain()
        writeEnvFile()
        writeFile(paths.toolsFile, contents: toolsFileContents())
        writeFile(paths.skillsFile, contents: skillsEnabled ? "1" : "0")
        writeFile(paths.preambleFile, contents: promptPreamble)
        writeFile(paths.systemPromptFile, contents: systemPromptOverride)
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
            export("ELDR_ACP_MAX_TOOL_RESULT_BYTES", String(maxToolResultBytes)),
            export("ELDR_ACP_MAX_HISTORY_TURNS", String(maxHistoryTurns)),
            export("ELDR_ACP_MAX_CONTEXT_CHARS", String(maxContextChars)),
            // Agent limits — 0 = unlimited (the engine's `fromEnvironment` default).
            export("ELDR_ACP_MAX_ITERATIONS", String(maxAgentSteps)),
            export("ELDR_ACP_SHELL_TIMEOUT", String(shellTimeoutSeconds)),
            export("ELDR_LLM_TIMEOUT_SECONDS", String(llmTimeoutSeconds)),
            // Empty value (learning off) → AgentConfig.stringEnv treats "" as nil.
            export("ELDR_ACP_EVENTS_FILE", learningEnabled ? paths.eventsFile : ""),
            export("ELDR_ACP_CONTEXTGRAPH", contextGraphEnabled ? "1" : "0"),
            export("ELDR_ACP_CONTEXTGRAPH_URL", contextGraphURL),
        ]
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
            maxHistoryTurns: maxHistoryTurns,
            maxContextChars: maxContextChars,
            toolAllowlist: enabledTools.count >= ConfigurationStore.allToolNames.count
                ? [] : ConfigurationStore.allToolNames.filter { enabledTools.contains($0) },
            promptPreamble: promptPreamble.isEmpty ? nil : promptPreamble,
            systemPromptOverride: systemPromptOverride.isEmpty ? nil : systemPromptOverride,
            skillsEnabled: skillsEnabled,
            eventsFilePath: learningEnabled ? paths.eventsFile : nil,
            maxIterations: maxAgentSteps,
            shellTimeoutSeconds: Double(shellTimeoutSeconds))
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

    var installedBinary: String { join(binDir, "eldr-acp") }
    var launcher: String { join(binDir, "eldr-acp-xcode") }
    /// Dedicated launcher OpenClaw (and other ACP clients) are pointed at. Same
    /// script body as the Xcode launcher — client-agnostic.
    var openClawLauncher: String { join(binDir, "eldr-acp-openclaw") }

    /// Default OpenClaw config file the agent is registered into (user-overridable
    /// in the wizard). OpenClaw loads ACP agents via its `acpx` plugin. Gateway-WATCHED.
    var defaultOpenClawConfig: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ((home as NSString).appendingPathComponent(".config/openclaw") as NSString)
            .appendingPathComponent("config.json")
    }

    /// Default sybilclaw gateway config (`~/.sybilclaw/sybilclaw.json`). Gateway-WATCHED:
    /// editing it can hot-reload/restart a running gateway, so registration treats it
    /// crash-safely (see `HarnessRegistration`).
    var defaultSybilclawConfig: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ((home as NSString).appendingPathComponent(".sybilclaw") as NSString)
            .appendingPathComponent("sybilclaw.json")
    }

    /// acpx's OWN global config (`~/.acpx/config.json`). A running gateway does NOT watch
    /// this, so the agent COMMAND can be written here anytime without restarting anything.
    var acpxGlobalConfig: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ((home as NSString).appendingPathComponent(".acpx") as NSString)
            .appendingPathComponent("config.json")
    }

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
