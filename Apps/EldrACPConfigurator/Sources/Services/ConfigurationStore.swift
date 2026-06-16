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

    /// The four built-in tools, in advertise order (mirrors ToolExecutor.allToolNames).
    static let allToolNames = ["read_file", "write_file", "list_dir", "run_shell"]

    let paths: ConfigPaths
    private var saveCancellable: AnyCancellable?
    private var loaded = false

    init(paths: ConfigPaths = .standard) {
        self.paths = paths

        // Load by re-reading the files through the binary's own parsers.
        let env = ConfigurationStore.parseEnvFile(at: paths.envFile)
        let llm = LLMConfig.fromEnvironment(env)
        let agent = AgentConfig.fromEnvironment(env, configDir: paths.configDir)

        llmURL = llm.url
        llmToken = llm.token
        llmModel = llm.model
        // AgentConfig clamps a non-positive byte cap to Int.max ("unbounded"); show 0
        // for that so the field round-trips cleanly.
        maxToolResultBytes = agent.maxToolResultBytes == Int.max ? 0 : agent.maxToolResultBytes
        maxHistoryTurns = agent.maxHistoryTurns
        maxContextChars = agent.maxContextChars
        enabledTools =
            agent.toolAllowlist.isEmpty
            ? Set(ConfigurationStore.allToolNames) : Set(agent.toolAllowlist)
        skillsEnabled = agent.skillsEnabled
        promptPreamble = agent.promptPreamble ?? ""
        systemPromptOverride = agent.systemPromptOverride ?? ""
        learningEnabled = (agent.eventsFilePath?.isEmpty == false)

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
            "# Written by EldrACPConfigurator — do not edit by hand.",
            export("ELDR_LLM_URL", llmURL),
            export("ELDR_LLM_TOKEN", llmToken),
            export("ELDR_LLM_MODEL", llmModel),
            export("ELDR_ACP_MAX_TOOL_RESULT_BYTES", String(maxToolResultBytes)),
            export("ELDR_ACP_MAX_HISTORY_TURNS", String(maxHistoryTurns)),
            export("ELDR_ACP_MAX_CONTEXT_CHARS", String(maxContextChars)),
            // Empty value (learning off) → AgentConfig.stringEnv treats "" as nil.
            export("ELDR_ACP_EVENTS_FILE", learningEnabled ? paths.eventsFile : ""),
        ]
        lines.append("")
        writeFile(paths.envFile, contents: lines.joined(separator: "\n"))
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
    }

    // MARK: - Derived config (for the in-process test chat + health checks)

    var llmConfig: LLMConfig { LLMConfig(url: llmURL, token: llmToken, model: llmModel) }

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
            eventsFilePath: learningEnabled ? paths.eventsFile : nil)
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
