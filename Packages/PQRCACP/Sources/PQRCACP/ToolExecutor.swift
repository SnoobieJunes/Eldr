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

    /// The effective environment for a spawned shell (base + DEVELOPER_DIR override).
    var shellEnvironment: [String: String] {
        var e = baseEnvironment
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
    /// Hard cap on captured shell output bytes fed back to the model, so a chatty
    /// build can't blow the context window.
    let outputByteLimit: Int

    public init(
        capabilities: ClientCapabilities, environment: ToolEnvironment,
        connection: ClientConnection?, sessionId: String, outputByteLimit: Int = 64 * 1024
    ) {
        self.capabilities = capabilities
        self.environment = environment
        self.connection = connection
        self.sessionId = sessionId
        self.outputByteLimit = outputByteLimit
    }

    /// The OpenAI tool/function definitions the agent advertises to its LLM.
    public static func toolDefinitions() -> [LLMTool] {
        [
            LLMTool(
                name: "read_file",
                description:
                    "Read a UTF-8 text file and return its contents. `path` is absolute, or relative to the working directory.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"), "description": .string("file path"),
                        ])
                    ]),
                    "required": .array([.string("path")]),
                ])),
            LLMTool(
                name: "write_file",
                description:
                    "Create or overwrite a UTF-8 text file with `content`. Parent directories are created as needed. Prefer this over shell redirection so edits show in the editor.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"), "description": .string("file path"),
                        ]),
                        "content": .object([
                            "type": .string("string"),
                            "description": .string("full new file contents"),
                        ]),
                    ]),
                    "required": .array([.string("path"), .string("content")]),
                ])),
            LLMTool(
                name: "list_dir",
                description:
                    "List the entries of a directory (one per line; directories suffixed with '/'). `path` is absolute or relative to the working directory; defaults to '.'.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "path": .object([
                            "type": .string("string"), "description": .string("directory path"),
                        ])
                    ]),
                    "required": .array([]),
                ])),
            LLMTool(
                name: "run_shell",
                description:
                    "Run a shell command via /bin/zsh -lc in the working directory and return its combined stdout/stderr and exit code. Use this for xcodebuild and xcrun simctl (DEVELOPER_DIR is set so they target the configured Xcode).",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "command": .object([
                            "type": .string("string"),
                            "description": .string("the shell command line to execute"),
                        ])
                    ]),
                    "required": .array([.string("command")]),
                ])),
        ]
    }

    /// ACP ToolKind for a tool name (drives the editor's icon/labeling).
    static func kind(for tool: String) -> String {
        switch tool {
        case "read_file", "list_dir": return "read"
        case "write_file": return "edit"
        case "run_shell": return "execute"
        default: return "other"
        }
    }

    /// True for tools that change the world / run code — these get a permission
    /// prompt (when the client supports it) before they run.
    static func needsPermission(_ tool: String) -> Bool {
        tool == "write_file" || tool == "run_shell"
    }

    /// A short human title for a tool call (shown in the editor's tool UI).
    static func title(for tool: String, args: JSONValue) -> String {
        switch tool {
        case "read_file": return "Read \(args["path"]?.stringValue ?? "file")"
        case "write_file": return "Write \(args["path"]?.stringValue ?? "file")"
        case "list_dir": return "List \(args["path"]?.stringValue ?? ".")"
        case "run_shell": return "Run: \(args["command"]?.stringValue ?? "")"
        default: return tool
        }
    }

    // MARK: Dispatch

    public func run(tool: String, args: JSONValue) async -> ToolResult {
        switch tool {
        case "read_file": return await readFile(args)
        case "write_file": return await writeFile(args)
        case "list_dir": return listDir(args)
        case "run_shell": return await runShell(args)
        default: return ToolResult(text: "unknown tool: \(tool)", isError: true)
        }
    }

    // MARK: Path resolution

    /// Resolve a (possibly relative) path against the working directory and make it
    /// absolute — ACP fs/* methods REQUIRE absolute paths.
    func absolutePath(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        return (environment.effectiveWorkdir as NSString).appendingPathComponent(path)
    }

    // MARK: read_file

    private func readFile(_ args: JSONValue) async -> ToolResult {
        guard let rawPath = args["path"]?.stringValue, !rawPath.isEmpty else {
            return ToolResult(text: "read_file: missing 'path'", isError: true)
        }
        let path = absolutePath(rawPath)

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
        let path = absolutePath(rawPath)

        if capabilities.fsWriteTextFile, let connection {
            do {
                _ = try await connection.request(
                    method: "fs/write_text_file",
                    params: .object([
                        "sessionId": .string(sessionId),
                        "path": .string(path),
                        "content": .string(content),
                    ]))
                return ToolResult(text: "wrote \(content.utf8.count) bytes to \(path)")
            } catch {
                // Fall back to FileManager below.
            }
        }
        do {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
            try content.data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
            return ToolResult(text: "wrote \(content.utf8.count) bytes to \(path)")
        } catch {
            return ToolResult(
                text: "write_file: \(error.localizedDescription) (\(path))", isError: true)
        }
    }

    // MARK: list_dir (always local — directory listing has no ACP method)

    private func listDir(_ args: JSONValue) -> ToolResult {
        let rawPath = args["path"]?.stringValue ?? "."
        let path = absolutePath(rawPath.isEmpty ? "." : rawPath)
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

        let handle = pipe.fileHandleForReading
        let limit = outputByteLimit
        // Drain to EOF on a background queue; resume with the captured bytes.
        let collected: Data = await withCheckedContinuation { continuation in
            DispatchQueue(label: "eldr-acp.shell.reader").async {
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }  // EOF (pipe closed when child exits)
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
        return ToolResult(
            text: formatShellResult(output: output, truncated: truncated, exitCode: exitCode),
            isError: exitCode != 0)
    }

    private func formatShellResult(output: String, truncated: Bool, exitCode: Int?) -> String {
        var text = output
        if truncated { text += "\n…[output truncated at \(outputByteLimit) bytes]" }
        text += "\n[exit code: \(exitCode.map(String.init) ?? "unknown")]"
        return text
    }
}
