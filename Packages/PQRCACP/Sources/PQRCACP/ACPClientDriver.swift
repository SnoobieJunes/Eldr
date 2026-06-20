import Foundation

// The CLIENT half of ACP — the counterpart to `ACPAgent`. An ACP client spawns the
// `eldr-acp` agent over stdio and drives it: `initialize → session/new →
// session/prompt`, while servicing the agent's OUTBOUND requests
// (`session/request_permission`, `fs/read_text_file`, `fs/write_text_file`) and
// rendering its `session/update` notifications. Until now the only client was
// Xcode-beta, so there was no way to run the agent by hand or from another Swift
// program; `ACPClientDriver` is that reusable seam — `eldr-acp-run` (terminal REPL)
// and the PQRC watch-along bridge both drive the agent through it.
//
// Transport framing is identical to the agent's: newline-delimited JSON-RPC 2.0.
// Our request ids are POSITIVE (the agent's outbound ids are negative), so the two
// id spaces never collide. The driver either SPAWNS the agent (piped stdin/stdout)
// or ATTACHES to a provided handle pair (tests/bridge supply their own).

/// The client-side decisions and render callbacks the driver needs. A struct of
/// `@Sendable` closures (not a protocol) so a caller fills in only what it cares
/// about — the terminal runner renders everything, the bridge collects the final
/// answer and silences the rest. All default to no-ops / permissive.
public struct ACPClientHandler: Sendable {
    /// A streamed slice of the assistant's answer (`agent_message_chunk`).
    public var onAgentMessageChunk: @Sendable (_ text: String) async -> Void
    /// A tool call entered the `pending` state (about to run).
    public var onToolCall:
        @Sendable (_ toolCallId: String, _ title: String, _ kind: String, _ status: String) async ->
            Void
    /// A tool call advanced (`in_progress`/`completed`/`failed`), with any result text.
    public var onToolCallUpdate:
        @Sendable (_ toolCallId: String, _ status: String, _ content: String?, _ isError: Bool)
            async -> Void
    /// The agent advertised its slash-commands/skills for the session.
    public var onAvailableCommands: @Sendable (_ names: [String]) async -> Void
    /// Decide a mutating tool's permission request. Default: allow.
    public var requestPermission: @Sendable (_ title: String, _ kind: String) async -> Bool
    /// Serve a client-side file read (only reached if fs caps are advertised); nil →
    /// tell the agent to fall back to its own filesystem. Default: nil.
    public var readTextFile: @Sendable (_ path: String) async -> String?
    /// Serve a client-side file write (only reached if fs caps are advertised);
    /// false → error back so the agent falls back. Default: false.
    public var writeTextFile: @Sendable (_ path: String, _ content: String) async -> Bool

    public init(
        onAgentMessageChunk: @escaping @Sendable (String) async -> Void = { _ in },
        onToolCall: @escaping @Sendable (String, String, String, String) async -> Void = {
            _, _, _, _ in
        },
        onToolCallUpdate: @escaping @Sendable (String, String, String?, Bool) async -> Void = {
            _, _, _, _ in
        },
        onAvailableCommands: @escaping @Sendable ([String]) async -> Void = { _ in },
        requestPermission: @escaping @Sendable (String, String) async -> Bool = { _, _ in true },
        readTextFile: @escaping @Sendable (String) async -> String? = { _ in nil },
        writeTextFile: @escaping @Sendable (String, String) async -> Bool = { _, _ in false }
    ) {
        self.onAgentMessageChunk = onAgentMessageChunk
        self.onToolCall = onToolCall
        self.onToolCallUpdate = onToolCallUpdate
        self.onAvailableCommands = onAvailableCommands
        self.requestPermission = requestPermission
        self.readTextFile = readTextFile
        self.writeTextFile = writeTextFile
    }
}

/// What `start()` resolved: the session to prompt and the agent's self-description.
public struct ACPSessionInfo: Sendable {
    public let sessionId: String
    public let agentName: String?
    public let agentVersion: String?
    public let availableCommands: [String]
}

public enum ACPClientError: Error, Sendable, Equatable {
    case notStarted
    case agentExited
    case rpc(code: Int, message: String)
    case malformed(String)
    case protocolError(String)
}

public actor ACPClientDriver {
    /// How the agent process is provided.
    private enum Transport {
        /// Spawn `eldr-acp` ourselves.
        case spawn(executableURL: URL, arguments: [String], environment: [String: String])
        /// Attach to an already-running pair (input = where WE write, output = where
        /// WE read). Used by tests and the in-process bridge.
        case attach(input: FileHandle, output: FileHandle)
        /// Drive the agent over an abstract `ACPTransport` (Multipeer / LAN / in-memory)
        /// — no Process, no FileHandle. The phone path (Phase 1).
        case preset(any ACPTransport)
    }

    private let transport: Transport
    private let handler: ACPClientHandler
    /// Capabilities we advertise at `initialize`. Default: none — the agent then does
    /// its own filesystem/shell I/O directly (which is what a real-files runner wants);
    /// advertise fs/terminal only if you intend to serve those via the handler.
    private let capabilities: ClientCapabilities

    private var process: Process?
    private var inputHandle: FileHandle?
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var sessionId: String?
    private var readerTask: Task<Void, Never>?
    private var started = false

    /// Spawn a fresh `eldr-acp` at `executableURL`. `environmentOverrides` are merged
    /// over the inherited process environment (which already carries `ELDR_LLM_*`,
    /// `ELDR_WORKDIR`, `DEVELOPER_DIR` when exported by the launcher).
    public init(
        executableURL: URL, arguments: [String] = [],
        environmentOverrides: [String: String] = [:],
        handler: ACPClientHandler = ACPClientHandler(),
        capabilities: ClientCapabilities = ClientCapabilities()
    ) {
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in environmentOverrides { environment[key] = value }
        self.transport = .spawn(
            executableURL: executableURL, arguments: arguments, environment: environment)
        self.handler = handler
        self.capabilities = capabilities
    }

    /// Attach to an already-running agent over the given handles.
    public init(
        input: FileHandle, output: FileHandle,
        handler: ACPClientHandler = ACPClientHandler(),
        capabilities: ClientCapabilities = ClientCapabilities()
    ) {
        self.transport = .attach(input: input, output: output)
        self.handler = handler
        self.capabilities = capabilities
    }

    /// Drive the agent over an abstract `ACPTransport` (Phase 1): the phone speaks ACP to
    /// a remote agent over Multipeer/LAN, and tests speak it over an in-memory pair — the
    /// same protocol logic, no stdio.
    public init(
        transport: any ACPTransport,
        handler: ACPClientHandler = ACPClientHandler(),
        capabilities: ClientCapabilities = ClientCapabilities()
    ) {
        self.transport = .preset(transport)
        self.handler = handler
        self.capabilities = capabilities
    }

    // MARK: - Lifecycle

    /// Spawn (if spawning), begin reading, then `initialize` + `session/new`. Returns
    /// the live session to prompt. Idempotent guard: calling twice throws.
    @discardableResult
    public func start(cwd: String? = nil) async throws -> ACPSessionInfo {
        guard !started else { throw ACPClientError.protocolError("already started") }
        started = true
        // Writing to a pipe whose peer has gone away (agent exited, handles closed at
        // teardown) raises SIGPIPE, which would kill the whole process. Ignore it so a
        // broken pipe surfaces as a catchable write error instead.
        signal(SIGPIPE, SIG_IGN)

        switch transport {
        case .spawn(let executableURL, let arguments, let environment):
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = environment
            let inPipe = Pipe()
            let outPipe = Pipe()
            process.standardInput = inPipe
            process.standardOutput = outPipe
            // Leave the agent's stderr inherited so its `eldr-acp:` diagnostics show.
            do { try process.run() } catch {
                throw ACPClientError.protocolError(
                    "could not launch \(executableURL.path): \(error.localizedDescription)")
            }
            self.process = process
            self.inputHandle = inPipe.fileHandleForWriting
            startReader(on: outPipe.fileHandleForReading)
        case .attach(let input, let output):
            self.inputHandle = input
            startReader(on: output)
        case .preset(let acpTransport):
            // Abstract transport: consume its line stream directly — no Process, no
            // FileHandle. Writes go out via `acpTransport.send` (see `writeLine`).
            readerTask = Task { [weak self] in
                for await line in acpTransport.inboundLines() { await self?.route(line) }
                await self?.failAll(ACPClientError.agentExited)
            }
        }

        // initialize → capture agentInfo + any commands advertised here.
        let initResult = try await request(
            method: "initialize", params: Self.initializeParams(capabilities: capabilities))
        let agentName = initResult["agentInfo"]?["name"]?.stringValue
        let agentVersion = initResult["agentInfo"]?["version"]?.stringValue
        var commands = Self.commandNames(initResult["agentCapabilities"]?["availableCommands"])

        // session/new → the session id we prompt against.
        var newParams: [String: JSONValue] = ["mcpServers": .array([])]
        if let cwd { newParams["cwd"] = .string(cwd) }
        let newResult = try await request(method: "session/new", params: .object(newParams))
        guard let sid = newResult["sessionId"]?.stringValue else {
            throw ACPClientError.protocolError("session/new returned no sessionId")
        }
        sessionId = sid
        // session/new also advertises commands via a session/update; if it arrived
        // before this point the handler already saw it. Surface what initialize gave.
        if commands.isEmpty { commands = [] }
        return ACPSessionInfo(
            sessionId: sid, agentName: agentName, agentVersion: agentVersion,
            availableCommands: commands)
    }

    /// Send one `session/prompt` and return its `stopReason` (e.g. `end_turn`,
    /// `cancelled`, `refusal`). `session/update`s stream to the handler meanwhile.
    public func prompt(_ text: String) async throws -> String {
        guard let sessionId else { throw ACPClientError.notStarted }
        let result = try await request(
            method: "session/prompt",
            params: .object([
                "sessionId": .string(sessionId),
                "prompt": .array([
                    .object(["type": .string("text"), "text": .string(text)])
                ]),
            ]))
        return result["stopReason"]?.stringValue ?? "end_turn"
    }

    /// Ask the agent to cancel the in-flight turn (a fire-and-forget notification).
    public func cancel() async {
        guard let sessionId else { return }
        await notify(
            method: "session/cancel", params: .object(["sessionId": .string(sessionId)]))
    }

    /// Tear down: stop reading, close our write end, terminate a spawned process, and
    /// fail any outstanding requests.
    public func shutdown() async {
        readerTask?.cancel()
        readerTask = nil
        if case .preset(let acpTransport) = transport { acpTransport.close() }
        try? inputHandle?.close()
        inputHandle = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        failAll(ACPClientError.agentExited)
    }

    // MARK: - Reader

    private func startReader(on handle: FileHandle) {
        let stream = AsyncStream<String> { continuation in
            let splitter = LineSplitter()
            handle.readabilityHandler = { fh in
                let data = fh.availableData
                if data.isEmpty {  // EOF: agent closed stdout / exited
                    fh.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                for line in splitter.feed(data) { continuation.yield(line) }
            }
            continuation.onTermination = { _ in handle.readabilityHandler = nil }
        }
        readerTask = Task { [weak self] in
            for await line in stream {
                await self?.route(line)
            }
            // Stream ended → the agent's stdout closed. Fail anything still waiting.
            await self?.failAll(ACPClientError.agentExited)
        }
    }

    /// Route one inbound line: a response to OUR request, an agent→client REQUEST
    /// (has method + id), or a notification (has method, no id).
    private func route(_ line: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let message = JSONValue.parse(trimmed) else { return }

        if message["method"] == nil {
            // Response to one of our requests.
            deliver(response: message)
            return
        }
        guard let method = message["method"]?.stringValue else { return }
        let params = message["params"] ?? .object([:])

        if let id = message["id"] {
            // A REQUEST from the agent — handle on its own Task so a slow handler
            // (a permission prompt awaiting the user) doesn't stall the read loop.
            Task { await self.handleAgentRequest(method: method, id: id, params: params) }
        } else {
            await dispatchNotification(method: method, params: params)
        }
    }

    /// Render a `session/update` (the only notification the agent emits).
    private func dispatchNotification(method: String, params: JSONValue) async {
        guard method == "session/update", let update = params["update"] else { return }
        switch update["sessionUpdate"]?.stringValue {
        case "agent_message_chunk":
            if let text = update["content"]?["text"]?.stringValue {
                await handler.onAgentMessageChunk(text)
            }
        case "tool_call":
            await handler.onToolCall(
                update["toolCallId"]?.stringValue ?? "",
                update["title"]?.stringValue ?? "",
                update["kind"]?.stringValue ?? "other",
                update["status"]?.stringValue ?? "pending")
        case "tool_call_update":
            await handler.onToolCallUpdate(
                update["toolCallId"]?.stringValue ?? "",
                update["status"]?.stringValue ?? "",
                Self.toolUpdateText(update["content"]),
                Self.toolUpdateIsError(update["content"]))
        case "available_commands_update":
            await handler.onAvailableCommands(
                Self.commandNames(update["availableCommands"]))
        default:
            break  // unknown updates ignored (forward-compat)
        }
    }

    /// Service an agent→client request and send the response.
    private func handleAgentRequest(method: String, id: JSONValue, params: JSONValue) async {
        switch method {
        case "session/request_permission":
            let title = params["toolCall"]?["title"]?.stringValue ?? ""
            let kind = params["toolCall"]?["kind"]?.stringValue ?? "other"
            let allowed = await handler.requestPermission(title, kind)
            await respond(
                id: id,
                result: .object([
                    "outcome": .object([
                        "outcome": .string("selected"),
                        "optionId": .string(allowed ? "allow_once" : "reject_once"),
                    ])
                ]))
        case "fs/read_text_file":
            let path = params["path"]?.stringValue ?? ""
            if let content = await handler.readTextFile(path) {
                await respond(id: id, result: .object(["content": .string(content)]))
            } else {
                await respondError(id: id, code: -32603, message: "read not served by client")
            }
        case "fs/write_text_file":
            let path = params["path"]?.stringValue ?? ""
            let content = params["content"]?.stringValue ?? ""
            if await handler.writeTextFile(path, content) {
                await respond(id: id, result: .object([:]))
            } else {
                await respondError(id: id, code: -32603, message: "write not served by client")
            }
        default:
            await respondError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - JSON-RPC plumbing

    /// Send a request and await the agent's response (resolved by `route`).
    private func request(method: String, params: JSONValue) async throws -> JSONValue {
        guard readerTask != nil else { throw ACPClientError.notStarted }
        let id = nextRequestID
        nextRequestID += 1
        let envelope: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string(method),
            "params": params,
        ])
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            writeLine(envelope.serialized())
        }
    }

    private func notify(method: String, params: JSONValue) async {
        let envelope: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params,
        ])
        writeLine(envelope.serialized())
    }

    private func respond(id: JSONValue, result: JSONValue) async {
        writeLine(
            JSONValue.object([
                "jsonrpc": .string("2.0"), "id": id, "result": result,
            ]).serialized())
    }

    private func respondError(id: JSONValue, code: Int, message: String) async {
        writeLine(
            JSONValue.object([
                "jsonrpc": .string("2.0"), "id": id,
                "error": .object(["code": .int(code), "message": .string(message)]),
            ]).serialized())
    }

    /// Resolve the pending request matching `response`'s id.
    private func deliver(response: JSONValue) {
        guard let id = response["id"]?.intValue, let continuation = pending[id] else { return }
        pending[id] = nil
        if let error = response["error"] {
            continuation.resume(
                throwing: ACPClientError.rpc(
                    code: error["code"]?.intValue ?? -32603,
                    message: error["message"]?.stringValue ?? "agent error"))
        } else {
            continuation.resume(returning: response["result"] ?? .object([:]))
        }
    }

    private func failAll(_ error: Error) {
        let waiters = pending.values
        pending.removeAll()
        for continuation in waiters { continuation.resume(throwing: error) }
    }

    /// Write one JSON-RPC line out: over the abstract transport for the preset path,
    /// else to the agent's stdin (spawn/attach).
    private func writeLine(_ line: String) {
        if case .preset(let acpTransport) = transport {
            acpTransport.send(line)
        } else if let inputHandle {
            try? inputHandle.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    // MARK: - Static helpers

    static func initializeParams(capabilities: ClientCapabilities) -> JSONValue {
        .object([
            "protocolVersion": .int(ACPAgent.protocolVersion),
            "clientCapabilities": .object([
                "fs": .object([
                    "readTextFile": .bool(capabilities.fsReadTextFile),
                    "writeTextFile": .bool(capabilities.fsWriteTextFile),
                ]),
                "terminal": .bool(capabilities.terminal),
            ]),
        ])
    }

    /// Pull the `name` field out of each availableCommands entry.
    static func commandNames(_ commands: JSONValue?) -> [String] {
        commands?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
    }

    /// Flatten a tool_call_update `content` array to its text (content or error block).
    static func toolUpdateText(_ content: JSONValue?) -> String? {
        guard let blocks = content?.arrayValue else { return nil }
        for block in blocks {
            if let text = block["content"]?["text"]?.stringValue { return text }
            if let error = block["error"]?.stringValue { return error }
        }
        return nil
    }

    static func toolUpdateIsError(_ content: JSONValue?) -> Bool {
        content?.arrayValue?.contains { $0["type"]?.stringValue == "error" } ?? false
    }
}

/// Accumulates raw pipe bytes and yields complete newline-delimited lines, holding
/// any trailing partial line until its newline arrives. `@unchecked Sendable`: the
/// only caller is a single `FileHandle.readabilityHandler`, which Foundation invokes
/// serially on one private queue, so there is never concurrent access to `buffer`.
private final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()

    func feed(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        let newline = UInt8(ascii: "\n")
        while let index = buffer.firstIndex(of: newline) {
            let lineData = buffer[buffer.startIndex..<index]
            lines.append(String(decoding: lineData, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...index)
        }
        return lines
    }
}
