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
        llm: any LLMClient, workdir: String? = nil
    ) -> (ACPAgent, CapturingSink) {
        let sink = CapturingSink()
        let connection = ClientConnection(sink: sink)
        let env = ToolEnvironment(developerDir: nil, workdir: workdir, baseEnvironment: [:])
        let agent = ACPAgent(connection: connection, llm: llm, toolEnvironment: env)
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
