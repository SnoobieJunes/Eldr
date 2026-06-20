import Foundation
import Testing

@testable import PQRCACP

// Phase 1: a headless ACP round-trip — a phone-style `ACPClient` talks to a real
// `ACPAgent` over an in-memory transport PAIR, with no stdio and no radios. Covers the
// lifecycle (initialize → session/new → prompt → streamed updates → end_turn), a tool-call
// cascade surfaced as typed UI events, and permission grant vs deny driving the node's
// file I/O. This is the foundation the Multipeer/LAN transports plug into unchanged.

/// A scripted LLM for these tests: returns queued responses in order, then a terminal
/// "done". `stream` uses the protocol's default (one-shot `complete`), so it works with the
/// agent's `streamingEnabled: false` path.
private actor ScriptedLLM: LLMClient {
    private var queue: [LLMResponse]
    init(_ responses: [LLMResponse]) { self.queue = responses }
    func complete(messages: [LLMMessage], tools: [LLMTool]) async throws -> LLMResponse {
        queue.isEmpty ? LLMResponse(content: "done") : queue.removeFirst()
    }
}

@Suite("ACPClient ↔ ACPAgent round-trip (in-memory transport)")
struct ACPRoundTripTests {

    /// Wire an `ACPClient` and a `runACPAgent` over a fresh in-memory pair, with a scripted
    /// LLM. Returns the client and the agent's run Task (cancel it when done).
    private func makePair(
        llm: any LLMClient, workdir: String,
        permission: @escaping @Sendable (String, String) async -> Bool = { _, _ in true }
    ) -> (ACPClient, Task<Void, Never>) {
        let (clientSide, agentSide) = InMemoryACPTransport.makePair()
        let agentTask = Task {
            await runACPAgent(
                transport: agentSide, llm: llm,
                toolEnvironment: ToolEnvironment(workdir: workdir, baseEnvironment: [:]),
                config: .default, configDir: nil, streamingEnabled: false)
        }
        let client = ACPClient(transport: clientSide, permissionHandler: permission)
        return (client, agentTask)
    }

    /// Drain `client.events` into an array until the stream finishes (on `shutdown()`).
    private func collect(_ client: ACPClient) -> Task<[ACPUIEvent], Never> {
        Task {
            var events: [ACPUIEvent] = []
            for await event in client.events { events.append(event) }
            return events
        }
    }

    @Test func handshakeStreamsAssistantTextAndEndsTurn() async throws {
        let llm = ScriptedLLM([LLMResponse(content: "Hello from the agent.")])
        let (client, agentTask) = makePair(llm: llm, workdir: NSTemporaryDirectory())
        defer { agentTask.cancel() }
        let events = collect(client)

        let info = try await client.start()
        #expect(info.agentName == "eldr-acp")
        let stop = try await client.prompt("hi")
        #expect(stop == "end_turn")
        await client.shutdown()

        let text = await events.value.compactMap { event -> String? in
            if case .assistantText(let t) = event { return t } else { return nil }
        }.joined()
        #expect(text.contains("Hello from the agent."))
    }

    @Test func toolCallWithPermissionGrantedWritesFileAndStreamsLifecycle() async throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-rt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let target = (dir as NSString).appendingPathComponent("out.txt")

        let llm = ScriptedLLM([
            LLMResponse(
                content: "",
                toolCalls: [
                    LLMToolCall(
                        id: "w1", name: "write_file",
                        arguments: "{\"path\":\"\(target)\",\"content\":\"hello\"}")
                ]),
            LLMResponse(content: "done"),
        ])
        let (client, agentTask) = makePair(llm: llm, workdir: dir, permission: { _, _ in true })
        defer { agentTask.cancel() }
        let events = collect(client)

        _ = try await client.start()
        let stop = try await client.prompt("write it")
        #expect(stop == "end_turn")
        await client.shutdown()

        // Permission granted ⇒ the node wrote the file (under the C-2 jail: target is in cwd).
        #expect(FileManager.default.fileExists(atPath: target))
        #expect((try? String(contentsOfFile: target, encoding: .utf8)) == "hello")
        // The UI saw the tool-call lifecycle.
        let all = await events.value
        #expect(all.contains { if case .toolCall = $0 { return true } else { return false } })
        #expect(
            all.contains {
                if case .toolCallUpdate(_, "completed", _, _) = $0 { return true } else { return false }
            })
    }

    @Test func toolCallPermissionDeniedSkipsTheWrite() async throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "eldr-rt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let target = (dir as NSString).appendingPathComponent("out.txt")

        let llm = ScriptedLLM([
            LLMResponse(
                content: "",
                toolCalls: [
                    LLMToolCall(
                        id: "w1", name: "write_file",
                        arguments: "{\"path\":\"\(target)\",\"content\":\"hello\"}")
                ]),
            LLMResponse(content: "ok, skipped"),
        ])
        // The client DENIES the permission request.
        let (client, agentTask) = makePair(llm: llm, workdir: dir, permission: { _, _ in false })
        defer { agentTask.cancel() }

        _ = try await client.start()
        let stop = try await client.prompt("write it")
        #expect(stop == "end_turn")
        await client.shutdown()

        #expect(!FileManager.default.fileExists(atPath: target))  // denied ⇒ never written
    }
}
