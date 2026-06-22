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

    /// Regression: `intValue` on a non-finite or out-of-range double must return nil,
    /// not TRAP. A malformed wire field like `1e400` parses (via JSONSerialization) to
    /// `+inf`, and `Int(.infinity)` is a fatal runtime error — a remote crash the
    /// instant any `id`/`n`/`exit` field is read as Int.
    @Test func intValueOnExtremeDoubleDoesNotTrap() {
        // These all parse to ±inf or an out-of-Int64-range double.
        #expect(JSONValue.parse(#"{"id":1e400}"#)?["id"]?.intValue == nil)
        #expect(JSONValue.parse(#"{"id":-1e400}"#)?["id"]?.intValue == nil)
        #expect(JSONValue.parse(#"{"id":1e309}"#)?["id"]?.intValue == nil)
        // In-range values still coerce fine (regression guard, not over-rejecting).
        #expect(JSONValue.parse(#"{"id":42.9}"#)?["id"]?.intValue == 42)
        #expect(JSONValue.parse(#"{"id":-7}"#)?["id"]?.intValue == -7)
        #expect(JSONValue.double(.nan).intValue == nil)
        #expect(JSONValue.double(.infinity).intValue == nil)
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

    // MARK: D2 — vision encoding (test c)

    @Test func encodesPlainStringContentWhenNoImages() {
        // No image parts → `content` is the plain STRING, byte-for-byte the prior shape.
        let m = LLMMessage(role: .user, content: "hello")
        let encoded = OpenAICompatibleLLMClient.encode(message: m)
        #expect(encoded["content"]?.stringValue == "hello")
        // Specifically NOT an array.
        #expect(encoded["content"]?.arrayValue == nil)
    }

    @Test func encodesMultimodalContentArrayWhenImagesPresent() {
        let m = LLMMessage(
            role: .user, content: "what's this error?",
            imageParts: [LLMImagePart(mimeType: "image/png", base64Data: "AAAB1234")])
        let encoded = OpenAICompatibleLLMClient.encode(message: m)
        // `content` is now the OpenAI vision ARRAY, not a string.
        let parts = try? #require(encoded["content"]?.arrayValue)
        #expect(encoded["content"]?.stringValue == nil)
        #expect(parts?.count == 2)
        // [0] text part.
        #expect(parts?[0]["type"]?.stringValue == "text")
        #expect(parts?[0]["text"]?.stringValue == "what's this error?")
        // [1] image_url part with the data: URI.
        #expect(parts?[1]["type"]?.stringValue == "image_url")
        #expect(
            parts?[1]["image_url"]?["url"]?.stringValue == "data:image/png;base64,AAAB1234")
    }

    @Test func encodesImageOnlyTurnWithoutEmptyTextPart() {
        // An image with empty text emits ONLY the image part (a valid non-empty array),
        // never a stray empty text part.
        let m = LLMMessage(
            role: .user, content: "",
            imageParts: [LLMImagePart(mimeType: "image/jpeg", base64Data: "ZZ99")])
        let parts = OpenAICompatibleLLMClient.encode(message: m)["content"]?.arrayValue
        #expect(parts?.count == 1)
        #expect(parts?[0]["type"]?.stringValue == "image_url")
    }

    // MARK: D2 — egress scrub MUST NOT touch images (test d)

    @Test func scrubLeavesImagePartsIntact() {
        // A base64 image is a long high-entropy run the entropy redactor WOULD mangle
        // if applied. Build one that the generic catch-all (40+ chars, has a letter and
        // a digit) would match, plus a real secret in the TEXT so we prove the scrub
        // still fires where it should.
        let bigBase64 = String(repeating: "A1b2C3d4", count: 16)  // 128 chars, letters+digits
        let secret = "sk-abcdef0123456789ABCDEF"
        let m = LLMMessage(
            role: .user, content: "here is my key \(secret)",
            imageParts: [LLMImagePart(mimeType: "image/png", base64Data: bigBase64)])

        let scrubbed = OpenAICompatibleLLMClient.scrubbed(m)

        // The image survives byte-for-byte (mime + data), NOT redacted/mangled.
        #expect(scrubbed.imageParts.count == 1)
        #expect(scrubbed.imageParts.first?.mimeType == "image/png")
        #expect(scrubbed.imageParts.first?.base64Data == bigBase64)
        // Sanity: the same high-entropy string IS mangled when run through scrub as
        // free text — proving we deliberately bypassed it for the image.
        #expect(ACPLogRedactor.scrub(bigBase64) != bigBase64)
        // And the secret in the TEXT field was still redacted (scrub fires on content).
        #expect(!scrubbed.content.contains(secret))

        // End-to-end: the encoded vision array carries the intact base64 in its data: URI.
        let parts = OpenAICompatibleLLMClient.encode(message: scrubbed)["content"]?.arrayValue
        let imagePart = parts?.first { $0["type"]?.stringValue == "image_url" }
        #expect(
            imagePart?["image_url"]?["url"]?.stringValue
                == "data:image/png;base64,\(bigBase64)")
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

    @Test func toolDefinitionsCoverAllTools() {
        let names = Set(ToolExecutor.toolDefinitions().map(\.name))
        #expect(
            names == [
                "read_file", "write_file", "edit_file", "list_dir", "search", "run_shell",
            ])
        // The advertised set must match the declared source of truth.
        #expect(names == Set(ToolExecutor.allToolNames))
    }

    @Test func permissionRequiredOnlyForMutating() {
        #expect(ToolExecutor.needsPermission("write_file"))
        #expect(ToolExecutor.needsPermission("edit_file"))
        #expect(ToolExecutor.needsPermission("run_shell"))
        #expect(!ToolExecutor.needsPermission("read_file"))
        #expect(!ToolExecutor.needsPermission("list_dir"))
        #expect(!ToolExecutor.needsPermission("search"))
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

// MARK: - Phase 1 helpers

@Suite("AgentConfig events/context")
struct AgentConfigEventsContextTests {
    @Test func parsesEventsAndContextPaths() {
        let c = AgentConfig.fromEnvironment(
            ["ELDR_ACP_EVENTS_FILE": "/tmp/ev.jsonl", "ELDR_ACP_CONTEXT_FILE": "/tmp/ctx.md"],
            configDir: nil)
        #expect(c.eventsFilePath == "/tmp/ev.jsonl")
        #expect(c.contextFilePath == "/tmp/ctx.md")
    }

    @Test func defaultsNilAndBackwardCompatible() {
        let c = AgentConfig.fromEnvironment([:], configDir: nil)
        #expect(c.eventsFilePath == nil)
        #expect(c.contextFilePath == nil)
        // The new fields don't disturb the existing defaults.
        #expect(c.maxToolResultBytes == AgentConfig.default.maxToolResultBytes)
    }
}

@Suite("Prompt content blocks (embedded context)")
struct PromptContentBlockTests {
    @Test func handlesCodeAndCompilationErrorBlocks() {
        let prompt: JSONValue = .array([
            .object(["type": "text", "text": "Fix this:"]),
            .object([
                "type": "code", "language": "swift", "path": "A.swift", "text": "let x = 1",
            ]),
            .object(["type": "compilation_error", "path": "A.swift", "text": "cannot find 'y'"]),
            .object(["type": "image", "data": "BASE64IMAGEPAYLOAD"]),  // ignored
        ])
        let text = ACPAgent.extractPromptText(prompt)
        #expect(text.contains("Fix this:"))
        #expect(text.contains("```swift"))
        #expect(text.contains("let x = 1"))
        #expect(text.contains("// A.swift"))
        #expect(text.contains("Compilation error at A.swift"))
        #expect(text.contains("cannot find 'y'"))
        // The image block is dropped entirely.
        #expect(!text.contains("BASE64IMAGEPAYLOAD"))
    }

    @Test func plainTextBlocksStillWork() {
        let prompt: JSONValue = .array([
            .object(["type": "text", "text": "one"]),
            .object(["type": "text", "text": "two"]),
        ])
        #expect(ACPAgent.extractPromptText(prompt) == "one\ntwo")
    }

    // MARK: D2 — image block parsing (node-side)

    @Test func extractImageParts_parsesDataAndMimeType() {
        // ACP image block: {type:"image", data:<base64>, mimeType:<mime>}.
        let prompt: JSONValue = .array([
            .object(["type": "text", "text": "see screenshot"]),
            .object([
                "type": "image", "mimeType": "image/png", "data": "iVBORw0KGgo=",
            ]),
        ])
        let parts = ACPAgent.extractImageParts(prompt)
        #expect(parts.count == 1)
        #expect(parts.first?.mimeType == "image/png")
        #expect(parts.first?.base64Data == "iVBORw0KGgo=")
        // Text extraction still drops the image (it carries no renderable text).
        #expect(ACPAgent.extractPromptText(prompt) == "see screenshot")
    }

    @Test func extractImageParts_skipsBlocksMissingFields() {
        // Missing `data` or `mimeType` → skipped (forward-compatible, never fatal).
        let prompt: JSONValue = .array([
            .object(["type": "image", "data": "abc"]),  // no mimeType
            .object(["type": "image", "mimeType": "image/png"]),  // no data
            .object(["type": "text", "text": "hi"]),
        ])
        #expect(ACPAgent.extractImageParts(prompt).isEmpty)
    }

    @Test func extractImageParts_emptyForPlainText() {
        let prompt: JSONValue = .array([.object(["type": "text", "text": "just text"])])
        #expect(ACPAgent.extractImageParts(prompt).isEmpty)
    }
}

@Suite("ACPAgent shell helpers")
struct ACPAgentShellHelperTests {
    @Test func parseShellExit_readsTrailingMarker() {
        #expect(ACPAgent.parseShellExit(from: "out\n[exit code: 0]") == 0)
        #expect(ACPAgent.parseShellExit(from: "boom\n[exit code: 3]") == 3)
        #expect(ACPAgent.parseShellExit(from: "x\n[exit code: unknown]") == -1)
        #expect(ACPAgent.parseShellExit(from: "no marker here") == -1)
    }

    @Test func isBuildCommand_detectsBuildsAndTests() {
        #expect(ACPAgent.isBuildCommand("xcodebuild -scheme X build"))
        #expect(ACPAgent.isBuildCommand("swift build -c release"))
        #expect(ACPAgent.isBuildCommand("SWIFT BUILD"))  // case-insensitive
        #expect(ACPAgent.isBuildCommand("swift test"))
        #expect(!ACPAgent.isBuildCommand("echo hi"))
        #expect(!ACPAgent.isBuildCommand("ls -la"))
    }

    @Test func resolvePath_matchesExecutorResolution() {
        #expect(ACPAgent.resolvePath("/abs/path.swift", cwd: "/work") == "/abs/path.swift")
        #expect(ACPAgent.resolvePath("rel/path.swift", cwd: "/work") == "/work/rel/path.swift")
    }
}

@Suite("ProjectContext")
struct ProjectContextTests {
    @Test func identityIsStableAndDependsOnCwd() {
        let a = ProjectContext.identity(forCwd: "/Users/x/proj")
        let b = ProjectContext.identity(forCwd: "/Users/x/proj")
        let c = ProjectContext.identity(forCwd: "/Users/x/other")
        #expect(a == b)  // stable across calls
        #expect(a != c)  // distinct projects → distinct ids
        #expect(a.count == 64)  // SHA-256 hex
        #expect(a.allSatisfy { $0.isHexDigit })
    }

    @Test func memoryPathPlacesEldrMdUnderProjectsHash() {
        let path = ProjectContext.memoryPath(configDir: "/cfg", cwd: "/Users/x/proj")
        let id = ProjectContext.identity(forCwd: "/Users/x/proj")
        #expect(path == "/cfg/projects/\(id)/eldr.md")
    }

    @Test func readPrefersExplicitThenAutoElseNil() throws {
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-pc-\(UUID().uuidString)")
        let cfg = (base as NSString).appendingPathComponent("cfg")
        let cwd = (base as NSString).appendingPathComponent("proj")
        let explicit = (base as NSString).appendingPathComponent("explicit.md")
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        // Nothing yet → nil.
        #expect(ProjectContext.read(explicitPath: explicit, configDir: cfg, cwd: cwd) == nil)

        // Auto path present → found.
        let auto = ProjectContext.memoryPath(configDir: cfg, cwd: cwd)
        try FileManager.default.createDirectory(
            atPath: (auto as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "AUTO".data(using: .utf8)!.write(to: URL(fileURLWithPath: auto))
        #expect(ProjectContext.read(explicitPath: nil, configDir: cfg, cwd: cwd) == "AUTO")

        // Explicit present → wins over auto.
        try "EXPLICIT".data(using: .utf8)!.write(to: URL(fileURLWithPath: explicit))
        #expect(ProjectContext.read(explicitPath: explicit, configDir: cfg, cwd: cwd) == "EXPLICIT")
    }
}

@Suite("eldr-acp executable")
struct ExecutableVersionTests {
    /// Package root derived from this source file: <pkg>/Tests/PQRCACPTests/<file>.
    static var packageRoot: String {
        ((((#filePath as NSString).deletingLastPathComponent) as NSString).deletingLastPathComponent
            as NSString).deletingLastPathComponent
    }

    /// The first existing pre-built `eldr-acp` (debug or release). We do NOT build it
    /// here: spawning `swift build`/`swift run` from inside `swift test` deadlocks on
    /// the SwiftPM `.build/.lock` the outer run still holds. The documented flow is
    /// `swift build` then `swift test`, so the binary is present when this runs.
    static var prebuiltBinary: String? {
        let pkg = packageRoot
        for config in ["debug", "release"] {
            let path = (pkg as NSString).appendingPathComponent(".build/\(config)/eldr-acp")
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    @Test func versionFlagPrintsNameAndVersion() throws {
        guard let binary = Self.prebuiltBinary else {
            // Not built yet (clean `swift test` without a prior `swift build`).
            // Verified end-to-end via Bash in the build flow instead; skip here.
            return
        }
        let output = try capture(binary, ["--version"])
        #expect(
            output.trimmingCharacters(in: .whitespacesAndNewlines)
                == "eldr-acp/\(ACPAgent.agentVersion)")
        #expect(output.contains("eldr-acp/0.1.0"))
    }

    @Test func versionConstantIsSourceOfTruth() {
        // The flag prints exactly this; pin it so a bump is deliberate.
        #expect(ACPAgent.agentVersion == "0.1.0")
    }

    private func capture(_ launch: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
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
