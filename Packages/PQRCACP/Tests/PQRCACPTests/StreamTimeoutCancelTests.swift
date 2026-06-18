import Foundation
import Testing

@testable import PQRCACP

// Path-1 §2/§3 coverage at the agent loop level: the final answer streams as ordered
// agent_message_chunks when streaming is on (and collapses to one chunk when off),
// a wedged model ends the turn via the timeout race, and a session/cancel that lands
// WHILE the model is generating aborts the turn. All network-free (scripted LLMs).

@Suite("ACP streaming / timeout / cancel")
struct StreamTimeoutCancelTests {

    /// Captures outbound lines; exposes the ordered text of agent_message_chunks.
    actor CapturingSink: OutputSink {
        private(set) var lines: [String] = []
        func write(line: String) async { lines.append(line) }
        func messageChunks() -> [String] {
            lines.compactMap { JSONValue.parse($0) }
                .filter { $0["method"]?.stringValue == "session/update" }
                .compactMap { $0["params"]?["update"] }
                .filter { $0["sessionUpdate"]?.stringValue == "agent_message_chunk" }
                .compactMap { $0["content"]?["text"]?.stringValue }
        }
    }

    /// Scripted streaming LLM: `stream` emits each delta in order then returns the
    /// joined content; `complete` returns the same content in one shot. Records which
    /// path was taken so the streaming gate can be asserted.
    actor ScriptedStreamingLLM: LLMClient {
        let deltas: [String]
        let finalToolCalls: [LLMToolCall]
        private(set) var streamCalls = 0
        private(set) var completeCalls = 0
        init(deltas: [String], finalToolCalls: [LLMToolCall] = []) {
            self.deltas = deltas
            self.finalToolCalls = finalToolCalls
        }
        func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
            completeCalls += 1
            return LLMResponse(content: deltas.joined(), toolCalls: finalToolCalls)
        }
        func stream(
            messages: [LLMMessage], tools: [LLMTool], onDelta: @Sendable (String) async -> Void
        ) async throws -> LLMResponse {
            streamCalls += 1
            for delta in deltas { await onDelta(delta) }
            return LLMResponse(content: deltas.joined(), toolCalls: finalToolCalls)
        }
        func streamCount() -> Int { streamCalls }
        func completeCount() -> Int { completeCalls }
    }

    /// Never returns in time: both paths sleep far past any test timeout.
    actor HangingLLM: LLMClient {
        func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return LLMResponse(content: "too late")
        }
    }

    /// Always asks for the same tool again — never a final answer — so the loop must
    /// terminate on the iteration cap.
    actor LoopingToolLLM: LLMClient {
        let path: String
        init(path: String) { self.path = path }
        func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
            LLMResponse(
                content: "",
                toolCalls: [
                    LLMToolCall(id: "loop", name: "read_file", arguments: "{\"path\":\"\(path)\"}")
                ])
        }
    }

    private func makeAgent(
        llm: any LLMClient, streaming: Bool, timeout: Double = 120
    ) -> (ACPAgent, CapturingSink) {
        let sink = CapturingSink()
        let connection = ClientConnection(sink: sink)
        let agent = ACPAgent(
            connection: connection, llm: llm,
            toolEnvironment: ToolEnvironment(workdir: NSTemporaryDirectory(), baseEnvironment: [:]),
            config: .default, configDir: nil,
            streamingEnabled: streaming, requestTimeoutSeconds: timeout)
        return (agent, sink)
    }

    private func parse(_ s: String?) throws -> JSONValue {
        let line = try #require(s)
        return try #require(JSONValue.parse(line))
    }

    private func startSession(_ agent: ACPAgent) async throws -> String {
        _ = await agent.handle(line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#)
        let newLine = await agent.handle(
            line: #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{}}"#)
        return try #require(try parse(newLine)["result"]?["sessionId"]?.stringValue)
    }

    private func promptLine(_ sid: String, _ text: String = "go") -> String {
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/prompt\",\"params\":{\"sessionId\":\"\(sid)\",\"prompt\":[{\"type\":\"text\",\"text\":\"\(text)\"}]}}"
    }

    @Test func streamingForwardsDeltasAsOrderedChunks() async throws {
        let llm = ScriptedStreamingLLM(deltas: ["Hel", "lo ", "world"])
        let (agent, sink) = makeAgent(llm: llm, streaming: true)
        let sid = try await startSession(agent)
        let response = try parse(await agent.handle(line: promptLine(sid)))
        #expect(response["result"]?["stopReason"]?.stringValue == "end_turn")

        // Each delta arrived as its own chunk, in order; nothing double-emitted at end.
        #expect(await sink.messageChunks() == ["Hel", "lo ", "world"])
        #expect(await llm.streamCount() == 1)
        #expect(await llm.completeCount() == 0)
    }

    @Test func nonStreamingEmitsSingleFinalChunk() async throws {
        let llm = ScriptedStreamingLLM(deltas: ["Hel", "lo ", "world"])
        let (agent, sink) = makeAgent(llm: llm, streaming: false)
        let sid = try await startSession(agent)
        _ = try parse(await agent.handle(line: promptLine(sid)))

        // The whole answer arrives as one chunk via the non-streaming path.
        #expect(await sink.messageChunks() == ["Hello world"])
        #expect(await llm.completeCount() == 1)
        #expect(await llm.streamCount() == 0)
    }

    @Test func timeoutEndsTurnAsRefusal() async throws {
        let (agent, sink) = makeAgent(llm: HangingLLM(), streaming: false, timeout: 0.3)
        let sid = try await startSession(agent)
        let response = try parse(await agent.handle(line: promptLine(sid)))
        #expect(response["result"]?["stopReason"]?.stringValue == "refusal")
        #expect(await sink.messageChunks().contains { $0.contains("did not respond within") })
    }

    @Test func cancelDuringGenerationStopsTurn() async throws {
        let (agent, _) = makeAgent(llm: HangingLLM(), streaming: false, timeout: 30)
        let sid = try await startSession(agent)

        // Start the turn (the model hangs), then deliver session/cancel while it's
        // mid-generation — the cancel poll must abort it well before the 30s timeout.
        async let promptResult = agent.handle(line: promptLine(sid))
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = await agent.handle(
            line:
                "{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\",\"params\":{\"sessionId\":\"\(sid)\"}}"
        )
        let response = try parse(await promptResult)
        #expect(response["result"]?["stopReason"]?.stringValue == "cancelled")
    }

    @Test func iterationCapEndsTurn() async throws {
        // A tiny real file so each looped read_file succeeds; the model never finishes,
        // so the turn must stop on the iteration cap (not spin forever).
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("cap-\(UUID().uuidString).txt")
        try "x".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let sink = CapturingSink()
        let connection = ClientConnection(sink: sink)
        let agent = ACPAgent(
            connection: connection, llm: LoopingToolLLM(path: path),
            toolEnvironment: ToolEnvironment(workdir: dir, baseEnvironment: [:]),
            config: .default, configDir: nil, maxIterations: 3,
            streamingEnabled: false, requestTimeoutSeconds: 30)
        let sid = try await startSession(agent)
        let response = try parse(await agent.handle(line: promptLine(sid)))
        #expect(response["result"]?["stopReason"]?.stringValue == "max_turn_requests")
        #expect(await sink.messageChunks().contains { $0.contains("tool-call limit") })
    }
}
