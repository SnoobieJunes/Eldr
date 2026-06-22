import Foundation
import Testing

@testable import PQRCACP

// Phase D3 — the PQRCACP (dependency-free) half of MCP passthrough over the relay:
//   1. `ACPAgent` MERGES an injected `ExtraToolProvider`'s tools into the advertised
//      set and ROUTES a call it owns to the provider — but ONLY for a session whose
//      `session/new` advertised `mcpServers` (the phone's consent gate). Without the
//      advertisement, or without a provider, the path is fully inert.
//   2. `MCPOverRelayClient` speaks MCP JSON-RPC over an abstract `MCPLineSeam`,
//      exposing the phone's MCP tools as `mcp_`-prefixed ACP tools and carrying a
//      tool call's REDACTED result + its window-gated `isError` straight through.
//
// All hermetic: an in-memory `MCPLineSeam` pair and a tiny fake MCP server stand in
// for the relay + the phone (PQRCACP can't import PQRCMCP, so the test models the
// phone's MCP responses directly — exactly what the real phone serves).
@Suite("ExtraToolProvider + MCP-over-relay (Phase D3)")
struct ExtraToolProviderTests {

    // MARK: - In-memory MCP line seam pair

    /// One end of a cross-wired `MCPLineSeam` pair: what this end `send`s arrives on
    /// the other's `inboundLines()`. Mirrors `InMemoryACPTransport.makePair`.
    struct InMemorySeam: MCPLineSeam {
        let inbound: AsyncStream<String>
        let outbound: AsyncStream<String>.Continuation
        func inboundLines() -> AsyncStream<String> { inbound }
        func send(_ line: String) { outbound.yield(line) }
        func close() { outbound.finish() }

        static func makePair() -> (InMemorySeam, InMemorySeam) {
            var a: AsyncStream<String>.Continuation!
            let aStream = AsyncStream<String> { a = $0 }
            var b: AsyncStream<String>.Continuation!
            let bStream = AsyncStream<String> { b = $0 }
            return (
                InMemorySeam(inbound: aStream, outbound: b),
                InMemorySeam(inbound: bStream, outbound: a)
            )
        }
    }

    /// A tiny stand-in for the PHONE's `MCPServer`: reads MCP request lines off
    /// `serverSeam` and answers initialize / tools/list / tools/call. It returns
    /// REDACTED-looking results (codenames) and fails `send_as_my_ai` CLOSED unless
    /// `windowOpen`, modeling exactly what `RuntimeSecureChatBridge` + `MCPServer`
    /// enforce phone-side. Records calls so the test can assert what was forwarded.
    actor FakePhoneMCPServer {
        private let seam: any MCPLineSeam
        private let windowOpen: Bool
        private(set) var toolCalls: [(name: String, args: JSONValue)] = []
        private var task: Task<Void, Never>?

        init(seam: any MCPLineSeam, windowOpen: Bool) {
            self.seam = seam
            self.windowOpen = windowOpen
        }

        func start() {
            let stream = seam.inboundLines()
            task = Task { [weak self] in
                for await line in stream { await self?.handle(line) }
            }
        }
        func stop() { task?.cancel() }

        private func handle(_ line: String) async {
            guard let msg = JSONValue.parse(line), let id = msg["id"] else { return }
            let method = msg["method"]?.stringValue ?? ""
            switch method {
            case "initialize":
                respond(id: id, result: .object([
                    "protocolVersion": .string("2025-06-18"),
                    "capabilities": .object(["tools": .object([:])]),
                    "serverInfo": .object(["name": .string("eldrchat")]),
                ]))
            case "tools/list":
                respond(id: id, result: .object([
                    "tools": .array([
                        .object([
                            "name": .string("read_conversation"),
                            "description": .string("Read recent messages (codenames, redacted)."),
                            "inputSchema": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "conversationID": .object(["type": .string("string")])
                                ]),
                                "required": .array([.string("conversationID")]),
                            ]),
                        ]),
                        .object([
                            "name": .string("send_as_my_ai"),
                            "description": .string("Post a message labeled as the user's AI (window-gated)."),
                            "inputSchema": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "conversationID": .object(["type": .string("string")]),
                                    "text": .object(["type": .string("string")]),
                                ]),
                                "required": .array([.string("conversationID"), .string("text")]),
                            ]),
                        ]),
                    ])
                ]))
            case "tools/call":
                let name = msg["params"]?["name"]?.stringValue ?? ""
                let args = msg["params"]?["arguments"] ?? .object([:])
                toolCalls.append((name, args))
                if name == "read_conversation" {
                    // A REDACTED transcript — codenames, never real names/hex.
                    respond(id: id, result: .object([
                        "content": .array([
                            .object([
                                "type": .string("text"),
                                "text": .string("you: hi\nbrave-otter-naps-007: hello back"),
                            ])
                        ]),
                        "isError": .bool(false),
                    ]))
                } else if name == "send_as_my_ai" {
                    if windowOpen {
                        respond(id: id, result: .object([
                            "content": .array([
                                .object(["type": .string("text"), "text": .string("Sent as your AI.")])
                            ]),
                            "isError": .bool(false),
                        ]))
                    } else {
                        // The window gate: no active ai_window ⇒ MCP error result.
                        respond(id: id, result: .object([
                            "content": .array([
                                .object([
                                    "type": .string("text"),
                                    "text": .string(
                                        "No AI window is open for this conversation — open one first."),
                                ])
                            ]),
                            "isError": .bool(true),
                        ]))
                    }
                } else {
                    respondError(id: id, code: -32602, message: "unknown tool: \(name)")
                }
            default:
                respondError(id: id, code: -32601, message: "Method not found: \(method)")
            }
        }

        private func respond(id: JSONValue, result: JSONValue) {
            seam.send(JSONValue.object([
                "jsonrpc": .string("2.0"), "id": id, "result": result,
            ]).serialized())
        }
        private func respondError(id: JSONValue, code: Int, message: String) {
            seam.send(JSONValue.object([
                "jsonrpc": .string("2.0"), "id": id,
                "error": .object(["code": .int(code), "message": .string(message)]),
            ]).serialized())
        }
    }

    /// Stand up `MCPOverRelayClient` wired to a `FakePhoneMCPServer` over an in-memory
    /// seam pair. Returns both so the test can assert what the phone received.
    private func makeClientAndPhone(windowOpen: Bool) async -> (MCPOverRelayClient, FakePhoneMCPServer) {
        let (clientSeam, serverSeam) = InMemorySeam.makePair()
        let phone = FakePhoneMCPServer(seam: serverSeam, windowOpen: windowOpen)
        await phone.start()
        let client = MCPOverRelayClient(seam: clientSeam, requestTimeoutSeconds: 5)
        return (client, phone)
    }

    // MARK: - MCPOverRelayClient: handshake + tool list

    @Test func toolDefinitions_advertisesPhoneToolsPrefixed() async throws {
        let (client, phone) = await makeClientAndPhone(windowOpen: false)
        defer { Task { await phone.stop() }; Task { await client.shutdown() } }

        let tools = await client.toolDefinitions()
        let names = Set(tools.map(\.name))
        #expect(names.contains("mcp_read_conversation"), "phone tools are advertised, mcp_-prefixed")
        #expect(names.contains("mcp_send_as_my_ai"))
        // The prefix means they can NEVER collide with the built-in file/shell tools.
        for builtin in ToolExecutor.allToolNames {
            #expect(!names.contains(builtin))
        }
    }

    // MARK: - MCPOverRelayClient: a read returns the REDACTED result

    @Test func call_read_returnsRedactedTranscript() async throws {
        let (client, phone) = await makeClientAndPhone(windowOpen: false)
        defer { Task { await phone.stop() }; Task { await client.shutdown() } }

        let result = await client.call(
            name: "mcp_read_conversation",
            arguments: .object(["conversationID": .string("c1")]))
        #expect(!result.isError)
        // The text is what the phone served — codenames, no identity hex.
        #expect(result.text.contains("brave-otter-naps-007"))
        #expect(result.text.contains("you: hi"))
        // The phone received the UN-prefixed tool name.
        let calls = await phone.toolCalls
        #expect(calls.contains { $0.name == "read_conversation" })
    }

    // MARK: - MCPOverRelayClient: send fails CLOSED with no window

    @Test func call_sendAsMyAI_failsClosed_withNoWindow() async throws {
        let (client, phone) = await makeClientAndPhone(windowOpen: false)
        defer { Task { await phone.stop() }; Task { await client.shutdown() } }

        let result = await client.call(
            name: "mcp_send_as_my_ai",
            arguments: .object(["conversationID": .string("c1"), "text": .string("hi there")]))
        #expect(result.isError, "no ai_window ⇒ the phone returns isError, surfaced as a tool error")
        #expect(result.text.contains("No AI window is open"))
    }

    @Test func call_sendAsMyAI_succeeds_withWindowOpen() async throws {
        let (client, phone) = await makeClientAndPhone(windowOpen: true)
        defer { Task { await phone.stop() }; Task { await client.shutdown() } }

        let result = await client.call(
            name: "mcp_send_as_my_ai",
            arguments: .object(["conversationID": .string("c1"), "text": .string("hi there")]))
        #expect(!result.isError, "an open window allows the phone-gated send")
        #expect(result.text.contains("Sent as your AI"))
    }

    // MARK: - MCPOverRelayClient: an unknown tool is refused without a round-trip

    @Test func call_unknownTool_refusedLocally() async throws {
        let (client, phone) = await makeClientAndPhone(windowOpen: false)
        defer { Task { await phone.stop() }; Task { await client.shutdown() } }
        _ = await client.toolDefinitions()  // handshake so the advertised set is known

        let result = await client.call(name: "mcp_not_a_real_tool", arguments: .object([:]))
        #expect(result.isError)
        let calls = await phone.toolCalls
        #expect(!calls.contains { $0.name == "not_a_real_tool" }, "an unadvertised tool is never forwarded")
    }

    // MARK: - ACPAgent merge/route gating

    /// A trivial `ExtraToolProvider` that advertises one tool and records calls — so
    /// the agent-side merge/route can be asserted without a real MCP client.
    actor StubExtraTools: ExtraToolProvider {
        private(set) var called: [(name: String, args: JSONValue)] = []
        func toolDefinitions() async -> [LLMTool] {
            [
                LLMTool(
                    name: "mcp_read_conversation",
                    description: "stub chat read",
                    parameters: .object(["type": .string("object"), "properties": .object([:])]))
            ]
        }
        func call(name: String, arguments: JSONValue) async -> ToolResult {
            called.append((name, arguments))
            return ToolResult(text: "REDACTED-from-phone", isError: false)
        }
        func calls() -> [(name: String, args: JSONValue)] { called }
    }

    /// Records the tools advertised on each model call so the test can assert the
    /// merge. Optionally calls the extra tool once, then finishes.
    actor ToolWatchingLLM: LLMClient {
        private(set) var advertised: [[String]] = []
        private var queue: [LLMResponse]
        init(_ responses: [LLMResponse]) { self.queue = responses }
        func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
            advertised.append(tools.map(\.name))
            return queue.isEmpty ? LLMResponse(content: "done") : queue.removeFirst()
        }
        func advertisedNames() -> [[String]] { advertised }
    }

    actor SilentSink: OutputSink {
        func write(line: String) async {}
    }

    private func makeAgent(llm: any LLMClient, extraTools: any ExtraToolProvider) -> ACPAgent {
        ACPAgent(
            connection: ClientConnection(sink: SilentSink()), llm: llm,
            toolEnvironment: ToolEnvironment(developerDir: nil, workdir: nil, baseEnvironment: [:]),
            config: .default, configDir: nil, streamingEnabled: false, extraTools: extraTools)
    }

    /// Open a session with the given `mcpServers` advertisement and return its id.
    private func newSession(_ agent: ACPAgent, mcpServers: String) async throws -> String {
        _ = await agent.handle(
            line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}"#)
        let resp = await agent.handle(
            line:
                #"{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp","mcpServers":\#(mcpServers)}}"#
        )
        let respLine = try #require(resp)
        let json = try #require(JSONValue.parse(respLine))
        return try #require(json["result"]?["sessionId"]?.stringValue)
    }

    @Test func session_withMCPServers_mergesAndRoutesExtraTool() async throws {
        let extra = StubExtraTools()
        // The model calls the extra tool on turn 1, then finishes on turn 2.
        let llm = ToolWatchingLLM([
            LLMResponse(
                content: "",
                toolCalls: [
                    LLMToolCall(
                        id: "t1", name: "mcp_read_conversation",
                        arguments: #"{"conversationID":"c1"}"#)
                ]),
            LLMResponse(content: "summarized the chat"),
        ])
        let agent = makeAgent(llm: llm, extraTools: extra)
        let sid = try await newSession(agent, mcpServers: #"[{"name":"eldrchat","command":"x"}]"#)

        let resp = await agent.handle(
            line:
                #"{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"\#(sid)","prompt":[{"type":"text","text":"what did we say?"}]}}"#
        )
        let respLine = try #require(resp)
        let json = try #require(JSONValue.parse(respLine))
        #expect(json["result"]?["stopReason"]?.stringValue == "end_turn")

        // (a) the extra tool was ADVERTISED (merged) on the first model call.
        let advertised = await llm.advertisedNames()
        #expect(
            advertised.first?.contains("mcp_read_conversation") == true,
            "the phone's MCP tool must be merged into the advertised set")
        // …alongside the built-ins (the merge ADDS, never replaces).
        #expect(advertised.first?.contains("read_file") == true)

        // (b) the call was ROUTED to the provider, not the file/shell executor.
        let calls = await extra.calls()
        #expect(calls.count == 1)
        #expect(calls.first?.name == "mcp_read_conversation")
        #expect(calls.first?.args["conversationID"]?.stringValue == "c1")
    }

    @Test func session_withoutMCPServers_doesNotMergeOrRoute() async throws {
        let extra = StubExtraTools()
        let llm = ToolWatchingLLM([LLMResponse(content: "done")])
        let agent = makeAgent(llm: llm, extraTools: extra)
        // session/new with an EMPTY mcpServers (the no-consent / no-advertise case).
        let sid = try await newSession(agent, mcpServers: "[]")

        _ = await agent.handle(
            line:
                #"{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"\#(sid)","prompt":[{"type":"text","text":"hi"}]}}"#
        )
        let advertised = await llm.advertisedNames()
        #expect(
            advertised.first?.contains("mcp_read_conversation") == false,
            "without an mcpServers advertisement the extra tools are NOT advertised (inert)")
        // The built-ins are still there — only the passthrough is gated off.
        #expect(advertised.first?.contains("read_file") == true)
        #expect(await extra.calls().isEmpty)
    }
}
