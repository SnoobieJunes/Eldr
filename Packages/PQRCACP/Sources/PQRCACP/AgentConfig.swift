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
// `Equatable` is hand-written (not synthesized) because `logRedactor` is a closure,
// which has no equality; the conformance compares every VALUE field and ignores the
// redactor. No call site compares whole configs (tests assert individual fields), so
// "two configs that differ only by injected redactor compare equal" is harmless.
public struct AgentConfig: Sendable, Equatable {
    /// Max bytes of a SINGLE tool result fed back to the model. A result larger
    /// than this is head+tail truncated with a `… N bytes elided …` marker, so one
    /// big file read or build log can't blow the window. Env: `ELDR_ACP_MAX_TOOL_RESULT_BYTES`.
    public var maxToolResultBytes: Int
    /// Max bytes `read_file` will pull off disk BEFORE truncation. `maxToolResultBytes`
    /// bounds what reaches the model, but it only trims AFTER the whole file is loaded
    /// into memory — a multi-gigabyte file would OOM the agent first. This is the
    /// read-side backpressure: `read_file` stats the file and, when it's over this
    /// cap, streams only a bounded prefix off disk (with an elision note) instead of
    /// loading it whole. Env: `ELDR_ACP_MAX_READ_FILE_BYTES`. `Int.max` → no cap.
    public var maxReadFileBytes: Int
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
    /// Path to a JSONL file where the agent appends one JSON line per significant
    /// event (write_file, shell_result, session_end). The Configurator GUI tails
    /// this to drive ContextLearner. nil → no event logging.
    /// Env: `ELDR_ACP_EVENTS_FILE`.
    public var eventsFilePath: String?
    /// Path to a project context file (eldr.md) to prepend to the system prompt at
    /// the start of every session. nil → auto-discover
    /// `~/.config/eldr-acp/projects/<sha256(cwd)>/eldr.md`.
    /// Env: `ELDR_ACP_CONTEXT_FILE`.
    public var contextFilePath: String?
    /// Route context assembly through the `contextgraph` service (graph-based, tag
    /// retrieval) instead of (well, ahead of) the local sliding-window budgeting.
    /// Default off → unchanged behavior. Env: `ELDR_ACP_CONTEXTGRAPH` (boolean).
    public var contextGraphEnabled: Bool
    /// contextgraph REST base URL. Env: `ELDR_ACP_CONTEXTGRAPH_URL`.
    public var contextGraphURL: String
    /// Channel/agent label so per-project graphs stay separate. nil → derived from
    /// the session cwd. Env: `ELDR_ACP_CONTEXTGRAPH_AGENT`.
    public var contextGraphAgentName: String?
    /// C-1: seconds to wait for a `session/request_permission` answer before treating
    /// silence as a DENIAL (deny-on-timeout), so a non-responding client can neither
    /// hang the turn nor auto-allow a mutating tool. Env: `ELDR_ACP_PERMISSION_TIMEOUT`.
    public var permissionTimeoutSeconds: Double
    /// Max agent loop iterations (model round-trips) per turn. **0 (default) =
    /// unlimited** — a capable model doing a real multi-step build can need many
    /// rounds; the per-call context budget still bounds each request, so an open loop
    /// doesn't blow the window. Set a positive value to cap. Env: `ELDR_ACP_MAX_ITERATIONS`.
    public var maxIterations: Int
    /// Wall-clock cap for a single `run_shell` / search child process, in seconds.
    /// **0 (default) = unlimited** — real builds/tests legitimately run for minutes.
    /// Set a positive value to bound a non-terminating command. Env: `ELDR_ACP_SHELL_TIMEOUT`.
    public var shellTimeoutSeconds: Double
    /// C-1 escape hatch: when true, mutating tools are NOT permission-gated at all —
    /// restoring allow-by-default for a trusted local client that can't prompt (e.g.
    /// one with no session/request_permission support). An EXPLICIT operator risk
    /// acceptance; default false (fail closed: a mutating tool runs only on an explicit
    /// grant; a timeout/error is a denial). Env: `ELDR_ACP_ALLOW_UNGATED_TOOLS`.
    public var allowUngatedTools: Bool
    /// D2 (node-side image input): whether the configured LLM can read images. When
    /// true, the agent advertises `promptCapabilities.image=true` at `initialize` and
    /// forwards a node-side ACP `image` content block to the model as a multimodal
    /// user message; when false (the DEFAULT), `image` is advertised false and any
    /// image block is dropped (today's behavior). Default OFF because most self-hosted
    /// models are text-only and would choke on — or silently ignore — image input, so
    /// vision is opt-in: only a model the operator knows is vision-capable should get
    /// images. NODE-SIDE ONLY; the phone product is text-only and never sends images
    /// (CLAUDE.md). Env: `ELDR_LLM_VISION` (boolean).
    public var visionEnabled: Bool
    /// C-6: redaction seam applied to the FREE-TEXT strings written to the AT-REST log
    /// sinks (a `run_shell` cmd + its captured output → `events.jsonl`; the agent's
    /// stderr diagnostics). Defaults to the built-in `ACPLogRedactor.scrub` so the
    /// zero-dependency agent self-protects; the host app injects PQRCCore's canonical
    /// `CredentialRedactor.scrub` to keep one source of truth. (The `path` field is
    /// scrubbed separately with the path-aware `ACPLogRedactor.scrubPath`, which spares
    /// a legitimate sha256/UUID path component.) NOT applied to the live ACP channel,
    /// the tool results returned to the model, or anything delivered to the owner —
    /// log hygiene on disk only.
    public var logRedactor: ACPLogScrubber

    /// Defaults preserve/improve prior behavior: 8 KB per tool result (the loop
    /// previously fed back whole files unbounded and only capped shell at 64 KB),
    /// keep the last 12 turns, a 48k-char total ceiling (~12k tokens of history,
    /// comfortably under a 16k-token model once the reply budget is reserved), all
    /// tools, no prompt changes, all skills advertised.
    public static let `default` = AgentConfig(
        maxToolResultBytes: 8 * 1024,
        maxReadFileBytes: 1024 * 1024,
        maxHistoryTurns: 12,
        maxContextChars: 48 * 1024,
        toolAllowlist: [],
        promptPreamble: nil,
        systemPromptOverride: nil,
        skillsEnabled: true,
        skillAllowlist: nil,
        eventsFilePath: nil,
        contextFilePath: nil,
        contextGraphEnabled: false,
        contextGraphURL: "http://localhost:8302",
        contextGraphAgentName: nil,
        permissionTimeoutSeconds: 120,
        maxIterations: 0,
        shellTimeoutSeconds: 0,
        allowUngatedTools: false,
        visionEnabled: false)

    public init(
        maxToolResultBytes: Int = 8 * 1024,
        maxReadFileBytes: Int = 1024 * 1024,
        maxHistoryTurns: Int = 12,
        maxContextChars: Int = 48 * 1024,
        toolAllowlist: [String] = [],
        promptPreamble: String? = nil,
        systemPromptOverride: String? = nil,
        skillsEnabled: Bool = true,
        skillAllowlist: [String]? = nil,
        eventsFilePath: String? = nil,
        contextFilePath: String? = nil,
        contextGraphEnabled: Bool = false,
        contextGraphURL: String = "http://localhost:8302",
        contextGraphAgentName: String? = nil,
        permissionTimeoutSeconds: Double = 120,
        maxIterations: Int = 0,
        shellTimeoutSeconds: Double = 0,
        allowUngatedTools: Bool = false,
        visionEnabled: Bool = false,
        logRedactor: @escaping ACPLogScrubber = ACPLogRedactor.scrub
    ) {
        // Clamp to sane floors: a non-positive byte cap would truncate everything to
        // nothing (worse than no cap), so treat ≤0 as "effectively unbounded".
        self.maxToolResultBytes = maxToolResultBytes > 0 ? maxToolResultBytes : Int.max
        self.maxReadFileBytes = maxReadFileBytes > 0 ? maxReadFileBytes : Int.max
        self.maxHistoryTurns = max(0, maxHistoryTurns)
        self.maxContextChars = max(0, maxContextChars)
        self.toolAllowlist = toolAllowlist
        self.promptPreamble = promptPreamble
        self.systemPromptOverride = systemPromptOverride
        self.skillsEnabled = skillsEnabled
        self.skillAllowlist = skillAllowlist
        self.eventsFilePath = eventsFilePath
        self.contextFilePath = contextFilePath
        self.contextGraphEnabled = contextGraphEnabled
        self.contextGraphURL = contextGraphURL.isEmpty ? "http://localhost:8302" : contextGraphURL
        self.contextGraphAgentName = contextGraphAgentName
        // ≤0 ⇒ no wait (deny immediately on no answer); otherwise the given seconds.
        self.permissionTimeoutSeconds = max(0, permissionTimeoutSeconds)
        self.maxIterations = max(0, maxIterations)
        self.shellTimeoutSeconds = max(0, shellTimeoutSeconds)
        self.allowUngatedTools = allowUngatedTools
        self.visionEnabled = visionEnabled
        self.logRedactor = logRedactor
    }

    /// Value-field equality; ignores `logRedactor` (closures have no equality). See
    /// the note on the type declaration.
    public static func == (lhs: AgentConfig, rhs: AgentConfig) -> Bool {
        lhs.maxToolResultBytes == rhs.maxToolResultBytes
            && lhs.maxReadFileBytes == rhs.maxReadFileBytes
            && lhs.maxHistoryTurns == rhs.maxHistoryTurns
            && lhs.maxContextChars == rhs.maxContextChars
            && lhs.toolAllowlist == rhs.toolAllowlist
            && lhs.promptPreamble == rhs.promptPreamble
            && lhs.systemPromptOverride == rhs.systemPromptOverride
            && lhs.skillsEnabled == rhs.skillsEnabled
            && lhs.skillAllowlist == rhs.skillAllowlist
            && lhs.eventsFilePath == rhs.eventsFilePath
            && lhs.contextFilePath == rhs.contextFilePath
            && lhs.contextGraphEnabled == rhs.contextGraphEnabled
            && lhs.contextGraphURL == rhs.contextGraphURL
            && lhs.contextGraphAgentName == rhs.contextGraphAgentName
            && lhs.permissionTimeoutSeconds == rhs.permissionTimeoutSeconds
            && lhs.allowUngatedTools == rhs.allowUngatedTools
            && lhs.visionEnabled == rhs.visionEnabled
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
        func boolEnv(_ key: String, default fallback: Bool) -> Bool {
            guard let raw = stringEnv(key)?.lowercased() else { return fallback }
            switch raw {
            case "1", "on", "true", "yes", "enable", "enabled": return true
            case "0", "off", "false", "no", "disable", "disabled": return false
            default: return fallback
            }
        }
        func doubleEnv(_ key: String, default fallback: Double) -> Double {
            guard let raw = env[key]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
                let n = Double(raw)
            else { return fallback }
            return n
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
            maxReadFileBytes: intEnv("ELDR_ACP_MAX_READ_FILE_BYTES", default: d.maxReadFileBytes),
            maxHistoryTurns: intEnv("ELDR_ACP_MAX_HISTORY_TURNS", default: d.maxHistoryTurns),
            maxContextChars: intEnv("ELDR_ACP_MAX_CONTEXT_CHARS", default: d.maxContextChars),
            toolAllowlist: tools,
            promptPreamble: textEnvOrFile("ELDR_ACP_PROMPT_PREAMBLE", file: "prompt-preamble"),
            systemPromptOverride: textEnvOrFile("ELDR_ACP_SYSTEM_PROMPT", file: "system-prompt"),
            skillsEnabled: skillsEnabled,
            skillAllowlist: skillAllowlist,
            eventsFilePath: stringEnv("ELDR_ACP_EVENTS_FILE"),
            contextFilePath: stringEnv("ELDR_ACP_CONTEXT_FILE"),
            contextGraphEnabled: boolEnv("ELDR_ACP_CONTEXTGRAPH", default: d.contextGraphEnabled),
            contextGraphURL: stringEnv("ELDR_ACP_CONTEXTGRAPH_URL") ?? d.contextGraphURL,
            contextGraphAgentName: stringEnv("ELDR_ACP_CONTEXTGRAPH_AGENT"),
            permissionTimeoutSeconds: doubleEnv("ELDR_ACP_PERMISSION_TIMEOUT", default: d.permissionTimeoutSeconds),
            maxIterations: intEnv("ELDR_ACP_MAX_ITERATIONS", default: d.maxIterations),
            shellTimeoutSeconds: doubleEnv("ELDR_ACP_SHELL_TIMEOUT", default: d.shellTimeoutSeconds),
            allowUngatedTools: boolEnv("ELDR_ACP_ALLOW_UNGATED_TOOLS", default: d.allowUngatedTools),
            visionEnabled: boolEnv("ELDR_LLM_VISION", default: d.visionEnabled))
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
            // A `suffix` boundary can land between an assistant tool_call and its
            // `tool` result, orphaning leading `tool` messages — which the OpenAI
            // shape rejects ("tool message must follow a preceding tool_calls").
            // Drop any leading orphaned tool results so the kept window starts on a
            // valid (user/assistant) message.
            while let first = keptTail.first, first.role == .tool {
                keptTail.removeFirst()
            }
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
