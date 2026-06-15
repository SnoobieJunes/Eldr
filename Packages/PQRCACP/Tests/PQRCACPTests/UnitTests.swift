import Foundation
import Testing

@testable import PQRCACP

@Suite("JSONValue")
struct JSONValueTests {
    @Test func parseAndAccess() throws {
        let v = try #require(JSONValue.parse(#"{"a":1,"b":"x","c":[true,null],"d":1.5}"#))
        #expect(v["a"]?.intValue == 1)
        #expect(v["b"]?.stringValue == "x")
        #expect(v["c"]?.arrayValue?.count == 2)
        #expect(v["c"]?.arrayValue?[0].boolValue == true)
        #expect(v["c"]?.arrayValue?[1].isNull == true)
        #expect(v["d"]?.intValue == 1)  // double coerced
    }

    @Test func roundTripSerialize() throws {
        let original: JSONValue = .object([
            "n": .int(3), "s": .string("hi"), "arr": .array([.bool(false)]),
        ])
        let reparsed = try #require(JSONValue.parse(original.serialized()))
        #expect(reparsed["n"]?.intValue == 3)
        #expect(reparsed["s"]?.stringValue == "hi")
        #expect(reparsed["arr"]?.arrayValue?.first?.boolValue == false)
    }

    @Test func slashesNotEscaped() {
        // ACP paths are full of slashes; the wire shouldn't escape them.
        let v: JSONValue = .object(["path": .string("/Users/x/y.swift")])
        #expect(v.serialized().contains("/Users/x/y.swift"))
    }

    @Test func parseEmptyIsNil() {
        #expect(JSONValue.parse("") == nil)
        #expect(JSONValue.parse("   ") == nil)
    }
}

@Suite("OpenAI codec")
struct OpenAICodecTests {
    @Test func decodesPlainContent() throws {
        let json = JSONValue.parse(
            #"{"choices":[{"message":{"role":"assistant","content":"hello <think>secret</think>"}}]}"#
        )!
        let response = try OpenAICompatibleLLMClient.decode(json)
        // Reasoning trace stripped.
        #expect(response.content == "hello")
        #expect(response.wantsTools == false)
    }

    @Test func decodesToolCalls() throws {
        let json = JSONValue.parse(
            #"{"choices":[{"message":{"content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"/a\"}"}}]}}]}"#
        )!
        let response = try OpenAICompatibleLLMClient.decode(json)
        #expect(response.wantsTools)
        #expect(response.toolCalls.first?.name == "read_file")
        #expect(response.toolCalls.first?.argumentsJSON["path"]?.stringValue == "/a")
    }

    @Test func decodesToolCallWithObjectArguments() throws {
        // Some servers emit `arguments` as an object instead of a JSON string.
        let json = JSONValue.parse(
            #"{"choices":[{"message":{"tool_calls":[{"id":"c1","function":{"name":"list_dir","arguments":{"path":"/x"}}}]}}]}"#
        )!
        let response = try OpenAICompatibleLLMClient.decode(json)
        #expect(response.toolCalls.first?.argumentsJSON["path"]?.stringValue == "/x")
    }

    @Test func encodesToolMessageWithToolCallId() {
        let m = LLMMessage(role: .tool, content: "result", toolCallId: "c7")
        let encoded = OpenAICompatibleLLMClient.encode(message: m)
        #expect(encoded["role"]?.stringValue == "tool")
        #expect(encoded["tool_call_id"]?.stringValue == "c7")
    }

    @Test func endpointNormalization() {
        func ep(_ s: String) -> String? {
            OpenAICompatibleLLMClient(config: .init(url: s, token: "", model: "m")).endpoint()?
                .absoluteString
        }
        #expect(ep("http://127.0.0.1:1337/v1") == "http://127.0.0.1:1337/v1/chat/completions")
        #expect(ep("http://127.0.0.1:1337") == "http://127.0.0.1:1337/v1/chat/completions")
        #expect(
            ep("http://127.0.0.1:1337/v1/chat/completions")
                == "http://127.0.0.1:1337/v1/chat/completions")
    }

    @Test func configFromEnvironmentDefaults() {
        let c = LLMConfig.fromEnvironment([:])
        #expect(c.url == "http://127.0.0.1:1337/v1")
        #expect(c.model == "local-model")
        #expect(c.token.isEmpty)
    }

    @Test func configFromEnvironmentOverrides() {
        let c = LLMConfig.fromEnvironment([
            "ELDR_LLM_URL": "http://host:9/v1", "ELDR_LLM_TOKEN": "t", "ELDR_LLM_MODEL": "qwen",
        ])
        #expect(c.url == "http://host:9/v1")
        #expect(c.token == "t")
        #expect(c.model == "qwen")
    }
}

@Suite("ReasoningTrace (vendored)")
struct ReasoningTraceTests {
    @Test func stripsThinkBlock() {
        #expect("<think>plan</think>answer".strippingReasoningTrace() == "answer")
    }
    @Test func stripsUnclosedThink() {
        #expect("partial<think>still thinking".strippingReasoningTrace() == "partial")
    }
    @Test func passesThroughPlain() {
        #expect("just text".strippingReasoningTrace() == "just text")
    }
}

@Suite("ToolExecutor")
struct ToolExecutorTests {
    private func executor(workdir: String, connection: ClientConnection? = nil) -> ToolExecutor {
        ToolExecutor(
            capabilities: ClientCapabilities(), environment: ToolEnvironment(workdir: workdir),
            connection: connection, sessionId: "s1")
    }

    @Test func writeThenReadFile_foundationFallback() async throws {
        let dir = NSTemporaryDirectory()
        let name = "eldr-acp-rw-\(UUID().uuidString).txt"
        let path = (dir as NSString).appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let ex = executor(workdir: dir)

        let write = await ex.run(
            tool: "write_file", args: .object(["path": .string(path), "content": .string("body")]))
        #expect(!write.isError)

        let read = await ex.run(tool: "read_file", args: .object(["path": .string(path)]))
        #expect(read.text == "body")
    }

    @Test func writeFile_relativePathResolvesAgainstWorkdir() async throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-acp-wd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ex = executor(workdir: dir)

        let write = await ex.run(
            tool: "write_file",
            args: .object(["path": .string("sub/file.txt"), "content": .string("x")]))
        #expect(!write.isError)
        // It landed under the workdir (parent dirs auto-created).
        let expected = (dir as NSString).appendingPathComponent("sub/file.txt")
        #expect(FileManager.default.fileExists(atPath: expected))
    }

    @Test func listDir_marksDirectories() async throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-acp-ls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: (dir as NSString).appendingPathComponent("childdir"),
            withIntermediateDirectories: true)
        try "x".data(using: .utf8)!.write(
            to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("childfile")))
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let ex = executor(workdir: dir)

        let result = await ex.run(tool: "list_dir", args: .object(["path": .string(dir)]))
        #expect(result.text.contains("childdir/"))
        #expect(result.text.contains("childfile"))
    }

    @Test func runShell_capturesOutputAndExitCode() async throws {
        let ex = executor(workdir: NSTemporaryDirectory())
        let ok = await ex.run(
            tool: "run_shell", args: .object(["command": .string("echo hello-shell")]))
        #expect(ok.text.contains("hello-shell"))
        #expect(ok.text.contains("[exit code: 0]"))
        #expect(!ok.isError)

        let fail = await ex.run(tool: "run_shell", args: .object(["command": .string("exit 3")]))
        #expect(fail.isError)
        #expect(fail.text.contains("[exit code: 3]"))
    }

    @Test func runShell_honorsDeveloperDir() async throws {
        let ex = ToolExecutor(
            capabilities: ClientCapabilities(),
            environment: ToolEnvironment(
                developerDir: "/Applications/Xcode-beta.app/Contents/Developer",
                workdir: NSTemporaryDirectory()),
            connection: nil, sessionId: "s1")
        let result = await ex.run(
            tool: "run_shell", args: .object(["command": .string("echo $DEVELOPER_DIR")]))
        #expect(result.text.contains("/Applications/Xcode-beta.app/Contents/Developer"))
    }

    @Test func toolDefinitionsCoverAllFour() {
        let names = Set(ToolExecutor.toolDefinitions().map(\.name))
        #expect(names == ["read_file", "write_file", "list_dir", "run_shell"])
    }

    @Test func permissionRequiredOnlyForMutating() {
        #expect(ToolExecutor.needsPermission("write_file"))
        #expect(ToolExecutor.needsPermission("run_shell"))
        #expect(!ToolExecutor.needsPermission("read_file"))
        #expect(!ToolExecutor.needsPermission("list_dir"))
    }
}

@Suite("ClientConnection")
struct ClientConnectionTests {
    actor BufferSink: OutputSink {
        private(set) var lines: [String] = []
        func write(line: String) async { lines.append(line) }
        func last() -> String? { lines.last }
    }

    @Test func outboundRequest_correlatesResponseById() async throws {
        let sink = BufferSink()
        let connection = ClientConnection(sink: sink)

        // Issue an outbound request in the background; it suspends awaiting a reply.
        let task = Task {
            try await connection.request(
                method: "fs/read_text_file",
                params: .object(["path": .string("/x")]))
        }
        // Let the request hit the sink, then read the id it used.
        try await Task.sleep(nanoseconds: 50_000_000)
        let sent = try #require(await sink.last())
        let id = try #require(JSONValue.parse(sent)?["id"]?.intValue)
        #expect(id < 0)  // outbound ids are negative

        // Deliver the client's response with that id.
        let response = JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .int(id),
            "result": .object(["content": .string("file-body")]),
        ])
        #expect(await connection.deliver(response: response) == true)

        let result = try await task.value
        #expect(result["content"]?.stringValue == "file-body")
    }

    @Test func outboundRequest_propagatesError() async throws {
        let sink = BufferSink()
        let connection = ClientConnection(sink: sink)
        let task = Task {
            try await connection.request(method: "terminal/create", params: .object([:]))
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let id = try #require(JSONValue.parse(await sink.last() ?? "")?["id"]?.intValue)
        let errorResponse = JSONValue.object([
            "jsonrpc": .string("2.0"), "id": .int(id),
            "error": .object(["code": .int(-32000), "message": .string("nope")]),
        ])
        _ = await connection.deliver(response: errorResponse)

        await #expect(throws: ClientConnection.ConnectionError.self) {
            _ = try await task.value
        }
    }

    @Test func deliverUnknownIdReturnsFalse() async {
        let connection = ClientConnection(sink: BufferSink())
        let stray = JSONValue.object(["id": .int(-999), "result": .object([:])])
        #expect(await connection.deliver(response: stray) == false)
    }

    @Test func notifyHasNoId() async throws {
        let sink = BufferSink()
        let connection = ClientConnection(sink: sink)
        await connection.notify(method: "session/update", params: .object(["x": .int(1)]))
        let sent = try #require(JSONValue.parse(await sink.last() ?? ""))
        #expect(sent["method"]?.stringValue == "session/update")
        #expect(sent["id"] == nil)
    }
}

@Suite("ACPWire permission")
struct ACPWirePermissionTests {
    @Test func grantedForAllowOption() {
        let r = JSONValue.object([
            "outcome": .object(["outcome": .string("selected"), "optionId": .string("allow_once")])
        ])
        #expect(ACPWire.permissionGranted(r))
    }
    @Test func deniedForRejectOption() {
        let r = JSONValue.object([
            "outcome": .object(["outcome": .string("selected"), "optionId": .string("reject_once")])
        ])
        #expect(!ACPWire.permissionGranted(r))
    }
    @Test func deniedForCancelled() {
        let r = JSONValue.object(["outcome": .object(["outcome": .string("cancelled")])])
        #expect(!ACPWire.permissionGranted(r))
    }
}
