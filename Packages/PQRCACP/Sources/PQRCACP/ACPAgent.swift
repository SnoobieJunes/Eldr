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
    private let maxIterations: Int

    /// Negotiated at `initialize`. Defaults to "everything off" until then (so a
    /// stray prompt before initialize still works via Foundation fallbacks).
    private var clientCapabilities = ClientCapabilities()
    /// Live sessions: id → working directory (the `cwd` from session/new).
    private var sessions: [String: String] = [:]
    private var sessionCounter = 0
    /// Sessions the client asked to cancel; the turn loop checks this and bails.
    private var cancelledSessions: Set<String> = []

    public init(
        connection: ClientConnection,
        llm: any LLMClient,
        toolEnvironment: ToolEnvironment = .fromEnvironment(),
        maxIterations: Int = 20
    ) {
        self.connection = connection
        self.llm = llm
        self.toolEnvironment = toolEnvironment
        self.maxIterations = maxIterations
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
        case "session/new": return newSessionResult(params: params)
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
        return .object([
            "protocolVersion": .int(version),
            "agentCapabilities": .object([
                // We don't persist sessions across runs.
                "loadSession": .bool(false),
                // Text in, text out — no image/audio/embedded context yet.
                "promptCapabilities": .object([
                    "image": .bool(false),
                    "audio": .bool(false),
                    "embeddedContext": .bool(false),
                ]),
            ]),
            "agentInfo": .object([
                "name": .string(Self.agentName),
                "version": .string(Self.agentVersion),
            ]),
            // We require NO authentication: empty authMethods.
            "authMethods": .array([]),
        ])
    }

    // MARK: - session/new

    private func newSessionResult(params: JSONValue) -> JSONValue {
        sessionCounter += 1
        let sessionId = "eldr-session-\(sessionCounter)"
        // Per-session cwd: the client's `cwd`, else the agent's configured workdir.
        let cwd = params["cwd"]?.stringValue ?? toolEnvironment.effectiveWorkdir
        sessions[sessionId] = cwd
        return .object(["sessionId": .string(sessionId)])
    }

    // MARK: - session/prompt (the turn)

    private func promptResult(params: JSONValue) async throws -> JSONValue {
        guard let sessionId = params["sessionId"]?.stringValue, sessions[sessionId] != nil else {
            throw RPCError(code: -32602, message: "unknown or missing sessionId")
        }
        // Fresh cancel state for this turn.
        cancelledSessions.remove(sessionId)

        let userText = Self.extractPromptText(params["prompt"])
        let stopReason = await runTurn(sessionId: sessionId, userText: userText)
        return .object(["stopReason": .string(stopReason.rawValue)])
    }

    /// Concatenate the text content blocks of a prompt into a single user string.
    /// (We advertise no image/audio support, so non-text blocks are ignored.)
    static func extractPromptText(_ prompt: JSONValue?) -> String {
        guard let blocks = prompt?.arrayValue else { return prompt?.stringValue ?? "" }
        return
            blocks
            .compactMap { block -> String? in
                guard block["type"]?.stringValue == "text" else { return nil }
                return block["text"]?.stringValue
            }
            .joined(separator: "\n")
    }

    /// The tool-calling loop. Builds the message list, calls the LLM with tool defs;
    /// on tool_calls, streams + executes each (permission-gated for mutating tools),
    /// feeds results back, and loops (≤ maxIterations). On a final assistant message,
    /// streams it as agent_message_chunk and returns end_turn.
    private func runTurn(sessionId: String, userText: String) async -> StopReason {
        let cwd = sessions[sessionId] ?? toolEnvironment.effectiveWorkdir
        var perTurnEnvironment = toolEnvironment
        perTurnEnvironment.workdir = cwd
        let executor = ToolExecutor(
            capabilities: clientCapabilities, environment: perTurnEnvironment,
            connection: connection, sessionId: sessionId)
        let tools = ToolExecutor.toolDefinitions()

        var messages: [LLMMessage] = [
            LLMMessage(role: .system, content: Self.systemPrompt(cwd: cwd)),
            LLMMessage(role: .user, content: userText),
        ]

        var toolCallSeq = 0
        for _ in 0..<maxIterations {
            if cancelledSessions.contains(sessionId) { return .cancelled }

            let response: LLMResponse
            do {
                response = try await llm.complete(messages: messages, tools: tools)
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
                    name: call.name, args: args)
                messages.append(
                    LLMMessage(role: .tool, content: result.text, toolCallId: call.id))
            }
        }

        // Hit the iteration cap without a final message.
        await emitMessage(
            sessionId: sessionId,
            text: "Reached the tool-call limit (\(maxIterations) steps) without finishing.")
        return .maxTurnRequests
    }

    /// Stream one tool call's lifecycle and run it. Mutating tools (write_file,
    /// run_shell) request permission first when the client supports it; a denial
    /// short-circuits to a failed tool_call_update and a "denied" tool result.
    private func runOneTool(
        sessionId: String, toolCallId: String, executor: ToolExecutor,
        name: String, args: JSONValue
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
        return result
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

    static func systemPrompt(cwd: String) -> String {
        """
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
          • When you build or test, run the command and report the real result; do not fabricate output.
          • When the task is done, reply with a short plain-text summary of what you did. \
        Do not include chain-of-thought.
        """
    }

    // MARK: - Helpers

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
