import Foundation

// Context budgeting, tool selection, and prompt tuning — the knobs that let one
// agent binary work across very different local models and ACP clients without
// flooding a small context window or confusing a weaker tool-caller.
//
// The single biggest failure mode of a tool-calling loop on a self-hosted model is
// CONTEXT FLOODING: one `read_file` of a 200 KB source, or a chatty `xcodebuild`,
// dumps tens of thousands of tokens straight into the next prompt, and after a few
// such turns the running message list no longer fits the window — the model starts
// dropping the system prompt / earliest instructions and loses the plot. The second
// is TOOL CONFUSION: vague/over-broad tools and an unbounded, noisy history trip up
// smaller or less tool-tuned models.
//
// `AgentConfig` makes the mitigations CONFIGURABLE (env first, optional config file
// second) with defaults chosen to preserve or improve the prior behavior: nothing
// here makes a turn fail that used to succeed; it only trims what the model never
// needed to see in full.

/// All user-tunable agent behavior, read once at startup. Defaults are safe (≈ the
/// prior behavior) so an un-tuned install just works; a user with a small model
/// dials the budgets down, a user with a large model dials them up.
public struct AgentConfig: Sendable, Equatable {
    /// Max bytes of a SINGLE tool result fed back to the model. A result larger
    /// than this is head+tail truncated with a `… N bytes elided …` marker, so one
    /// big file read or build log can't blow the window. Env: `ELDR_ACP_MAX_TOOL_RESULT_BYTES`.
    public var maxToolResultBytes: Int
    /// How many of the most-recent user/assistant/tool TURNS to keep verbatim when
    /// the running history is trimmed before each LLM call. The system prompt and
    /// the first user message are always kept; older tool noise beyond this window
    /// is dropped/elided. Env: `ELDR_ACP_MAX_HISTORY_TURNS`. 0 → no turn-count cap.
    public var maxHistoryTurns: Int
    /// Soft cap on the TOTAL characters of the message list sent to the model. When
    /// the assembled history exceeds it, the oldest non-system messages are elided
    /// (oldest-first) until it fits. Env: `ELDR_ACP_MAX_CONTEXT_CHARS`. 0 → no cap.
    public var maxContextChars: Int
    /// Tool allowlist: only these tool names are advertised to the model and
    /// accepted. Empty → all built-in tools. Env: `ELDR_ACP_TOOLS` (comma/space
    /// separated, e.g. `read_file,write_file,run_shell`).
    public var toolAllowlist: [String]
    /// Extra guidance appended to the system prompt (e.g. terse tool-calling rules a
    /// particular model needs). Env: `ELDR_ACP_PROMPT_PREAMBLE`, or a
    /// `prompt-preamble` file in the config dir.
    public var promptPreamble: String?
    /// FULL replacement system prompt. When set, the built-in prompt is replaced
    /// entirely (the `{cwd}` token, if present, is substituted). Env:
    /// `ELDR_ACP_SYSTEM_PROMPT`, or a `system-prompt` file in the config dir. Takes
    /// precedence over `promptPreamble`.
    public var systemPromptOverride: String?
    /// Whether the agent advertises + executes its skills (ACP slash-commands:
    /// `/spec`, `/snippet`, `/html`). Default true. Set `ELDR_ACP_SKILLS=0`/`off`/
    /// `false` to advertise none and treat a `/skill` prompt as ordinary text.
    public var skillsEnabled: Bool
    /// Optional allowlist of skill command names to advertise (subset of the
    /// built-ins, e.g. `spec,html`). nil/empty → all built-ins. Env:
    /// `ELDR_ACP_SKILLS` when it names skills rather than a boolean.
    public var skillAllowlist: [String]?

    /// Defaults preserve/improve prior behavior: 8 KB per tool result (the loop
    /// previously fed back whole files unbounded and only capped shell at 64 KB),
    /// keep the last 12 turns, a 48k-char total ceiling (~12k tokens of history,
    /// comfortably under a 16k-token model once the reply budget is reserved), all
    /// tools, no prompt changes, all skills advertised.
    public static let `default` = AgentConfig(
        maxToolResultBytes: 8 * 1024,
        maxHistoryTurns: 12,
        maxContextChars: 48 * 1024,
        toolAllowlist: [],
        promptPreamble: nil,
        systemPromptOverride: nil,
        skillsEnabled: true,
        skillAllowlist: nil)

    public init(
        maxToolResultBytes: Int = 8 * 1024,
        maxHistoryTurns: Int = 12,
        maxContextChars: Int = 48 * 1024,
        toolAllowlist: [String] = [],
        promptPreamble: String? = nil,
        systemPromptOverride: String? = nil,
        skillsEnabled: Bool = true,
        skillAllowlist: [String]? = nil
    ) {
        // Clamp to sane floors: a non-positive byte cap would truncate everything to
        // nothing (worse than no cap), so treat ≤0 as "effectively unbounded".
        self.maxToolResultBytes = maxToolResultBytes > 0 ? maxToolResultBytes : Int.max
        self.maxHistoryTurns = max(0, maxHistoryTurns)
        self.maxContextChars = max(0, maxContextChars)
        self.toolAllowlist = toolAllowlist
        self.promptPreamble = promptPreamble
        self.systemPromptOverride = systemPromptOverride
        self.skillsEnabled = skillsEnabled
        self.skillAllowlist = skillAllowlist
    }

    /// Build from the process environment, falling back to an optional config
    /// directory (`~/.config/eldr-acp/` by default) for the longer prompt strings
    /// that are awkward to pass as env vars. Env always wins over a file.
    ///
    /// `configDir` is injected (not hard-coded) so tests can point it at a temp dir
    /// or disable file lookups with `nil` — keeping config parsing network- and
    /// home-directory-free under test.
    public static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment,
        configDir: String? = defaultConfigDir(ProcessInfo.processInfo.environment)
    ) -> AgentConfig {
        func intEnv(_ key: String, default fallback: Int) -> Int {
            guard let raw = env[key]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
                let n = Int(raw)
            else { return fallback }
            return n
        }
        func stringEnv(_ key: String) -> String? {
            env[key].flatMap { $0.isEmpty ? nil : $0 }
        }
        // Env value, else a file in the config dir, else nil.
        func textEnvOrFile(_ key: String, file: String) -> String? {
            if let s = stringEnv(key) { return s }
            return configDir.flatMap { Self.readConfigFile(dir: $0, name: file) }
        }

        let d = AgentConfig.default
        let tools =
            stringEnv("ELDR_ACP_TOOLS").map(Self.parseToolList)
            ?? configDir.flatMap { Self.readConfigFile(dir: $0, name: "tools") }
                .map(Self.parseToolList)
            ?? d.toolAllowlist

        // ELDR_ACP_SKILLS is overloaded: a boolean toggles ALL skills, while a
        // name list narrows to a subset (and implies enabled). Env, else a `skills`
        // file, else default (enabled, all).
        let skillsRaw =
            stringEnv("ELDR_ACP_SKILLS")
            ?? configDir.flatMap { Self.readConfigFile(dir: $0, name: "skills") }
        let (skillsEnabled, skillAllowlist) = Self.parseSkills(skillsRaw)

        return AgentConfig(
            maxToolResultBytes: intEnv("ELDR_ACP_MAX_TOOL_RESULT_BYTES", default: d.maxToolResultBytes),
            maxHistoryTurns: intEnv("ELDR_ACP_MAX_HISTORY_TURNS", default: d.maxHistoryTurns),
            maxContextChars: intEnv("ELDR_ACP_MAX_CONTEXT_CHARS", default: d.maxContextChars),
            toolAllowlist: tools,
            promptPreamble: textEnvOrFile("ELDR_ACP_PROMPT_PREAMBLE", file: "prompt-preamble"),
            systemPromptOverride: textEnvOrFile("ELDR_ACP_SYSTEM_PROMPT", file: "system-prompt"),
            skillsEnabled: skillsEnabled,
            skillAllowlist: skillAllowlist)
    }

    /// Interpret the overloaded `ELDR_ACP_SKILLS` value.
    ///  - nil / empty → (enabled: true, allowlist: nil)  [default: all skills]
    ///  - a falsey boolean (`0`, `off`, `false`, `no`, `none`, `disable(d)`) →
    ///    (enabled: false, allowlist: nil)  [advertise none]
    ///  - a truthy boolean (`1`, `on`, `true`, `yes`, `all`) →
    ///    (enabled: true, allowlist: nil)   [all skills]
    ///  - anything else → a name list → (enabled: true, allowlist: [names])
    static func parseSkills(_ raw: String?) -> (Bool, [String]?) {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return (true, nil) }
        switch raw.lowercased() {
        case "0", "off", "false", "no", "none", "disable", "disabled":
            return (false, nil)
        case "1", "on", "true", "yes", "all", "enable", "enabled":
            return (true, nil)
        default:
            let names = parseToolList(raw)  // same comma/space splitter
            return names.isEmpty ? (true, nil) : (true, names)
        }
    }

    /// `$ELDR_ACP_CONFIG_DIR`, else `$XDG_CONFIG_HOME/eldr-acp`, else
    /// `~/.config/eldr-acp`. Returns nil only if no home can be determined.
    public static func defaultConfigDir(_ env: [String: String]) -> String? {
        if let explicit = env["ELDR_ACP_CONFIG_DIR"], !explicit.isEmpty { return explicit }
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return (xdg as NSString).appendingPathComponent("eldr-acp")
        }
        if let home = env["HOME"], !home.isEmpty {
            return ((home as NSString).appendingPathComponent(".config") as NSString)
                .appendingPathComponent("eldr-acp")
        }
        return nil
    }

    /// Parse a comma/whitespace/newline-separated tool list, dropping blanks.
    static func parseToolList(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Read a config file's trimmed contents; nil if absent/unreadable/empty.
    static func readConfigFile(dir: String, name: String) -> String? {
        let path = (dir as NSString).appendingPathComponent(name)
        guard let data = FileManager.default.contents(atPath: path),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Pure, deterministic context-budgeting helpers. No I/O, no clock — just string
/// math — so they're trivially unit-testable and identical on every model/client.
public enum ContextBudget {

    /// Head+tail truncation of an oversized tool result. Keeps the BEGINNING and the
    /// END (the parts that matter for a file or a build log — the signature/imports
    /// up top, the error/exit status at the bottom) and elides the middle with an
    /// explicit, machine-and-human-readable marker. Counts UTF-8 BYTES (what an LLM
    /// tokenizer roughly tracks and what the window is measured in), but cuts on
    /// CHARACTER boundaries so the output is always valid UTF-8.
    ///
    /// Returns the input unchanged when it already fits.
    public static func truncate(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0, maxBytes != Int.max else { return text }
        let totalBytes = text.utf8.count
        guard totalBytes > maxBytes else { return text }

        // Reserve room for the marker; if the budget is tiny, still emit a marker.
        let elided = totalBytes - maxBytes
        let marker = "\n… \(elided) bytes elided (\(totalBytes) total; raised cap with ELDR_ACP_MAX_TOOL_RESULT_BYTES) …\n"
        let markerBytes = marker.utf8.count
        let budgetForText = max(0, maxBytes - markerBytes)
        // Split the remaining budget: ~60% head, ~40% tail (heads carry more signal
        // — declarations, the command that ran — but errors live at the tail).
        let headBudget = (budgetForText * 6) / 10
        let tailBudget = budgetForText - headBudget

        let head = prefixBytes(text, headBudget)
        let tail = suffixBytes(text, tailBudget)
        return head + marker + tail
    }

    /// Trim the running message list to fit the configured budgets before an LLM
    /// call, WITHOUT losing the instructions the model needs:
    ///  - the leading system message(s) are ALWAYS kept (the agent's contract);
    ///  - the first user message (the task) is kept;
    ///  - then the most-recent messages are kept up to `maxTurns` non-system turns;
    ///  - finally, if still over `maxChars`, the oldest *kept* non-anchor messages
    ///    are replaced with a one-line elision note, oldest-first, until it fits.
    ///
    /// Dropping a message that an `assistant` tool-call turn references is safe here:
    /// we elide *content*, never reorder, and an elided tool result still leaves its
    /// `tool` envelope (with the call id) so the OpenAI message sequence stays valid.
    public static func trim(_ messages: [LLMMessage], maxTurns: Int, maxChars: Int) -> [LLMMessage] {
        guard !messages.isEmpty else { return messages }

        // Partition off the leading run of system messages (always anchored).
        var systemCount = 0
        while systemCount < messages.count, messages[systemCount].role == .system {
            systemCount += 1
        }
        let system = Array(messages[0..<systemCount])
        var rest = Array(messages[systemCount...])

        // Anchor the first non-system message (the task) so it's never dropped.
        let firstTask = rest.first
        let tail = firstTask == nil ? [] : Array(rest.dropFirst())

        // (1) Turn-count cap: keep the most-recent `maxTurns` of the tail.
        var keptTail = tail
        if maxTurns > 0, tail.count > maxTurns {
            keptTail = Array(tail.suffix(maxTurns))
        }

        rest = (firstTask.map { [$0] } ?? []) + keptTail
        var result = system + rest

        // (2) Char-budget cap: while over budget, elide the oldest non-anchor
        // message's content (anchors = system + first task). Eliding content rather
        // than removing the message keeps tool_call/tool pairing intact.
        if maxChars > 0 {
            let anchorCount = system.count + (firstTask == nil ? 0 : 1)
            var idx = anchorCount
            while totalChars(result) > maxChars, idx < result.count {
                if !result[idx].content.isEmpty
                    && !result[idx].content.hasPrefix(elisionPrefix)
                {
                    result[idx] = elide(result[idx])
                }
                idx += 1
            }
        }
        return result
    }

    static let elisionPrefix = "[elided to fit context budget"

    private static func elide(_ m: LLMMessage) -> LLMMessage {
        let originalChars = m.content.count
        var copy = m
        copy.content = "\(elisionPrefix): \(originalChars) chars from an earlier \(m.role.rawValue) message]"
        return copy
    }

    static func totalChars(_ messages: [LLMMessage]) -> Int {
        messages.reduce(0) { $0 + $1.content.count }
    }

    // MARK: Byte-bounded prefix/suffix on character boundaries

    /// Largest prefix of `s` whose UTF-8 size is ≤ `maxBytes` (whole characters).
    static func prefixBytes(_ s: String, _ maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        if s.utf8.count <= maxBytes { return s }
        var used = 0
        var out = String()
        for ch in s {
            let w = String(ch).utf8.count
            if used + w > maxBytes { break }
            out.append(ch)
            used += w
        }
        return out
    }

    /// Largest suffix of `s` whose UTF-8 size is ≤ `maxBytes` (whole characters).
    static func suffixBytes(_ s: String, _ maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        if s.utf8.count <= maxBytes { return s }
        var used = 0
        var chars: [Character] = []
        for ch in s.reversed() {
            let w = String(ch).utf8.count
            if used + w > maxBytes { break }
            chars.append(ch)
            used += w
        }
        return String(chars.reversed())
    }
}
