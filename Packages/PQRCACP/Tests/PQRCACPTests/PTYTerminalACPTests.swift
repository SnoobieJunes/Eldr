import Foundation
import Testing

@testable import PQRCACP

// Phase D4 — the INTERACTIVE PTY terminal driven THROUGH the ACP agent (node side):
// the model calls `open_terminal`, the agent spawns a real `PTYProcess`, its output
// streams to the client as `terminal_output` session/updates, the client writes stdin
// via `terminal/input`, and `terminal/release` (the phone's Stop) kills it. macOS-only
// (PTYProcess + ACPAgent are node-side). Hermetic: scripted LLM, no network.
//
// The phone-side CONSENT GATE (the standing autonomous-changes consent, fail-closed
// without it) is tested at the App layer (PersonaRuntime). Here we use
// `allowUngatedTools` so the node's C-1 permission round-trip is satisfied and we can
// exercise the MECHANISM + the safeguards the node owns (always-killable, fail-closed
// teardown, no PTY output at rest).
#if os(macOS)
import Darwin

@Suite("Phase D4 — interactive PTY over ACP (node side)")
struct PTYTerminalACPTests {

    // MARK: Test doubles

    actor CapturingSink: OutputSink {
        private(set) var lines: [String] = []
        func write(line: String) async { lines.append(line) }
        func snapshot() -> [String] { lines }
        /// The `update` object of each session/update notification, in order.
        func updates() -> [JSONValue] {
            lines.compactMap { JSONValue.parse($0) }
                .filter { $0["method"]?.stringValue == "session/update" }
                .compactMap { $0["params"]?["update"] }
        }
        /// Concatenated `chunk` text of every `terminal_output` update.
        func terminalOutputText() -> String {
            updates()
                .filter { $0["sessionUpdate"]?.stringValue == "terminal_output" }
                .compactMap { $0["chunk"]?.stringValue }
                .joined()
        }
        func firstTerminalId() -> String? {
            updates().first { $0["sessionUpdate"]?.stringValue == "terminal_opened" }?[
                "terminalId"]?.stringValue
        }
        func sawClosed() -> Bool {
            updates().contains { $0["sessionUpdate"]?.stringValue == "terminal_closed" }
        }
        /// Parse a `CHILDPID=<n>` (digits) out of the streamed terminal output. Skips the
        /// echoed input line `CHILDPID=$!` (no digits) in favor of the real output.
        func parsedChildPID() -> pid_t? {
            let text = terminalOutputText()
            var start = text.startIndex
            while let r = text.range(of: "CHILDPID=", range: start..<text.endIndex) {
                let digits = text[r.upperBound...].prefix { $0.isNumber }
                if let n = Int32(digits), n > 0 { return n }
                start = r.upperBound
            }
            return nil
        }
    }

    /// A scripted LLM: one tool-call response (open_terminal), then a final message.
    actor ScriptedLLM: LLMClient {
        private var queue: [LLMResponse]
        init(_ responses: [LLMResponse]) { self.queue = responses }
        func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
            queue.isEmpty ? LLMResponse(content: "done") : queue.removeFirst()
        }
    }

    // MARK: Harness

    private func makeAgent(
        llm: any LLMClient, workdir: String, config: AgentConfig
    ) -> (ACPAgent, CapturingSink) {
        let sink = CapturingSink()
        let connection = ClientConnection(sink: sink)
        // A constrained env so the PTY shell is fast + deterministic.
        let env = ToolEnvironment(
            developerDir: nil, workdir: workdir,
            baseEnvironment: ["PATH": "/usr/bin:/bin", "TERM": "dumb"])
        let agent = ACPAgent(
            connection: connection, llm: llm, toolEnvironment: env, config: config,
            configDir: nil, streamingEnabled: false)
        return (agent, sink)
    }

    private func newSession(_ agent: ACPAgent) async throws -> String {
        _ = await agent.handle(line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#)
        let raw = await agent.handle(
            line: #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{}}"#)
        let rawLine = try #require(raw)
        let result = try #require(JSONValue.parse(rawLine))
        return try #require(result["result"]?["sessionId"]?.stringValue)
    }

    /// Drive a `session/prompt` on its own task (the turn awaits nothing here since the
    /// tool is ungated), returning when it completes.
    private func prompt(_ agent: ACPAgent, sessionId: String) async {
        _ = await agent.handle(
            line:
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"\(sessionId)\",\"prompt\":[{\"type\":\"text\",\"text\":\"go\"}]}}"
        )
    }

    private func waitUntil(
        _ timeoutMillis: Int = 5_000, _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        var waited = 0
        while waited < timeoutMillis {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
            waited += 20
        }
        return await condition()
    }

    // MARK: - (1) open_terminal spawns a PTY whose output streams to the client

    @Test func openTerminal_streamsOutput_thenKillClosesIt() async throws {
        let dir = NSTemporaryDirectory()
        let marker = "PTY_STREAM_\(UUID().uuidString.prefix(8))"
        // The model opens a terminal that immediately echoes the marker.
        let openCall = LLMToolCall(
            id: "t1", name: "open_terminal",
            arguments: "{\"command\":\"echo \(marker)\"}")
        let llm = ScriptedLLM([
            LLMResponse(content: "", toolCalls: [openCall]),
            LLMResponse(content: "terminal opened"),
        ])
        let cfg = AgentConfig(allowUngatedTools: true)
        let (agent, sink) = makeAgent(llm: llm, workdir: dir, config: cfg)
        let sid = try await newSession(agent)

        await prompt(agent, sessionId: sid)

        // A terminal_opened update arrived with an id.
        let gotOpened = await waitUntil { await sink.firstTerminalId() != nil }
        #expect(gotOpened, "open_terminal must emit a terminal_opened session/update")
        let terminalId = try #require(await sink.firstTerminalId())

        // The marker streamed back as terminal_output (incremental, not buffered to EOF).
        let sawMarker = await waitUntil { await sink.terminalOutputText().contains(marker) }
        let streamSnapshot = await sink.terminalOutputText()
        #expect(
            sawMarker,
            "the PTY's output must stream as terminal_output; got: \(streamSnapshot)")

        // The agent still tracks one live terminal.
        #expect(await agent.liveTerminalCount() == 1)

        // The phone's Stop control: terminal/release kills it.
        _ = await agent.handle(
            line:
                "{\"jsonrpc\":\"2.0\",\"method\":\"terminal/release\",\"params\":{\"sessionId\":\"\(sid)\",\"terminalId\":\"\(terminalId)\"}}"
        )
        let closed = await waitUntil { await sink.sawClosed() }
        #expect(closed, "terminal/release must emit a terminal_closed update")
        #expect(await agent.liveTerminalCount() == 0, "the killed terminal is dropped")
    }

    // MARK: - (2) terminal/input writes stdin to the live shell

    @Test func terminalInput_runsInTheLiveShell() async throws {
        let dir = NSTemporaryDirectory()
        // Open a bare shell (no initial command), then drive it via terminal/input.
        let openCall = LLMToolCall(
            id: "t1", name: "open_terminal", arguments: "{\"command\":\"\"}")
        let llm = ScriptedLLM([
            LLMResponse(content: "", toolCalls: [openCall]),
            LLMResponse(content: "ready"),
        ])
        let (agent, sink) = makeAgent(llm: llm, workdir: dir, config: AgentConfig(allowUngatedTools: true))
        let sid = try await newSession(agent)
        await prompt(agent, sessionId: sid)

        #expect(await waitUntil { await sink.firstTerminalId() != nil })
        let terminalId = try #require(await sink.firstTerminalId())

        // Type a command into the live terminal.
        let marker = "INPUT_OK_\(UUID().uuidString.prefix(8))"
        let inputLine = "{\"jsonrpc\":\"2.0\",\"method\":\"terminal/input\",\"params\":{\"sessionId\":\"\(sid)\",\"terminalId\":\"\(terminalId)\",\"data\":\"echo \(marker)\\n\"}}"
        _ = await agent.handle(line: inputLine)

        let sawMarker = await waitUntil { await sink.terminalOutputText().contains(marker) }
        let inputSnapshot = await sink.terminalOutputText()
        #expect(
            sawMarker,
            "terminal/input must reach the live shell; got: \(inputSnapshot)")

        await agent.terminateAllTerminals()
    }

    // MARK: - (3) FAIL-CLOSED: terminateAllTerminals kills a live shell (teardown)

    @Test func terminateAllTerminals_killsLiveShell_noOrphan() async throws {
        let dir = NSTemporaryDirectory()
        // Open a shell and start a LONG background process whose PID it prints, so we can
        // prove the child dies on teardown (no orphan), not just the shell.
        let openCall = LLMToolCall(
            id: "t1", name: "open_terminal",
            arguments: "{\"command\":\"sleep 600 & echo CHILDPID=$!\"}")
        let llm = ScriptedLLM([
            LLMResponse(content: "", toolCalls: [openCall]),
            LLMResponse(content: "ready"),
        ])
        let (agent, sink) = makeAgent(llm: llm, workdir: dir, config: AgentConfig(allowUngatedTools: true))
        let sid = try await newSession(agent)
        await prompt(agent, sessionId: sid)

        // Read the backgrounded child's PID out of the stream (parsed inside the actor).
        let gotPID = await waitUntil(8_000) { await sink.parsedChildPID() != nil }
        let outSnapshot = await sink.terminalOutputText()
        #expect(gotPID, "could not read the backgrounded child's PID; got: \(outSnapshot)")
        let childPID = await sink.parsedChildPID() ?? 0
        #expect(kill(childPID, 0) == 0, "the child should be alive before teardown")
        #expect(await agent.liveTerminalCount() == 1)

        // FAIL-CLOSED TEARDOWN (the node-side guarantee runACPAgent invokes when the
        // transport drops): every live PTY is killed.
        await agent.terminateAllTerminals()
        #expect(await agent.liveTerminalCount() == 0)
        // Teardown announces closure too (fix #5): the phone's terminal view resolves to
        // closed instead of silently freezing when the transport drops.
        #expect(
            await waitUntil { await sink.sawClosed() },
            "teardown must emit a terminal_closed update")

        let pidForClosure = childPID
        let childGone = await waitUntil(5_000) { kill(pidForClosure, 0) != 0 }
        #expect(childGone, "teardown must kill the backgrounded child — no orphaned shell")
    }

    // MARK: - (4) session/cancel kills the session's terminals (fail-closed)

    @Test func sessionCancel_killsSessionTerminals() async throws {
        let dir = NSTemporaryDirectory()
        let openCall = LLMToolCall(
            id: "t1", name: "open_terminal", arguments: "{\"command\":\"\"}")
        let llm = ScriptedLLM([
            LLMResponse(content: "", toolCalls: [openCall]),
            LLMResponse(content: "ready"),
        ])
        let (agent, sink) = makeAgent(llm: llm, workdir: dir, config: AgentConfig(allowUngatedTools: true))
        let sid = try await newSession(agent)
        await prompt(agent, sessionId: sid)
        #expect(await waitUntil { await sink.firstTerminalId() != nil })
        #expect(await agent.liveTerminalCount() == 1)

        // A session/cancel must tear down the session's interactive terminals.
        _ = await agent.handle(
            line:
                "{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\",\"params\":{\"sessionId\":\"\(sid)\"}}"
        )
        #expect(
            await agent.liveTerminalCount() == 0,
            "a cancelled session must not leave an interactive shell running")
        // A cancel emits terminal_closed too (fix #5), so the phone's terminal view
        // resolves to closed rather than hanging on a shell that's already gone.
        #expect(
            await waitUntil { await sink.sawClosed() },
            "session/cancel must emit a terminal_closed update")
    }

    // MARK: - (5) C-6: no PTY output is written to the at-rest events log

    /// CLAUDE.md invariant 12 / C-6: the LIVE PTY stream is NEVER written at rest, and the
    /// only at-rest write for a terminal (the close event) carries no output. Plant a
    /// secret-shaped marker in the terminal's OUTPUT and assert it never lands in
    /// events.jsonl — neither raw nor as a redaction marker (because nothing about the
    /// stream is logged at all). The stream still carries it RAW to the device (the
    /// data channel is not filtered — same policy as run_shell, ACPRedactionAtRestTests).
    @Test func interactiveTerminalOutput_isNeverWrittenAtRest() async throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-pty-c6-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let eventsPath = (dir as NSString).appendingPathComponent("events.jsonl")

        let secret = "sk-PTYSECRET123abcDEF456ghi789"
        let openCall = LLMToolCall(
            id: "t1", name: "open_terminal",
            arguments: "{\"command\":\"echo \(secret)\"}")
        let llm = ScriptedLLM([
            LLMResponse(content: "", toolCalls: [openCall]),
            LLMResponse(content: "opened a terminal"),  // a benign final message
        ])
        let cfg = AgentConfig(eventsFilePath: eventsPath, allowUngatedTools: true)
        let (agent, sink) = makeAgent(llm: llm, workdir: dir, config: cfg)
        let sid = try await newSession(agent)
        await prompt(agent, sessionId: sid)

        // The secret reaches the DEVICE via the live stream (channel is raw).
        let onChannel = await waitUntil { await sink.terminalOutputText().contains(secret) }
        #expect(onChannel, "the live stream must carry the terminal output to the device (raw channel)")

        await agent.terminateAllTerminals()

        // Now inspect the at-rest log: the PTY's output must be ABSENT entirely — the live
        // stream is never logged, and the close event records only the exit code.
        if FileManager.default.fileExists(atPath: eventsPath) {
            let onDisk = String(
                decoding: try Data(contentsOf: URL(fileURLWithPath: eventsPath)), as: UTF8.self)
            #expect(!onDisk.contains(secret), "the PTY's output must never be written at rest")
            // Belt-and-suspenders: no terminal_output event type exists at rest at all.
            #expect(!onDisk.contains("terminal_output"))
        }
        // (If no events file was written at all, that trivially satisfies "never at rest".)
    }
}
#endif  // os(macOS)
