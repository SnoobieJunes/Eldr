import Foundation

// NODE-SIDE (macOS only): the AGENT half of ACP. It runs the tool-calling loop and
// executes file/shell tools via `ToolExecutor` (which spawns `Process`), so it only
// runs on the Mac node. The iOS app drives a remote agent over an `ACPTransport` via
// `ACPClient`/`ACPClientDriver` and never instantiates the agent itself, so this whole
// type is guarded off the iOS-compiled `PQRCACP` library. The one wire constant the
// client path needs (`protocolVersion`) lives on `ACPClientDriver` (iOS-available) and
// is mirrored here so macOS keeps a single source of truth.
#if os(macOS)
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
    /// ACP MAJOR protocol version we speak (a single integer; see spec). Defined on the
    /// iOS-available client driver so the phone path can reference it without pulling in
    /// this macOS-only agent; mirrored here to keep the agent's call sites unchanged.
    public static let protocolVersion = ACPClientDriver.acpProtocolVersion

    private let connection: ClientConnection
    private let llm: any LLMClient
    private let toolEnvironment: ToolEnvironment
    private let config: AgentConfig
    /// Config dir used to auto-discover a project's `eldr.md` when no explicit
    /// `ELDR_ACP_CONTEXT_FILE` is set. Injected (not hard-coded to ~/.config) so
    /// unit tests stay home-directory-free — pass `nil` to disable auto-discovery.
    private let configDir: String?
    private let maxIterations: Int
    /// Stream the final answer to the client token-by-token (`agent_message_chunk`
    /// per delta) instead of one message at end-of-turn. Tool-call turns are never
    /// streamed (they produce no visible text). Off for echo/tests via `ELDR_ACP_STREAM`.
    private let streamingEnabled: Bool
    /// Wall-clock backstop for a single model call: `runTurn` races each completion
    /// against this so a wedged model (or one that streams forever) ends the turn
    /// instead of hanging. Mirrors `LLMConfig.requestTimeoutSeconds`.
    private let requestTimeoutSeconds: Double
    /// The advertised, executable skills (ACP slash-commands). Derived from config
    /// once at init; empty when skills are disabled.
    private let skills: AgentSkillSet
    /// Optional external context manager (contextgraph). nil → local sliding-window
    /// budgeting only. When present and healthy, it assembles prior context per
    /// turn and learns each completed turn; any failure falls back to local.
    private let contextGraph: (any ContextGraphAssembling)?
    /// Cached `contextGraph.health()` result (checked once, before first use).
    private var contextGraphHealthy: Bool?

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
        maxIterations: Int = 20,
        streamingEnabled: Bool = true,
        requestTimeoutSeconds: Double = 120,
        contextGraph: (any ContextGraphAssembling)? = nil
    ) {
        self.connection = connection
        self.llm = llm
        self.toolEnvironment = toolEnvironment
        self.config = config
        self.configDir = configDir
        self.maxIterations = maxIterations
        self.streamingEnabled = streamingEnabled
        self.requestTimeoutSeconds = requestTimeoutSeconds > 0 ? requestTimeoutSeconds : 120
        self.skills = AgentSkillSet.from(config: config)
        // Build the real client from config when enabled and not injected (tests
        // inject a stub so they stay network-free).
        self.contextGraph =
            contextGraph
            ?? (config.contextGraphEnabled ? ContextGraphClient(baseURL: config.contextGraphURL) : nil)
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
            maxResultBytes: config.maxToolResultBytes,
            maxReadFileBytes: config.maxReadFileBytes)
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
        // contextgraph (optional): assemble prior context via graph/tag retrieval
        // ahead of the local sliding window. Part of the anchored leading-system
        // run, so ContextBudget.trim never drops it. Unreachable → nil → fall back.
        if let assembled = await assembledContext(for: userText), !assembled.isEmpty {
            messages.append(LLMMessage(role: .system, content: assembled))
        }
        messages.append(LLMMessage(role: .user, content: userText))

        var toolCallSeq = 0
        // Plan/TODO visibility (Phase D1): a heuristic checklist the client surfaces
        // so the user sees the agent's approach, not just raw tool calls. We can't
        // ask the model for an explicit plan without a model-protocol dependency, so
        // we DERIVE it from the tool calls the model actually makes: each tool call
        // in a turn becomes one plan entry, accumulating across iterations, and an
        // entry flips pending → in_progress → completed as that step runs. The whole
        // plan is re-emitted on each change (ACP models a plan as a full snapshot).
        // This rides alongside the existing tool_call/tool_call_update flow without
        // altering it — purely additive session/updates.
        var plan = TurnPlan()
        for _ in 0..<maxIterations {
            if cancelledSessions.contains(sessionId) { return .cancelled }

            // Context budgeting: bound the history sent to the model each turn so a
            // long tool loop (and the large results it accumulates) can't outgrow
            // the window. The system prompt + the task are always preserved.
            let outgoing = ContextBudget.trim(
                messages, maxTurns: config.maxHistoryTurns, maxChars: config.maxContextChars)

            // One model call, raced against a timeout and against an in-flight
            // session/cancel so a hung model or a mid-generation cancel aborts the
            // turn rather than blocking on `complete`. When streaming is on, the final
            // answer's deltas are forwarded to the client as they arrive.
            let response: LLMResponse
            let alreadyStreamed: String
            switch await runModelCall(sessionId: sessionId, outgoing: outgoing, tools: tools) {
            case .completed(let r, let streamed):
                response = r
                alreadyStreamed = streamed
            case .cancelled:
                return .cancelled
            case .timedOut:
                await emitMessage(
                    sessionId: sessionId,
                    text:
                        "The local model did not respond within \(Int(requestTimeoutSeconds))s "
                        + "(raise ELDR_LLM_TIMEOUT_SECONDS or check the model server).")
                return .refusal
            case .failed(let error):
                // Surface the failure to the user as a message, then end the turn.
                await emitMessage(
                    sessionId: sessionId,
                    text: "The local model call failed: \(Self.describe(error))")
                return .refusal
            }

            if cancelledSessions.contains(sessionId) { return .cancelled }

            guard response.wantsTools else {
                // Final answer. Streaming already forwarded `alreadyStreamed`; emit only
                // the remainder (the whole text when nothing streamed, e.g. tests/echo).
                let text = response.content.isEmpty
                    ? "(The model returned no final answer — only private reasoning, which is "
                        + "stripped from chat. If this is a reasoning/QAT model, switch to an "
                        + "instruct model or disable its “thinking” mode for agentic tool use.)"
                    : response.content
                let remainder = Self.remainder(of: text, afterStreaming: alreadyStreamed)
                if !remainder.isEmpty { await emitMessage(sessionId: sessionId, text: remainder) }
                logSessionEnd(sessionId: sessionId, cwd: cwd, summary: text)
                await ingestTurn(userText: userText, assistantText: text, cwd: cwd)
                return .endTurn
            }

            // Record the assistant's tool-call turn so the model sees its own calls.
            messages.append(
                LLMMessage(role: .assistant, content: response.content, toolCalls: response.toolCalls))

            // Extend the plan with this batch's steps (one entry per tool call,
            // titled like the editor's tool UI) and emit the updated snapshot before
            // running them, so the user sees the upcoming steps as `pending`.
            let newIndices = plan.addSteps(
                response.toolCalls.map { call in
                    ToolExecutor.title(for: call.name, args: call.argumentsJSON)
                })
            await emitPlan(sessionId: sessionId, plan: plan)

            // Execute each requested tool, streaming ACP tool_call lifecycle, and
            // advance the matching plan entry (in_progress while it runs, then
            // completed/failed) so the checklist tracks real progress.
            for (offset, call) in response.toolCalls.enumerated() {
                if cancelledSessions.contains(sessionId) { return .cancelled }
                toolCallSeq += 1
                let toolCallId = "\(sessionId)-tc-\(toolCallSeq)"
                let args = call.argumentsJSON
                let planIndex = newIndices[offset]
                plan.setStatus(planIndex, to: "in_progress")
                await emitPlan(sessionId: sessionId, plan: plan)
                let result = await runOneTool(
                    sessionId: sessionId, toolCallId: toolCallId, executor: executor,
                    name: call.name, args: args, cwd: cwd)
                // A step is "completed" either way — the tool_call_update already
                // carries the failed/error detail; ACP's PlanEntry status has no
                // "failed" value, so the checklist marks the step done and the user
                // reads the failure in the tool result.
                plan.setStatus(planIndex, to: "completed")
                await emitPlan(sessionId: sessionId, plan: plan)
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

    /// Assembled prior context from contextgraph, or nil to use local budgeting.
    /// Health is checked (and cached) before the first assemble; any failure → nil
    /// so the turn falls back to `ContextBudget.trim` (no turn ever fails because
    /// contextgraph is down).
    private func assembledContext(for userText: String) async -> String? {
        guard let cg = contextGraph else { return nil }
        if contextGraphHealthy == nil { contextGraphHealthy = await cg.health() }
        guard contextGraphHealthy == true else { return nil }
        do {
            // token_budget ≈ chars/4 (rough tokenizer ratio); never below 1.
            let budget = max(1, config.maxContextChars / 4)
            return try await cg.assemble(userText: userText, tokenBudget: budget)
        } catch {
            // C-6: stderr is an at-rest diagnostic sink (the launcher tees it to a
            // logfile); scrub the error text in case it echoes a request body/header.
            FileHandle.standardError.write(
                Data(config.logRedactor("contextgraph assemble failed: \(Self.describe(error))\n").utf8))
            return nil
        }
    }

    /// Record a completed turn so contextgraph learns it. Only when the service is
    /// known-healthy this turn; fire-and-forget (never fails the turn).
    private func ingestTurn(userText: String, assistantText: String, cwd: String) async {
        guard let cg = contextGraph, contextGraphHealthy == true else { return }
        let label = config.contextGraphAgentName ?? (cwd as NSString).lastPathComponent
        await cg.ingest(userText: userText, assistantText: assistantText, channelLabel: label)
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
            // Fail closed on a cancel that RACED the permission round-trip: requesting
            // permission is an `await`, so a session/cancel can land on the actor while
            // it's in flight and resolve AFTER the grant. Re-check before the
            // side-effecting `executor.run` so a cancelled turn never performs the write
            // it was mid-asking-about — the loop-top check (runTurn) is too late, the
            // mutation would already have happened.
            if cancelledSessions.contains(sessionId) {
                await connection.notify(
                    method: "session/update",
                    params: ACPWire.toolCallUpdate(
                        sessionId: sessionId, toolCallId: toolCallId, status: "failed",
                        contentText: "Cancelled before the tool ran.", isError: true))
                return ToolResult(text: "Cancelled before \(name) ran.", isError: true)
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
            // Path uses the PATH-AWARE default scrub (catches an embedded credential
            // but preserves legitimate sha256/UUID path components ContextLearner
            // reads), NOT the free-text `config.logRedactor`.
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
                session: sessionId, cwd: cwd, to: config.eventsFilePath,
                redact: config.logRedactor)
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
            to: config.eventsFilePath, redact: config.logRedactor)
    }

    /// Ask the client for permission for a mutating tool, and FAIL CLOSED. The request
    /// is time-bounded (`config.permissionTimeoutSeconds`); any non-grant outcome — an
    /// explicit deny, a timeout (the client never answered), a transport error, or a
    /// client that doesn't implement `session/request_permission` — is a DENIAL.
    /// (C-1: the previous fallback to ALLOW turned the gate into a no-op the moment a
    /// remote driver could reach it, and a non-responding client hung the turn instead.)
    /// The trusted-local case — a client the operator spawned that genuinely can't
    /// prompt — can disable the gate entirely with `ELDR_ACP_ALLOW_UNGATED_TOOLS`.
    private func requestPermission(
        sessionId: String, toolCallId: String, title: String, kind: String
    ) async -> Bool {
        // Operator explicitly disabled gating for a trusted local client that can't
        // prompt — restore allow-by-default (no wait, no prompt).
        if config.allowUngatedTools { return true }
        do {
            let result = try await connection.request(
                method: "session/request_permission",
                params: ACPWire.requestPermission(
                    sessionId: sessionId, toolCallId: toolCallId, title: title, kind: kind),
                timeout: config.permissionTimeoutSeconds)
            return ACPWire.permissionGranted(result)
        } catch {
            // Timeout / transport failure / unimplemented ⇒ DENY (fail closed).
            return false
        }
    }

    private func emitMessage(sessionId: String, text: String) async {
        await connection.notify(
            method: "session/update",
            params: ACPWire.agentMessageChunk(sessionId: sessionId, text: text))
    }

    /// Send the current plan snapshot as a `plan` session/update. No-op for an
    /// empty plan (a turn with no tool calls never has steps, so it never emits one).
    private func emitPlan(sessionId: String, plan: TurnPlan) async {
        guard !plan.isEmpty else { return }
        await connection.notify(
            method: "session/update",
            params: ACPWire.plan(sessionId: sessionId, entries: plan.entries))
    }

    // MARK: - Model call (timeout + cancel race + streaming)

    /// The outcome of one raced model call.
    private enum ModelCallOutcome {
        /// The model returned; `streamed` is the visible text already sent as
        /// `agent_message_chunk`s during streaming (empty when not streaming).
        case completed(LLMResponse, streamed: String)
        case timedOut
        case cancelled
        case failed(Error)
    }

    /// True iff the client asked to cancel this session (actor-isolated read so the
    /// racing cancel-poll can observe a session/cancel that arrives mid-generation).
    private func isCancelled(_ sessionId: String) -> Bool {
        cancelledSessions.contains(sessionId)
    }

    /// Run one model completion, racing it against (a) a wall-clock timeout and (b) an
    /// in-flight session/cancel, whichever resolves first. When streaming is enabled
    /// the final answer's deltas are forwarded to the client as `agent_message_chunk`s
    /// as they arrive; a tool-call turn produces no deltas. The non-winning racers are
    /// cancelled (which cancels the underlying URLSession request too).
    private func runModelCall(
        sessionId: String, outgoing: [LLMMessage], tools: [LLMTool]
    ) async -> ModelCallOutcome {
        let llm = self.llm
        let connection = self.connection
        let streaming = self.streamingEnabled
        let timeoutNanos = UInt64(requestTimeoutSeconds * 1_000_000_000)

        return await withTaskGroup(of: ModelCallOutcome.self) { group in
            // 1. The model call.
            group.addTask {
                let streamed = StreamedTextBox()
                do {
                    let response: LLMResponse
                    if streaming {
                        response = try await llm.stream(messages: outgoing, tools: tools) { delta in
                            await streamed.append(delta)
                            await connection.notify(
                                method: "session/update",
                                params: ACPWire.agentMessageChunk(sessionId: sessionId, text: delta))
                        }
                    } else {
                        response = try await llm.complete(messages: outgoing, tools: tools)
                    }
                    return .completed(response, streamed: await streamed.value)
                } catch {
                    return .failed(error)
                }
            }
            // 2. Timeout backstop.
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanos)
                return .timedOut
            }
            // 3. Cancel poll (session/cancel can land on the actor while we await).
            group.addTask { [weak self] in
                while !Task.isCancelled {
                    if await self?.isCancelled(sessionId) == true { return .cancelled }
                    do { try await Task.sleep(nanoseconds: 50_000_000) } catch { break }
                }
                return .cancelled
            }

            let first = await group.next() ?? .failed(LLMError.badResponse("no model outcome"))
            group.cancelAll()
            return first
        }
    }

    /// The slice of `text` not yet streamed: when `streamed` is a prefix of `text`,
    /// the unsent tail; when nothing was streamed, the whole text; otherwise (the
    /// streamed text diverged — shouldn't happen, both are reasoning-stripped) the
    /// whole text, so the client never loses the answer.
    static func remainder(of text: String, afterStreaming streamed: String) -> String {
        guard !streamed.isEmpty else { return text }
        if text == streamed { return "" }
        if text.hasPrefix(streamed) { return String(text.dropFirst(streamed.count)) }
        return text
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
              • edit_file(path, old_string, new_string): replace one exact, unique substring \
            in a file (prefer this for small edits — you don't resend the whole file).
              • list_dir(path): list a directory.
              • search(query, path): find a literal string in files (path:line:text); use it to \
            locate code before reading whole files.
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

/// A tiny actor that accumulates streamed deltas inside the model-call child task,
/// so the `@Sendable` onDelta closure has a Sendable place to write without sharing
/// mutable state across the task boundary.
private actor StreamedTextBox {
    private(set) var value = ""
    func append(_ s: String) { value += s }
}

/// The heuristic plan for a turn (Phase D1): an ordered checklist derived from the
/// tool calls the model makes, with a per-step status. Not actor state — it lives on
/// `runTurn`'s stack (the actor already serializes the turn), so a plain struct keeps
/// it simple and value-typed. Each entry's status is one of ACP's PlanEntry values
/// (pending|in_progress|completed); the wire builder fills in `priority`.
private struct TurnPlan {
    private(set) var entries: [(content: String, status: String)] = []

    var isEmpty: Bool { entries.isEmpty }

    /// Append one entry per title (all `pending`) and return their indices, so the
    /// caller can flip the right entry as each corresponding tool runs.
    mutating func addSteps(_ titles: [String]) -> [Int] {
        var indices: [Int] = []
        for title in titles {
            indices.append(entries.count)
            entries.append((content: title, status: "pending"))
        }
        return indices
    }

    /// Set one entry's status (no-op for an out-of-range index — defensive).
    mutating func setStatus(_ index: Int, to status: String) {
        guard entries.indices.contains(index) else { return }
        entries[index].status = status
    }
}
#endif  // os(macOS) — ACPAgent (node-side: tool-calling loop + ToolExecutor/Process)
