import Foundation

/// What the client said it can do (from `initialize` → clientCapabilities). Drives
/// whether the agent routes file/shell work THROUGH the client (so edits and
/// terminals show up in Xcode) or falls back to Foundation `Process`/`FileManager`.
public struct ClientCapabilities: Sendable, Equatable {
    public var fsReadTextFile: Bool
    public var fsWriteTextFile: Bool
    public var terminal: Bool

    public init(fsReadTextFile: Bool = false, fsWriteTextFile: Bool = false, terminal: Bool = false) {
        self.fsReadTextFile = fsReadTextFile
        self.fsWriteTextFile = fsWriteTextFile
        self.terminal = terminal
    }

    /// Parse the `clientCapabilities` object of an `initialize` request.
    public init(initializeParams params: JSONValue) {
        let fs = params["clientCapabilities"]?["fs"]
        self.fsReadTextFile = fs?["readTextFile"]?.boolValue ?? false
        self.fsWriteTextFile = fs?["writeTextFile"]?.boolValue ?? false
        self.terminal = params["clientCapabilities"]?["terminal"]?.boolValue ?? false
    }
}

/// Settings that shape shell execution (so `xcodebuild`/`xcrun simctl` hit the
/// right Xcode and run in the right directory).
public struct ToolEnvironment: Sendable {
    /// `DEVELOPER_DIR` to export for shell commands (selects Xcode 27 beta). nil →
    /// don't override; inherit the parent.
    public var developerDir: String?
    /// Working directory for shell + relative path resolution. nil → process cwd.
    public var workdir: String?
    /// The rest of the environment to pass to spawned shells (defaults to the
    /// agent's own environment).
    public var baseEnvironment: [String: String]

    public init(
        developerDir: String? = nil, workdir: String? = nil,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.developerDir = developerDir
        self.workdir = workdir
        self.baseEnvironment = baseEnvironment
    }

    public static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> ToolEnvironment {
        ToolEnvironment(
            developerDir: env["DEVELOPER_DIR"].flatMap { $0.isEmpty ? nil : $0 },
            workdir: env["ELDR_WORKDIR"].flatMap { $0.isEmpty ? nil : $0 },
            baseEnvironment: env)
    }

    /// Exact env-var names that must NEVER reach a spawned shell: the agent's own
    /// long-term secrets. The agent process legitimately holds these (it authenticates
    /// to the LLM, seals at-rest metadata, talks to the gateway), but a `run_shell` /
    /// `open_terminal` it spawns has no need of them — and a prompt-injected model that
    /// gets one shell approved could otherwise `env` them straight back into its own
    /// context (self-exfiltration, no network needed) or pipe them outbound.
    private static let secretEnvKeys: Set<String> = [
        "ELDR_LLM_TOKEN", "ELDR_ACP_METADATA_KEY", "SYBILCLAW_GATEWAY_TOKEN",
    ]

    /// Defense-in-depth over the exact list: strip any secret-SHAPED key within a
    /// namespace WE own (`ELDR_`/`PQRC_`/`SYBILCLAW_`), so a future secret added to one
    /// of our env vars is covered without an allowlist that might drop a variable a
    /// legitimate build tool in the shell actually needs. Scoped to our own prefixes on
    /// purpose: never touch the user's own `*_TOKEN`/`*_KEY` build vars.
    private static func isOwnedSecretShaped(_ key: String) -> Bool {
        let k = key.uppercased()
        guard k.hasPrefix("ELDR_") || k.hasPrefix("PQRC_") || k.hasPrefix("SYBILCLAW_")
        else { return false }
        return k.contains("TOKEN") || k.contains("SECRET") || k.contains("PASSWORD")
            || k.contains("PASSPHRASE") || k.hasSuffix("_KEY") || k.contains("_KEY_")
    }

    /// Strip the agent's own long-term secrets (`secretEnvKeys` + `isOwnedSecretShaped`) from
    /// an arbitrary environment. Shared by `shellEnvironment` (run_shell / open_terminal) and
    /// the external-harness spawn seam (`StdioHarnessTransport`) so NO child the agent spawns —
    /// a shell, a PTY, or a cloud CLI — ever inherits `ELDR_LLM_TOKEN` / `ELDR_ACP_METADATA_KEY`
    /// / `SYBILCLAW_GATEWAY_TOKEN`. One definition so the two seams can't drift apart.
    public static func scrubbingAgentSecrets(_ env: [String: String]) -> [String: String] {
        var e = env
        for key in e.keys where secretEnvKeys.contains(key) || isOwnedSecretShaped(key) {
            e.removeValue(forKey: key)
        }
        return e
    }

    /// The effective environment for a spawned shell: the base environment with the
    /// agent's secrets removed (see `secretEnvKeys`), plus the DEVELOPER_DIR override.
    var shellEnvironment: [String: String] {
        var e = Self.scrubbingAgentSecrets(baseEnvironment)
        if let dev = developerDir { e["DEVELOPER_DIR"] = dev }
        return e
    }

    /// Effective working directory string.
    var effectiveWorkdir: String { workdir ?? FileManager.default.currentDirectoryPath }
}

/// Outcome of running a tool: human-readable text fed back to the model as the
/// `tool` message, plus whether it failed (for the tool_call_update status/variant).
public struct ToolResult: Sendable {
    public var text: String
    public var isError: Bool
    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

// NODE-SIDE (macOS only): the tool executor spawns shells (`Process`) and touches the
// filesystem to do real file/shell work. The iOS app never runs the AGENT half — the
// phone is the remote control that drives a Mac node over an `ACPTransport` — so this
// whole type is guarded off the iOS-compiled `PQRCACP` library. The phone-side value
// types above (`ClientCapabilities`/`ToolEnvironment`/`ToolResult`) stay available
// because `ACPClient`/`ACPClientDriver` reference them.
#if os(macOS)
/// Executes the agent's four tools, preferring client-routed I/O over Foundation
/// fallbacks. Constructed once per prompt turn (it carries that turn's sessionId,
/// which the fs/* and terminal/* methods require); stateless otherwise, so it's a
/// `Sendable` value type.
public struct ToolExecutor: Sendable {
    let capabilities: ClientCapabilities
    let environment: ToolEnvironment
    let connection: ClientConnection?
    /// The active session — fs/* and terminal/* requests must carry it.
    let sessionId: String
    /// Hard cap on CAPTURED shell output bytes (a memory/deadlock guard on a chatty
    /// build). This is the large outer cap; the smaller `maxResultBytes` then bounds
    /// what actually reaches the model.
    let outputByteLimit: Int
    /// Cap on the bytes of ANY tool result fed back to the model (head+tail
    /// truncated past this). The context-window guard — a huge `read_file` or build
    /// log is trimmed here so it can't flood the next prompt. `Int.max` → no cap.
    let maxResultBytes: Int
    /// Cap on bytes `read_file` pulls off DISK before truncation — the read-side
    /// backpressure (`maxResultBytes` only trims after the whole file is in memory).
    /// Over-cap files are read as a bounded prefix via `FileHandle`. `Int.max` → no cap.
    let maxReadFileBytes: Int
    /// Wall-clock cap (seconds) for a single `run_shell` / search child process.
    /// 0 = unlimited (no watchdog) — a real build/test legitimately runs for minutes.
    let shellTimeoutSeconds: TimeInterval

    public init(
        capabilities: ClientCapabilities, environment: ToolEnvironment,
        connection: ClientConnection?, sessionId: String, outputByteLimit: Int = 64 * 1024,
        maxResultBytes: Int = Int.max, maxReadFileBytes: Int = Int.max,
        shellTimeoutSeconds: TimeInterval = 0
    ) {
        self.capabilities = capabilities
        self.environment = environment
        self.connection = connection
        self.sessionId = sessionId
        self.outputByteLimit = outputByteLimit
        self.maxResultBytes = maxResultBytes
        self.maxReadFileBytes = maxReadFileBytes
        self.shellTimeoutSeconds = max(0, shellTimeoutSeconds)
    }

    /// The built-in tools' names, in advertise order. The single source of truth for
    /// "what tools exist" (used to validate an allowlist).
    public static let allToolNames = [
        "read_file", "write_file", "edit_file", "list_dir", "search", "run_shell",
        "open_terminal",
    ]

    /// Phase D4 — the interactive-PTY tool name. A PERSISTENT streaming terminal (REPLs,
    /// debuggers, long-running processes), as opposed to one-shot `run_shell`. NOT run by
    /// `ToolExecutor` (a value type can't own a long-lived process); `ACPAgent` intercepts
    /// it and manages the `PTYProcess` lifecycle. Defined here so it shares the tool
    /// allowlist + the `execute` ToolKind (and therefore the phone's mutating-tool gate).
    public static let openTerminalTool = "open_terminal"

    /// The OpenAI tool/function definitions the agent advertises to its LLM,
    /// optionally filtered to an allowlist (empty → all). Descriptions are written
    /// terse and imperative with one concrete example each: weaker/smaller models
    /// pick the right tool far more reliably from a crisp one-liner than from prose,
    /// and schemas pin exactly one required string arg so there's nothing to
    /// hallucinate. Order is preserved; unknown allowlist names are ignored.
    public static func toolDefinitions(allowlist: [String] = []) -> [LLMTool] {
        let all = [
            LLMTool(
                name: "read_file",
                description:
                    "Read a UTF-8 text file and return its contents. Use before editing a file. path is absolute or relative to the working directory. Example: read_file(path: \"Sources/App.swift\"). Large files come back head+tail truncated.",
                parameters: stringArgSchema(
                    name: "path", desc: "path to the file to read", required: true)),
            LLMTool(
                name: "write_file",
                description:
                    "Create or overwrite a UTF-8 text file. Pass the FULL new file contents in content (not a diff); missing parent directories are created. Use this for edits, not shell redirection, so changes show in the editor. Example: write_file(path: \"Sources/App.swift\", content: \"...\").",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("path to the file to create or overwrite"),
                        ]),
                        "content": .object([
                            "type": .string("string"),
                            "description": .string("the complete new contents of the file"),
                        ]),
                    ]),
                    "required": .array([.string("path"), .string("content")]),
                    "additionalProperties": .bool(false),
                ])),
            LLMTool(
                name: "edit_file",
                description:
                    "Replace an exact substring in a UTF-8 text file: old_string must occur EXACTLY ONCE (include enough surrounding lines to make it unique). Prefer this over write_file for small edits — you don't resend the whole file. Fails if old_string is missing or appears more than once. Example: edit_file(path: \"Sources/App.swift\", old_string: \"let x = 1\", new_string: \"let x = 2\").",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"),
                            "description": .string("path to the file to edit"),
                        ]),
                        "old_string": .object([
                            "type": .string("string"),
                            "description": .string(
                                "the exact text to replace (must be unique in the file)"),
                        ]),
                        "new_string": .object([
                            "type": .string("string"),
                            "description": .string("the replacement text"),
                        ]),
                    ]),
                    "required": .array([
                        .string("path"), .string("old_string"), .string("new_string"),
                    ]),
                    "additionalProperties": .bool(false),
                ])),
            LLMTool(
                name: "list_dir",
                description:
                    "List a directory's entries, one per line, directories suffixed with '/'. Use to discover files before reading them. path is absolute or relative to the working directory and defaults to '.'. Example: list_dir(path: \"Sources\").",
                parameters: stringArgSchema(
                    name: "path", desc: "directory to list (defaults to '.')", required: false)),
            LLMTool(
                name: "search",
                description:
                    "Search file contents for a literal string and return matching lines as path:line:text. Use to find where a symbol/string is defined or used before reading whole files. path scopes the search (a file or directory, default '.'). Read-only; results are capped. Example: search(query: \"func runTurn\", path: \"Sources\").",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("the literal text to search for"),
                        ]),
                        "path": .object([
                            "type": .string("string"),
                            "description": .string(
                                "file or directory to search (defaults to '.')"),
                        ]),
                    ]),
                    "required": .array([.string("query")]),
                    "additionalProperties": .bool(false),
                ])),
            LLMTool(
                name: "run_shell",
                description:
                    "Run one shell command with /bin/zsh -lc in the working directory; returns combined stdout+stderr and the exit code. Use for builds and tests, e.g. run_shell(command: \"xcodebuild -scheme App test\") or xcrun simctl / swift build. DEVELOPER_DIR is preset to the configured Xcode. Long output is truncated.",
                parameters: stringArgSchema(
                    name: "command", desc: "the single shell command line to run", required: true)),
            LLMTool(
                name: "open_terminal",
                description:
                    "Open a PERSISTENT interactive terminal (a live shell on a pseudo-terminal) for REPLs, debuggers, or long-running processes that need streamed input/output over time — NOT for one-off commands (use run_shell for those). Returns a terminalId; output streams live to the user's device and you cannot read it back, so only use this when the USER needs an interactive session. An optional command runs immediately in the shell. Example: open_terminal(command: \"python3\").",
                parameters: stringArgSchema(
                    name: "command",
                    desc: "an optional command to run immediately in the new shell (may be empty)",
                    required: false)),
        ]
        guard !allowlist.isEmpty else { return all }
        let wanted = Set(allowlist)
        return all.filter { wanted.contains($0.name) }
    }

    /// A JSON-Schema `object` with exactly one string property — the shape every
    /// single-arg tool shares. `additionalProperties:false` discourages a model
    /// from inventing extra keys.
    private static func stringArgSchema(name: String, desc: String, required: Bool) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                name: .object([
                    "type": .string("string"), "description": .string(desc),
                ])
            ]),
            "required": .array(required ? [.string(name)] : []),
            "additionalProperties": .bool(false),
        ])
    }

    /// ACP ToolKind for a tool name (drives the editor's icon/labeling).
    static func kind(for tool: String) -> String {
        switch tool {
        case "read_file", "list_dir", "search": return "read"
        case "write_file", "edit_file": return "edit"
        // run_shell and open_terminal both EXECUTE on the node → the `execute` ToolKind,
        // which the phone's allowlist (`PersonaRuntime.isMutatingACPToolKind`) treats as
        // mutating. open_terminal carries the stronger phone-side gate (the standing
        // autonomous-changes consent, no allow-once) because an open-ended interactive
        // shell can't be meaningfully approved per-keystroke — that distinction is made
        // phone-side off the tool TITLE (`isInteractiveTerminalTitle`), since the ACP
        // ToolKind vocabulary has no finer-grained value.
        case "run_shell", "open_terminal": return "execute"
        default: return "other"
        }
    }

    /// True for tools that change the world / run code — these get a permission
    /// prompt (when the client supports it) before they run.
    static func needsPermission(_ tool: String) -> Bool {
        tool == "write_file" || tool == "edit_file" || tool == "run_shell"
            || tool == "open_terminal"
    }

    /// A short human title for a tool call (shown in the editor's tool UI).
    static func title(for tool: String, args: JSONValue) -> String {
        switch tool {
        case "read_file": return "Read \(args["path"]?.stringValue ?? "file")"
        case "write_file": return "Write \(args["path"]?.stringValue ?? "file")"
        case "edit_file": return "Edit \(args["path"]?.stringValue ?? "file")"
        case "list_dir": return "List \(args["path"]?.stringValue ?? ".")"
        case "search": return "Search \"\(args["query"]?.stringValue ?? "")\""
        case "run_shell": return "Run: \(args["command"]?.stringValue ?? "")"
        case "open_terminal":
            // The phone keys its STRONGER gate (standing autonomous-changes consent, no
            // allow-once) off this exact prefix — `ACPTerminal.interactiveTerminalTitlePrefix`
            // (iOS-available, the single source of truth) / `PersonaRuntime.isInteractiveTerminalTitle`.
            let cmd = args["command"]?.stringValue ?? ""
            return cmd.isEmpty
                ? interactiveTerminalTitlePrefix
                : "\(interactiveTerminalTitlePrefix): \(cmd)"
        default: return tool
        }
    }

    /// Phase D4 — the stable title prefix every `open_terminal` permission request
    /// carries. Re-exported from the iOS-available `ACPTerminal` (the single source of
    /// truth shared with the phone's gate) so node-side call sites stay terse.
    public static let interactiveTerminalTitlePrefix = ACPTerminal.interactiveTerminalTitlePrefix

    // MARK: Dispatch

    public func run(tool: String, args: JSONValue) async -> ToolResult {
        let result: ToolResult
        switch tool {
        case "read_file": result = await readFile(args)
        case "write_file": result = await writeFile(args)
        case "edit_file": result = await editFile(args)
        case "list_dir": result = listDir(args)
        case "search": result = await search(args)
        case "run_shell": result = await runShell(args)
        default: return ToolResult(text: "unknown tool: \(tool)", isError: true)
        }
        // Context-window guard: every tool result fed back to the model is bounded.
        // (Shell already capped its CAPTURE at outputByteLimit; this trims further
        // for the prompt, and is the ONLY cap for read_file/list_dir.)
        return capped(result)
    }

    /// Head+tail truncate an over-budget result for the model, preserving the error
    /// flag and noting the elision. A no-op when the result already fits.
    private func capped(_ result: ToolResult) -> ToolResult {
        let trimmed = ContextBudget.truncate(result.text, maxBytes: maxResultBytes)
        guard trimmed.utf8.count != result.text.utf8.count else { return result }
        return ToolResult(text: trimmed, isError: result.isError)
    }

    // MARK: Path resolution

    /// Resolve a (possibly relative) path against the working directory and make it
    /// absolute — ACP fs/* methods REQUIRE absolute paths.
    func absolutePath(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        return (environment.effectiveWorkdir as NSString).appendingPathComponent(path)
    }

    /// C-2: resolve `path` to a canonical absolute path and confirm it stays WITHIN the
    /// session working directory. Returns nil when it escapes — an absolute path outside
    /// the workdir, a `../` traversal, or a symlink that points out — so the four file
    /// tools serve the project tree but never `~/.ssh`, `../../etc/...`, or a planted
    /// symlink. (run_shell is the deliberate, permission-gated escape hatch.) Symlinks
    /// are resolved BEFORE the prefix check so a link can't step out and back in.
    func jailedPath(_ path: String) -> String? {
        func canonical(_ p: String) -> String {
            URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path
        }
        var root = canonical(environment.effectiveWorkdir)
        if root.count > 1, root.hasSuffix("/") { root.removeLast() }
        // `resolvingSymlinksInPath` only resolves a symlinked component when the FULL
        // path exists on disk. For a NEW file (the normal `write_file` case) the leaf
        // doesn't exist, so a symlinked PARENT dir is left unresolved — `write_file(
        // "link/newfile")` through `link -> ~/.ssh` then passed the prefix check while
        // the actual write followed the link OUT of the jail (CR-2, PoC-confirmed). Fix:
        // canonicalize the deepest EXISTING ancestor (whose symlinks DO resolve), then
        // re-append the not-yet-existing leaf components and re-check.
        let fm = FileManager.default
        let absURL = URL(fileURLWithPath: absolutePath(path)).standardizedFileURL
        var existing = absURL
        var tail: [String] = []
        while !fm.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            if parent.path == existing.path { break }  // reached "/"
            tail.insert(existing.lastPathComponent, at: 0)
            existing = parent
        }
        var resolved = canonical(existing.path)
        for component in tail { resolved += "/" + component }
        resolved = canonical(resolved)  // also resolve a leaf that is itself a symlink
        return resolved == root || resolved.hasPrefix(root + "/") ? resolved : nil
    }

    // MARK: read_file

    private func readFile(_ args: JSONValue) async -> ToolResult {
        guard let rawPath = args["path"]?.stringValue, !rawPath.isEmpty else {
            return ToolResult(text: "read_file: missing 'path'", isError: true)
        }
        guard let path = jailedPath(rawPath) else {
            return ToolResult(
                text: "read_file: path is outside the working directory: \(rawPath)",
                isError: true)
        }

        // Prefer the client so the read is consistent with unsaved editor buffers.
        if capabilities.fsReadTextFile, let connection {
            do {
                let result = try await connection.request(
                    method: "fs/read_text_file",
                    params: .object(["sessionId": .string(sessionId), "path": .string(path)]))
                if let content = result["content"]?.stringValue {
                    return ToolResult(text: content)
                }
                // Fall through to Foundation if the client returned an odd shape.
            } catch {
                // Fall back to Foundation on any client-side failure.
            }
        }
        // Foundation fallback with read-side backpressure: stat first, and if the
        // file is over `maxReadFileBytes` read only a bounded PREFIX off disk (via
        // FileHandle) rather than loading the whole thing into memory just to trim it.
        let size =
            (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
        if let size, maxReadFileBytes != Int.max, size > maxReadFileBytes {
            guard let handle = FileHandle(forReadingAtPath: path) else {
                return ToolResult(text: "read_file: cannot read \(path)", isError: true)
            }
            defer { try? handle.close() }
            let prefix = (try? handle.read(upToCount: maxReadFileBytes)) ?? Data()
            // Cut on a UTF-8 character boundary so the prefix is always valid text.
            let head = String(decoding: prefix, as: UTF8.self)
            let note =
                "\n…[read_file: showing first \(prefix.count) of \(size) bytes; "
                + "the file is over the \(maxReadFileBytes)-byte read cap "
                + "(ELDR_ACP_MAX_READ_FILE_BYTES). Use search or read a narrower path.]"
            return ToolResult(text: head + note)
        }
        guard let data = FileManager.default.contents(atPath: path),
            let text = String(data: data, encoding: .utf8)
        else {
            return ToolResult(text: "read_file: cannot read \(path)", isError: true)
        }
        return ToolResult(text: text)
    }

    // MARK: write_file

    private func writeFile(_ args: JSONValue) async -> ToolResult {
        guard let rawPath = args["path"]?.stringValue, !rawPath.isEmpty else {
            return ToolResult(text: "write_file: missing 'path'", isError: true)
        }
        let content = args["content"]?.stringValue ?? ""
        guard let path = jailedPath(rawPath) else {
            return ToolResult(
                text: "write_file: path is outside the working directory: \(rawPath)",
                isError: true)
        }
        return await writeTextContents(
            path: path, content: content, label: "write_file",
            successNote: "wrote \(content.utf8.count) bytes to \(path)")
    }

    /// Write a file, preferring the client's `fs/write_text_file` (so the edit shows
    /// in the editor) and falling back to FileManager. Shared by write_file/edit_file.
    private func writeTextContents(
        path: String, content: String, label: String, successNote: String
    ) async -> ToolResult {
        if capabilities.fsWriteTextFile, let connection {
            do {
                _ = try await connection.request(
                    method: "fs/write_text_file",
                    params: .object([
                        "sessionId": .string(sessionId),
                        "path": .string(path),
                        "content": .string(content),
                    ]))
                return ToolResult(text: successNote)
            } catch {
                // Fall back to FileManager below.
            }
        }
        do {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
            try content.data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
            return ToolResult(text: successNote)
        } catch {
            return ToolResult(
                text: "\(label): \(error.localizedDescription) (\(path))", isError: true)
        }
    }

    /// Read a file's full contents as text (prefer the client buffer, then
    /// FileManager). No backpressure cap: callers that need the WHOLE file (edit_file
    /// must see every byte to do a correct substring replace) use this. Returns nil on
    /// any failure.
    private func readTextContents(path: String) async -> String? {
        if capabilities.fsReadTextFile, let connection {
            if let result = try? await connection.request(
                method: "fs/read_text_file",
                params: .object(["sessionId": .string(sessionId), "path": .string(path)])),
                let content = result["content"]?.stringValue
            {
                return content
            }
        }
        guard let data = FileManager.default.contents(atPath: path),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }

    // MARK: edit_file

    /// Exact-substring replace. `old_string` must be present and UNIQUE in the file —
    /// absent or ambiguous is an error (the model must add surrounding context), so an
    /// edit never silently changes the wrong occurrence. Mutating; permission-gated.
    private func editFile(_ args: JSONValue) async -> ToolResult {
        guard let rawPath = args["path"]?.stringValue, !rawPath.isEmpty else {
            return ToolResult(text: "edit_file: missing 'path'", isError: true)
        }
        guard let oldString = args["old_string"]?.stringValue, !oldString.isEmpty else {
            return ToolResult(text: "edit_file: missing or empty 'old_string'", isError: true)
        }
        let newString = args["new_string"]?.stringValue ?? ""
        if oldString == newString {
            return ToolResult(
                text: "edit_file: old_string and new_string are identical (no change)",
                isError: true)
        }
        guard let path = jailedPath(rawPath) else {
            return ToolResult(
                text: "edit_file: path is outside the working directory: \(rawPath)",
                isError: true)
        }
        guard let current = await readTextContents(path: path) else {
            return ToolResult(text: "edit_file: cannot read \(path)", isError: true)
        }
        let occurrences = current.components(separatedBy: oldString).count - 1
        if occurrences == 0 {
            return ToolResult(
                text: "edit_file: old_string not found in \(path)", isError: true)
        }
        if occurrences > 1 {
            return ToolResult(
                text:
                    "edit_file: old_string is not unique in \(path) (\(occurrences) matches); "
                    + "include more surrounding context so it matches exactly once",
                isError: true)
        }
        // Single occurrence: replace it (range-based so a `newString` that itself
        // contains `oldString` can't trigger a second replacement).
        guard let range = current.range(of: oldString) else {
            return ToolResult(text: "edit_file: old_string not found in \(path)", isError: true)
        }
        let updated = current.replacingCharacters(in: range, with: newString)
        return await writeTextContents(
            path: path, content: updated, label: "edit_file",
            successNote:
                "edited \(path): replaced \(oldString.utf8.count) bytes with \(newString.utf8.count) bytes")
    }

    // MARK: search

    /// Max matching lines a single `search` returns (the rest are elided with a
    /// note). Bounds the result so a broad query can't flood the context window.
    static let searchMatchCap = 200
    /// Directories never descended into during a recursive search (build/VCS noise).
    static let searchSkipDirs: Set<String> = [".git", ".build", ".swiftpm", "node_modules", ".DS_Store"]

    /// Literal, read-only content search. Prefers ripgrep (fast on a big tree) and
    /// falls back to a Foundation recursive walk; both emit `path:line:text` lines
    /// relative to the search root and are capped at `searchMatchCap`.
    private func search(_ args: JSONValue) async -> ToolResult {
        guard let query = args["query"]?.stringValue, !query.isEmpty else {
            return ToolResult(text: "search: missing 'query'", isError: true)
        }
        let rawPath = args["path"]?.stringValue ?? "."
        guard let root = jailedPath(rawPath.isEmpty ? "." : rawPath) else {
            return ToolResult(
                text: "search: path is outside the working directory: \(rawPath)",
                isError: true)
        }
        let cap = Self.searchMatchCap

        let matches =
            await searchViaRipgrep(query: query, root: root, cap: cap)
            ?? searchViaFoundation(query: query, root: root, cap: cap)

        guard !matches.lines.isEmpty else {
            return ToolResult(text: "search: no matches for \"\(query)\" under \(root)")
        }
        var text = matches.lines.joined(separator: "\n")
        if matches.truncated {
            text += "\n…[search: more than \(cap) matches; showing the first \(cap). Narrow the query or path.]"
        }
        return ToolResult(text: text)
    }

    private struct SearchMatches { var lines: [String]; var truncated: Bool }

    /// Run ripgrep with `cwd = root` (a dir) or its parent (a file) so it prints
    /// root-relative paths; returns nil when ripgrep is unavailable/failed (caller
    /// falls back to Foundation). `-F` = literal, `--no-heading -n` = `path:line:text`.
    private func searchViaRipgrep(query: String, root: String, cap: Int) async -> SearchMatches? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir) else { return nil }
        let cwd = isDir.boolValue ? root : (root as NSString).deletingLastPathComponent
        let target = isDir.boolValue ? "." : (root as NSString).lastPathComponent

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "rg", "--no-heading", "--line-number", "--color", "never", "-F",
            "--max-count", "\(cap)", "--", query, target,
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil  // ripgrep not installed → Foundation fallback
        }
        // Bound the search the same way as run_shell so a pathological tree can't
        // wedge the turn. rg is normally fast and self-terminating (`--max-count`);
        // this is belt-and-suspenders.
        // 0 = unlimited: no watchdog. A positive shellTimeoutSeconds reclaims a
        // non-terminating command; a real build/test may legitimately run minutes.
        let watchdog: Task<Void, Never>? = shellTimeoutSeconds > 0
            ? Self.processWatchdog(pid: process.processIdentifier, seconds: shellTimeoutSeconds)
            : nil
        defer { watchdog?.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // rg exit 1 = no matches (still a valid empty result); 2+ = usage/IO error.
        // 127 (env couldn't find rg) surfaces as a launch that ran but errored → treat
        // any status > 1 as "unavailable" so we fall back.
        if process.terminationStatus > 1 { return nil }
        let allLines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let capped = Array(allLines.prefix(cap))
        return SearchMatches(lines: capped, truncated: allLines.count > cap)
    }

    /// Foundation fallback: recursively walk `root` (skipping build/VCS dirs and
    /// over-cap files), matching the literal query line-by-line.
    private func searchViaFoundation(query: String, root: String, cap: Int) -> SearchMatches {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDir) else {
            return SearchMatches(lines: [], truncated: false)
        }
        let files: [String]
        if isDir.boolValue {
            var collected: [String] = []
            if let enumerator = fm.enumerator(atPath: root) {
                for case let rel as String in enumerator {
                    let last = (rel as NSString).lastPathComponent
                    if Self.searchSkipDirs.contains(last) {
                        enumerator.skipDescendants()
                        continue
                    }
                    let full = (root as NSString).appendingPathComponent(rel)
                    var entryIsDir: ObjCBool = false
                    fm.fileExists(atPath: full, isDirectory: &entryIsDir)
                    if !entryIsDir.boolValue { collected.append(full) }
                }
            }
            files = collected
        } else {
            files = [root]
        }

        var lines: [String] = []
        for file in files {
            // Skip obviously-binary or huge files (bounded read).
            let size = (try? fm.attributesOfItem(atPath: file)[.size] as? Int) ?? nil ?? 0
            if size > 2 * 1024 * 1024 { continue }
            guard let data = fm.contents(atPath: file),
                let text = String(data: data, encoding: .utf8)
            else { continue }
            let display = relativePath(file, to: root, rootIsDir: isDir.boolValue)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if line.contains(query) {
                    lines.append("\(display):\(i + 1):\(line)")
                    if lines.count > cap {
                        return SearchMatches(lines: Array(lines.prefix(cap)), truncated: true)
                    }
                }
            }
        }
        return SearchMatches(lines: lines, truncated: false)
    }

    /// Path of `file` relative to the search root (so output matches ripgrep's).
    private func relativePath(_ file: String, to root: String, rootIsDir: Bool) -> String {
        guard rootIsDir else { return (file as NSString).lastPathComponent }
        let base = root.hasSuffix("/") ? root : root + "/"
        return file.hasPrefix(base) ? String(file.dropFirst(base.count)) : file
    }

    // MARK: list_dir (always local — directory listing has no ACP method)

    private func listDir(_ args: JSONValue) -> ToolResult {
        let rawPath = args["path"]?.stringValue ?? "."
        guard let path = jailedPath(rawPath.isEmpty ? "." : rawPath) else {
            return ToolResult(
                text: "list_dir: path is outside the working directory: \(rawPath)",
                isError: true)
        }
        do {
            let entries = try FileManager.default.contentsOfDirectory(atPath: path).sorted()
            if entries.isEmpty { return ToolResult(text: "(empty directory) \(path)") }
            let lines = entries.map { name -> String in
                var isDir: ObjCBool = false
                let full = (path as NSString).appendingPathComponent(name)
                FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
                return isDir.boolValue ? "\(name)/" : name
            }
            return ToolResult(text: lines.joined(separator: "\n"))
        } catch {
            return ToolResult(text: "list_dir: cannot list \(path)", isError: true)
        }
    }

    // MARK: run_shell

    /// Wall-clock ceiling for a node-spawned child on the Foundation fallback
    /// path. The preferred client-terminal route delegates lifetime to the
    /// editor; this fallback owns it, so a non-terminating command can never hang
    /// the agent turn. A tool-execution safety bound — not a key-schedule timer.
    static let childProcessTimeout: TimeInterval = 120

    /// Fire-and-forget watchdog: after `seconds`, SIGTERM then (after a 0.5s
    /// grace) SIGKILL `pid`. Captures only the Sendable `pid_t` + Doubles, so it
    /// is safe to spawn from this `Sendable` value type without touching the
    /// non-Sendable `Process`. Cancel it once the child exits so a normally
    /// finishing command is never signalled. Kills the direct child — the common
    /// hang (`sleep` / `tail -f` / a wedged build / a `read` prompt) is a single
    /// exec'd process; deliberately backgrounded grandchildren are out of scope
    /// for this fallback (the client-terminal path is the supported long-lived route).
    static func processWatchdog(pid: pid_t, seconds: TimeInterval) -> Task<Void, Never> {
        Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if Task.isCancelled { return }
                kill(pid, SIGTERM)
                try await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                kill(pid, SIGKILL)
            } catch {
                // Cancelled — the child exited in time; nothing to reclaim.
            }
        }
    }

    private func runShell(_ args: JSONValue) async -> ToolResult {
        guard let command = args["command"]?.stringValue, !command.isEmpty else {
            return ToolResult(text: "run_shell: missing 'command'", isError: true)
        }
        if capabilities.terminal, let connection {
            if let result = await runShellViaClient(command, connection: connection) {
                return result
            }
            // nil → client terminal path failed; fall back to Foundation.
        }
        return await runShellViaProcess(command)
    }

    /// Route through the client's terminal/* methods so the command appears in the
    /// editor's terminal UI. Returns nil if the round-trip fails (caller falls back).
    private func runShellViaClient(_ command: String, connection: ClientConnection) async -> ToolResult? {
        let envArray: [JSONValue] = environment.shellEnvironment.map {
            .object(["name": .string($0.key), "value": .string($0.value)])
        }
        do {
            let created = try await connection.request(
                method: "terminal/create",
                params: .object([
                    "sessionId": .string(sessionId),
                    "command": .string("/bin/zsh"),
                    "args": .array([.string("-lc"), .string(command)]),
                    "env": .array(envArray),
                    "cwd": .string(environment.effectiveWorkdir),
                    "outputByteLimit": .int(outputByteLimit),
                ]))
            guard let terminalId = created["terminalId"]?.stringValue else { return nil }

            // Block until the command exits, then collect output, then release.
            let exit = try await connection.request(
                method: "terminal/wait_for_exit",
                params: .object([
                    "sessionId": .string(sessionId), "terminalId": .string(terminalId),
                ]))
            let out = try await connection.request(
                method: "terminal/output",
                params: .object([
                    "sessionId": .string(sessionId), "terminalId": .string(terminalId),
                ]))
            _ = try? await connection.request(
                method: "terminal/release",
                params: .object([
                    "sessionId": .string(sessionId), "terminalId": .string(terminalId),
                ]))

            // exitStatus lives on terminal/output result; wait_for_exit returns
            // {exitCode, signal} directly — accept either.
            let exitCode =
                exit["exitCode"]?.intValue ?? out["exitStatus"]?["exitCode"]?.intValue
            let output = out["output"]?.stringValue ?? ""
            let truncated = out["truncated"]?.boolValue ?? false
            return ToolResult(
                text: formatShellResult(output: output, truncated: truncated, exitCode: exitCode),
                isError: (exitCode ?? 0) != 0)
        } catch {
            return nil
        }
    }

    /// Foundation fallback: spawn /bin/zsh -lc with the (DEVELOPER_DIR-augmented)
    /// environment and capture combined stdout+stderr.
    ///
    /// `async` + a continuation: a background reader drains the pipe to EOF (so a
    /// child that fills the OS pipe buffer before exiting can't deadlock), owning
    /// its accumulator entirely within the closure and handing back one finished
    /// `Data` value. No shared mutable state, no lock — Sendable-clean.
    private func runShellViaProcess(_ command: String) async -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.environment = environment.shellEnvironment
        process.currentDirectoryURL = URL(fileURLWithPath: environment.effectiveWorkdir)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return ToolResult(
                text: "run_shell: failed to launch /bin/zsh: \(error.localizedDescription)",
                isError: true)
        }

        // A non-terminating command must never hang the agent turn. The watchdog
        // captures only the Sendable pid (never the non-Sendable `Process`) and,
        // on overrun, SIGTERM→SIGKILLs the child — which closes the pipe, ending
        // the drain below and letting `waitUntilExit()` return. Cancelled the
        // instant the child exits normally, so a fast command is never signalled.
        // 0 = unlimited: no watchdog. A positive shellTimeoutSeconds reclaims a
        // non-terminating command; a real build/test may legitimately run minutes.
        let watchdog: Task<Void, Never>? = shellTimeoutSeconds > 0
            ? Self.processWatchdog(pid: process.processIdentifier, seconds: shellTimeoutSeconds)
            : nil
        defer { watchdog?.cancel() }

        let handle = pipe.fileHandleForReading
        let limit = outputByteLimit
        // Drain to EOF on a background queue; resume with the captured bytes.
        let collected: Data = await withCheckedContinuation { continuation in
            DispatchQueue(label: "eldr-acp.shell.reader").async {
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }  // EOF (pipe closed when child exits/killed)
                    if buffer.count < limit {
                        buffer.append(chunk.prefix(limit - buffer.count))
                    }
                }
                continuation.resume(returning: buffer)
            }
        }
        process.waitUntilExit()

        let truncated = collected.count >= limit
        let output = String(data: collected, encoding: .utf8) ?? ""
        let exitCode = Int(process.terminationStatus)
        // A SIGTERM/SIGKILL exit on this path is the watchdog reclaiming a runaway
        // (a command that self-signals is a rare, acceptable false-positive label).
        let timedOut = process.terminationReason == .uncaughtSignal
            && (process.terminationStatus == SIGKILL || process.terminationStatus == SIGTERM)
        return ToolResult(
            text: formatShellResult(
                output: output, truncated: truncated, exitCode: exitCode, timedOut: timedOut),
            isError: exitCode != 0 || timedOut)
    }

    private func formatShellResult(
        output: String, truncated: Bool, exitCode: Int?, timedOut: Bool = false
    ) -> String {
        var text = output
        if truncated { text += "\n…[output truncated at \(outputByteLimit) bytes]" }
        if timedOut {
            text +=
                "\n…[run_shell: timed out after \(Int(shellTimeoutSeconds))s and was killed — the command did not exit. Use open_terminal for long-lived processes, or background it and poll.]"
        }
        text += "\n[exit code: \(exitCode.map(String.init) ?? "unknown")]"
        return text
    }
}
#endif  // os(macOS) — ToolExecutor (node-side, spawns Process)
