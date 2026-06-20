import Foundation
import Testing

@testable import PQRCACP

/// C-6 canary: secrets that flow through a turn (a `run_shell` command + its echoed
/// output, a `write_file` path) MUST be redacted before they land in the node's
/// AT-REST diagnostic log (`events.jsonl`). These FAIL before C-6 (the raw secret hit
/// disk) and PASS after.
///
/// Scope guard, restated by `dataChannel_isNotRedacted`: C-6 is on-disk log hygiene,
/// NOT a channel filter. The tool result fed back to the model and the wire stream to
/// the paired device stay RAW (the owner moves their own keys between their own
/// agents freely). Only the bytes written to the log file are scrubbed.
@Suite("C-6: at-rest log redaction")
struct ACPRedactionAtRestTests {

    /// A canary unlikely to occur by accident; `sk-…` ⇒ OpenAI/Anthropic key shape.
    static let secret = "sk-ABC123def456GHI789jkl012MNO"

    // MARK: Test doubles (mirror ACPAgentTests' harness)

    /// Scripted LLM returning queued responses, then a terminal "done".
    private actor ScriptedLLM: LLMClient {
        private var queue: [LLMResponse]
        init(_ responses: [LLMResponse]) { self.queue = responses }
        func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
            queue.isEmpty ? LLMResponse(content: "done") : queue.removeFirst()
        }
    }

    /// Captures outbound lines AND auto-grants permission requests so a mutating-tool
    /// turn doesn't hang (same shape as ACPAgentTests.AutoGrantSink).
    private actor AutoGrantSink: OutputSink {
        private(set) var lines: [String] = []
        private var connection: ClientConnection?
        func attach(_ c: ClientConnection) { connection = c }
        func snapshot() -> [String] { lines }
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

    private func makeAgent(
        llm: any LLMClient, workdir: String, config: AgentConfig
    ) async -> (ACPAgent, AutoGrantSink) {
        let sink = AutoGrantSink()
        let connection = ClientConnection(sink: sink)
        await sink.attach(connection)
        let env = ToolEnvironment(developerDir: nil, workdir: workdir, baseEnvironment: [:])
        let agent = ACPAgent(
            connection: connection, llm: llm, toolEnvironment: env, config: config,
            configDir: nil)
        return (agent, sink)
    }

    private func parse(_ string: String?) throws -> JSONValue {
        let string = try #require(string)
        return try #require(JSONValue.parse(string))
    }

    private func newSession(_ agent: ACPAgent) async throws -> String {
        _ = await agent.handle(line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#)
        return try #require(
            try parse(
                await agent.handle(
                    line: #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{}}"#))[
                "result"]?["sessionId"]?.stringValue)
    }

    // MARK: The canary

    /// Plant the secret in a `run_shell` command (which the node echoes, so it appears
    /// in the captured OUTPUT too) and in a `write_file` path. Run the turn, then read
    /// the events.jsonl BYTES: the raw secret must be ABSENT and a redaction marker
    /// PRESENT.
    @Test func secretsInShellAndWriteAreRedactedInEventsLog() async throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-acp-c6-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let eventsPath = (dir as NSString).appendingPathComponent("events.jsonl")
        // A write target whose PATH embeds the secret (paths are logged; content isn't).
        let secretTarget = (dir as NSString).appendingPathComponent("\(Self.secret).txt")

        let secret = Self.secret
        let writeCall = LLMToolCall(
            id: "w1", name: "write_file",
            arguments: "{\"path\":\"\(secretTarget)\",\"content\":\"hello\"}")
        // `echo` prints the secret to stdout → it's captured into the result text,
        // which becomes the event's `summary`. Both `cmd` and `summary` are at-rest.
        let shellCall = LLMToolCall(
            id: "s1", name: "run_shell",
            arguments: "{\"command\":\"echo \(secret)\"}")
        let llm = ScriptedLLM([
            LLMResponse(content: "", toolCalls: [writeCall]),
            LLMResponse(content: "", toolCalls: [shellCall]),
            // Final message also carries the secret → exercises session_end.summary.
            LLMResponse(content: "all done with \(secret)"),
        ])
        let cfg = AgentConfig(eventsFilePath: eventsPath)  // default redactor = ACPLogRedactor.scrub
        let (agent, _) = await makeAgent(llm: llm, workdir: dir, config: cfg)

        let sid = try await newSession(agent)
        _ = await agent.handle(
            line:
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"\(sid)\",\"prompt\":[{\"type\":\"text\",\"text\":\"go\"}]}}"
        )

        // Read the RAW BYTES on disk — not the parsed/decoded view — so we're asserting
        // exactly what an attacker reading events.jsonl would see.
        let onDisk = try Data(contentsOf: URL(fileURLWithPath: eventsPath))
        let text = String(decoding: onDisk, as: UTF8.self)

        // Sanity: the events were actually written (else the test proves nothing).
        #expect(text.contains("\"type\":\"write_file\""))
        #expect(text.contains("\"type\":\"shell_result\""))
        #expect(text.contains("\"type\":\"session_end\""))

        // The secret is GONE from every at-rest field (cmd, summary, path, end summary).
        #expect(!text.contains(secret))
        // And the redaction marker is present where it used to be.
        #expect(text.contains(ACPLogRedactor.apiKeyMarker))
    }

    /// SCOPE GUARD: the same secret reaches the model (tool result) and the wire
    /// (session/update stream) UNREDACTED. C-6 must not have broken the delivery path —
    /// the owner's own agents pass their own keys freely. Only the log file is scrubbed.
    @Test func dataChannel_isNotRedacted() async throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-acp-c6-chan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let secret = Self.secret
        let shellCall = LLMToolCall(
            id: "s1", name: "run_shell", arguments: "{\"command\":\"echo \(secret)\"}")
        let llm = ScriptedLLM([
            LLMResponse(content: "", toolCalls: [shellCall]),
            LLMResponse(content: "done"),
        ])
        // No eventsFilePath: nothing is logged at rest; we only inspect the channel.
        let (agent, sink) = await makeAgent(llm: llm, workdir: dir, config: .default)

        let sid = try await newSession(agent)
        _ = await agent.handle(
            line:
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"\(sid)\",\"prompt\":[{\"type\":\"text\",\"text\":\"go\"}]}}"
        )

        // The tool_call_update streamed to the paired device still carries the RAW
        // secret (the echoed command output) — the channel is not filtered.
        let lines = await sink.snapshot()
        let wireHasRawSecret = lines.contains { $0.contains(secret) }
        #expect(wireHasRawSecret, "C-6 must not redact the live ACP data channel")
    }

    // MARK: Unit-level proof at the write site (independent of the agent loop)

    /// `ACPLogRedactor.scrub` matches the high-risk shapes; markers never echo the
    /// secret. (Mirrors PQRCCore.CredentialRedactor's coverage.)
    @Test func redactor_scrubsCommonSecretShapes() {
        let cases = [
            "sk-ABC123def456GHI789jkl012MNO",  // OpenAI
            "sk-ant-api03-abc123DEF456ghi789",  // Anthropic
            "AKIAIOSFODNN7EXAMPLE",  // AWS access key id
            "ghp_1234567890abcdefABCDEF1234567890abcd",  // GitHub
        ]
        for raw in cases {
            let line = "leaked here: \(raw) end"
            let scrubbed = ACPLogRedactor.scrub(line)
            #expect(!scrubbed.contains(raw), "should redact \(raw)")
            #expect(scrubbed != line)
        }
        // Bearer keeps its prefix, drops the credential.
        let bearer = ACPLogRedactor.scrub("Authorization: Bearer sk-ABC123def456GHI789")
        #expect(bearer.contains("Bearer "))
        #expect(!bearer.contains("sk-ABC123def456GHI789"))
        // A plain non-secret string is returned unchanged.
        #expect(ACPLogRedactor.scrub("just a normal path /tmp/build/out.txt") == "just a normal path /tmp/build/out.txt")
    }

    /// The at-rest write site (`ACPEventLog.shellResult`) applies the default redactor
    /// even when called directly — so any caller, not just the agent loop, is covered.
    @Test func eventLogWriteSite_redactsByDefault() throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-acp-c6-direct-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let eventsPath = (dir as NSString).appendingPathComponent("events.jsonl")

        ACPEventLog.shellResult(
            cmd: "export TOKEN=\(Self.secret)", exit: 0,
            summary: "printed \(Self.secret)", session: "s", cwd: dir, to: eventsPath)

        let onDisk = try Data(contentsOf: URL(fileURLWithPath: eventsPath))
        let text = String(decoding: onDisk, as: UTF8.self)
        #expect(!text.contains(Self.secret))
        #expect(text.contains(ACPLogRedactor.apiKeyMarker))
    }

    /// The seam works: an injected custom redactor supersedes the default at the write
    /// site (proving the app can plug in PQRCCore's canonical CredentialRedactor).
    @Test func injectedRedactor_supersedesDefault() throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-acp-c6-seam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let eventsPath = (dir as NSString).appendingPathComponent("events.jsonl")

        let marker = "[[CUSTOM-SCRUBBED]]"
        ACPEventLog.shellResult(
            cmd: "echo \(Self.secret)", exit: 0, summary: "out", session: "s", cwd: dir,
            to: eventsPath, redact: { _ in marker })

        let text = String(
            decoding: try Data(contentsOf: URL(fileURLWithPath: eventsPath)), as: UTF8.self)
        #expect(text.contains(marker))
        #expect(!text.contains(Self.secret))
    }
}
