import Foundation
import Testing

@testable import PQRCACP

/// Network-free ACP protocol checks: drive `ACPAgent.handle` with JSON-RPC lines,
/// capture the outbound `session/update` stream through a fake sink, and inject a
/// scripted `MockLLMClient` so no model server (and no network) is involved.
@Suite("ACP agent")
struct ACPAgentTests {

    // MARK: Test doubles

    /// Captures every outbound line the agent writes (notifications + outbound
    /// requests), so tests can assert the session/update stream.
    actor CapturingSink: OutputSink {
        private(set) var lines: [String] = []
        func write(line: String) async { lines.append(line) }
        func snapshot() -> [String] { lines }
        /// Parsed updates: the `update` object of each session/update notification.
        func updates() -> [JSONValue] {
            lines.compactMap { JSONValue.parse($0) }
                .filter { $0["method"]?.stringValue == "session/update" }
                .compactMap { $0["params"]?["update"] }
        }
    }

    /// A scripted LLM: returns a queued response per `complete` call. Records the
    /// messages it was given so tests can assert tool results were fed back.
    actor MockLLMClient: LLMClient {
        private var queue: [LLMResponse]
        private(set) var receivedMessages: [[LLMMessage]] = []
        init(_ responses: [LLMResponse]) { self.queue = responses }
        func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
            receivedMessages.append(messages)
            if queue.isEmpty { return LLMResponse(content: "(no more scripted responses)") }
            return queue.removeFirst()
        }
        func calls() -> [[LLMMessage]] { receivedMessages }
    }

    // MARK: Harness

    private func makeAgent(
        llm: any LLMClient, workdir: String? = nil, config: AgentConfig = .default,
        configDir: String? = nil
    ) -> (ACPAgent, CapturingSink) {
        let sink = CapturingSink()
        let connection = ClientConnection(sink: sink)
        let env = ToolEnvironment(developerDir: nil, workdir: workdir, baseEnvironment: [:])
        // configDir defaults to nil so unit tests never auto-discover a project
        // eldr.md from the real home dir (hermetic; CLAUDE.md: no real home under test).
        let agent = ACPAgent(
            connection: connection, llm: llm, toolEnvironment: env, config: config,
            configDir: configDir)
        return (agent, sink)
    }

    private func parse(_ string: String?) throws -> JSONValue {
        let string = try #require(string)
        return try #require(JSONValue.parse(string))
    }

    // MARK: initialize

    @Test func initialize_advertisesV1NoAuthAndAgentInfo() async throws {
        let (agent, _) = makeAgent(llm: EchoLLMClient())
        let response = try parse(
            await agent.handle(
                line:
                    #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":true,"writeTextFile":true},"terminal":true}}}"#
            ))
        let result = try #require(response["result"])
        #expect(result["protocolVersion"]?.intValue == 1)
        // We require NO auth.
        #expect(result["authMethods"]?.arrayValue?.isEmpty == true)
        #expect(result["agentInfo"]?["name"]?.stringValue == "eldr-acp")
        // We don't persist sessions.
        #expect(result["agentCapabilities"]?["loadSession"]?.boolValue == false)
        // WS2 — the silent-bypass indicator: DEFAULT config never runs tools ungated, and
        // the node must say so honestly at initialize (the phone has no other way to know).
        #expect(result["agentCapabilities"]?["eldrAllowUngatedTools"]?.boolValue == false)
    }

    /// WS2 — when the node's `allowUngatedTools` override IS on (the Mac-side "run tools
    /// without asking" escape hatch), `initialize` must say so, so the phone can show its
    /// silent-bypass banner instead of trusting a prompt that will never come.
    @Test func initialize_advertisesUngatedToolsWhenConfigured() async throws {
        let (agent, _) = makeAgent(
            llm: EchoLLMClient(), config: AgentConfig(allowUngatedTools: true))
        let response = try parse(
            await agent.handle(
                line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#))
        #expect(response["result"]?["agentCapabilities"]?["eldrAllowUngatedTools"]?.boolValue == true)
    }

    // MARK: D2 — vision capability gate + image forwarding

    /// Pull the user message that reached the model on the FIRST completion call.
    private func firstUserMessage(_ llm: MockLLMClient) async -> LLMMessage? {
        await llm.calls().first?.first { $0.role == .user }
    }

    @Test func visionOff_advertisesImageFalse_andDropsImageBlock() async throws {
        // DEFAULT config: vision disabled. (a) image capability is false, AND an image
        // block in the prompt is dropped — never reaches the model. Today's behavior.
        let llm = MockLLMClient([LLMResponse(content: "ok")])
        let (agent, _) = makeAgent(llm: llm, config: .default)  // visionEnabled == false

        let initResult = try parse(
            await agent.handle(
                line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#))
        #expect(
            initResult["result"]?["agentCapabilities"]?["promptCapabilities"]?["image"]?
                .boolValue == false)

        let sid = try #require(
            try parse(
                await agent.handle(
                    line: #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{}}"#))[
                "result"]?["sessionId"]?.stringValue)

        // Prompt = text + an image block.
        _ = await agent.handle(
            line:
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"\(sid)\",\"prompt\":[{\"type\":\"text\",\"text\":\"look\"},{\"type\":\"image\",\"mimeType\":\"image/png\",\"data\":\"PNGBYTES1234\"}]}}"
        )

        // The model saw the TEXT but NO image part (dropped).
        let user = try #require(await firstUserMessage(llm))
        #expect(user.content == "look")
        #expect(user.imageParts.isEmpty)
    }

    @Test func visionOn_advertisesImageTrue_andForwardsImageAsMultimodal() async throws {
        // Vision ENABLED: (b) image capability is true, AND an image block becomes an
        // `LLMImagePart` on the multimodal user message handed to the model.
        let llm = MockLLMClient([LLMResponse(content: "I see a build error.")])
        let cfg = AgentConfig(visionEnabled: true)
        let (agent, _) = makeAgent(llm: llm, config: cfg)

        let initResult = try parse(
            await agent.handle(
                line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#))
        #expect(
            initResult["result"]?["agentCapabilities"]?["promptCapabilities"]?["image"]?
                .boolValue == true)

        let sid = try #require(
            try parse(
                await agent.handle(
                    line: #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{}}"#))[
                "result"]?["sessionId"]?.stringValue)

        _ = await agent.handle(
            line:
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"\(sid)\",\"prompt\":[{\"type\":\"text\",\"text\":\"debug this\"},{\"type\":\"image\",\"mimeType\":\"image/png\",\"data\":\"PNGBYTES1234\"}]}}"
        )

        let user = try #require(await firstUserMessage(llm))
        #expect(user.content == "debug this")
        #expect(user.imageParts.count == 1)
        #expect(user.imageParts.first?.mimeType == "image/png")
        #expect(user.imageParts.first?.base64Data == "PNGBYTES1234")
    }

    // MARK: session/new

    @Test func sessionNew_returnsSessionId() async throws {
        let (agent, _) = makeAgent(llm: EchoLLMClient())
        _ = await agent.handle(line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#)
        let response = try parse(
            await agent.handle(
                line:
                    #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}"#
            ))
        let sessionId = try #require(response["result"]?["sessionId"]?.stringValue)
        #expect(sessionId.hasPrefix("eldr-session-"))
    }

    // MARK: session/prompt — plain final answer

    @Test func prompt_streamsAgentMessageChunk_andEndsTurn() async throws {
        let llm = MockLLMClient([LLMResponse(content: "Hello from the model.")])
        let (agent, sink) = makeAgent(llm: llm)
        _ = await agent.handle(line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#)
        let sid = try #require(
            try parse(
                await agent.handle(
                    line: #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{}}"#))[
                "result"]?["sessionId"]?.stringValue)

        let promptResponse = try parse(
            await agent.handle(
                line:
                    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"\(sid)\",\"prompt\":[{\"type\":\"text\",\"text\":\"hi\"}]}}"
            ))

        // The turn result carries a stopReason.
        #expect(promptResponse["result"]?["stopReason"]?.stringValue == "end_turn")

        // An agent_message_chunk was streamed with the model's text.
        let updates = await sink.updates()
        let chunk = updates.first { $0["sessionUpdate"]?.stringValue == "agent_message_chunk" }
        #expect(chunk?["content"]?["text"]?.stringValue == "Hello from the model.")
    }

    // MARK: session/prompt — tool call round-trip (read_file via Foundation fallback)

    @Test func prompt_toolCall_roundTripsToCompleted_andResultFedBack() async throws {
        // Arrange a real temp file the mock will ask read_file to read (no client
        // fs caps → Foundation fallback, still network-free).
        let dir = NSTemporaryDirectory()
        let fileName = "eldr-acp-test-\(UUID().uuidString).txt"
        let filePath = (dir as NSString).appendingPathComponent(fileName)
        let contents = "secret-canary-\(UUID().uuidString)"
        try contents.data(using: .utf8)!.write(to: URL(fileURLWithPath: filePath))
        defer { try? FileManager.default.removeItem(atPath: filePath) }

        // Round 1: model asks for read_file. Round 2: model gives a final answer.
        let toolCall = LLMToolCall(
            id: "call_1", name: "read_file",
            arguments: "{\"path\":\"\(filePath)\"}")
        let llm = MockLLMClient([
            LLMResponse(content: "", toolCalls: [toolCall]),
            LLMResponse(content: "I read the file."),
        ])
        let (agent, sink) = makeAgent(llm: llm, workdir: dir)

        _ = await agent.handle(line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#)
        let sid = try #require(
            try parse(
                await agent.handle(
                    line: #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{}}"#))[
                "result"]?["sessionId"]?.stringValue)

        let promptResponse = try parse(
            await agent.handle(
                line:
                    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"\(sid)\",\"prompt\":[{\"type\":\"text\",\"text\":\"read it\"}]}}"
            ))
        #expect(promptResponse["result"]?["stopReason"]?.stringValue == "end_turn")

        let updates = await sink.updates()

        // A tool_call (pending) was streamed for read_file.
        let toolCallUpdate = updates.first { $0["sessionUpdate"]?.stringValue == "tool_call" }
        #expect(toolCallUpdate?["kind"]?.stringValue == "read")
        #expect(toolCallUpdate?["status"]?.stringValue == "pending")
        let toolCallId = try #require(toolCallUpdate?["toolCallId"]?.stringValue)

        // A tool_call_update reached "completed" for that same toolCallId.
        let completed = updates.first {
            $0["sessionUpdate"]?.stringValue == "tool_call_update"
                && $0["toolCallId"]?.stringValue == toolCallId
                && $0["status"]?.stringValue == "completed"
        }
        #expect(completed != nil)

        // The file's contents were fed back to the model as a tool message on the
        // SECOND completion call.
        let calls = await llm.calls()
        #expect(calls.count == 2)
        let secondCallMessages = calls[1]
        let toolMessage = secondCallMessages.first {
            $0.role == .tool && $0.toolCallId == "call_1"
        }
        #expect(toolMessage?.content.contains(contents) == true)
    }

    // MARK: session/cancel

    @Test func cancel_stopsTheTurn() async throws {
        // An LLM that signals cancel mid-flight: it cancels the session on its first
        // call, then would (if reached) ask for a tool. The loop must bail to
        // "cancelled" before running the tool.
        actor CancelingLLM: LLMClient {
            let agentBox: AgentBox
            let sessionIDBox: StringBox
            init(_ agentBox: AgentBox, _ sessionIDBox: StringBox) {
                self.agentBox = agentBox
                self.sessionIDBox = sessionIDBox
            }
            func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
                // Deliver a session/cancel notification, then return a tool request.
                if let agent = await agentBox.value, let sid = await sessionIDBox.value {
                    _ = await agent.handle(
                        line:
                            "{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\",\"params\":{\"sessionId\":\"\(sid)\"}}"
                    )
                }
                return LLMResponse(
                    content: "",
                    toolCalls: [
                        LLMToolCall(id: "c1", name: "run_shell", arguments: "{\"command\":\"echo hi\"}")
                    ])
            }
        }

        let agentBox = AgentBox()
        let sidBox = StringBox()
        let llm = CancelingLLM(agentBox, sidBox)
        let (agent, _) = makeAgent(llm: llm)
        await agentBox.set(agent)

        _ = await agent.handle(line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#)
        let sid = try #require(
            try parse(
                await agent.handle(
                    line: #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{}}"#))[
                "result"]?["sessionId"]?.stringValue)
        await sidBox.set(sid)

        let promptResponse = try parse(
            await agent.handle(
                line:
                    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"\(sid)\",\"prompt\":[{\"type\":\"text\",\"text\":\"go\"}]}}"
            ))
        #expect(promptResponse["result"]?["stopReason"]?.stringValue == "cancelled")
    }

    // MARK: unknown method

    @Test func unknownMethod_returnsMethodNotFound() async throws {
        let (agent, _) = makeAgent(llm: EchoLLMClient())
        let response = try parse(
            await agent.handle(line: #"{"jsonrpc":"2.0","id":9,"method":"does/notExist"}"#))
        #expect(response["error"]?["code"]?.intValue == -32601)
    }

    // MARK: notification produces no response

    @Test func notification_producesNoResponse() async {
        let (agent, _) = makeAgent(llm: EchoLLMClient())
        let response = await agent.handle(
            line: #"{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"x"}}"#)
        #expect(response == nil)
    }

    // MARK: context budgeting — a large tool result is truncated before feedback

    @Test func largeToolResult_isTruncatedBeforeFeedingBackToModel() async throws {
        // A big file the model reads; with a small per-result cap the bytes fed back
        // on the SECOND completion call must be bounded + carry the elision marker.
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("eldr-acp-flood-\(UUID().uuidString).txt")
        let big = String(repeating: "Z", count: 40_000)
        try big.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let toolCall = LLMToolCall(
            id: "call_1", name: "read_file", arguments: "{\"path\":\"\(path)\"}")
        let llm = MockLLMClient([
            LLMResponse(content: "", toolCalls: [toolCall]),
            LLMResponse(content: "done"),
        ])
        let cfg = AgentConfig(maxToolResultBytes: 4096)
        let (agent, _) = makeAgent(llm: llm, workdir: dir, config: cfg)

        _ = await agent.handle(line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#)
        let sid = try #require(
            try parse(
                await agent.handle(
                    line: #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{}}"#))[
                "result"]?["sessionId"]?.stringValue)
        _ = await agent.handle(
            line:
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"\(sid)\",\"prompt\":[{\"type\":\"text\",\"text\":\"read it\"}]}}"
        )

        let calls = await llm.calls()
        #expect(calls.count == 2)
        let toolMessage = try #require(
            calls[1].first { $0.role == .tool && $0.toolCallId == "call_1" })
        #expect(toolMessage.content.utf8.count <= 4096)  // not the full 40 KB
        #expect(toolMessage.content.contains("bytes elided"))
    }

    // MARK: context budgeting — history sent to the model is turn-bounded

    @Test func history_isTrimmedToRecentTurns() async throws {
        // Force several tool round-trips (echo a tiny file each time), with a tight
        // history cap; the final completion call must see far fewer messages than the
        // unbounded loop would have accumulated, yet still the system + task.
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("eldr-acp-hist-\(UUID().uuidString).txt")
        try "tiny".data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        func readCall(_ n: Int) -> LLMResponse {
            LLMResponse(
                content: "",
                toolCalls: [
                    LLMToolCall(id: "c\(n)", name: "read_file", arguments: "{\"path\":\"\(path)\"}")
                ])
        }
        // 6 tool turns, then a final answer.
        let llm = MockLLMClient([
            readCall(1), readCall(2), readCall(3), readCall(4), readCall(5), readCall(6),
            LLMResponse(content: "finished"),
        ])
        let cfg = AgentConfig(maxHistoryTurns: 4, maxContextChars: 0)
        let (agent, _) = makeAgent(llm: llm, workdir: dir, config: cfg)

        _ = await agent.handle(line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#)
        let sid = try #require(
            try parse(
                await agent.handle(
                    line: #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{}}"#))[
                "result"]?["sessionId"]?.stringValue)
        _ = await agent.handle(
            line:
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"\(sid)\",\"prompt\":[{\"type\":\"text\",\"text\":\"loop\"}]}}"
        )

        let calls = await llm.calls()
        // Last completion call (the 7th) saw a bounded list: system + task + ≤4 turns.
        let lastSeen = try #require(calls.last)
        #expect(lastSeen.count <= 1 /*system*/ + 1 /*task*/ + 4)
        #expect(lastSeen.first?.role == .system)
        #expect(lastSeen.contains { $0.role == .user && $0.content == "loop" })
    }

    // MARK: - Phase 1c: events.jsonl logging

    /// A sink that captures outbound lines AND auto-grants any permission request,
    /// so a turn that runs mutating tools (write_file/run_shell) doesn't hang waiting
    /// for a client that the unit harness doesn't have. (Same shape the app's
    /// in-process TestChatSession uses.)
    actor AutoGrantSink: OutputSink {
        private(set) var lines: [String] = []
        private var connection: ClientConnection?
        func attach(_ c: ClientConnection) { connection = c }
        func write(line: String) async {
            lines.append(line)
            guard let message = JSONValue.parse(line),
                message["method"]?.stringValue == "session/request_permission",
                let id = message["id"]
            else { return }
            await connection?.deliver(
                response: .object([
                    "jsonrpc": .string("2.0"), "id": id,
                    "result": .object([
                        "outcome": .object([
                            "outcome": .string("selected"), "optionId": .string("allow_once"),
                        ])
                    ]),
                ]))
        }
    }

    private func makeAutoGrantAgent(
        llm: any LLMClient, workdir: String? = nil, config: AgentConfig = .default,
        configDir: String? = nil
    ) async -> (ACPAgent, AutoGrantSink) {
        let sink = AutoGrantSink()
        let connection = ClientConnection(sink: sink)
        await sink.attach(connection)
        let env = ToolEnvironment(developerDir: nil, workdir: workdir, baseEnvironment: [:])
        let agent = ACPAgent(
            connection: connection, llm: llm, toolEnvironment: env, config: config,
            configDir: configDir)
        return (agent, sink)
    }

    @Test func eventsFile_recordsWriteShellAndSessionEnd() async throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-acp-ev-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let eventsPath = (dir as NSString).appendingPathComponent("events.jsonl")
        let targetFile = (dir as NSString).appendingPathComponent("out.txt")

        let writeCall = LLMToolCall(
            id: "w1", name: "write_file",
            arguments: "{\"path\":\"\(targetFile)\",\"content\":\"hello\"}")
        let shellCall = LLMToolCall(
            id: "s1", name: "run_shell", arguments: "{\"command\":\"echo run-canary\"}")
        let llm = MockLLMClient([
            LLMResponse(content: "", toolCalls: [writeCall]),
            LLMResponse(content: "", toolCalls: [shellCall]),
            LLMResponse(content: "all done"),
        ])
        let cfg = AgentConfig(eventsFilePath: eventsPath)
        let (agent, _) = await makeAutoGrantAgent(llm: llm, workdir: dir, config: cfg)

        _ = await agent.handle(line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#)
        let sid = try #require(
            try parse(
                await agent.handle(
                    line: #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{}}"#))[
                "result"]?["sessionId"]?.stringValue)
        _ = await agent.handle(
            line:
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"\(sid)\",\"prompt\":[{\"type\":\"text\",\"text\":\"go\"}]}}"
        )

        let events =
            try String(contentsOfFile: eventsPath, encoding: .utf8)
            .split(separator: "\n").map(String.init)
            .compactMap { JSONValue.parse($0) }

        let write = try #require(events.first { $0["type"]?.stringValue == "write_file" })
        #expect(write["path"]?.stringValue == targetFile)
        #expect(write["session"]?.stringValue == sid)
        #expect(write["cwd"]?.stringValue == dir)
        #expect(write["ts"]?.stringValue?.isEmpty == false)

        let shell = try #require(events.first { $0["type"]?.stringValue == "shell_result" })
        #expect(shell["cmd"]?.stringValue == "echo run-canary")
        #expect(shell["exit"]?.intValue == 0)
        #expect(shell["summary"]?.stringValue?.contains("run-canary") == true)

        let end = try #require(events.first { $0["type"]?.stringValue == "session_end" })
        #expect(end["files"]?.intValue == 1)
        #expect(end["build"]?.stringValue == "unknown")  // echo isn't a build command
        #expect(end["summary"]?.stringValue == "all done")
    }

    @Test func eventsFile_absentWhenNotConfigured() async throws {
        // Default config has no eventsFilePath → no file is ever created.
        let llm = MockLLMClient([LLMResponse(content: "done")])
        let (agent, _) = makeAgent(llm: llm)
        _ = await agent.handle(line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#)
        let sid = try #require(
            try parse(
                await agent.handle(
                    line: #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{}}"#))[
                "result"]?["sessionId"]?.stringValue)
        _ = await agent.handle(
            line:
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"\(sid)\",\"prompt\":[{\"type\":\"text\",\"text\":\"hi\"}]}}"
        )
        // No crash, no file — nothing to assert beyond reaching here cleanly.
        #expect(sid.hasPrefix("eldr-session-"))
    }

    // MARK: - C-1: permission gate fails closed

    /// A sink that captures outbound lines but NEVER answers session/request_permission
    /// — a client with no permission support (or one that hangs).
    actor SilentSink: OutputSink {
        private(set) var lines: [String] = []
        func write(line: String) async { lines.append(line) }
    }

    /// Drive one write_file turn against a silent client with the given config.
    private func driveWrite(target: String, dir: String, config: AgentConfig) async throws {
        let writeCall = LLMToolCall(
            id: "w1", name: "write_file",
            arguments: "{\"path\":\"\(target)\",\"content\":\"hello\"}")
        let llm = MockLLMClient([
            LLMResponse(content: "", toolCalls: [writeCall]),
            LLMResponse(content: "done"),
        ])
        let env = ToolEnvironment(developerDir: nil, workdir: dir, baseEnvironment: [:])
        let agent = ACPAgent(
            connection: ClientConnection(sink: SilentSink()), llm: llm,
            toolEnvironment: env, config: config)
        _ = await agent.handle(line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#)
        let newResult = await agent.handle(
            line: #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{}}"#)
        let sid = (try parse(newResult))["result"]?["sessionId"]?.stringValue ?? ""
        _ = await agent.handle(
            line:
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"\(sid)\",\"prompt\":[{\"type\":\"text\",\"text\":\"go\"}]}}"
        )
    }

    /// C-1: a client that never answers a permission request must NOT auto-allow a
    /// mutating tool. With a short permission timeout the request times out → DENY,
    /// so write_file never touches disk.
    @Test func mutatingToolDeniedWhenClientNeverAnswers() async throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-acp-c1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let target = (dir as NSString).appendingPathComponent("out.txt")

        try await driveWrite(
            target: target, dir: dir, config: AgentConfig(permissionTimeoutSeconds: 0.05))

        #expect(!FileManager.default.fileExists(atPath: target))  // denied ⇒ never written
    }

    /// C-1 opt-in: ELDR_ACP_ALLOW_UNGATED_TOOLS disables the gate for a trusted local
    /// client. Same silent client, opt-in true → the write goes through.
    @Test func mutatingToolAllowedWhenGatingDisabled() async throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-acp-c1opt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let target = (dir as NSString).appendingPathComponent("out.txt")

        try await driveWrite(
            target: target, dir: dir,
            config: AgentConfig(permissionTimeoutSeconds: 0.05, allowUngatedTools: true))

        #expect(FileManager.default.fileExists(atPath: target))
        #expect((try? String(contentsOfFile: target, encoding: .utf8)) == "hello")
    }

    // MARK: - WS3e: delegate_to_cloud_agent (cloud-CLI brokering) fail-closed gate

    /// The gate order matters: `cloudAgentDelegationEnabled` is checked BEFORE the
    /// harness lookup or any process spawn, so even `allowUngatedTools: true` (which
    /// skips the phone permission card entirely) must NOT let the call through when
    /// the operator's separate cloud-delegation switch is off (the default). Two
    /// INDEPENDENT gates, neither implies the other.
    @Test func delegateToCloudAgent_disabledByDefault_refusesBeforeSpawning() async throws {
        let toolCall = LLMToolCall(
            id: "d1", name: "delegate_to_cloud_agent",
            arguments: "{\"harness\":\"claude-code\",\"task\":\"do a thing\"}")
        let llm = MockLLMClient([
            LLMResponse(content: "", toolCalls: [toolCall]),
            LLMResponse(content: "done"),
        ])
        // allowUngatedTools ON: proves the DISTINCT cloudAgentDelegationEnabled gate
        // isn't just a proxy for the standing mutating-tool gate.
        let (agent, sink) = makeAgent(
            llm: llm, config: AgentConfig(allowUngatedTools: true, cloudAgentDelegationEnabled: false))
        _ = await agent.handle(line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#)
        let sid = try #require(
            try parse(
                await agent.handle(
                    line: #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{}}"#))[
                "result"]?["sessionId"]?.stringValue)
        _ = await agent.handle(
            line:
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"\(sid)\",\"prompt\":[{\"type\":\"text\",\"text\":\"go\"}]}}"
        )

        let updates = await sink.updates()
        let completed = updates.last { $0["sessionUpdate"]?.stringValue == "tool_call_update" }
        #expect(completed?["status"]?.stringValue == "failed")
        let errorText = completed?["content"]?.arrayValue?.first?["error"]?.stringValue
        #expect(errorText?.contains("disabled") == true)
    }

    /// Enabled but an unknown/unsupported harness id ⇒ a clear error, no spawn attempt —
    /// never silently falls back to SOME default harness.
    @Test func delegateToCloudAgent_unknownHarness_isRejected() async throws {
        let toolCall = LLMToolCall(
            id: "d2", name: "delegate_to_cloud_agent",
            arguments: "{\"harness\":\"not-a-real-harness\",\"task\":\"do a thing\"}")
        let llm = MockLLMClient([
            LLMResponse(content: "", toolCalls: [toolCall]),
            LLMResponse(content: "done"),
        ])
        let (agent, sink) = makeAgent(
            llm: llm, config: AgentConfig(allowUngatedTools: true, cloudAgentDelegationEnabled: true))
        _ = await agent.handle(line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#)
        let sid = try #require(
            try parse(
                await agent.handle(
                    line: #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{}}"#))[
                "result"]?["sessionId"]?.stringValue)
        _ = await agent.handle(
            line:
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"\(sid)\",\"prompt\":[{\"type\":\"text\",\"text\":\"go\"}]}}"
        )

        let updates = await sink.updates()
        let completed = updates.last { $0["sessionUpdate"]?.stringValue == "tool_call_update" }
        #expect(completed?["status"]?.stringValue == "failed")
        let errorText = completed?["content"]?.arrayValue?.first?["error"]?.stringValue
        #expect(errorText?.contains("unknown or unsupported") == true)
    }

    // MARK: - Phase 1c: project-context injection

    @Test func contextFile_injectedAsLeadingSystemMessage() async throws {
        let dir = NSTemporaryDirectory()
        let ctxPath = (dir as NSString).appendingPathComponent("eldr-ctx-\(UUID().uuidString).md")
        let canary = "PROJECT-CANARY-\(UUID().uuidString)"
        try canary.data(using: .utf8)!.write(to: URL(fileURLWithPath: ctxPath))
        defer { try? FileManager.default.removeItem(atPath: ctxPath) }

        let llm = MockLLMClient([LLMResponse(content: "ok")])
        let cfg = AgentConfig(contextFilePath: ctxPath)
        let (agent, _) = makeAgent(llm: llm, workdir: dir, config: cfg)
        _ = await agent.handle(line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#)
        let sid = try #require(
            try parse(
                await agent.handle(
                    line: #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{}}"#))[
                "result"]?["sessionId"]?.stringValue)
        _ = await agent.handle(
            line:
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"\(sid)\",\"prompt\":[{\"type\":\"text\",\"text\":\"hi\"}]}}"
        )

        let firstSeen = try #require(await llm.calls().first)
        // Leading system message = the project-context block carrying the file.
        #expect(firstSeen.first?.role == .system)
        #expect(firstSeen.first?.content.contains(canary) == true)
        #expect(firstSeen.first?.content.contains("Project Context") == true)
        // The operating system prompt and the task still follow it.
        #expect(firstSeen.count >= 3)
        #expect(firstSeen[1].role == .system)
        #expect(firstSeen.contains { $0.role == .user && $0.content == "hi" })
    }

    @Test func contextFile_autoDiscoveredByProjectIdentity() async throws {
        // No explicit ELDR_ACP_CONTEXT_FILE: the agent must find the per-project
        // eldr.md at <configDir>/projects/<sha256(cwd)>/eldr.md — proving the agent
        // and ProjectContext agree on the path math.
        let cwd = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-proj-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: cwd) }

        let configDir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-cfg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: configDir) }
        let memPath = ProjectContext.memoryPath(configDir: configDir, cwd: cwd)
        try FileManager.default.createDirectory(
            atPath: (memPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        let canary = "AUTO-CANARY-\(UUID().uuidString)"
        try canary.data(using: .utf8)!.write(to: URL(fileURLWithPath: memPath))

        let llm = MockLLMClient([LLMResponse(content: "ok")])
        let (agent, _) = makeAgent(llm: llm, workdir: cwd, config: .default, configDir: configDir)
        _ = await agent.handle(line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#)
        let sid = try #require(
            try parse(
                await agent.handle(
                    line: #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{}}"#))[
                "result"]?["sessionId"]?.stringValue)
        _ = await agent.handle(
            line:
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"\(sid)\",\"prompt\":[{\"type\":\"text\",\"text\":\"hi\"}]}}"
        )

        let firstSeen = try #require(await llm.calls().first)
        #expect(firstSeen.first?.content.contains(canary) == true)
    }
}

// Small boxes used only by the cancel test to break the agent⇄LLM construction cycle.
actor AgentBox {
    private(set) var value: ACPAgent?
    func set(_ a: ACPAgent) { value = a }
}
actor StringBox {
    private(set) var value: String?
    func set(_ s: String) { value = s }
}
