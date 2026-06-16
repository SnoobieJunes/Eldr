import Foundation

/// EldrChat's ACP agent. An ACP CLIENT (Xcode 27) spawns it over stdio and drives
/// it with JSON-RPC: `initialize` → `session/new` → `session/prompt`. On a prompt
/// the agent runs a tool-calling loop against a local LLM, streaming `session/update`
/// notifications (agent_message_chunk / tool_call / tool_call_update) and routing
/// file/shell work through the client (fs/*, terminal/*) when the client supports it.
///
/// This is the agent half of the bidirectional transport: inbound requests are
/// answered by `handle(line:)` (mirroring `MCPServer`), while outbound
/// notifications/requests flow through the injected `ClientConnection`. An actor so
/// all session/turn state is serialized without locks.
public actor ACPAgent {
    public static let agentName = "eldr-acp"
    public static let agentVersion = "0.1.0"
    /// ACP MAJOR protocol version we speak (a single integer; see spec).
    public static let protocolVersion = 1

    private let connection: ClientConnection
    private let llm: any LLMClient
    private let toolEnvironment: ToolEnvironment
    private let config: AgentConfig
    /// Config dir used to auto-discover a project's `eldr.md` when no explicit
    /// `ELDR_ACP_CONTEXT_FILE` is set. Injected (not hard-coded to ~/.config) so
    /// unit tests stay home-directory-free — pass `nil` to disable auto-discovery.
    private let configDir: String?
    private let maxIterations: Int
    /// The advertised, executable skills (ACP slash-commands). Derived from config
    /// once at init; empty when skills are disabled.
    private let skills: AgentSkillSet

    /// Negotiated at `initialize`. Defaults to "everything off" until then (so a
    /// stray prompt before initialize still works via Foundation fallbacks).
    private var clientCapabilities = ClientCapabilities()
    /// Live sessions: id → working directory (the `cwd` from session/new).
    private var sessions: [String: String] = [:]
    private var sessionCounter = 0
    /// Sessions the client asked to cancel; the turn loop checks this and bails.
    private var cancelledSessions: Set<String> = []
    /// Per-session project context (eldr.md contents), resolved at session/new and
    /// prepended to the system prompt on every turn of that session.
    private var sessionContext: [String: String] = [:]
    /// Per-session count of files written (for the session_end event's `files`).
    private var sessionWriteCounts: [String: Int] = [:]
    /// Per-session last observed build result ("green" | "red" | "unknown"), updated
    /// whenever a run_shell command looks like a build/test (for `session_end.build`).
    private var sessionBuildStatus: [String: String] = [:]

    public init(
        connection: ClientConnection,
        llm: any LLMClient,
        toolEnvironment: ToolEnvironment = .fromEnvironment(),
        config: AgentConfig = .fromEnvironment(),
        configDir: String? = AgentConfig.defaultConfigDir(ProcessInfo.processInfo.environment),
        maxIterations: Int = 20
    ) {
        self.connection = connection
        self.llm = llm
        self.toolEnvironment = toolEnvironment
        self.config = config
        self.configDir = configDir
        self.maxIterations = maxIterations
        self.skills = AgentSkillSet.from(config: config)
    }

    struct RPCError: Error { let code: Int; let message: String }

    // MARK: - Inbound dispatch (mirrors MCPServer.handle)

    /// Handle one inbound JSON-RPC line from the client. Returns the response line
    /// for a request, or nil for a notification / a response to one of OUR outbound
    /// requests (those are routed into `ClientConnection`, not answered here).
    public func handle(line: String) async -> String? {
        guard let message = JSONValue.parse(line) else { return nil }

        // A response to one of our outbound requests (has id + result/error, no
        // method) — hand it to the connection and produce no reply.
        if message["method"] == nil {
            await connection.deliver(response: message)
            return nil
        }

        let id = message["id"]  // nil → notification; present → request
        guard let method = message["method"]?.stringValue else {
            return id == nil
                ? nil : errorResponse(id: id, code: -32600, message: "Invalid Request")
        }

        let params = message["params"] ?? .object([:])

        // Notifications (no id): handled for side effects, never answered.
        if id == nil {
            await handleNotification(method: method, params: params)
            return nil
        }

        do {
            let result = try await dispatch(method: method, params: params)
            return successResponse(id: id, result: result)
        } catch let e as RPCError {
            return errorResponse(id: id, code: e.code, message: e.message)
        } catch {
            return errorResponse(id: id, code: -32603, message: "Internal error")
        }
    }

    private func dispatch(method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "initialize": return initializeResult(params: params)
        case "session/new": return await newSessionResult(params: params)
        case "session/prompt": return try await promptResult(params: params)
        // session/load and authenticate are intentionally not implemented — we
        // require no auth and advertise loadSession:false (see initialize).
        default: throw RPCError(code: -32601, message: "Method not found: \(method)")
        }
    }

    private func handleNotification(method: String, params: JSONValue) async {
        switch method {
        case "session/cancel":
            if let sid = params["sessionId"]?.stringValue { cancelledSessions.insert(sid) }
        default:
            break  // unknown notifications are ignored (forward-compat)
        }
    }

    // MARK: - initialize

    private func initializeResult(params: JSONValue) -> JSONValue {
        clientCapabilities = ClientCapabilities(initializeParams: params)
        // Echo the client's MAJOR version if we speak it; otherwise our own.
        let requested = params["protocolVersion"]?.intValue ?? Self.protocolVersion
        let version = requested == Self.protocolVersion ? requested : Self.protocolVersion
        var agentCapabilities: [String: JSONValue] = [
            // We don't persist sessions across runs.
            "loadSession": .bool(false),
            // Text + embedded context (Xcode 27 sends selected code / build errors
            // as embedded blocks; `extractPromptText` folds them into the prompt).
            // Still no image/audio.
            "promptCapabilities": .object([
                "image": .bool(false),
                "audio": .bool(false),
                "embeddedContext": .bool(true),
            ]),
        ]
        // Advertise skills here too (in addition to the post-session/new
        // available_commands_update), so a client that reads commands at initialize
        // — or never opens a session before showing its menu — still sees them. The
        // canonical place is the session/update; this is an upward-compatible hint.
        if !skills.isEmpty {
            agentCapabilities["availableCommands"] = .array(skills.availableCommandsJSON)
        }
        return .object([
            "protocolVersion": .int(version),
            "agentCapabilities": .object(agentCapabilities),
            "agentInfo": .object([
                "name": .string(Self.agentName),
                "version": .string(Self.agentVersion),
            ]),
            // We require NO authentication: empty authMethods.
            "authMethods": .array([]),
        ])
    }

    // MARK: - session/new

    private func newSessionResult(params: JSONValue) async -> JSONValue {
        sessionCounter += 1
        let sessionId = "eldr-session-\(sessionCounter)"
        // Per-session cwd: the client's `cwd`, else the agent's configured workdir.
        let cwd = params["cwd"]?.stringValue ?? toolEnvironment.effectiveWorkdir
        sessions[sessionId] = cwd
        // Resolve this project's persistent context (explicit ELDR_ACP_CONTEXT_FILE,
        // else the auto-discovered per-project eldr.md). Stored once; prepended to
        // the system prompt on every turn of this session.
        if let context = ProjectContext.read(
            explicitPath: config.contextFilePath, configDir: configDir, cwd: cwd)
        {
            sessionContext[sessionId] = context
        }
        // Advertise the agent's skills for this session. ACP's canonical channel for
        // command discovery is an available_commands_update session/update; clients
        // (Zed, OpenClaw) surface these as slash-commands in their menu.
        await advertiseSkills(sessionId: sessionId)
        return .object(["sessionId": .string(sessionId)])
    }

    /// Emit an `available_commands_update` for `sessionId` listing the active skills.
    /// No-op when skills are disabled (nothing to advertise).
    private func advertiseSkills(sessionId: String) async {
        guard !skills.isEmpty else { return }
        await connection.notify(
            method: "session/update",
            params: ACPWire.availableCommandsUpdate(
                sessionId: sessionId, commands: skills.availableCommandsJSON))
    }

    // MARK: - session/prompt (the turn)

    private func promptResult(params: JSONValue) async throws -> JSONValue {
        guard let sessionId = params["sessionId"]?.stringValue, sessions[sessionId] != nil else {
            throw RPCError(code: -32602, message: "unknown or missing sessionId")
        }
        // Fresh cancel state for this turn.
        cancelledSessions.remove(sessionId)

        let rawText = Self.extractPromptText(params["prompt"])
        // A leading `/skill …` invokes a skill: the rest is the user's text and the
        // skill contributes a focused system instruction for this turn only. Plain
        // prompts (and unknown /commands) run with the default system prompt.
        let invocation = skills.invocation(for: rawText)
        let userText = invocation?.argument ?? rawText
        let stopReason = await runTurn(
            sessionId: sessionId, userText: userText, skill: invocation?.skill)
        return .object(["stopReason": .string(stopReason.rawValue)])
    }

    /// Flatten a prompt's content blocks into a single user string. Handles the
    /// embedded-context blocks an ACP client (Xcode 27) sends when the user invokes
    /// the agent on a selection or a build error: `code` blocks are fenced (with any
    /// language/path hint) and `compilation_error`/`diagnostic` blocks are labeled so
    /// the model treats them as something to fix. image/audio/unknown blocks are
    /// ignored (forward-compatible).
    static func extractPromptText(_ prompt: JSONValue?) -> String {
        guard let blocks = prompt?.arrayValue else { return prompt?.stringValue ?? "" }
        return blocks.compactMap(blockText(_:)).joined(separator: "\n")
    }

    /// Render one ACP content block as prompt text, or nil to drop it.
    static func blockText(_ block: JSONValue) -> String? {
        switch block["type"]?.stringValue {
        case "text":
            return block["text"]?.stringValue
        case "code":
            guard let code = block["text"]?.stringValue ?? block["code"]?.stringValue else {
                return nil
            }
            let language = block["language"]?.stringValue ?? ""
            let location = block["path"]?.stringValue ?? block["uri"]?.stringValue
            let header = location.map { "// \($0)\n" } ?? ""
            return "\(header)```\(language)\n\(code)\n```"
        case "compilation_error", "diagnostic":
            guard let message = block["text"]?.stringValue ?? block["message"]?.stringValue else {
                return nil
            }
            let at = (block["path"]?.stringValue).map { " at \($0)" } ?? ""
            return "Compilation error\(at):\n\(message)"
        default:
            return nil
        }
    }

    /// The tool-calling loop. Builds the message list, calls the LLM with tool defs;
    /// on tool_calls, streams + executes each (permission-gated for mutating tools),
    /// feeds results back, and loops (≤ maxIterations). On a final assistant message,
    /// streams it as agent_message_chunk and returns end_turn.
    private func runTurn(
        sessionId: String, userText: String, skill: AgentSkill? = nil
    ) async -> StopReason {
        let cwd = sessions[sessionId] ?? toolEnvironment.effectiveWorkdir
        var perTurnEnvironment = toolEnvironment
        perTurnEnvironment.workdir = cwd
        let executor = ToolExecutor(
            capabilities: clientCapabilities, environment: perTurnEnvironment,
            connection: connection, sessionId: sessionId,
            maxResultBytes: config.maxToolResultBytes)
        let tools = ToolExecutor.toolDefinitions(allowlist: config.toolAllowlist)

        // Leading system run: optional project-context block FIRST (so the model
        // reads the project's accumulated facts/corrections before its operating
        // instructions), then the operating system prompt, then the task. Both
        // system messages are anchored by ContextBudget.trim's leading-system rule.
        var messages: [LLMMessage] = []
        if let context = sessionContext[sessionId] {
            messages.append(
                LLMMessage(role: .system, content: ProjectContext.systemBlock(context)))
        }
        messages.append(
            LLMMessage(
                role: .system,
                content: Self.systemPrompt(cwd: cwd, config: config, skill: skill)))
        messages.append(LLMMessage(role: .user, content: userText))

        var toolCallSeq = 0
        for _ in 0..<maxIterations {
            if cancelledSessions.contains(sessionId) { return .cancelled }

            // Context budgeting: bound the history sent to the model each turn so a
            // long tool loop (and the large results it accumulates) can't outgrow
            // the window. The system prompt + the task are always preserved.
            let outgoing = ContextBudget.trim(
                messages, maxTurns: config.maxHistoryTurns, maxChars: config.maxContextChars)

            let response: LLMResponse
            do {
                response = try await llm.complete(messages: outgoing, tools: tools)
            } catch {
                // Surface the failure to the user as a message, then end the turn.
                await emitMessage(
                    sessionId: sessionId,
                    text: "The local model call failed: \(Self.describe(error))")
                return .refusal
            }

            if cancelledSessions.contains(sessionId) { return .cancelled }

            guard response.wantsTools else {
                // Final answer.
                let text = response.content.isEmpty ? "(no response)" : response.content
                await emitMessage(sessionId: sessionId, text: text)
                logSessionEnd(sessionId: sessionId, cwd: cwd, summary: text)
                return .endTurn
            }

            // Record the assistant's tool-call turn so the model sees its own calls.
            messages.append(
                LLMMessage(role: .assistant, content: response.content, toolCalls: response.toolCalls))

            // Execute each requested tool, streaming ACP tool_call lifecycle.
            for call in response.toolCalls {
                if cancelledSessions.contains(sessionId) { return .cancelled }
                toolCallSeq += 1
                let toolCallId = "\(sessionId)-tc-\(toolCallSeq)"
                let args = call.argumentsJSON
                let result = await runOneTool(
                    sessionId: sessionId, toolCallId: toolCallId, executor: executor,
                    name: call.name, args: args, cwd: cwd)
                messages.append(
                    LLMMessage(role: .tool, content: result.text, toolCallId: call.id))
            }
        }

        // Hit the iteration cap without a final message.
        let capMessage = "Reached the tool-call limit (\(maxIterations) steps) without finishing."
        await emitMessage(sessionId: sessionId, text: capMessage)
        logSessionEnd(sessionId: sessionId, cwd: cwd, summary: capMessage)
        return .maxTurnRequests
    }

    /// Stream one tool call's lifecycle and run it. Mutating tools (write_file,
    /// run_shell) request permission first when the client supports it; a denial
    /// short-circuits to a failed tool_call_update and a "denied" tool result.
    private func runOneTool(
        sessionId: String, toolCallId: String, executor: ToolExecutor,
        name: String, args: JSONValue, cwd: String
    ) async -> ToolResult {
        let kind = ToolExecutor.kind(for: name)
        let title = ToolExecutor.title(for: name, args: args)

        // tool_call (pending)
        await connection.notify(
            method: "session/update",
            params: ACPWire.toolCall(
                sessionId: sessionId, toolCallId: toolCallId, title: title, kind: kind,
                status: "pending", rawInput: args))

        // Permission gate for mutating tools (only if the client can prompt).
        if ToolExecutor.needsPermission(name) {
            let allowed = await requestPermission(
                sessionId: sessionId, toolCallId: toolCallId, title: title, kind: kind)
            if !allowed {
                await connection.notify(
                    method: "session/update",
                    params: ACPWire.toolCallUpdate(
                        sessionId: sessionId, toolCallId: toolCallId, status: "failed",
                        contentText: "Permission denied by the user.", isError: true))
                return ToolResult(
                    text: "The user denied permission to run \(name).", isError: true)
            }
        }

        // tool_call_update (in_progress)
        await connection.notify(
            method: "session/update",
            params: ACPWire.toolCallUpdate(
                sessionId: sessionId, toolCallId: toolCallId, status: "in_progress"))

        let result = await executor.run(tool: name, args: args)

        // tool_call_update (completed | failed) with the result text.
        await connection.notify(
            method: "session/update",
            params: ACPWire.toolCallUpdate(
                sessionId: sessionId, toolCallId: toolCallId,
                status: result.isError ? "failed" : "completed",
                contentText: result.text, isError: result.isError))

        logToolEvent(name: name, args: args, result: result, sessionId: sessionId, cwd: cwd)
        return result
    }

    /// Append a JSONL event for a significant tool call (write_file / run_shell) and
    /// update per-session counters that feed the session_end event. No-op unless
    /// `ELDR_ACP_EVENTS_FILE` is set.
    private func logToolEvent(
        name: String, args: JSONValue, result: ToolResult, sessionId: String, cwd: String
    ) {
        switch name {
        case "write_file" where !result.isError:
            sessionWriteCounts[sessionId, default: 0] += 1
            let path = Self.resolvePath(args["path"]?.stringValue ?? "", cwd: cwd)
            ACPEventLog.writeFile(
                path: path, session: sessionId, cwd: cwd, to: config.eventsFilePath)
        case "run_shell":
            let cmd = args["command"]?.stringValue ?? ""
            let exit = Self.parseShellExit(from: result.text)
            // A build/test command's outcome is the session's build status.
            if Self.isBuildCommand(cmd) {
                sessionBuildStatus[sessionId] = exit == 0 ? "green" : "red"
            }
            ACPEventLog.shellResult(
                cmd: cmd, exit: exit, summary: String(result.text.prefix(200)),
                session: sessionId, cwd: cwd, to: config.eventsFilePath)
        default:
            break
        }
    }

    /// Emit the session_end event with the final summary, files-written count, and
    /// build status. No-op unless `ELDR_ACP_EVENTS_FILE` is set.
    private func logSessionEnd(sessionId: String, cwd: String, summary: String) {
        ACPEventLog.sessionEnd(
            cwd: cwd, session: sessionId, summary: String(summary.prefix(200)),
            files: sessionWriteCounts[sessionId] ?? 0,
            build: sessionBuildStatus[sessionId] ?? "unknown",
            to: config.eventsFilePath)
    }

    /// Ask the client for permission. If the client can't prompt (no permission
    /// support implied by terminal/fs caps), default to ALLOW — the client spawned
    /// us as a trusted local subprocess, and the user expects the agent to act.
    private func requestPermission(
        sessionId: String, toolCallId: String, title: String, kind: String
    ) async -> Bool {
        // ACP doesn't expose a dedicated "can request permission" capability; the
        // method is always available on a conformant client. We attempt it and, on
        // any transport failure, fall back to allow.
        do {
            let result = try await connection.request(
                method: "session/request_permission",
                params: ACPWire.requestPermission(
                    sessionId: sessionId, toolCallId: toolCallId, title: title, kind: kind))
            return ACPWire.permissionGranted(result)
        } catch {
            return true
        }
    }

    private func emitMessage(sessionId: String, text: String) async {
        await connection.notify(
            method: "session/update",
            params: ACPWire.agentMessageChunk(sessionId: sessionId, text: text))
    }

    // MARK: - System prompt

    /// The turn's system prompt. A user override (`ELDR_ACP_SYSTEM_PROMPT` / config
    /// file) replaces the BASE wholesale ({cwd} substituted); otherwise the built-in
    /// prompt is used and any preamble (`ELDR_ACP_PROMPT_PREAMBLE`) is appended so a
    /// user can nudge a finicky model's tool-calling without forking the binary.
    ///
    /// When a `skill` is active (a `/spec`, `/snippet`, `/html` invocation), its
    /// focused instruction is appended LAST so it steers this turn's output format
    /// while the base prompt's facts (cwd, the tool list, "report real results")
    /// still apply. The skill text wins on any output-shape conflict because it
    /// comes last.
    static func systemPrompt(
        cwd: String, config: AgentConfig = .default, skill: AgentSkill? = nil
    ) -> String {
        func withSkill(_ base: String) -> String {
            guard let skill else { return base }
            let instruction = skill.systemInstruction.replacingOccurrences(of: "{cwd}", with: cwd)
            return base + "\n\n--- Skill: /\(skill.name) ---\n" + instruction
        }
        if let override = config.systemPromptOverride {
            return withSkill(override.replacingOccurrences(of: "{cwd}", with: cwd))
        }
        var prompt = """
            You are EldrChat's coding agent, embedded in an iOS/macOS developer's editor \
            (an Agent Client Protocol client such as Xcode). You help write Swift code, \
            edit files, build projects, and run tests on the iOS Simulator.

            You have these tools — call them rather than guessing:
              • read_file(path): read a text file.
              • write_file(path, content): create/overwrite a text file with full new contents.
              • list_dir(path): list a directory.
              • run_shell(command): run a shell command (e.g. `xcodebuild …`, `xcrun simctl …`, \
            `swift build`). DEVELOPER_DIR is preconfigured so xcodebuild/xcrun target the \
            intended Xcode.

            Guidelines:
              • The working directory is: \(cwd). Prefer paths relative to it; absolute paths also work.
              • Make minimal, correct edits. Read a file before rewriting it.
              • Call ONE tool at a time and wait for its result before the next step.
              • Tool results may be truncated (a `… N bytes elided …` marker): read a \
            specific file or grep for the part you need rather than re-reading huge output.
              • When you build or test, run the command and report the real result; do not fabricate output.
              • When the task is done, reply with a short plain-text summary of what you did. \
            Do not include chain-of-thought.
            """
        if let preamble = config.promptPreamble, !preamble.isEmpty {
            prompt += "\n\n" + preamble
        }
        return withSkill(prompt)
    }

    // MARK: - Helpers

    /// Resolve a (possibly relative) tool path against the session cwd, matching
    /// `ToolExecutor.absolutePath` so an events.jsonl `path` equals where the file
    /// actually landed (ContextLearner watches that path).
    static func resolvePath(_ path: String, cwd: String) -> String {
        if path.isEmpty || path.hasPrefix("/") { return path }
        return (cwd as NSString).appendingPathComponent(path)
    }

    /// Pull the exit code out of a run_shell result (`formatShellResult` appends
    /// `[exit code: N]`). Returns -1 when absent/unknown.
    static func parseShellExit(from text: String) -> Int {
        guard let marker = text.range(of: "[exit code: ", options: .backwards) else { return -1 }
        let tail = text[marker.upperBound...]
        let digits = tail.prefix { $0 == "-" || $0.isNumber }
        return Int(digits) ?? -1
    }

    /// True when a shell command is a build/test invocation whose exit status should
    /// become the session's build result.
    static func isBuildCommand(_ command: String) -> Bool {
        let c = command.lowercased()
        return c.contains("xcodebuild") || c.contains("swift build") || c.contains("swift test")
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let e as LLMError:
            switch e {
            case .notConfigured(let m): return "not configured: \(m)"
            case .http(let code, let m): return "HTTP \(code): \(m)"
            case .badResponse(let m): return "bad response: \(m)"
            }
        default:
            return (error as NSError).localizedDescription
        }
    }

    // MARK: - JSON-RPC envelopes (mirrors MCPServer)

    private func successResponse(id: JSONValue?, result: JSONValue) -> String {
        JSONValue.object(["jsonrpc": .string("2.0"), "id": id ?? .null, "result": result])
            .serialized()
    }
    private func errorResponse(id: JSONValue?, code: Int, message: String) -> String {
        JSONValue.object([
            "jsonrpc": .string("2.0"), "id": id ?? .null,
            "error": .object(["code": .int(code), "message": .string(message)]),
        ]).serialized()
    }
}
