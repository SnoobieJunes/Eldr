import Foundation
import Testing

@testable import PQRCACP

/// contextgraph integration — fully network-free via an injected stub
/// `ContextGraphAssembling`. Asserts the agent assembles + ingests when the
/// service is healthy, and falls back to local budgeting (no assemble, no
/// ingest) when it isn't.
@Suite("contextgraph")
struct ContextGraphTests {

    // MARK: Test doubles

    /// No-op output sink (we don't assert the stream here).
    actor NullSink: OutputSink {
        func write(line: String) async {}
    }

    /// Records the messages each `complete` call received, so we can assert the
    /// assembled context reached the model. Always returns a final (tool-free) answer.
    actor RecordingLLM: LLMClient {
        private(set) var received: [[LLMMessage]] = []
        func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
            received.append(messages)
            return LLMResponse(content: "done")
        }
        func calls() -> [[LLMMessage]] { received }
    }

    /// Stub contextgraph: configurable health + fixed assembled block; records ingests.
    actor StubContextGraph: ContextGraphAssembling {
        let healthy: Bool
        let assembled: String
        private(set) var ingests: [(user: String, assistant: String, label: String?)] = []
        private(set) var assembleCount = 0

        init(healthy: Bool, assembled: String) {
            self.healthy = healthy
            self.assembled = assembled
        }
        func health() async -> Bool { healthy }
        func assemble(userText: String, tokenBudget: Int) async throws -> String {
            assembleCount += 1
            return assembled
        }
        func ingest(userText: String, assistantText: String, channelLabel: String?) async {
            ingests.append((userText, assistantText, channelLabel))
        }
        func recordedIngests() -> [(user: String, assistant: String, label: String?)] { ingests }
        func assembles() -> Int { assembleCount }
    }

    // MARK: Harness

    private func runPrompt(
        contextGraph: any ContextGraphAssembling, llm: RecordingLLM, cwd: String, text: String
    ) async {
        let connection = ClientConnection(sink: NullSink())
        let env = ToolEnvironment(developerDir: nil, workdir: cwd, baseEnvironment: [:])
        let agent = ACPAgent(
            connection: connection, llm: llm, toolEnvironment: env, config: .default,
            configDir: nil, contextGraph: contextGraph)
        _ = await agent.handle(line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#)
        _ = await agent.handle(
            line:
                #"{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"\#(cwd)","mcpServers":[]}}"#
        )
        // session/new returns a generated id; re-derive it deterministically: it's
        // "eldr-session-1" for the first session of this agent.
        _ = await agent.handle(
            line:
                #"{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"eldr-session-1","prompt":[{"type":"text","text":"\#(text)"}]}}"#
        )
    }

    // MARK: Tests

    @Test func healthy_assemblesIntoContextAndIngestsTurn() async throws {
        let marker = "ASSEMBLED-CONTEXT-MARKER-42"
        let stub = StubContextGraph(healthy: true, assembled: marker)
        let llm = RecordingLLM()
        await runPrompt(contextGraph: stub, llm: llm, cwd: "/tmp/myproj", text: "hello")

        // The assembled block reached the model as a system message.
        let firstCall = try #require(await llm.calls().first)
        #expect(firstCall.contains { $0.role == .system && $0.content == marker })

        // The completed turn was ingested with the project label (cwd basename).
        let ingests = await stub.recordedIngests()
        #expect(ingests.count == 1)
        #expect(ingests.first?.user == "hello")
        #expect(ingests.first?.assistant == "done")
        #expect(ingests.first?.label == "myproj")
    }

    @Test func unhealthy_fallsBackNoAssembleNoIngest() async throws {
        let marker = "SHOULD-NOT-APPEAR"
        let stub = StubContextGraph(healthy: false, assembled: marker)
        let llm = RecordingLLM()
        await runPrompt(contextGraph: stub, llm: llm, cwd: "/tmp/myproj", text: "hello")

        let firstCall = try #require(await llm.calls().first)
        #expect(!firstCall.contains { $0.content == marker })
        #expect(await stub.assembles() == 0)
        #expect(await stub.recordedIngests().isEmpty)
    }

    // MARK: Pure helpers

    @Test func config_parsesContextGraphEnv() {
        let env = [
            "ELDR_ACP_CONTEXTGRAPH": "1",
            "ELDR_ACP_CONTEXTGRAPH_URL": "http://localhost:9999",
            "ELDR_ACP_CONTEXTGRAPH_AGENT": "proj-x",
        ]
        let config = AgentConfig.fromEnvironment(env, configDir: nil)
        #expect(config.contextGraphEnabled)
        #expect(config.contextGraphURL == "http://localhost:9999")
        #expect(config.contextGraphAgentName == "proj-x")
    }

    @Test func config_defaultsContextGraphOff() {
        let config = AgentConfig.fromEnvironment([:], configDir: nil)
        #expect(!config.contextGraphEnabled)
        #expect(config.contextGraphURL == "http://localhost:8302")
        #expect(config.contextGraphAgentName == nil)
    }

    @Test func render_joinsTurnsAndSkipsEmpty() {
        let response = ContextGraphClient.AssembleResponse(messages: [
            .init(user_text: "q1", assistant_text: "a1"),
            .init(user_text: nil, assistant_text: nil),
            .init(user_text: "q2", assistant_text: "a2"),
        ])
        let rendered = ContextGraphClient.render(response)
        #expect(rendered.contains("User: q1"))
        #expect(rendered.contains("Assistant: a2"))
        #expect(ContextGraphClient.render(.init(messages: [])).isEmpty)
    }
}
